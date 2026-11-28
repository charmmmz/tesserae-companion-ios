import SwiftUI
import ImageIO
import TesseraeKit

struct CloudPendingPresentationState {
    struct Item: Identifiable {
        let id = UUID()
        let input: CloudPendingInput
    }
    var item: Item?

    mutating func show(_ input: CloudPendingInput) { item = Item(input: input) }
    mutating func accept(_ batchID: UUID, from presentationID: UUID) -> UUID? {
        guard item?.id == presentationID else { return nil }
        item = nil
        return batchID
    }
}

struct CloudSubmissionActivity: View {
    let context: CloudPresentationContext
    let tenant: String?
    let isActive: Bool
    @Binding var path: [UUID]
    @Environment(ConnectionHost.self) private var host
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var reloadRevision = UUID()
    @State private var history: [CloudSubmissionBatch] = []
    @State private var pending: [CloudPendingInput] = []
    @State private var pendingPresentation = CloudPendingPresentationState()
    @State private var error: String?
    @State private var didLoadResults = false
    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    CloudNavigationTitle(title: String(localized: "Activity"), tenant: tenant)
                    if let error {
                        Label(error, systemImage: "exclamationmark.circle")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .accessibilityIdentifier("cloud-results-error")
                    }
                    if !pending.isEmpty {
                        Text("Not Sent").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(pending) { input in
                            Button { pendingPresentation.show(input) } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: "photo.badge.clock")
                                        .foregroundStyle(TesseraeTheme.accent)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(input.kind == .photo ? String(localized: "Photo to review")
                                            : String(localized: "Refresh to review"))
                                            .font(.headline)
                                        Text(input.createdAt.formatted()).font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 0)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                                }
                                .frame(minHeight: 44)
                                .tesseraeCard()
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("cloud-pending-\(input.id.uuidString)")
                        }
                    }
                    let calendar = Calendar.current
                    let batchesByDay = Dictionary(grouping: history) { calendar.startOfDay(for: $0.createdAt) }
                    ForEach(batchesByDay.keys.sorted(by: >), id: \.self) { day in
                        Section {
                            ForEach(batchesByDay[day] ?? []) { batch in
                                NavigationLink(value: batch.id) { activityCard(batch) }
                                    .buttonStyle(.plain)
                                    .accessibilityIdentifier("cloud-result-\(batch.id.uuidString)")
                            }
                        } header: {
                            historyDay(day, calendar: calendar)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .accessibilityAddTraits(.isHeader)
                        }
                    }
                    if history.isEmpty, pending.isEmpty, error == nil {
                        if didLoadResults {
                            ContentUnavailableView("No Activity Yet", systemImage: "clock",
                                description: Text("Photo sends and display refreshes appear here."))
                                .accessibilityIdentifier("cloud-no-activity")
                        } else {
                            ProgressView("Loading Activity…").frame(maxWidth: .infinity, minHeight: 120)
                        }
                    }
                }
                .frame(maxWidth: 820)
                .padding(16)
                .frame(maxWidth: .infinity)
            }
            .tesseraeScreenBackground()
            .tesseraeRootPageChrome()
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { reloadRevision = UUID() }
            .toolbar { TesseraeRootToolbar { EmptyView() } }
            .navigationDestination(for: UUID.self) { id in
                CloudSubmissionResultView(id: id, context: context) { next in path.append(next) }
            }
        }
        .sheet(item: $pendingPresentation.item, onDismiss: { reloadRevision = UUID() }) { selection in
            CloudPendingInputSheet(input: selection.input, context: context) { id in
                if let accepted = pendingPresentation.accept(id, from: selection.id) { path.append(accepted) }
            }
        }
        .task(id: HistoryLoadKey(context: context, isVisible: isActive && path.isEmpty, revision: reloadRevision)) {
            guard isActive, path.isEmpty else { return }
            while !Task.isCancelled {
                do {
                    let values = try await host.cloudPendingInputs(context: context)
                    let results = try await host.cloudSubmissionHistory(context: context)
                    guard !Task.isCancelled else { return }
                    host.withCurrentCloudPresentation(context) {
                        pending = values
                        history = results
                        didLoadResults = true
                        error = nil
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    history = []
                    pending = []
                    self.error = error.localizedDescription
                    return
                }
                let pendingDelay = pending.map { $0.expiresAt.timeIntervalSinceNow }.filter { $0 > 0 }.min()
                guard let delay = [nextCloudResultUpdate(history), pendingDelay].compactMap({ $0 }).min() else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
        .task(id: pendingPresentation.item?.id) {
            guard let selected = pendingPresentation.item else { return }
            let deadline = selected.input.expiresAt
            do { if deadline > Date() { try await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow)) } }
            catch { return }
            if pendingPresentation.item?.id == selected.id { pendingPresentation.item = nil; reloadRevision = UUID() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if let selected = pendingPresentation.item, selected.input.expiresAt <= Date() { pendingPresentation.item = nil }
                reloadRevision = UUID()
            }
        }
    }
    private func historyDay(_ day: Date, calendar: Calendar) -> Text {
        if calendar.isDateInToday(day) { return Text("Today") }
        if calendar.isDateInYesterday(day) { return Text("Yesterday") }
        return Text(day, format: .dateTime.year().month().day())
    }

    private func activityCard(_ batch: CloudSubmissionBatch) -> some View {
        let names = batch.targets.map(\.name).formatted(.list(type: .and))
        let statuses = CloudBatchStatus.labels(for: batch)
        return HStack(spacing: 12) {
            CloudActivityThumbnail(batch: batch, context: context)
            VStack(alignment: .leading, spacing: 5) {
                Text(batch.kind == .photo ? String(localized: "Photo to \(names)")
                    : String(localized: "Refresh for \(names)"))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                Label(
                    batch.isActive ? (batch.kind == .photo ? String(localized: "Sending…") : String(localized: "Refreshing…"))
                    : CloudBatchStatus.isReady(batch) ? String(localized: "Ready for next wake")
                    : statuses.joined(separator: dynamicTypeSize.isAccessibilitySize ? "\n" : " · "),
                    systemImage: batch.isActive ? "clock" : CloudBatchStatus.isReady(batch) ? "checkmark.circle" : "exclamationmark.circle"
                )
                .font(.subheadline)
                .foregroundStyle(CloudBatchStatus.isReady(batch) ? TesseraeTheme.success : .secondary)
                .accessibilityIdentifier("cloud-result-summary-\(batch.id.uuidString)")
                Text(batch.createdAt, format: .dateTime.hour().minute()).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .frame(minHeight: 44)
        .tesseraeCard()
        .contentShape(Rectangle())
    }
}

private struct CloudActivityThumbnail: View {
    let batch: CloudSubmissionBatch
    let context: CloudPresentationContext
    @Environment(ConnectionHost.self) private var host
    @State private var image: UIImage?

    private var taskID: UUID? {
        guard batch.mediaExpiresAt.map({ $0 > Date() }) == true else { return nil }
        return batch.tasks.first { $0.raster != nil }?.id
    }

    var body: some View {
        ZStack {
            TesseraeTheme.surfaceInset
            if let image, taskID != nil {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: batch.kind == .photo ? "photo" : "arrow.clockwise")
                    .foregroundStyle(TesseraeTheme.accent)
            }
        }
        .frame(width: 52, height: 52)
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
        .task(id: taskID) {
            image = nil
            guard let taskID else { return }
            guard let data = try? await host.cloudSubmissionPreview(batch.id, taskID: taskID, context: context),
                  !Task.isCancelled, taskID == self.taskID,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 156,
                  ] as CFDictionary) else { return }
            host.withCurrentCloudPresentation(context) { image = UIImage(cgImage: thumbnail) }
        }
        .onDisappear { image = nil }
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
    @State private var selectsTargets = false
    @State private var showStorage = false
    @State private var confirmationIDs: Set<String> = []
    @State private var decisionTargets: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let batch {
                    summaryCard(batch)
                    displaysCard(batch)
                } else if let error {
                    ContentUnavailableView("Activity Unavailable", systemImage: "clock.badge.exclamationmark",
                        description: Text(error))
                        .accessibilityIdentifier("cloud-result-unavailable")
                } else {
                    ProgressView("Loading Activity…").frame(maxWidth: .infinity, minHeight: 120)
                }
                if let message = actionError ?? error {
                    Text(message).foregroundStyle(TesseraeTheme.danger)
                        .accessibilityIdentifier("cloud-result-error")
                }
            }
            .frame(maxWidth: 820)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
        .tesseraeScreenBackground()
        .tesseraeMessageCenter()
        .navigationTitle(batch?.kind == .currentPage ? String(localized: "Refresh Details") : String(localized: "Photo Details"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            TesseraeToolbarActions {
                if let batch { moreMenu(batch) }
            }
        }
        .sheet(isPresented: $showStorage) {
            if let batch { storageDetails(batch) }
        }
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
        .confirmationDialog("Some Displays May Already Have Received This", isPresented: $confirmResend,
                            titleVisibility: .visible) {
            Button("Send Selected Again") { resend(targetIDs: confirmationIDs, confirmsDuplicates: true) }
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

    private func summaryCard(_ batch: CloudSubmissionBatch) -> some View {
        DisplayPreviewCard {
            if let previewData, let image = UIImage(data: previewData) {
                Image(uiImage: image).resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    .accessibilityLabel("Submitted Photo")
                    .accessibilityIdentifier("cloud-submitted-photo")
                if batch.initialUploadCount > 1 {
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
                }
            }
            if batch.isActive {
                ProgressView(batch.kind == .photo ? String(localized: "Sending…") : String(localized: "Refreshing…"))
                    .accessibilityIdentifier("cloud-result-sending")
            } else {
                Text(summary(batch)).font(.title2.weight(.semibold))
            }
            Text(batch.createdAt.formatted()).font(.subheadline).foregroundStyle(.secondary)
            if mediaUnavailable(batch) {
                Text("The saved photo is no longer available.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("cloud-result-media-expired")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summary(_ batch: CloudSubmissionBatch) -> String {
        let ready = CloudBatchStatus.readyCount(batch)
        if CloudBatchStatus.isReady(batch) { return String(localized: "Ready for next wake") }
        if ready == 0 {
            return batch.kind == .photo ? String(localized: "Check this send") : String(localized: "Check this refresh")
        }
        return String(localized: "\(ready) of \(batch.targets.count) displays ready")
    }

    private func displaysCard(_ batch: CloudSubmissionBatch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectsTargets ? String(localized: "Select Displays") : String(localized: "Displays")).font(.headline)
                Spacer(minLength: 0)
                if selectsTargets {
                    Button("Cancel") { selectsTargets = false }
                        .frame(minHeight: 44)
                }
            }

            let outcomes = Dictionary(batch.results.map { ($0.id, $0.outcome) }, uniquingKeysWith: { first, _ in first })
            ForEach(batch.targets) { target in
                if target.id != batch.targets.first?.id { Divider() }
                let value = outcomes[target.id]
                if selectsTargets {
                    Button {
                        if selectedIDs.contains(target.id) { selectedIDs.remove(target.id) }
                        else { selectedIDs.insert(target.id) }
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: selectedIDs.contains(target.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(TesseraeTheme.accent)
                                .accessibilityHidden(true)
                            targetStatus(target, value: value, isActive: batch.isActive)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(selectedIDs.contains(target.id) ? .isSelected : [])
                    .accessibilityIdentifier("cloud-result-target-\(target.id)")
                } else {
                    HStack(alignment: .top, spacing: 10) {
                        targetStatus(target, value: value, isActive: batch.isActive)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("cloud-result-target-\(target.id)")
                        if canResend(batch), canRetry(value) {
                            Button {
                                requestResend([target.id])
                            } label: {
                                Text("Try Again")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(minWidth: 44, minHeight: 44)
                                    .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Try again for \(target.name)")
                            .accessibilityIdentifier("cloud-result-retry-\(target.id)")
                        }
                    }
                }
            }
            if selectsTargets {
                Button(batch.kind == .photo ? String(localized: "Send Selected Again") : String(localized: "Refresh Selected Again")) {
                    requestResend(selectedIDs)
                }
                .frame(minHeight: 44)
                .disabled(!canResend(batch) || selectedIDs.isEmpty)
                .accessibilityIdentifier("cloud-result-resend")
            }
        }
        .tesseraeCard()
    }

    private func targetStatus(_ target: CloudSubmissionTarget, value: CloudTargetOutcome?, isActive: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(target.name).font(.headline)
            outcome(value, isActive: isActive)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    @ViewBuilder private func outcome(_ value: CloudTargetOutcome?, isActive: Bool) -> some View {
        switch value {
        case .generated(_, let warnings):
            Label(warnings.isEmpty ? String(localized: "Ready for next wake") : String(localized: "Ready with a note"),
                systemImage: warnings.isEmpty ? "checkmark.circle" : "exclamationmark.circle")
                .font(.subheadline)
                .foregroundStyle(warnings.isEmpty ? TesseraeTheme.success : TesseraeTheme.warning)
            ForEach(Array(Set(warnings)).sorted(), id: \.self) { warning in
                Text(warning).font(.caption).foregroundStyle(.secondary)
            }
        case .refused(let problem, let message, let retry):
            Label("Not sent", systemImage: "exclamationmark.circle")
                .font(.subheadline).foregroundStyle(TesseraeTheme.warning)
            Text(refusalMessage(problem, fallback: message)).font(.caption).foregroundStyle(.secondary)
            if let retry, retry > 0 {
                Text("Wait \(retry.rounded(.up).formatted(.number.precision(.fractionLength(0)))) seconds before trying again.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .unknown:
            unconfirmed
        case .notAttempted:
            Label("Not sent", systemImage: "pause.circle").font(.subheadline).foregroundStyle(.secondary)
        case nil:
            if isActive {
                Label("Sending…", systemImage: "hourglass").font(.subheadline).foregroundStyle(.secondary)
            } else {
                unconfirmed
            }
        }
    }

    private var unconfirmed: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Couldn’t confirm", systemImage: "questionmark.circle")
                .font(.subheadline).foregroundStyle(TesseraeTheme.warning)
            Text("Check the display before sending again.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refusalMessage(_ problem: CloudSubmissionProblem, fallback: String) -> String {
        switch problem {
        case .authorization: String(localized: "Sign in to Cloud again.")
        case .permission: String(localized: "Your account can’t send to this display.")
        case .membershipRemoved, .tenantUnavailable, .resourceMismatch: String(localized: "This Cloud workspace is unavailable.")
        case .quota: String(localized: "Your Cloud plan limit was reached.")
        case .rateLimited: String(localized: "Cloud is busy. Try again later.")
        case .unavailable: String(localized: "Cloud is temporarily unavailable.")
        case .noFrame: String(localized: "Assign a dashboard to this display in Cloud.")
        default: fallback
        }
    }

    private func canResend(_ batch: CloudSubmissionBatch) -> Bool {
        !batch.isActive && !isResending && !mediaHidden && !mediaUnavailable(batch)
            && host.cloud?.snapshot?.account.auth.scopes.contains(batch.kind == .photo ? "app:send" : "app:refresh") == true
    }

    private func canRetry(_ value: CloudTargetOutcome?) -> Bool {
        switch value {
        case .refused(.unavailable, _, let retry): retry.map { $0 <= 0 } ?? true
        case .notAttempted(.mediaExpired), .notAttempted(.deleted): false
        case .notAttempted: true
        default: false
        }
    }

    private func requestResend(_ ids: Set<String>) {
        guard let batch, canResend(batch), !ids.isEmpty else { return }
        if batch.results.contains(where: { ids.contains($0.id) && $0.outcome.needsDuplicateConfirmation }) {
            confirmationIDs = ids
            confirmResend = true
        } else {
            resend(targetIDs: ids, confirmsDuplicates: false)
        }
    }

    private func moreMenu(_ batch: CloudSubmissionBatch) -> some View {
        Menu {
            Button(batch.kind == .photo ? "Send Again…" : "Refresh Again…", systemImage: "arrow.clockwise") {
                selectedIDs = Set(batch.results.filter {
                    if case .generated = $0.outcome { false } else { true }
                }.map(\.id))
                selectsTargets = true
            }
            .disabled(!canResend(batch))
            .accessibilityIdentifier("cloud-result-select-targets")
            Button("Storage & Retention", systemImage: "clock") { showStorage = true }
            if batch.kind == .photo {
                Button("Delete Photo", systemImage: "photo", role: .destructive) { confirmDeleteMedia = true }
                    .disabled(mediaUnavailable(batch))
                    .accessibilityIdentifier("cloud-result-delete-photo")
            }
            Button("Delete Result", systemImage: "trash", role: .destructive) { confirmDeleteResult = true }
                .accessibilityIdentifier("cloud-result-delete-result")
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .accessibilityIdentifier("cloud-result-more")
    }

    private func storageDetails(_ batch: CloudSubmissionBatch) -> some View {
        NavigationStack {
            Form {
                if let expiry = batch.mediaExpiresAt {
                    LabeledContent("Photo Available Until", value: expiry.formatted())
                }
                LabeledContent("Result Available Until", value: batch.resultsExpireAt.formatted())
                    .accessibilityIdentifier("cloud-result-expiry")
            }
            .scrollContentBackground(.hidden)
            .tesseraeScreenBackground()
            .navigationTitle("Storage & Retention")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { showStorage = false }.labelStyle(.iconOnly)
                }
            }
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
            if mediaUnavailable(value) { previewData = nil }
        } catch {
            batch = nil; previewData = nil; self.error = error.localizedDescription
        }
    }
    private func resend(targetIDs: Set<String>, confirmsDuplicates: Bool) {
        guard let batch, canResend(batch), !targetIDs.isEmpty else { return }
        isResending = true; error = nil; actionError = nil
        if targetIDs != decisionTargets {
            decision = UUID()
            decisionTargets = targetIDs
        }
        let selection = CloudResendSelection(targetIDs: targetIDs, confirmsPossibleDuplicates: confirmsDuplicates)
        let decision = decision
        Task {
            defer { isResending = false }
            do {
                let next = try await host.resendCloud(id, expectedRevision: batch.revision,
                    selection: selection, decision: decision, context: context)
                host.withCurrentCloudPresentation(context) {
                    selectsTargets = false
                    onResent(next)
                }
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

private enum CloudBatchStatus: CaseIterable {
    case generated, generatedWithWarnings, notSent, unconfirmed, waiting

    static func readyCount(_ batch: CloudSubmissionBatch) -> Int {
        batch.results.filter { $0.outcome.isCleanGenerated }.count
    }

    static func isReady(_ batch: CloudSubmissionBatch) -> Bool {
        !batch.isActive && !batch.targets.isEmpty && readyCount(batch) == batch.targets.count
    }

    static func labels(for batch: CloudSubmissionBatch) -> [String] {
        let outcomes = Dictionary(batch.results.map { ($0.id, $0.outcome) }, uniquingKeysWith: { first, _ in first })
        var counts: [CloudBatchStatus: Int] = [:]
        for target in batch.targets {
            let status: CloudBatchStatus
            switch outcomes[target.id] {
            case .generated(_, let warnings): status = warnings.isEmpty ? .generated : .generatedWithWarnings
            case .refused, .notAttempted: status = .notSent
            case .unknown: status = .unconfirmed
            case nil: status = batch.isActive ? .waiting : .unconfirmed
            }
            counts[status, default: 0] += 1
        }
        return allCases.compactMap { status in
            counts[status].map { status.label(count: $0.formatted()) }
        }
    }

    private func label(count: String) -> String {
        switch self {
        case .generated: String(localized: "\(count) ready")
        case .generatedWithWarnings: String(localized: "\(count) ready with notes")
        case .notSent: String(localized: "\(count) not sent")
        case .unconfirmed: String(localized: "\(count) unconfirmed")
        case .waiting: String(localized: "\(count) sending")
        }
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
            if let review, let model = host.cloud { CloudSendSheet(model: model, context: context, recovery: review, onAccepted: onAccepted) }
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
