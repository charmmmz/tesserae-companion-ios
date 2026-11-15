import SwiftUI
import TesseraeKit

struct CloudPendingReview: Identifiable {
    let input: CloudPendingInput
    let data: Data
    let read: CloudEntryReadContext
    var id: UUID { input.id }
}

struct CloudSendSheet: View {
    let model: CloudBrowseModel
    let context: CloudPresentationContext
    var recovery: CloudPendingReview? = nil
    var onRecoveryAccepted: ((UUID) -> Void)? = nil
    @Environment(ConnectionHost.self) private var host
    @Environment(CompanionPresentation.self) private var presentation
    @State private var media = MediaFrameSession()
    @State private var previewImage: UIImage?
    @State private var framing = PhotoFramingSession()
    @State private var selection: MediaPickerSelection?
    @State private var pickerPresented = false
    @State private var livePhotosOnly = false
    @State private var appliedMediaSourceID: UUID?
    @State private var selectedIDs: Set<String> = []
    @State private var didLoadPreferences = false
    @State private var previewID: String?
    @State private var canvasHeight: CGFloat = 276
    @State private var fit: ImageFitMode = .fill
    @State private var decision = UUID()
    @State private var isPreparing = false
    @State private var isLoadingMedia = false
    @State private var savedDisplayWarning: String?
    @State private var error: String?
    @State private var recoveryOutcome: CloudEntryCompletion?
    @State private var recoveryExpired = false
    @State private var recoverySubmissionTask: Task<Void, Never>?
    private var reviewHasExpired: Bool { recoveryExpired || recovery.map { $0.input.expiresAt <= Date() } == true }
    private var unavailableIDs: [String] { selectedIDs.subtracting(devices.map(\.id)).sorted() }

    private var devices: [CloudDevice] { (recovery?.read.devices ?? model.devices).filter { $0.panel.compositionGeometry != nil } }
    private var selected: [CloudDevice] { devices.filter { selectedIDs.contains($0.id) } }
    private var preview: CloudDevice? { selected.first { $0.id == previewID } ?? selected.first ?? devices.first }
    private var aspect: PanelAspectRatio? {
        preview?.panel.compositionGeometry.map { .init(width: $0.width, height: $0.height) }
    }
    private var image: UIImage? { media.scrubbingPreview ?? previewImage }
    private var framingBinding: Binding<ImageFraming>? {
        guard fit == .fill, media.output != nil, image != nil, let aspect else { return nil }
        return Binding(get: { framing.framing(for: aspect) }, set: { framing.setFraming($0, for: aspect) })
    }
    private var automaticContext: PhotoFramingSession.AutomaticContext {
        .init(imageID: framing.imageID, instanceID: context.fence.connectionID.rawValue,
            aspect: aspect, targetIDs: selectedIDs, maximumZoom: 4,
            isReady: fit == .fill && media.output != nil && !media.isBusy && !isPreparing && !selectedIDs.isEmpty)
    }
    var body: some View {
        NavigationStack {
            if reviewHasExpired {
                ContentUnavailableView("Item Expired", systemImage: "clock.badge.exclamationmark",
                    description: Text("This unsent photo is no longer available."))
            } else {
                AdaptiveComposerLayout {
                    VStack(alignment: .leading, spacing: TesseraeComposerLayout.contentCardSpacing) {
                        TesseraeComposerPreviewHeader(titleAccessibilityIdentifier: "send-preview-title",
                            changePhotoAccessibilityIdentifier: "send-change-photo", isLoading: isLoadingMedia,
                            onChoosePhoto: media.output != nil ? { livePhotosOnly = false; pickerPresented = true } : nil)
                        TesseraeComposerMediaPreview(session: media, canvasHeight: canvasHeight, isSending: isPreparing,
                            onChooseLivePhoto: { livePhotosOnly = true; pickerPresented = true }) {
                            canvas
                        } targets: { previewPicker }
                        if isPreparing { ProgressView("Preparing Send…").accessibilityIdentifier("cloud-send-preparing") }
                        if let error { Text(error).foregroundStyle(.red).accessibilityIdentifier("cloud-send-error") }
                    }
                    .tesseraeCard()
                } controls: {
                    VStack(alignment: .leading, spacing: TesseraeComposerLayout.selectionCardSpacing) {
                        Text("Displays").font(.headline)
                        if let savedDisplayWarning {
                            Text(savedDisplayWarning)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .accessibilityIdentifier("cloud-send-saved-displays-unavailable")
                        }
                        ForEach(devices) { device in
                            Button {
                                savedDisplayWarning = nil
                                if selectedIDs.contains(device.id) { selectedIDs.remove(device.id) }
                                else { selectedIDs.insert(device.id); previewID = device.id }
                            } label: {
                                TesseraeDisplaySelectionRow(name: device.name,
                                    resolution: "\(device.panel.width)×\(device.panel.height)",
                                    isSelected: selectedIDs.contains(device.id), transport: nil, isAvailable: true)
                            }
                            .buttonStyle(.plain)
                            .disabled(!didLoadPreferences)
                            .accessibilityIdentifier("send-display-\(device.id)")
                        }
                        ForEach(unavailableIDs, id: \.self) { id in
                            Button { selectedIDs.remove(id) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    TesseraeDisplaySelectionRow(name: recovery?.read.devices.first { $0.id == id }?.name ?? id,
                                        resolution: "", isSelected: true, transport: nil, isAvailable: false)
                                    Text(recovery?.read.devices.contains { $0.id == id } == true
                                        ? "This display's panel configuration is not supported. Deselect it to continue."
                                        : "This display is no longer available. Deselect it to continue.")
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.plain).accessibilityIdentifier("cloud-review-unavailable-\(id)")
                        }
                        if devices.isEmpty {
                            Text("Refresh Displays before sending an image.").foregroundStyle(.secondary)
                        }
                        Text("A generated frame appears on each display's next wake. Its dashboard binding stays unchanged.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .tesseraeCard()
                }
                .disabled(isPreparing)
                .onGeometryChange(for: CGSize.self) { $0.size } action: { canvasHeight = composerCanvasHeight(in: $0) }
                .navigationTitle(recovery == nil ? String(localized: "Send") : String(localized: "Review Photo"))
                .navigationBarTitleDisplayMode(.inline)
                .tesseraeScreenBackground()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { presentation.sheet = nil }
                            .labelStyle(.iconOnly).disabled(isPreparing)
                            .accessibilityIdentifier("root-send-close")
                    }
                    TesseraeToolbarActions(identifier: "send-toolbar-actions") {
                        Button("Send to Displays", systemImage: "paperplane.fill") { send() }
                            .disabled(media.output == nil || media.isBusy || media.isScrubbing || isLoadingMedia || selectedIDs.isEmpty || !unavailableIDs.isEmpty || isPreparing || reviewHasExpired)
                            .accessibilityIdentifier("send-submit")
                    }
                }
            }
        }
        .frame(idealWidth: 960, idealHeight: 760)
        .presentationSizing(.fitted)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isPreparing)
        .mediaLibraryPicker(isPresented: $pickerPresented, selection: $selection, livePhotosOnly: livePhotosOnly)
        .task(id: selection?.id) { await loadSelection() }
        .task {
            if let recovery { await loadRecovery(recovery) }
            else { await loadPreferences() }
        }
        .sheet(isPresented: Binding(get: { recoveryOutcome != nil }, set: { if !$0 { recoveryOutcome = nil } })) {
            if let recoveryOutcome {
                NavigationStack {
                    CloudEntryOutcomeView(completion: recoveryOutcome)
                        .toolbar { ToolbarItem(placement: .confirmationAction) {
                            Button("Done", systemImage: "checkmark") { presentation.sheet = nil }
                                .labelStyle(.iconOnly)
                        } }
                }
            }
        }
        .onAppear { presentation.isSendComposerPresented = true }
        .onDisappear {
            if recovery != nil { recoverySubmissionTask?.cancel() }
            media.cancelWork(); framing.discardAnalysis(); presentation.isSendComposerPresented = false
        }
        .task(id: recovery?.input.expiresAt) {
            guard let deadline = recovery?.input.expiresAt else { return }
            do { if deadline > Date() { try await Task.sleep(for: .seconds(deadline.timeIntervalSinceNow)) } }
            catch { return }
            recoveryExpired = true; recoverySubmissionTask?.cancel()
            previewImage = nil; recoveryOutcome = nil; media.clear(); framing.discardAnalysis()
        }
        .onChange(of: media.outputRevision) { _, _ in
            guard !reviewHasExpired else { previewImage = nil; return }
            previewImage = media.output.flatMap { UIImage(data: $0.data) }
            if appliedMediaSourceID != media.source?.id { framing.replaceImage(); appliedMediaSourceID = media.source?.id }
            else { framing.discardAnalysis() }
            decision = UUID()
        }
        .onChange(of: selectedIDs) { _, _ in decision = UUID(); savePreferences() }
        .onChange(of: fit) { _, _ in decision = UUID(); savePreferences() }
        .onChange(of: framing.framings) { _, _ in decision = UUID() }
        .onChange(of: automaticContext, initial: true) { _, value in framing.updateAutomaticContext(value, data: media.output?.data) }
    }

    @ViewBuilder private var canvas: some View {
        if let preview {
            let panel = PanelProfile(width: preview.panel.width, height: preview.panel.height,
                gamut: preview.panel.gamut ?? "", orientation: preview.panel.width >= preview.panel.height ? "landscape" : "portrait")
            TesseraePanelImagePreview(image: image, panel: panel, contentInset: preview.panel.underscan ?? 0,
                fit: fit, maximumCanvasHeight: canvasHeight - 14, emptyTitle: String(localized: "Choose a photo or video"),
                accessibilityIdentifier: "send-panel-preview", imageAccessibilityIdentifier: "selected-image-preview",
                framing: framingBinding, fitSelection: $fit, availableFitModes: [.fill, .fit],
                maximumFramingZoom: 4, onCanvasTap: media.output == nil ? { livePhotosOnly = false; pickerPresented = true } : nil,
                prioritizesFramingGesture: true, framingEditingEnabled: !isPreparing && !media.isBusy,
                onAutoFrame: fit == .fill && media.output != nil ? { autoFrame() } : nil,
                isAutoFraming: framing.isAnalyzing, autoFramingFeedback: framing.feedback,
                onFramingInteraction: { if let aspect { framing.userDidInteract(with: aspect) } })
        } else {
            ContentUnavailableView("No Cloud Displays", systemImage: "display")
        }
    }
    @ViewBuilder private var previewPicker: some View {
        if selected.isEmpty {
            Text("None selected").font(.footnote).foregroundStyle(.secondary)
        } else {
            selectedPreviewPicker
        }
    }

    private var selectedPreviewPicker: some View {
        Menu {
            ForEach(selected) { device in
                Button { previewID = device.id } label: {
                    Label(device.name, systemImage: preview?.id == device.id ? "checkmark.circle.fill" : "circle")
                }
                .accessibilityIdentifier("send-preview-display-\(device.id)")
            }
        } label: {
            Label(preview.map { "\($0.name) · \($0.panel.width) × \($0.panel.height)" } ?? String(localized: "None selected"),
                  systemImage: "rectangle.on.rectangle")
                .font(.footnote.weight(.semibold)).frame(minHeight: 44)
        }
        .accessibilityIdentifier("send-preview-display-picker")
    }
    private func loadPreferences() async {
        guard !didLoadPreferences else { return }
        do {
            let preferences = try await host.cloudSendPreferences(context: context)
            guard !Task.isCancelled else { return }
            let selection = CloudShareSelection(devices: devices, preferredIDs: preferences?.deviceIDs ?? [])
            selectedIDs = selection.initialIDs
            savedDisplayWarning = selection.selectionWarning
            if let savedFit = preferences?.imageFitMode, [.fit, .fill].contains(savedFit) { fit = savedFit }
            previewID = selected.first?.id
        } catch {
            guard !Task.isCancelled else { return }
            savedDisplayWarning = String(localized: "Could not load your saved displays. Choose a display to send to.")
        }
        didLoadPreferences = true
    }
    private func loadRecovery(_ review: CloudPendingReview) async {
        guard !didLoadPreferences, !reviewHasExpired else { return }
        isLoadingMedia = true
        defer { isLoadingMedia = false }
        do {
            let bytes = review.data
            let image = try await Task.detached {
                try UploadImagePreparer.prepare(data: bytes, fallbackContentType: "image/jpeg", maximumPixelSize: 8192)
            }.value
            try Task.checkCancellation()
            guard host.cloudPresentationContext == context, !reviewHasExpired else { return }
            media.adopt(MediaFrameSource(kind: .photo, primaryImage: image, maximumPixelSize: 8192,
                loadMovie: { throw MediaFrameError.unavailable }))
            previewImage = UIImage(data: image.data)
            appliedMediaSourceID = media.source?.id
            framing.replaceImage()
            for (aspect, value) in review.input.recipe?.framings ?? [:] { framing.setFraming(value, for: aspect) }
            fit = review.input.recipe?.fit ?? .fill
            selectedIDs = Set(review.input.targets.deviceIDs)
            previewID = devices.first { selectedIDs.contains($0.id) }?.id
            didLoadPreferences = true
        } catch { self.error = error.localizedDescription }
    }
    private func savePreferences() {
        guard didLoadPreferences, recovery == nil, savedDisplayWarning == nil, !selectedIDs.isEmpty else { return }
        let selected = selectedIDs, fit = fit
        Task { try? await host.saveCloudSendPreferences(targetIDs: selected, fit: fit, context: context) }
    }
    private func autoFrame() {
        guard let aspect, let data = media.output?.data else { return }
        framing.request(data: data, aspect: aspect, maximumZoom: 4)
    }
    private func loadSelection() async {
        guard let selection else { return }
        let selectionID = selection.id
        isLoadingMedia = true
        defer { if self.selection?.id == selectionID { isLoadingMedia = false } }
        do {
            let source = try await selection.load(maximumPixelSize: 8192)
            try Task.checkCancellation()
            guard self.selection?.id == selectionID, !reviewHasExpired else { return }
            media.adopt(source); error = nil
        } catch is CancellationError { }
        catch { if self.selection?.id == selectionID { self.error = error.localizedDescription } }
    }
    private func send() {
        guard !isPreparing, !isLoadingMedia, let still = media.output, !media.isBusy, !media.isScrubbing,
              !reviewHasExpired, unavailableIDs.isEmpty else { return }
        framing.freeze(); isPreparing = true; error = nil
        let selected = selectedIDs, fit = fit, framings = framing.framings, decision = decision
        let task = Task {
            defer { isPreparing = false }
            do {
                if let recovery {
                    let result = try await host.replaceCloudPending(recovery, media: still, selectedIDs: selected,
                        fit: fit, framings: framings, decision: decision, context: context)
                    host.withCurrentCloudPresentation(context) {
                        if case .finished(let batch) = result, let onRecoveryAccepted { onRecoveryAccepted(batch.id) }
                        else if !reviewHasExpired { recoveryOutcome = result }
                    }
                    return
                }
                let id = try await host.submitCloudPhoto(media: still, selectedIDs: selected, fit: fit,
                    framings: framings, decision: decision, context: context)
                host.withCurrentCloudPresentation(context) {
                    presentation.cloudResultID = id
                    presentation.sheet = .cloudResults
                }
            } catch {
                guard !reviewHasExpired else { return }
                self.error = error.localizedDescription
                framing.resumeEditing()
            }
        }
        if recovery != nil { recoverySubmissionTask = task }
    }
}
