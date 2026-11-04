import SwiftUI
import ImageIO
import TesseraeKit

struct CloudSubmissionResultsSheet: View {
    let context: CloudPresentationContext
    let initialID: UUID?
    @Environment(ConnectionHost.self) private var host
    @Environment(CompanionPresentation.self) private var presentation
    @Environment(\.scenePhase) private var scenePhase
    @State private var reloadRevision = UUID()
    @State private var history: [CloudSubmissionBatch] = []
    @State private var pending: [CloudPendingInput] = []
    @State private var selectedPending: CloudPendingInput?
    @State private var error: String?
    @State private var path: [UUID]

    init(context: CloudPresentationContext, initialID: UUID?) {
        self.context = context; self.initialID = initialID
        _path = State(initialValue: initialID.map { [$0] } ?? [])
    }
    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let error { Text(error).foregroundStyle(.secondary).accessibilityIdentifier("cloud-results-error") }
                if !pending.isEmpty {
                    Section("Not Sent") {
                        ForEach(pending) { input in
                            Button { selectedPending = input } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(String(localized: input.kind == .photo ? "Photo Send" : "Current Page Refresh")).font(.headline)
                                    Text(input.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                                    Text("Open to review and explicitly continue.").font(.subheadline)
                                }
                            }
                            .accessibilityIdentifier("cloud-pending-\(input.id.uuidString)")
                        }
                    }
                }
                ForEach(history) { batch in
                    NavigationLink(value: batch.id) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(String(localized: batch.kind == .photo ? "Photo Send" : "Current Page Refresh")).font(.headline)
                            Text(batch.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                            Text("\(batch.targets.count) displays").font(.subheadline)
                        }
                    }
                    .accessibilityIdentifier("cloud-result-\(batch.id.uuidString)")
                }
                if history.isEmpty, pending.isEmpty, error == nil {
                    ContentUnavailableView("No Cloud Send Results", systemImage: "clock",
                        description: Text("Your Cloud sends and page refreshes appear here. Opening results never sends again."))
                }
            }
            .scrollContentBackground(.hidden).tesseraeScreenBackground()
            .refreshable { reloadRevision = UUID() }
            .navigationTitle("Send Results")
            .navigationDestination(for: UUID.self) { id in
                CloudSubmissionResultView(id: id, context: context) { next in path.append(next) }
            }
            .toolbar { closeToolbar }
        }
        .frame(idealWidth: 800, idealHeight: 720)
        .presentationDetents([.large])
        .sheet(item: $selectedPending, onDismiss: { reloadRevision = UUID() }) { input in
            CloudPendingInputSheet(input: input, context: context) { id in
                selectedPending = nil; path.append(id)
            }
        }
        .task(id: HistoryLoadKey(context: context, isVisible: path.isEmpty, revision: reloadRevision)) {
            guard path.isEmpty else { return }
            while !Task.isCancelled {
                do {
                    let values = try await host.cloudPendingInputs(context: context)
                    let results = try await host.cloudSubmissionHistory(context: context)
                    guard !Task.isCancelled else { return }
                    host.withCurrentCloudPresentation(context) { pending = values; history = results; error = nil }
                } catch { history = []; pending = []; self.error = error.localizedDescription; return }
                let pendingDelay = pending.map { $0.expiresAt.timeIntervalSinceNow }.filter { $0 > 0 }.min()
                guard let delay = [nextCloudResultUpdate(history), pendingDelay].compactMap({ $0 }).min() else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
        .task(id: selectedPending?.expiresAt) {
            guard let selected = selectedPending else { return }
            do { if selected.expiresAt > Date() { try await Task.sleep(for: .seconds(selected.expiresAt.timeIntervalSinceNow)) } }
            catch { return }
            if selectedPending?.id == selected.id { selectedPending = nil; reloadRevision = UUID() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if let selected = selectedPending, selected.expiresAt <= Date() { selectedPending = nil }
                reloadRevision = UUID()
            }
        }
    }
    private var closeToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close", systemImage: "xmark") { presentation.sheet = nil }
                .labelStyle(.iconOnly).accessibilityIdentifier("cloud-results-close")
        }
    }
}

private struct CloudSubmissionResultView: View {
    let id: UUID
    let context: CloudPresentationContext
    let onResent: (UUID) -> Void
    @Environment(ConnectionHost.self) private var host
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var reloadRevision = UUID()
    @State private var previewTaskID: UUID?
    @State private var batch: CloudSubmissionBatch?
    @State private var previewData: Data?
    @State private var mediaHidden = false
    @State private var selectedIDs: Set<String> = []
    @State private var decision = UUID()
    @State private var error: String?
    @State private var actionError: String?
    @State private var isResending = false
    @State private var confirmResend = false
    @State private var confirmDeleteMedia = false
    @State private var confirmDeleteResult = false
    @State private var didSetSelection = false

    var body: some View {
        Form {
            if let batch {
                Section {
                    Text(String(localized: batch.kind == .photo ? "Photo Send" : "Current Page Refresh")).font(.headline)
                    Text(batch.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                    if batch.isActive { ProgressView("Sending…").accessibilityIdentifier("cloud-result-sending") }
                    Text("Generated frames appear on the next display wake. A generated frame does not confirm that the physical screen has updated.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Displays") {
                    ForEach(batch.targets) { target in
                        Button {
                            if selectedIDs.contains(target.id) { selectedIDs.remove(target.id) }
                            else { selectedIDs.insert(target.id) }
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: selectedIDs.contains(target.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(TesseraeTheme.accent).accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(target.name).font(.headline)
                                    outcome(batch.results.first { $0.id == target.id }?.outcome)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 44)
                        }
                        .buttonStyle(.plain).disabled(batch.isActive || isResending)
                        .accessibilityElement(children: .combine)
                        .accessibilityAddTraits(selectedIDs.contains(target.id) ? .isSelected : [])
                        .accessibilityIdentifier("cloud-result-target-\(target.id)")
                    }
                }
                if let previewData, let image = UIImage(data: previewData) {
                    Section("Submitted Photo") {
                        Menu {
                            ForEach(batch.tasks.filter { $0.raster != nil }) { task in
                                Button(previewNames(batch, task: task)) { previewTaskID = task.id }
                                    .accessibilityIdentifier("cloud-result-preview-\(task.id.uuidString)")
                            }
                        } label: {
                            Label(previewNames(batch, task: previewTask(batch)), systemImage: "rectangle.on.rectangle")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("cloud-result-preview-picker")
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                            .accessibilityLabel("Submitted Photo").accessibilityIdentifier("cloud-submitted-photo")
                    }
                }
                Section {
                    Button(String(localized: batch.kind == .photo ? "Send Selected Again" : "Refresh Selected Again")) {
                        let outcomes = batch.results.filter { selectedIDs.contains($0.id) }
                        if outcomes.contains(where: { $0.outcome.needsDuplicateConfirmation }) { confirmResend = true }
                        else { resend(confirmsDuplicates: false) }
                    }
                    .disabled(batch.isActive || selectedIDs.isEmpty || isResending || mediaUnavailable(batch))
                    .accessibilityIdentifier("cloud-result-resend")
                    if mediaUnavailable(batch) {
                        Text("The photo was deleted or expired. Choose a photo to create a new send.")
                            .font(.footnote).foregroundStyle(.secondary).accessibilityIdentifier("cloud-result-media-expired")
                    }
                    if let expiry = batch.mediaExpiresAt {
                        LabeledContent("Photo Available Until", value: expiry.formatted())
                    }
                    LabeledContent("Result Available Until", value: batch.resultsExpireAt.formatted())
                        .accessibilityIdentifier("cloud-result-expiry")
                    Text("Results are kept for 30 days. Viewing them does not extend photo or result retention.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section {
                    if batch.kind == .photo {
                        Button("Delete Photo", role: .destructive) { confirmDeleteMedia = true }
                            .disabled(mediaUnavailable(batch)).accessibilityIdentifier("cloud-result-delete-photo")
                    }
                    Button("Delete Result", role: .destructive) { confirmDeleteResult = true }
                        .accessibilityIdentifier("cloud-result-delete-result")
                }
            } else {
                ContentUnavailableView("Result Unavailable", systemImage: "clock.badge.exclamationmark",
                    description: Text(actionError ?? error ?? String(localized: "Loading Cloud…")))
                    .accessibilityIdentifier("cloud-result-unavailable")
            }
            if let message = actionError ?? error { Text(message).foregroundStyle(.red).accessibilityIdentifier("cloud-result-error") }
        }
        .scrollContentBackground(.hidden).tesseraeScreenBackground()
        .navigationTitle("Send Result").navigationBarTitleDisplayMode(.inline)
        .task(id: ResultLoadKey(context: context, revision: reloadRevision)) {
            while !Task.isCancelled {
                await reload()
                guard let batch, let delay = nextCloudResultUpdate([batch]) else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
        .task(id: previewKey) {
            let requestKey = previewKey
            previewData = nil
            guard !mediaHidden, let batch, !mediaUnavailable(batch), let task = previewTask(batch) else { return }
            do {
                let data = try await host.cloudSubmissionPreview(id, taskID: task.id, context: context)
                guard !Task.isCancelled, !mediaHidden, previewKey == requestKey else { return }
                host.withCurrentCloudPresentation(context) { previewData = data }
            } catch { if previewKey == requestKey { previewData = nil } }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .active { reloadRevision = UUID() } }
        .refreshable {
            actionError = nil
            await reload()
            if let batch, !mediaUnavailable(batch) { mediaHidden = false }
        }
        .onChange(of: selectedIDs) { _, _ in decision = UUID() }
        .confirmationDialog("Some Displays May Already Have Received This", isPresented: $confirmResend,
                            titleVisibility: .visible) {
            Button("Send Selected Again") { resend(confirmsDuplicates: true) }
                .accessibilityIdentifier("cloud-result-confirm-resend")
        } message: {
            Text("Check the selected displays first. This creates a new request and may generate the same frame again.")
        }
        .confirmationDialog("Delete Photo?", isPresented: $confirmDeleteMedia, titleVisibility: .visible) {
            Button("Delete Photo", role: .destructive) { delete(mediaOnly: true) }
                .accessibilityIdentifier("cloud-result-confirm-delete-photo")
        } message: { Text("This removes the saved photo and stops unstarted work. A request already in progress may still take effect.") }
        .confirmationDialog("Delete Result?", isPresented: $confirmDeleteResult, titleVisibility: .visible) {
            Button("Delete Result", role: .destructive) { delete(mediaOnly: false) }
                .accessibilityIdentifier("cloud-result-confirm-delete-result")
        } message: { Text("This removes the photo and result from this device. It cannot undo a request already received by Cloud.") }
    }

    @ViewBuilder private func outcome(_ value: CloudTargetOutcome?) -> some View {
        switch value {
        case .generated(_, let warnings):
            Label(warnings.isEmpty ? String(localized: "cloud.result.frameGenerated", defaultValue: "Frame Generated")
                  : String(localized: "Frame Generated with Warnings"),
                  systemImage: warnings.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .foregroundStyle(warnings.isEmpty ? Color.green : Color.orange)
            ForEach(Array(Set(warnings)).sorted(), id: \.self) { warning in Text(warning).font(.caption) }
        case .refused(let problem, let message, let retry):
            Label(refusalTitle(problem), systemImage: "xmark.circle").foregroundStyle(.orange)
            Text(LocalizedStringKey(message)).font(.caption).foregroundStyle(.secondary)
            if let retry { Text("Wait at least \(retry.rounded(.up).formatted(.number.precision(.fractionLength(0)))) seconds before trying again.").font(.caption) }
        case .unknown(_, let message):
            Label("Outcome Unknown", systemImage: "questionmark.circle").foregroundStyle(.orange)
            Text(LocalizedStringKey(message)).font(.caption).foregroundStyle(.secondary)
        case .notAttempted:
            Label("Not Sent", systemImage: "pause.circle")
        case nil:
            Label("Waiting for Result", systemImage: "hourglass")
        }
    }
    private func refusalTitle(_ problem: CloudSubmissionProblem) -> String {
        switch problem {
        case .authorization: String(localized: "Sign In Required")
        case .permission: String(localized: "Sending Not Allowed")
        case .membershipRemoved, .tenantUnavailable, .resourceMismatch: String(localized: "Access Unavailable")
        case .quota: String(localized: "Cloud Plan Limit Reached")
        case .rateLimited: String(localized: "Try Later")
        case .unavailable: String(localized: "Cloud Temporarily Unavailable")
        case .noFrame: String(localized: "No Current Dashboard")
        default: String(localized: "Request Refused")
        }
    }
    private func mediaUnavailable(_ batch: CloudSubmissionBatch) -> Bool {
        batch.kind == .photo && (batch.mediaExpiresAt.map { $0 <= Date() } ?? true)
    }
    private func reload() async {
        do {
            let value = try await host.cloudSubmissionResult(id, context: context)
            guard !Task.isCancelled else { return }
            batch = value
            error = nil
            if !didSetSelection && !value.isActive {
                selectedIDs = Set(value.results.filter {
                    if case .generated = $0.outcome { false } else { true }
                }.map(\.id))
                didSetSelection = true
            }
            if mediaUnavailable(value) { previewData = nil }
        } catch {
            batch = nil; previewData = nil; self.error = error.localizedDescription
        }
    }
    private func resend(confirmsDuplicates: Bool) {
        guard let batch, !isResending else { return }
        isResending = true; error = nil; actionError = nil
        let selection = CloudResendSelection(targetIDs: selectedIDs, confirmsPossibleDuplicates: confirmsDuplicates)
        let decision = decision
        Task {
            defer { isResending = false }
            do {
                let next = try await host.resendCloud(id, expectedRevision: batch.revision,
                    selection: selection, decision: decision, context: context)
                host.withCurrentCloudPresentation(context) { onResent(next) }
            } catch { actionError = error.localizedDescription; await reload() }
        }
    }
    private func delete(mediaOnly: Bool) {
        mediaHidden = true
        actionError = nil
        previewData = nil
        if !mediaOnly { batch = nil }
        Task {
            do {
                if mediaOnly { try await host.deleteCloudMedia(id, context: context) }
                else {
                    try await host.deleteCloudResult(id, context: context)
                    host.withCurrentCloudPresentation(context) { dismiss() }
                }
            } catch { actionError = error.localizedDescription }
            await reload()
            reloadRevision = UUID()
        }
    }
    private func previewTask(_ batch: CloudSubmissionBatch) -> CloudSubmissionTask? {
        batch.tasks.first { $0.id == previewTaskID && $0.raster != nil } ?? batch.tasks.first { $0.raster != nil }
    }
    private func previewNames(_ batch: CloudSubmissionBatch, task: CloudSubmissionTask?) -> String {
        guard let task else { return String(localized: "Submitted Photo") }
        return batch.targets.filter { task.targetIDs.contains($0.id) }.map(\.name).joined(separator: ", ")
    }
    private var previewKey: String {
        [context.revision.uuidString, id.uuidString, mediaHidden ? "hidden" : "visible", batch.flatMap(previewTask)?.id.uuidString ?? "none",
         batch?.mediaExpiresAt.map { String($0.timeIntervalSince1970) } ?? "none"].joined(separator: ":")
    }
}

private struct HistoryLoadKey: Hashable {
    let context: CloudPresentationContext
    let isVisible: Bool
    let revision: UUID
}
private struct ResultLoadKey: Hashable {
    let context: CloudPresentationContext
    let revision: UUID
}
private func nextCloudResultUpdate(_ batches: [CloudSubmissionBatch]) -> TimeInterval? {
    if batches.contains(where: \.isActive) { return 0.5 }
    let now = Date()
    let deadlines = batches.flatMap { [$0.mediaExpiresAt, Optional($0.resultsExpireAt)].compactMap { $0 } }
        .filter { $0 > now }
    return deadlines.min().map { max(0.05, $0.timeIntervalSince(now)) }
}

private struct CloudPendingInputSheet: View {
    let input: CloudPendingInput
    let context: CloudPresentationContext
    let onAccepted: (UUID) -> Void
    @Environment(ConnectionHost.self) private var host
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var review: CloudPendingReview?
    @State private var preview: UIImage?
    @State private var actionError: String?
    @State private var completion: CloudEntryCompletion?
    @State private var isBusy = false
    @State private var showReview = false
    @State private var confirmDiscard = false
    @State private var revision = UUID()
    @State private var previewRevision = UUID()
    @State private var expired = false
    private var isAvailable: Bool { !expired && input.expiresAt > Date() }

    var body: some View {
        NavigationStack {
            Form {
                if !isAvailable {
                    ContentUnavailableView("Item Expired", systemImage: "clock.badge.exclamationmark",
                        description: Text("This unsent photo is no longer available."))
                } else if let completion { CloudEntryOutcomeView(completion: completion) }
                else {
                    Section {
                        Label("Not Sent", systemImage: "tray.and.arrow.down")
                        Text("This item will not be sent automatically. Review its fixed displays before continuing.")
                        LabeledContent("Available Until", value: input.expiresAt.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let review {
                        Section("Displays") {
                            ForEach(input.targets.deviceIDs, id: \.self) { id in
                                Text(review.read.devices.first { $0.id == id }?.name ?? id)
                            }
                        }
                    }
                    if let preview {
                        Section("Photo") {
                            Image(uiImage: preview).resizable().scaledToFit().frame(maxHeight: 260)
                                .accessibilityIdentifier("cloud-pending-preview")
                        }
                    }
                    if let actionError { Text(actionError).foregroundStyle(.secondary).accessibilityIdentifier("cloud-pending-error") }
                    Section {
                        Button("Continue") { continueInput() }
                            .disabled(isBusy || review == nil).accessibilityIdentifier("cloud-pending-continue")
                        if input.kind == .photo {
                            Button("Review Photo") { showReview = true }
                                .disabled(isBusy || review == nil).accessibilityIdentifier("cloud-pending-review")
                        }
                        Button("Discard", role: .destructive) { confirmDiscard = true }
                            .disabled(isBusy).accessibilityIdentifier("cloud-pending-discard")
                    }
                    if isBusy { ProgressView("Preparing Send…") }
                }
            }
            .scrollContentBackground(.hidden).tesseraeScreenBackground()
            .navigationTitle("Not Sent")
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("Close", systemImage: "xmark") { dismiss() }.labelStyle(.iconOnly).disabled(isBusy)
            } }
        }
        .presentationDetents([.large])
        .interactiveDismissDisabled(isBusy)
        .task(id: revision) { await load() }
        .task(id: input.expiresAt) {
            do { if input.expiresAt > Date() { try await Task.sleep(for: .seconds(input.expiresAt.timeIntervalSinceNow)) } }
            catch { return }
            expired = true; previewRevision = UUID(); preview = nil; review = nil; completion = nil; showReview = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { previewRevision = UUID(); preview = nil; review = nil; completion = nil }
            else { revision = UUID() }
        }
        .sheet(isPresented: $showReview, onDismiss: { preview = nil; review = nil; revision = UUID() }) {
            if let review, let model = host.cloud { CloudSendSheet(model: model, context: context, recovery: review, onRecoveryAccepted: onAccepted) }
        }
        .confirmationDialog("Discard this unsent item?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { discard() }
        } message: { Text("Its photo and pending send will be removed. Nothing will be sent.") }
    }
    private func load() async {
        guard isAvailable else { return }
        let token = UUID()
        previewRevision = token
        preview = nil; review = nil
        do {
            if input.kind == .photo {
                let value = try await host.cloudPendingReview(input, context: context)
                let bytes = value.data
                let thumbnail = await Task.detached {
                    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil) else { return nil as CGImage? }
                    return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 2048] as CFDictionary)
                }.value
                guard !Task.isCancelled, previewRevision == token, isAvailable else { return }
                host.withCurrentCloudPresentation(context) { review = value; preview = thumbnail.map(UIImage.init(cgImage:)); actionError = nil }
            } else {
                let value = try await host.cloudPendingReadContext(context: context)
                guard !Task.isCancelled, previewRevision == token, isAvailable else { return }
                host.withCurrentCloudPresentation(context) { review = .init(input: input, data: Data(), read: value); actionError = nil }
            }
        } catch {
            guard previewRevision == token, isAvailable else { return }
            preview = nil; review = nil; actionError = error.localizedDescription
        }
    }
    private func continueInput() {
        guard !isBusy, isAvailable, let currentReview = review else { return }
        isBusy = true; actionError = nil
        Task {
            defer { isBusy = false }
            do {
                let result = try await host.continueCloudPending(input, review: currentReview.read, context: context)
                host.withCurrentCloudPresentation(context) {
                    preview = nil; review = nil
                    if case .finished(let batch) = result { onAccepted(batch.id) }
                    else if isAvailable { completion = result }
                }
            } catch { preview = nil; review = nil; actionError = error.localizedDescription }
        }
    }
    private func discard() {
        guard !isBusy, isAvailable else { return }
        previewRevision = UUID(); preview = nil; review = nil; isBusy = true
        Task {
            defer { isBusy = false }
            do { try await host.discardCloudPending(input, context: context); dismiss() }
            catch { actionError = error.localizedDescription; revision = UUID() }
        }
    }
}
