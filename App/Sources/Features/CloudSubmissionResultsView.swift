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
    @Binding var resultToReveal: UUID?
    @Environment(ConnectionHost.self) private var host
    @Environment(\.scenePhase) private var scenePhase
    @State private var filter: ActivityFilter = .all
    @State private var expandedID: UUID?
    @State private var reloadRevision = UUID()
    @State private var history: [CloudSubmissionBatch] = []
    @State private var pending: [CloudPendingInput] = []
    @State private var pendingPresentation = CloudPendingPresentationState()
    @State private var historyError: String?
    @State private var pendingError: String?
    @State private var didLoadResults = false

    private var error: String? { historyError ?? pendingError }

    private var loadKey: CloudActivityLoadKey {
        CloudActivityLoadKey(context: context, isVisible: isActive, revision: reloadRevision)
    }

    private var visibleHistory: [CloudSubmissionBatch] {
        history.filter { filter.includes(needsAttention: CloudBatchStatus.needsAttention($0)) }
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
                let results = visibleHistory
                let revealID = resultToReveal.flatMap { id in
                    isActive && results.contains(where: { $0.id == id }) ? id : nil
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        CloudNavigationTitle(title: String(localized: "Activity"), tenant: tenant)
                        if let error {
                            Label(error, systemImage: "exclamationmark.circle")
                                .font(.subheadline).foregroundStyle(.secondary)
                                .accessibilityIdentifier("cloud-results-error")
                        }
                        ForEach(pending) { input in
                            pendingCard(input)
                        }
                        ForEach(results) { batch in
                            activityCard(batch)
                                .id(batch.id)
                        }
                        if results.isEmpty, pending.isEmpty {
                            emptyState
                        }
                    }
                    .frame(maxWidth: 820)
                    .padding(16)
                    .frame(maxWidth: .infinity)
                }
                .accessibilityIdentifier("cloud-activity-list")
                .task(id: revealID) {
                    guard let revealID else { return }
                    expandedID = revealID
                    await Task.yield()
                    guard !Task.isCancelled, resultToReveal == revealID else { return }
                    scroll.scrollTo(revealID, anchor: .top)
                    resultToReveal = nil
                }
            }
            .tesseraeScreenBackground()
            .tesseraeRootPageChrome()
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { requestReload() }
            .toolbar { TesseraeRootToolbar { ActivityFilterMenu(filter: $filter) } }
        }
        .sheet(item: $pendingPresentation.item, onDismiss: requestReload) { selection in
            CloudPendingInputSheet(input: selection.input, context: context) { id in
                if let accepted = pendingPresentation.accept(id, from: selection.id) { resultToReveal = accepted }
            }
        }
        .onChange(of: resultToReveal, initial: true) { _, id in
            if id != nil {
                filter = .all
                requestReload()
            }
        }
        .task(id: loadKey) {
            guard isActive else { return }
            while !Task.isCancelled {
                await loadHistory()
                guard let delay = nextCloudResultUpdate(history) else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
        .task(id: loadKey) {
            guard isActive else { return }
            while !Task.isCancelled {
                await loadPending()
                guard let deadline = pending.map(\.expiresAt).filter { $0 > Date() }.min() else { return }
                do { try await Task.sleep(for: .seconds(max(0.05, deadline.timeIntervalSinceNow))) }
                catch { return }
            }
        }
        .task(id: pendingPresentation.item?.id) {
            guard let selected = pendingPresentation.item else { return }
            do { try await Task.sleep(for: .seconds(max(0, selected.input.expiresAt.timeIntervalSinceNow))) }
            catch { return }
            if pendingPresentation.item?.id == selected.id { pendingPresentation.item = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                if let selected = pendingPresentation.item, selected.input.expiresAt <= Date() { pendingPresentation.item = nil }
                requestReload()
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if error == nil {
            if !didLoadResults {
                ProgressView("Loading Activity…").frame(maxWidth: .infinity, minHeight: 120)
            } else if filter == .needsAttention {
                ContentUnavailableView {
                    Label("No Matching Activity", systemImage: "line.3.horizontal.decrease.circle")
                } description: {
                    Text("No items need attention in the activity loaded so far.")
                } actions: {
                    Button("Show All") { filter = .all }
                        .accessibilityIdentifier("activity-show-all")
                }
                .accessibilityIdentifier("activity-attention-empty")
            } else {
                ContentUnavailableView("No Activity Yet", systemImage: "clock.arrow.circlepath",
                    description: Text("Photo sends and display refreshes appear here."))
                    .accessibilityIdentifier("cloud-no-activity")
            }
        }
    }

    private func requestReload() {
        reloadRevision = UUID()
    }

    private func loadHistory() async {
        let requestedID = resultToReveal
        do {
            let results = try await host.cloudSubmissionHistory(context: context)
            guard !Task.isCancelled else { return }
            host.withCurrentCloudPresentation(context) {
                history = results
                didLoadResults = true
                historyError = nil
                if let expandedID, !results.contains(where: { $0.id == expandedID }) {
                    self.expandedID = nil
                }
                if let requestedID, resultToReveal == requestedID, !results.contains(where: { $0.id == requestedID }) {
                    historyError = CloudSubmissionError.missingResult.localizedDescription
                    resultToReveal = nil
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            host.withCurrentCloudPresentation(context) {
                history = []
                historyError = error.localizedDescription
            }
        }
    }

    private func loadPending() async {
        do {
            let inputs = try await host.cloudPendingInputs(context: context)
            guard !Task.isCancelled else { return }
            host.withCurrentCloudPresentation(context) {
                pending = inputs
                pendingError = nil
            }
        } catch {
            guard !Task.isCancelled else { return }
            host.withCurrentCloudPresentation(context) {
                pending = []
                pendingError = error.localizedDescription
            }
        }
    }

    private func pendingCard(_ input: CloudPendingInput) -> some View {
        Button {
            pendingPresentation.show(input)
        } label: {
            ActivityCard {
                ActivityCardRow {
                    Text(input.kind == .photo ? String(localized: "Photo to review") : String(localized: "Refresh to review"))
                        .font(.headline)
                    Text("Not Sent").font(.caption.weight(.semibold)).foregroundStyle(TesseraeTheme.warning)
                    timestamp(input.createdAt)
                } artwork: {
                    Image(systemName: input.kind == .photo ? "photo.badge.clock" : "arrow.clockwise")
                        .font(.title3)
                        .foregroundStyle(TesseraeTheme.accent)
                        .frame(width: 112, height: 70)
                        .background(TesseraeTheme.surfaceInset, in: RoundedRectangle(cornerRadius: 12))
                        .frame(width: ActivityCardMetrics.previewSize.width, height: ActivityCardMetrics.previewSize.height)
                        .accessibilityHidden(true)
                }
            } details: {
                EmptyView()
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("cloud-pending-\(input.id.uuidString)")
    }

    private func activityCard(_ batch: CloudSubmissionBatch) -> some View {
        let isExpanded = expandedID == batch.id
        let title: String = switch batch.kind {
        case .photo: String(localized: "Shared Photo")
        case .currentPage: String(localized: "Dashboard Refresh")
        case .dashboard: batch.dashboard?.name ?? String(localized: "Push Dashboard")
        }
        let summary = CloudBatchStatus.summary(batch)
        let attention = CloudBatchStatus.needsAttention(batch)
        let color = attention ? TesseraeTheme.warning : batch.isActive ? TesseraeTheme.info : TesseraeTheme.success
        return ActivityCard(spacing: 14, hasShadow: true) {
            ActivityCardRow {
                Text(title).font(.headline)
                Text(batch.targets.map(\.name).formatted(.list(type: .and)))
                    .font(.subheadline).foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(summary)
                    .font(.caption.weight(.semibold)).foregroundStyle(color)
                    .accessibilityLabel(attention ? CloudBatchStatus.labels(for: batch).joined(separator: ", ") : summary)
                    .accessibilityIdentifier("cloud-result-summary-\(batch.id.uuidString)")
                timestamp(batch.createdAt)
            } artwork: {
                ActivityDisclosureButton(isExpanded: isExpanded, expandHint: "Expand activity details",
                                         collapseHint: "Collapse activity details", onToggle: {
                    expandedID = isExpanded ? nil : batch.id
                }) {
                    CloudActivityThumbnail(batch: batch, context: context, isExpanded: isExpanded,
                                           status: summary, statusColor: color)
                }
                .accessibilityLabel(title)
                .accessibilityIdentifier("cloud-result-\(batch.id.uuidString)")
            }
        } details: {
            if isExpanded {
                CloudSubmissionResultView(id: batch.id, context: context, isActive: isActive, onChanged: requestReload) {
                    resultToReveal = $0
                }
                .transition(.opacity)
            }
        }
    }

    private func timestamp(_ date: Date) -> some View {
        Text(date, format: .dateTime.month(.abbreviated).day().hour().minute())
            .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
    }
}

private struct CloudActivityThumbnail: View {
    let batch: CloudSubmissionBatch
    let context: CloudPresentationContext
    let isExpanded: Bool
    let status: String
    let statusColor: Color
    @Environment(ConnectionHost.self) private var host
    @State private var image: UIImage?

    private var rasterTask: CloudSubmissionTask? {
        guard batch.mediaExpiresAt.map({ $0 > Date() }) == true else { return nil }
        return batch.tasks.first { $0.raster != nil }
    }

    private var artworkSize: CGSize {
        guard let geometry = rasterTask?.raster?.geometry,
              geometry.width > 0, geometry.height > 0 else {
            return CGSize(width: ActivityCardMetrics.previewSize.width, height: 70)
        }
        let canvas = ActivityCardMetrics.previewSize
        let scale = min(canvas.width / CGFloat(geometry.width), canvas.height / CGFloat(geometry.height))
        return CGSize(width: CGFloat(geometry.width) * scale, height: CGFloat(geometry.height) * scale)
    }

    private var placeholderSymbol: String {
        switch batch.kind {
        case .photo: "photo"
        case .currentPage: "arrow.clockwise"
        case .dashboard: "rectangle.stack"
        }
    }

    var body: some View {
        let size = artworkSize
        ZStack {
            TesseraeTheme.surfaceInset
            if let image, rasterTask != nil {
                Image(uiImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: placeholderSymbol)
                    .font(.title3).foregroundStyle(TesseraeTheme.accent)
            }
        }
        .frame(width: size.width, height: size.height)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(alignment: .topTrailing) {
            ActivityStatusBadge(label: status, symbol: batch.isActive ? "clock"
                : CloudBatchStatus.isReady(batch) ? "paperplane.fill" : "exclamationmark.circle.fill", color: statusColor)
                .padding(5)
        }
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(.thinMaterial, in: Circle())
                .padding(5)
        }
        .frame(width: ActivityCardMetrics.previewSize.width, height: ActivityCardMetrics.previewSize.height)
        .accessibilityHidden(true)
        .task(id: rasterTask?.id) {
            image = nil
            guard let taskID = rasterTask?.id,
                  let data = try? await host.cloudSubmissionPreview(batch.id, taskID: taskID, context: context),
                  !Task.isCancelled, taskID == rasterTask?.id,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceCreateThumbnailWithTransform: true,
                      kCGImageSourceThumbnailMaxPixelSize: 354,
                  ] as CFDictionary) else { return }
            host.withCurrentCloudPresentation(context) { image = UIImage(cgImage: thumbnail) }
        }
        .onDisappear { image = nil }
    }
}

private struct CloudSubmissionResultView: View {
    let id: UUID
    let context: CloudPresentationContext
    let isActive: Bool
    let onChanged: () -> Void
    let onResent: (UUID) -> Void
    @Environment(ConnectionHost.self) private var host
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        VStack(alignment: .leading, spacing: 12) {
            if let batch {
                photoPreview(batch)
                displays(batch)
            } else if let error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("cloud-result-unavailable")
            } else {
                ProgressView("Loading Activity…").frame(maxWidth: .infinity, minHeight: 60)
            }
            if let actionError {
                Text(actionError).font(.footnote).foregroundStyle(TesseraeTheme.danger)
                    .accessibilityIdentifier("cloud-result-error")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(isPresented: $showStorage) {
            if let batch { storageDetails(batch) }
        }
        .task(id: CloudActivityLoadKey(context: context, isVisible: isActive, revision: reloadRevision)) {
            guard isActive else { return }
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

    @ViewBuilder private func photoPreview(_ batch: CloudSubmissionBatch) -> some View {
        if let previewData, let image = UIImage(data: previewData) {
            ActivityExpandedPhoto(image: image, maximumHeight: 150)
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
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("cloud-result-preview-picker")
            }
        } else if mediaUnavailable(batch) {
            Text("The saved photo is no longer available.")
                .font(.footnote).foregroundStyle(.secondary)
                .accessibilityIdentifier("cloud-result-media-expired")
        }
    }

    private func displays(_ batch: CloudSubmissionBatch) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(selectsTargets ? String(localized: "Select Displays") : String(localized: "Displays")).font(.headline)
                Spacer(minLength: 0)
                if selectsTargets {
                    Button("Cancel") { selectsTargets = false }
                        .frame(minHeight: 44)
                } else {
                    moreMenu(batch)
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
                                Label("Try again for \(target.name)", systemImage: "arrow.clockwise")
                                    .labelStyle(.iconOnly)
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(TesseraeTheme.accent)
                                    .frame(width: 32, height: 32)
                                    .background(TesseraeTheme.accent.opacity(0.08), in: Circle())
                                    .frame(width: 44, height: 44)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("cloud-result-retry-\(target.id)")
                        }
                    }
                }
            }
            if selectsTargets {
                Button(batch.kind == .currentPage ? String(localized: "Refresh Selected Again") : String(localized: "Send Selected Again")) {
                    requestResend(selectedIDs)
                }
                .frame(minHeight: 44)
                .disabled(!canResend(batch) || selectedIDs.isEmpty)
                .accessibilityIdentifier("cloud-result-resend")
            }
        }
    }

    private func targetStatus(_ target: CloudSubmissionTarget, value: CloudTargetOutcome?, isActive: Bool) -> some View {
        let status = CloudDisplayActivityStatus(outcome: value, isActive: isActive)
        return HStack(spacing: 8) {
            Image(systemName: status.symbol)
                .font(.subheadline)
                .foregroundStyle(status.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(target.name).font(.subheadline.weight(.semibold))
                Text(status.label).font(.footnote.weight(.medium)).foregroundStyle(status.color)
            }
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }

    private func canResend(_ batch: CloudSubmissionBatch) -> Bool {
        !batch.isActive && !isResending && !mediaHidden && !mediaUnavailable(batch)
            && host.cloud?.snapshot?.account.auth.scopes.contains(batch.kind.requiredScope) == true
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
            Button(batch.kind == .currentPage ? "Refresh Again…" : "Send Again…", systemImage: "arrow.clockwise") {
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
                .tesseraeIconActionLabel()
        }
        .menuStyle(.button)
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
            guard !Task.isCancelled else { return }
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
            } catch {
                actionError = error.localizedDescription
                await reload()
                onChanged()
            }
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
                }
            } catch {
                actionError = error.localizedDescription
                mediaHidden = false
            }
            host.withCurrentCloudPresentation(context, onChanged)
            if mediaOnly || actionError != nil { reloadRevision = UUID() }
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

private struct CloudDisplayActivityStatus {
    let label: String
    let symbol: String
    let color: Color

    init(outcome: CloudTargetOutcome?, isActive: Bool) {
        switch outcome {
        case .generated(_, let warnings) where warnings.isEmpty:
            (label, symbol, color) = (String(localized: "Ready for next wake"), "checkmark.circle.fill", TesseraeTheme.success)
        case .generated:
            (label, symbol, color) = (String(localized: "Ready with a note"), "exclamationmark.circle.fill", TesseraeTheme.warning)
        case .refused(let problem, _, _):
            let reason: String
            switch problem {
            case .authorization: reason = String(localized: "Sign in to Cloud again.")
            case .quota: reason = String(localized: "Your Cloud plan limit was reached.")
            case .rateLimited: reason = String(localized: "Try again later")
            default: reason = String(localized: "Not sent")
            }
            (label, symbol, color) = (reason, "exclamationmark.circle.fill", TesseraeTheme.warning)
        case .notAttempted:
            (label, symbol, color) = (String(localized: "Not sent"), "exclamationmark.circle.fill", TesseraeTheme.warning)
        case nil where isActive:
            (label, symbol, color) = (String(localized: "Sending…"), "clock", .secondary)
        case .unknown, nil:
            (label, symbol, color) = (String(localized: "Couldn’t confirm"), "questionmark.circle.fill", TesseraeTheme.warning)
        }
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

    static func needsAttention(_ batch: CloudSubmissionBatch) -> Bool {
        batch.results.contains { !$0.outcome.isCleanGenerated } || (!batch.isActive && !isReady(batch))
    }

    static func summary(_ batch: CloudSubmissionBatch) -> String {
        if batch.isActive {
            return batch.kind == .currentPage ? String(localized: "Refreshing…") : String(localized: "Sending…")
        }
        if isReady(batch) { return String(localized: "Ready for next wake") }
        let ready = readyCount(batch)
        return ready > 0 ? String(localized: "\(ready) of \(batch.targets.count) displays ready")
            : labels(for: batch).joined(separator: " · ")
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

private struct CloudActivityLoadKey: Hashable {
    let context: CloudPresentationContext
    let isVisible: Bool
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
