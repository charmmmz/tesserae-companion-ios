import SwiftUI
import TesseraeKit
import UIKit

struct OfflineAlbumEditorDraft: Equatable {
    var name: String
    var enabled: Bool
    var deviceIDs: [String]
    var order: [String]
    var fit: OfflineAlbumFitMode
    var playbackMode: OfflineAlbumPlaybackMode
    var intervalSeconds: Int
    var repeatMode: OfflineAlbumRepeatMode

    init(
        folderName: String,
        imageIDs: [String],
        album: OfflineAlbum? = nil
    ) {
        name = album?.name ?? folderName
        enabled = album?.enabled ?? true
        deviceIDs = album?.deviceIDs ?? []
        order = album?.order ?? imageIDs
        fit = album?.fit ?? .fill
        playbackMode = album?.playback.mode ?? .sequential
        intervalSeconds = album?.playback.intervalSeconds ?? 1_800
        repeatMode = album?.playback.repeatMode ?? .loop
    }

    var validationMessage: String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return String(localized: "Enter an Album name.")
        }
        if deviceIDs.isEmpty {
            return String(localized: "Choose at least one display.")
        }
        return nil
    }

    func hasChanges(comparedTo baseline: Self) -> Bool {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            != baseline.name.trimmingCharacters(in: .whitespacesAndNewlines)
            || enabled != baseline.enabled
            || Set(deviceIDs) != Set(baseline.deviceIDs)
            || order != baseline.order
            || fit != baseline.fit
            || playbackMode != baseline.playbackMode
            || intervalSeconds != baseline.intervalSeconds
            || repeatMode != baseline.repeatMode
    }

    var albumDraft: OfflineAlbumDraft {
        OfflineAlbumDraft(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines),
            enabled: enabled,
            deviceIDs: deviceIDs,
            order: order,
            fit: fit,
            playback: OfflineAlbumPlayback(
                mode: playbackMode,
                intervalSeconds: intervalSeconds,
                repeatMode: repeatMode
            )
        )
    }
}

func offlineAlbumCanSelectTarget(_ support: DeviceCapabilitySupport?) -> Bool {
    support?.state != .unsupported
}

func offlineAlbumShouldShowReview(
    isExistingAlbum: Bool,
    draft: OfflineAlbumEditorDraft,
    baseline: OfflineAlbumEditorDraft
) -> Bool {
    !isExistingAlbum || draft.hasChanges(comparedTo: baseline)
}

func offlineAlbumNormalizedExplicitOrder(
    _ explicitOrder: [String],
    folderOrder: [String]
) -> [String] {
    let availableIDs = Set(folderOrder)
    var seenIDs = Set<String>()
    return explicitOrder.filter { imageID in
        availableIDs.contains(imageID) && seenIDs.insert(imageID).inserted
    }
}

func offlineAlbumResolvedPhotoOrder(
    explicitOrder: [String],
    folderOrder: [String]
) -> [String] {
    let explicit = offlineAlbumNormalizedExplicitOrder(
        explicitOrder,
        folderOrder: folderOrder
    )
    let explicitIDs = Set(explicit)
    return explicit + folderOrder.filter { !explicitIDs.contains($0) }
}

func offlineAlbumTargetStatus(
    _ target: OfflineAlbumTarget
) -> String {
    if let observed = target.observed {
        switch observed.state {
        case .syncing:
            if let cached = observed.cached, let total = observed.total {
                return String(localized: "Syncing \(cached) of \(total)")
            }
            return String(localized: "Syncing")
        case .playing:
            return String(localized: "Playing offline")
        case .paused:
            return String(localized: "Paused")
        case .error:
            return String(localized: "Needs attention")
        }
    }
    switch target.support.state {
    case .supported:
        return String(localized: "Ready to sync")
    case .unknown:
        return String(localized: "Support not recently confirmed")
    case .unsupported:
        return String(localized: "Offline playback unavailable")
    }
}

struct OfflineAlbumSummaryCard: View {
    let response: OfflineAlbumResponse
    let displays: [DisplaySummary]
    let open: () -> Void

    private var displayByID: [String: DisplaySummary] {
        Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
    }

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.fill.badge.wifi")
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(TesseraeTheme.accent)
                        .frame(width: 42, height: 42)
                        .background(
                            TesseraeTheme.accent.opacity(0.11),
                            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                        )

                    VStack(alignment: .leading, spacing: 2) {
                        Text(response.album.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Text(response.album.enabled ? "Offline Album" : "Offline Album · Paused")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }

                ForEach(response.targets, id: \.deviceID) { target in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(statusColor(target))
                            .frame(width: 7, height: 7)
                        Text(displayByID[target.deviceID]?.name ?? target.deviceID)
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        Text(offlineAlbumTargetStatus(target))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .tesseraeCard()
        .accessibilityIdentifier("offline-album-summary")
    }

    private func statusColor(_ target: OfflineAlbumTarget) -> Color {
        if target.observed?.state == .error || target.support.state == .unsupported {
            return TesseraeTheme.danger
        }
        if target.support.state == .unknown {
            return TesseraeTheme.warning
        }
        switch target.observed?.state {
        case .syncing:
            return TesseraeTheme.info
        case .playing:
            return TesseraeTheme.success
        case .paused, .none:
            return .secondary
        case .error:
            return TesseraeTheme.danger
        }
    }
}

struct OfflineAlbumEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var draft: OfflineAlbumEditorDraft
    @State private var baselineDraft: OfflineAlbumEditorDraft
    @State private var session = DraftEditingSession()
    @State private var preflight: OfflineAlbumPreflightResponse?
    @State private var replaceConflicts = false
    @State private var errorMessage: String?
    @State private var deleting = false

    let folder: GalleryFolder
    let images: [GalleryImage]
    let current: OfflineAlbumResponse?

    private let intervals = [60, 300, 900, 1_800, 3_600, 10_800, 21_600, 43_200, 86_400]

    init(
        folder: GalleryFolder,
        images: [GalleryImage],
        current: OfflineAlbumResponse?
    ) {
        self.folder = folder
        self.images = images
        self.current = current
        let initialDraft = OfflineAlbumEditorDraft(
            folderName: folder.name,
            imageIDs: images.map(\.id),
            album: current?.album
        )
        // The editor owns its draft until it saves, discards, or explicitly reloads a conflict.
        _draft = State(initialValue: initialDraft)
        _baselineDraft = State(initialValue: initialDraft)
    }

    private var hasConflicts: Bool {
        preflight?.targets.contains { $0.conflict != nil } == true
    }

    private var isWorking: Bool {
        session.isSaving
    }

    private var hasUnsupportedTarget: Bool {
        preflight?.targets.contains { $0.support.state == .unsupported } == true
    }

    private var shouldShowReview: Bool {
        offlineAlbumShouldShowReview(
            isExistingAlbum: current != nil,
            draft: draft,
            baseline: baselineDraft
        )
    }

    var body: some View {
        NavigationStack {
            Group {
                if let preflight {
                    reviewForm(preflight)
                } else {
                    setupForm
                }
            }
            .disabled(isWorking)
            .navigationTitle(current == nil ? "New Album" : "Offline Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        if preflight == nil {
                            updateDirtyState()
                            if session.canExit(to: .close) { dismiss() }
                        } else {
                            self.preflight = nil
                            replaceConflicts = false
                        }
                    } label: {
                        Label(
                            preflight == nil ? String(localized: "Cancel") : String(localized: "Back"),
                            systemImage: preflight == nil ? "xmark" : "chevron.left"
                        )
                        .labelStyle(.iconOnly)
                    }
                    .disabled(isWorking)
                    .accessibilityIdentifier("offline-album-exit")
                }

                if preflight != nil || shouldShowReview {
                    ToolbarItem(placement: .confirmationAction) {
                        Button {
                            Task {
                                if preflight == nil {
                                    await runPreflight()
                                } else {
                                    await save()
                                }
                            }
                        } label: {
                            if preflight == nil {
                                Text("Review")
                            } else {
                                Label("Save", systemImage: "checkmark")
                                    .labelStyle(.iconOnly)
                            }
                        }
                        .disabled(
                            isWorking
                                || draft.validationMessage != nil
                                || (preflight != nil && hasUnsupportedTarget)
                                || (hasConflicts && !replaceConflicts)
                                || model.offlineAlbumAuthoringPermission == .denied
                        )
                        .accessibilityIdentifier("offline-album-review-save")
                    }
                }
            }
        }
        .modifier(DraftExitProtection(session: session) { _ in dismiss() })
        .onChange(of: draft, initial: true) { updateDirtyState() }
        .onChange(of: baselineDraft) { updateDirtyState() }
        .alert("Couldn’t Continue", isPresented: errorPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(errorMessage ?? "Unknown error")
        }
        .confirmationDialog(
            "Remove Offline Album?",
            isPresented: $deleting,
            titleVisibility: .visible
        ) {
            Button("Remove Offline Album", role: .destructive) {
                Task { await deleteAlbum() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Stops this Album on its displays. Your folder and photos are kept.")
        }
    }

    private var setupForm: some View {
        Form {
            if model.offlineAlbumAuthoringPermission == .denied {
                Section {
                    Label(
                        "This pairing can view Offline Albums but cannot change them.",
                        systemImage: "lock.fill"
                    )
                    .foregroundStyle(.secondary)
                    Button("Open Tesserae Settings") {
                        openOfflineAlbumSettings()
                    }
                }
            }

            Section("Album") {
                TextField("Name", text: $draft.name)
                    .textInputAutocapitalization(.words)
                    .accessibilityIdentifier("offline-album-name")
                Toggle("Enabled", isOn: $draft.enabled)
                    .accessibilityIdentifier("offline-album-enabled")
            }

            Section {
                if model.sortedDisplays.isEmpty {
                    ContentUnavailableView(
                        "No Displays",
                        systemImage: "display.slash",
                        description: Text("Add a display before creating an Offline Album.")
                    )
                } else {
                    ForEach(model.sortedDisplays) { display in
                        targetRow(display)
                    }
                }
            } header: {
                Text("Displays")
            } footer: {
                Text("Displays without offline playback are unavailable. Review will check the selected displays before saving.")
            }

            Section("Presentation") {
                Picker("Photo Layout", selection: $draft.fit) {
                    Text("Fill").tag(OfflineAlbumFitMode.fill)
                    Text("Fit").tag(OfflineAlbumFitMode.fit)
                }
                .tesseraeAdaptivePickerStyle()

                Picker("Order", selection: $draft.playbackMode) {
                    Text("In Order").tag(OfflineAlbumPlaybackMode.sequential)
                    Text("Shuffle").tag(OfflineAlbumPlaybackMode.shuffle)
                }

                Picker("Change Photo", selection: $draft.intervalSeconds) {
                    ForEach(intervals, id: \.self) { seconds in
                        Text(intervalLabel(seconds)).tag(seconds)
                    }
                }

                Picker("After the Last Photo", selection: $draft.repeatMode) {
                    Text("Start Over").tag(OfflineAlbumRepeatMode.loop)
                    Text("Reshuffle").tag(OfflineAlbumRepeatMode.reshuffle)
                    Text("Stop").tag(OfflineAlbumRepeatMode.once)
                }
            }

            Section {
                LabeledContent("Photos", value: "\(images.count)")
                NavigationLink {
                    OfflineAlbumPhotoOrderView(
                        images: images,
                        explicitOrder: $draft.order
                    )
                } label: {
                    LabeledContent(
                        "Photo Order",
                        value: draft.order.isEmpty ? "Folder Order" : "Custom"
                    )
                }
                .disabled(images.count < 2)
                .accessibilityIdentifier("offline-album-photo-order-link")
            } footer: {
                Text("New photos are added at the end. Photo layout applies to the whole Album; individual cropping isn’t available.")
            }

            if let validationMessage = draft.validationMessage {
                Section {
                    Label(validationMessage, systemImage: "exclamationmark.circle")
                        .foregroundStyle(.secondary)
                }
            }

            if current != nil {
                Section {
                    Button("Remove Offline Album", role: .destructive) {
                        deleting = true
                    }
                    .disabled(
                        isWorking || model.offlineAlbumAuthoringPermission == .denied
                    )
                }
            }
        }
        .scrollContentBackground(.hidden)
        .tesseraeScreenBackground()
        .accessibilityIdentifier("offline-album-setup")
    }

    private func reviewForm(_ preflight: OfflineAlbumPreflightResponse) -> some View {
        Form {
            Section("Summary") {
                LabeledContent("Album", value: draft.albumDraft.name)
                LabeledContent("Photos", value: "\(images.count)")
                LabeledContent("Layout", value: draft.fit == .fill ? "Fill" : "Fit")
                LabeledContent("Playback", value: playbackSummary)
            }

            Section {
                ForEach(preflight.targets, id: \.deviceID) { target in
                    preflightTargetRow(target)
                }
            } header: {
                Text("Display Check")
            } footer: {
                Text("Tesserae checks offline capacity and storage for each display. Displays need to connect to sync this Album.")
            }

            if hasConflicts {
                Section {
                    Toggle("Use These Displays for This Album", isOn: $replaceConflicts)
                        .accessibilityIdentifier("offline-album-replace-conflicts")
                } footer: {
                    Text("These displays will stop playing their other Offline Albums. The other Albums and photos are kept.")
                }
            }

            if preflight.targets.contains(where: { $0.support.state == .unknown }) {
                Section {
                    Label(
                        "You can save, but offline playback isn’t guaranteed on displays with unconfirmed support.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(TesseraeTheme.warning)
                }
            }

            if isWorking {
                Section {
                    HStack {
                        ProgressView()
                        Text("Saving Offline Album…")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .tesseraeScreenBackground()
        .accessibilityIdentifier("offline-album-review")
    }

    private func targetRow(_ display: DisplaySummary) -> some View {
        let support = display.frameCacheSupport
        let selectable = offlineAlbumCanSelectTarget(support)
        let selected = draft.deviceIDs.contains(display.id)
        let interactive = selectable || selected

        return Button {
            guard interactive else { return }
            if selected {
                draft.deviceIDs.removeAll { $0 == display.id }
            } else {
                draft.deviceIDs.append(display.id)
            }
        } label: {
            HStack(spacing: 12) {
                PhosphorIcon(
                    name: display.canonicalIconName,
                    size: 20,
                    color: interactive ? TesseraeTheme.accent : .secondary,
                    fallbackSystemName: "display"
                )
                .frame(width: 42, height: 42)
                .background(
                    (interactive ? TesseraeTheme.accent : Color.secondary).opacity(0.10),
                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                )

                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name)
                        .font(.headline)
                        .foregroundStyle(interactive ? .primary : .secondary)
                    Text(supportDescription(support))
                        .font(.caption)
                        .foregroundStyle(support?.state == .unknown ? TesseraeTheme.warning : .secondary)
                }

                Spacer(minLength: 8)

                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(TesseraeTheme.accent)
                } else if support?.state == .unsupported {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "circle")
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!interactive)
        .accessibilityIdentifier("offline-album-target-\(display.id)")
    }

    private func preflightTargetRow(_ target: OfflineAlbumTarget) -> some View {
        let display = model.displays.first { $0.id == target.deviceID }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(display?.name ?? target.deviceID)
                    .font(.headline)
                Spacer()
                Text(supportDescription(target.support))
                    .font(.caption)
                    .foregroundStyle(target.support.state == .unknown ? TesseraeTheme.warning : .secondary)
            }

            if let plan = target.plan {
                LabeledContent(
                    plan.accuracy == .exact ? "Local Frames" : "Estimated Local Frames",
                    value: "\(plan.cacheableFrames) of \(plan.totalFrames)"
                )
                .font(.subheadline)
                LabeledContent(
                    "Offline",
                    value: plan.fullyOffline ? "Complete" : "Partial"
                )
                .font(.subheadline)
                if let storage = plan.storage {
                    LabeledContent(
                        storage.accuracy == .exact ? "Storage" : "Estimated Storage",
                        value: ByteCountFormatter.string(
                            fromByteCount: Int64(storage.bytes),
                            countStyle: .file
                        )
                    )
                    .font(.subheadline)
                }
            } else {
                Text("Offline capacity isn’t available for this display yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let conflict = target.conflict {
                Label(
                    "Used by \(conflict.name)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .font(.caption)
                    .foregroundStyle(TesseraeTheme.warning)
            }
        }
        .padding(.vertical, 4)
    }

    private var playbackSummary: String {
        let mode = draft.playbackMode == .shuffle
            ? String(localized: "Shuffle") : String(localized: "In Order")
        return "\(mode) · \(intervalLabel(draft.intervalSeconds))"
    }

    private func supportDescription(_ support: DeviceCapabilitySupport?) -> String {
        guard let support else {
            return String(localized: "Support not reported")
        }
        switch support.state {
        case .supported:
            if let maxFrames = support.frameCacheMaxFrames {
                return String(localized: "Offline ready · up to \(maxFrames) frames")
            }
            return String(localized: "Offline ready")
        case .unknown:
            return String(localized: "Support not recently confirmed")
        case .unsupported:
            return String(localized: "Offline playback unavailable")
        }
    }

    private func intervalLabel(_ seconds: Int) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds < 3_600 ? [.minute] : [.hour, .minute]
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        return formatter.string(from: TimeInterval(seconds)) ?? "\(seconds) seconds"
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { presented in
                if !presented { errorMessage = nil }
            }
        )
    }

    private func runPreflight() async {
        guard !isWorking, draft.validationMessage == nil, shouldShowReview else { return }
        session.isSaving = true
        defer { session.isSaving = false }
        do {
            let response = try await model.preflightOfflineAlbum(
                folderID: folder.id,
                draft: draft.albumDraft
            )
            preflight = response
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard !isWorking, preflight != nil, !hasUnsupportedTarget,
              !hasConflicts || replaceConflicts else { return }
        session.isSaving = true
        defer { session.isSaving = false }
        do {
            try await model.saveOfflineAlbum(
                folderID: folder.id,
                draft: draft.albumDraft,
                replaceConflicts: replaceConflicts
            )
            session.hasChanges = false
            dismiss()
        } catch let error as TesseraeClientError {
            switch error {
            case .offlineAlbumConflict:
                replaceConflicts = false
            case let .offlineAlbumUnsupportedTargets(deviceIDs, _, _):
                replaceConflicts = false
                do {
                    preflight = try await model.preflightOfflineAlbum(
                        folderID: folder.id,
                        draft: draft.albumDraft
                    )
                } catch {
                    preflight = nil
                }
                let names = deviceIDs.map { deviceID in
                    model.displays.first { $0.id == deviceID }?.name ?? deviceID
                }
                errorMessage = String(
                    localized: "Offline Album support changed for: \(names.joined(separator: ", ")). Review the target selection before saving again."
                )
                return
            case let .server(code, _, _) where code == "precondition_failed":
                let latest = model.offlineAlbumsByFolderID[folder.id]?.album
                let latestDraft = OfflineAlbumEditorDraft(
                    folderName: folder.name,
                    imageIDs: images.map(\.id),
                    album: latest
                )
                draft = latestDraft
                baselineDraft = latestDraft
                updateDirtyState()
                preflight = nil
                replaceConflicts = false
                errorMessage = String(
                    localized: "This Offline Album changed elsewhere. The latest version has been reloaded; review it before saving."
                )
                return
            default:
                break
            }
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteAlbum() async {
        guard !isWorking else { return }
        session.isSaving = true
        defer { session.isSaving = false }
        do {
            try await model.deleteOfflineAlbum(folderID: folder.id)
            session.hasChanges = false
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func updateDirtyState() {
        session.hasChanges = draft.hasChanges(comparedTo: baselineDraft)
    }

    private func openOfflineAlbumSettings() {
        guard let instance = model.activeInstance else { return }
        let destination = model.offlineAlbumSettingsURL ?? instance.webURL
        guard let url = URL(
            string: destination,
            relativeTo: instance.baseURL
        )?.absoluteURL else {
            return
        }
        openURL(url)
    }
}

private struct OfflineAlbumPhotoOrderView: View {
    let images: [GalleryImage]
    @Binding var explicitOrder: [String]

    @State private var editMode: EditMode = .active

    private var folderOrder: [String] {
        images.map(\.id)
    }

    private var orderedIDs: [String] {
        offlineAlbumResolvedPhotoOrder(explicitOrder: explicitOrder, folderOrder: folderOrder)
    }

    private var usesFolderOrder: Bool {
        explicitOrder.isEmpty
    }

    private var imageByID: [String: GalleryImage] {
        Dictionary(uniqueKeysWithValues: images.map { ($0.id, $0) })
    }

    private var orderedImages: [GalleryImage] {
        orderedIDs.compactMap { imageByID[$0] }
    }

    var body: some View {
        List {
            Section {
                ForEach(Array(orderedImages.enumerated()), id: \.element.id) { index, image in
                    HStack(spacing: 12) {
                        OfflineAlbumOrderThumbnail(image: image)
                            .frame(width: 52, height: 52)
                            .clipShape(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                            )

                        VStack(alignment: .leading, spacing: 3) {
                            Text(image.name)
                                .font(.body)
                                .lineLimit(1)
                            Text("\(image.width) × \(image.height)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 8)

                        Text(index + 1, format: .number)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Position \(index + 1)")
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("offline-album-order-\(image.id)")
                    .accessibilityActions {
                        if index > 0 {
                            Button("Move Up") { move(image.id, by: -1) }
                        }
                        if index < orderedImages.count - 1 {
                            Button("Move Down") { move(image.id, by: 1) }
                        }
                    }
                }
                .onMove { source, destination in
                    var reordered = orderedIDs
                    reordered.move(fromOffsets: source, toOffset: destination)
                    if reordered != orderedIDs { explicitOrder = reordered }
                }
            } header: {
                Text("Playback Order")
            } footer: {
                Text(
                    usesFolderOrder
                        ? "Following the folder’s natural order."
                        : "Using a custom order. New photos are appended after these photos."
                )
            }

            Section {
                Button("Use Folder Order", systemImage: "arrow.uturn.backward") {
                    withAnimation {
                        explicitOrder = []
                    }
                }
                .disabled(usesFolderOrder)
                .accessibilityIdentifier("offline-album-folder-order")
            }
        }
        .scrollContentBackground(.hidden)
        .tesseraeScreenBackground()
        .environment(\.editMode, $editMode)
        .navigationTitle("Photo Order")
        .navigationBarTitleDisplayMode(.inline)
        .accessibilityIdentifier("offline-album-photo-order")
    }

    private func move(_ imageID: String, by offset: Int) {
        var reordered = orderedIDs
        guard let source = reordered.firstIndex(of: imageID),
              reordered.indices.contains(source + offset) else { return }
        withAnimation {
            reordered.swapAt(source, source + offset)
            explicitOrder = reordered
        }
    }
}

private struct OfflineAlbumOrderThumbnail: View {
    @Environment(AppModel.self) private var model

    let image: GalleryImage

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.secondary.opacity(0.10))

            if let data = model.galleryThumbnailStates[image.thumbnailURL]?.data,
               let thumbnail = UIImage(data: data)
            {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
            } else if model.galleryThumbnailStates[image.thumbnailURL]?.showsProgress == true {
                ProgressView()
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .clipped()
        .task(id: image.thumbnailURL) {
            await model.loadGalleryThumbnail(path: image.thumbnailURL)
        }
        .accessibilityHidden(true)
    }
}
