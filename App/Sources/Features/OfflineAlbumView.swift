import SwiftUI
import TesseraeKit

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
            return .red
        }
        if target.observed?.state == .syncing || target.support.state == .unknown {
            return .orange
        }
        return TesseraeTheme.accent
    }
}

struct OfflineAlbumEditorView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var draft: OfflineAlbumEditorDraft
    @State private var preflight: OfflineAlbumPreflightResponse?
    @State private var isWorking = false
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
        _draft = State(
            initialValue: OfflineAlbumEditorDraft(
                folderName: folder.name,
                imageIDs: images.map(\.id),
                album: current?.album
            )
        )
    }

    private var hasConflicts: Bool {
        preflight?.targets.contains { $0.conflict != nil } == true
    }

    private var hasUnsupportedTarget: Bool {
        preflight?.targets.contains { $0.support.state == .unsupported } == true
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
            .navigationTitle(current == nil ? "New Offline Album" : "Offline Album")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(preflight == nil ? "Cancel" : "Back") {
                        if preflight == nil {
                            dismiss()
                        } else {
                            withAnimation(.smooth(duration: 0.2)) {
                                self.preflight = nil
                                replaceConflicts = false
                            }
                        }
                    }
                    .disabled(isWorking)
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button(preflight == nil ? "Review" : "Save") {
                        Task {
                            if preflight == nil {
                                await runPreflight()
                            } else {
                                await save()
                            }
                        }
                    }
                    .disabled(
                        isWorking
                            || draft.validationMessage != nil
                            || (preflight != nil && hasUnsupportedTarget)
                            || (hasConflicts && !replaceConflicts)
                            || model.offlineAlbumAuthoringPermission == .denied
                    )
                }
            }
            .interactiveDismissDisabled(isWorking)
        }
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
            Text("This unbinds the folder from its displays. It does not delete the folder or photos.")
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
                Toggle("Enabled", isOn: $draft.enabled)
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
                Text("Support is reported by Tesserae. Unknown displays may be selected with a warning; unsupported displays cannot be selected.")
            }

            Section("Presentation") {
                Picker("Photo Layout", selection: $draft.fit) {
                    Text("Fill").tag(OfflineAlbumFitMode.fill)
                    Text("Fit").tag(OfflineAlbumFitMode.fit)
                }
                .pickerStyle(.segmented)

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
                Text("Photos use the folder’s current order. Per-photo framing will be added separately after the server includes it in frame identity.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        .accessibilityIdentifier("offline-album-setup")
    }

    private func reviewForm(_ preflight: OfflineAlbumPreflightResponse) -> some View {
        Form {
            Section("Summary") {
                LabeledContent("Album", value: draft.name)
                LabeledContent("Photos", value: "\(images.count)")
                LabeledContent("Layout", value: draft.fit == .fill ? "Fill" : "Fit")
                LabeledContent("Playback", value: playbackSummary)
            }

            Section {
                ForEach(preflight.targets, id: \.deviceID) { target in
                    preflightTargetRow(target)
                }
            } header: {
                Text("Preflight")
            } footer: {
                Text("Storage and frame counts are calculated by Tesserae for each target panel. They are not estimated from the source-photo files by Companion.")
            }

            if hasConflicts {
                Section {
                    Toggle("Replace Existing Display Bindings", isOn: $replaceConflicts)
                } footer: {
                    Text("A selected display already belongs to another enabled Offline Album. Replacement only unbinds that display; it does not delete the other Album or its photos.")
                }
            }

            if preflight.targets.contains(where: { $0.support.state == .unknown }) {
                Section {
                    Label(
                        "At least one display has not recently confirmed Offline Album support. Saving may succeed, but fully offline playback is not guaranteed until it reports fresh capabilities.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
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
                        .foregroundStyle(support?.state == .unknown ? .orange : .secondary)
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
                    .foregroundStyle(target.support.state == .unknown ? .orange : .secondary)
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
                Text("Tesserae cannot provide a cache plan for this display yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let conflict = target.conflict {
                Label(
                    "Used by \(conflict.name)",
                    systemImage: "exclamationmark.triangle.fill"
                )
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private var playbackSummary: String {
        let mode = draft.playbackMode == .shuffle ? "Shuffle" : "In Order"
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
        guard draft.validationMessage == nil else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            let response = try await model.preflightOfflineAlbum(
                folderID: folder.id,
                draft: draft.albumDraft
            )
            withAnimation(.smooth(duration: 0.2)) {
                preflight = response
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func save() async {
        guard preflight != nil else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.saveOfflineAlbum(
                folderID: folder.id,
                draft: draft.albumDraft,
                replaceConflicts: replaceConflicts
            )
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
                draft = OfflineAlbumEditorDraft(
                    folderName: folder.name,
                    imageIDs: images.map(\.id),
                    album: latest
                )
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
        isWorking = true
        defer { isWorking = false }
        do {
            try await model.deleteOfflineAlbum(folderID: folder.id)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
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
