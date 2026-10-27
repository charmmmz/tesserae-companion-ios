import PhotosUI
import SwiftUI
import TesseraeKit
import UIKit
import UniformTypeIdentifiers

struct SendImageDraft: Identifiable {
    let id = UUID()
    let data: Data
    let contentType: String
}

@MainActor @Observable
final class SendSubmissionSession {
    var isSubmitting = false
}

struct SendView: View {
    @Environment(AppModel.self) private var model
    @Environment(TesseraeMessageCenter.self) private var messageCenter
    @Environment(NearbyDeviceManager.self) private var nearbyDevices
    @Environment(\.scenePhase) private var scenePhase
    @State private var bluetoothSession: BluetoothShareSession?
    @State private var bluetoothTargetID: String?
    @State private var bluetoothConfirmation: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var previewHeight: CGFloat = 276
    @State private var source: SendSource = .photo
    @State private var pickerItem: MediaPickerSelection?
    @State private var loadedPickerItem: MediaPickerSelection?
    @State private var mediaFrames = MediaFrameSession()
    @State private var appliedMediaSourceID: UUID?
    @State private var appliedMediaRevision: UUID?
    @State private var initialImageWasPrepared = false
    @State private var isPhotoPickerPresented = false
    @State private var imageData: Data?
    @State private var previewImage: UIImage?
    @State private var imageContentType = "image/jpeg"
    @State private var linkText = ""
    @State private var linkKind: LinkPushKind = .webpage
    @State private var fitMode: ImageFitMode = .fill
    @State private var framingSession = PhotoFramingSession()
    @State private var imageLoadRevision = UUID()
    @State private var isPreparingImage = false
    @State private var submission: SendSubmissionSession
    @State private var imageRevision = UUID()
    @State private var imageSendAttempt: ImageSendAttempt?
    @State private var selectedDeviceIDs: Set<String> = []
    @State private var previewDeviceID: String?
    @State private var didLoadSendPreferences = false
    @State private var hapticEvent = TesseraeHapticEvent()
    @FocusState private var linkFieldIsFocused: Bool
    private let prioritizesFramingGesture: Bool
    private let initialImage: SendImageDraft?

    init(
        initialImage: SendImageDraft? = nil,
        prioritizesFramingGesture: Bool = false,
        submission: SendSubmissionSession = SendSubmissionSession()
    ) {
        _submission = State(initialValue: submission)
        self.prioritizesFramingGesture = prioritizesFramingGesture
        self.initialImage = initialImage
    }

    private var previewSlotHeight: CGFloat {
        previewHeight + 9 + 44
    }

    private var composerPage: some View {
        // Read readiness in this view's observation scope, before the layout's
        // deferred builders capture it. BLE authentication can finish on its own.
        let destinationReady = destinationIsReady
        let canSubmit = sourceIsReady && destinationReady && !isSending && !submission.isSubmitting
        return AdaptiveComposerLayout {
            Group {
                if supportsLinks { sourceCard }
                if source == .photo { imagePickerCard } else { linkCard }
            }
            .disabled(submission.isSubmitting)
        } controls: {
            Group {
                targetCard
                fitCard
            }
            .disabled(submission.isSubmitting)
            submitButton(isEnabled: canSubmit)
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            previewHeight = composerCanvasHeight(in: size)
        }
        .interactiveDismissDisabled(submission.isSubmitting)
        .task(id: sendPreferenceContextID) {
            await loadSendPreferences()
        }
        .task(id: supportedLinkKindsID) {
            normalizeLinkSelection()
        }
        .onChange(of: sendPreferenceSelection) { _, selection in
            guard didLoadSendPreferences, bluetoothTargetID == nil else { return }
            Task {
                await model.saveSendPreferences(
                    deviceIDs: selection.deviceIDs,
                    fit: selection.fit
                )
            }
        }
        .task(id: pickerItem) {
            if let pickerItem, pickerItem != loadedPickerItem { await load(pickerItem) }
        }
        .onChange(of: mediaFrames.outputRevision) { _, _ in applyMediaFrame() }
        .onDisappear { mediaFrames.cancelWork() }
        .onAppear { mediaFrames.loadTimeline() }
        #if DEBUG
        .task {
            if let value = ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_MEDIA"] {
                do {
                    let source = try await MediaFrameFixtures.source(kind: value == "live" ? .livePhoto : .video)
                    try Task.checkCancellation()
                    mediaFrames.adopt(source)
                    applyMediaFrame()
                } catch { if !Task.isCancelled { model.lastError = error.localizedDescription } }
            }
        }
        #endif
        .task(id: initialImage?.id) {
            if !initialImageWasPrepared, imageData == nil, let initialImage {
                await prepareInitialImage(initialImage)
            }
        }
        .onChange(of: automaticFramingContext, initial: true) { _, context in
            framingSession.updateAutomaticContext(context, data: imageData)
        }
        .onChange(of: model.activeInstance?.id) { framingSession.discardAnalysis() }
        .mediaLibraryPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $pickerItem
        )
        .tesseraeScreenBackground()
        .tesseraeHapticFeedback(trigger: hapticEvent)
    }

    var body: some View {
        composerPage
            .task { startBluetoothDiscovery() }
            .onDisappear {
                bluetoothSession?.stop()
                if let confirmation = bluetoothConfirmation {
                    bluetoothConfirmation = nil
                    showSentConfirmation(confirmation)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                bluetoothSession?.nearby.updateApplicationActivity(phase == .active)
            }
            .onChange(of: sendTargets) { _, _ in reconcileBluetoothSelection() }
            .onChange(of: bluetoothSession?.failure) { _, failure in
                guard let failure else { return }
                submission.isSubmitting = false
                framingSession.resumeEditing()
                messageCenter.dismiss(id: "send.submission")
                model.lastError = failure
            }
            .onChange(of: bluetoothSession?.nearby.photoState) { _, state in
                guard state == .received, let target = bluetoothTarget else { return }
                bluetoothConfirmation = String(localized: "Sent to \(target.name)")
                submission.isSubmitting = false
                if let device = bluetoothSession?.selectedDevice { nearbyDevices.dismissSuggestion(for: device) }
                dismiss()
            }
            .onChange(of: source) { _, source in
                if source != .photo, bluetoothTargetID != nil {
                    bluetoothSession?.changeDisplay()
                    bluetoothTargetID = nil
                }
            }
    }

    private var sendTargets: [ShareDisplayTarget] {
        ShareDisplayTarget.catalog(displays: model.sortedDisplays, serverID: model.activeInstance?.id,
            records: nearbyDevices.displayRecords, nearby: bluetoothSession?.devices ?? [])
    }

    private var bluetoothTarget: ShareDisplayTarget? { sendTargets.first { $0.id == bluetoothTargetID } }
    private var hasSelectedDestination: Bool { bluetoothTargetID != nil || !selectedDeviceIDs.isEmpty }
    private var destinationIsReady: Bool {
        if bluetoothTargetID != nil {
            return bluetoothTarget?.isAvailable == true && bluetoothSession?.canSend == true
        }
        return !selectedDeviceIDs.isEmpty
            && selectedDeviceIDs.isSubset(of: Set(sendTargets.filter { !$0.isBluetooth }.map(\.id)))
    }

    private func canSelect(_ target: ShareDisplayTarget) -> Bool {
        target.isAvailable && (!target.isBluetooth ||
            (source == .photo && bluetoothSession?.nearby.bluetoothUnavailableMessage == nil))
    }

    private func startBluetoothDiscovery() {
        guard bluetoothSession == nil else { return }
        let nearby = NearbyDeviceManager(displayRecords: nearbyDevices.displayRecords, photoSharingOnly: true)
#if DEBUG
        if ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_SEND_BLUETOOTH"] == "1",
           let device = nearby.nearbyDevices.first, let serverID = model.activeInstance?.id {
            let records = nearbyDevices.displayRecords
            records.activeServerID = serverID
            records.observe(deviceID: "picpak-f85b1ba1b2c3", name: "Kitchen", mode: .bluetooth,
                batteryMillivolts: nil, peripheralID: device.id)
            records.link("picpak-f85b1ba1b2c3", to: "picpak-kitchen", serverID: serverID)
        }
#endif
        let session = BluetoothShareSession(nearby: nearby)
        bluetoothSession = session
        session.start()
        reconcileBluetoothSelection()
    }

    private func select(_ target: ShareDisplayTarget) {
        guard canSelect(target), !submission.isSubmitting else { return }
        model.lastError = nil
        if target.isBluetooth {
            selectedDeviceIDs = []
            if bluetoothTargetID == target.id, bluetoothSession?.failure == nil {
                bluetoothTargetID = nil
                bluetoothSession?.changeDisplay()
            } else if let device = target.nearby {
                bluetoothTargetID = target.id
                bluetoothSession?.select(device)
            }
        } else {
            if bluetoothTargetID != nil { bluetoothSession?.changeDisplay() }
            bluetoothTargetID = nil
            if selectedDeviceIDs.contains(target.id) { selectedDeviceIDs.remove(target.id) }
            else { selectedDeviceIDs.insert(target.id); previewDeviceID = target.id }
        }
        if !availableFitModes.contains(fitMode) { fitMode = .fill }
    }

    private func reconcileBluetoothSelection() {
        selectedDeviceIDs.subtract(sendTargets.filter(\.isBluetooth).map(\.id))
        for device in bluetoothSession?.devices ?? [] { nearbyDevices.dismissSuggestion(for: device) }
        if let session = bluetoothSession, bluetoothTargetID != nil, bluetoothTarget == nil,
           let id = session.selectedDevice?.id,
           let resolved = sendTargets.first(where: { $0.nearby?.id == id }) {
            bluetoothTargetID = resolved.id
        }
    }

    private func sendBluetooth() {
        guard sourceIsReady, destinationIsReady, let session = bluetoothSession,
              let image = previewImage, let panel = previewPanel else { return }
        framingSession.freeze()
        submission.isSubmitting = true
        showSendingMessage()
        session.send(image: image, fit: fitMode,
            framing: framingSession.framing(for: PanelAspectRatio(panel: panel))) { busy in
                if !busy, let failure = session.failure {
                    submission.isSubmitting = false
                    framingSession.resumeEditing()
                    messageCenter.dismiss(id: "send.submission")
                    model.lastError = failure
                }
            }
    }

    private func submitButton(isEnabled: Bool) -> some View {
        Button {
            guard !submission.isSubmitting, sourceIsReady, destinationIsReady, !isSending else { return }
            if bluetoothTargetID != nil {
                sendBluetooth()
                return
            }
            framingSession.freeze()
            submission.isSubmitting = true
            let submittedSource = source
            let submittedData = imageData
            let submittedFit = fitMode
            let submittedContentType = imageContentType
            let targetGroups = outgoingImageTargetGroups
            let keys = imageIdempotencyKeys(for: targetGroups)
            let submittedURL = linkURL
            let submittedLinkKind = linkKind
            let submittedIDs = Array(selectedDeviceIDs)
            Task {
                defer {
                    submission.isSubmitting = false
                    framingSession.resumeEditing()
                }
                showSendingMessage()
                let sent: Bool
                switch submittedSource {
                case .photo:
                    guard let submittedData else {
                        messageCenter.dismiss(id: "send.submission")
                        return
                    }
                    sent = await model.sendImage(
                        data: submittedData,
                        fit: submittedFit,
                        targetGroups: targetGroups,
                        idempotencyKeys: keys,
                        contentType: submittedContentType
                    )
                case .link:
                    guard let submittedURL else {
                        messageCenter.dismiss(id: "send.submission")
                        return
                    }
                    sent = await model.sendLink(
                        url: submittedURL,
                        kind: submittedLinkKind,
                        fit: submittedFit,
                        deviceIDs: submittedIDs
                    )
                }
                if sent {
                    linkFieldIsFocused = false
                    showSentConfirmation(confirmationMessage)
                    dismiss()
                } else {
                    messageCenter.dismiss(id: "send.submission")
                    hapticEvent.trigger(.error)
                }
            }
        } label: {
            Label("Send to Displays", systemImage: "paperplane.fill")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(TesseraeTheme.accentFill)
        .foregroundStyle(.white)
        .controlSize(.large)
        .disabled(!isEnabled)
        .accessibilityIdentifier("send-submit")
    }

    private var sourceCard: some View {
        VStack(
            alignment: .leading,
            spacing: TesseraeComposerLayout.controlCardSpacing
        ) {
            Text("Source")
                .font(.headline)
            Picker("Source", selection: $source) {
                Label("Photo", systemImage: "photo")
                    .tag(SendSource.photo)
                Label("Link", systemImage: "link")
                    .tag(SendSource.link)
            }
            .tesseraeAdaptivePickerStyle()
            .accessibilityIdentifier("send-source-picker")
        }
        .tesseraeCard()
    }

    private var linkCard: some View {
        VStack(
            alignment: .leading,
            spacing: TesseraeComposerLayout.contentCardSpacing
        ) {
            Text("Link")
                .font(.headline)

            TextField("https://example.com", text: $linkText)
                .focused($linkFieldIsFocused)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .submitLabel(.done)
                .onSubmit { linkFieldIsFocused = false }
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("send-link-url")

            if supportedLinkKinds.count > 1 {
                Picker("Link Action", selection: $linkKind) {
                    ForEach(supportedLinkKinds, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .tesseraeAdaptivePickerStyle()
                .accessibilityIdentifier("send-link-action-picker")
            } else if let onlyKind = supportedLinkKinds.first {
                Label(onlyKind.displayName, systemImage: onlyKind.systemImage)
                    .font(.subheadline.weight(.semibold))
            }

            Text(linkKind.helpText)
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text(
                "Tesserae fetches the public link without Safari cookies. Private and local addresses are blocked."
            )
            .font(.caption)
            .foregroundStyle(.secondary)

            if !linkText.isEmpty, linkURL == nil {
                Label(
                    "Enter a valid public HTTP or HTTPS URL.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.footnote)
                .foregroundStyle(TesseraeTheme.danger)
            }
        }
        .tesseraeCard()
    }

    private var imagePickerCard: some View {
        VStack(
            alignment: .leading,
            spacing: TesseraeComposerLayout.contentCardSpacing
        ) {
            previewHeader

            simulatedPanel

            if model.connectionMode == .demo {
                Button("Use Sample") {
                    mediaFrames.clear()
                    appliedMediaSourceID = nil
                    imageLoadRevision = UUID()
                    isPreparingImage = false
                    let renderer = UIGraphicsImageRenderer(
                        size: CGSize(width: 800, height: 600)
                    )
                    let sample = renderer.image { context in
                        // Demo artwork is fixed paper/ink, independent of the
                        // interface appearance, just like a real photo.
                        UIColor(red: 255 / 255, green: 253 / 255, blue: 248 / 255, alpha: 1)
                            .setFill()
                        context.fill(
                            CGRect(x: 0, y: 0, width: 800, height: 600)
                        )
                        UIImage(named: "TesseraeLogo")?.draw(
                            in: CGRect(x: 240, y: 140, width: 320, height: 320)
                        )
                    }
                    imageData = sample.jpegData(compressionQuality: 0.9)
                    previewImage = sample
                    imageContentType = "image/jpeg"
                    resetImageFramingState()
                }
                .buttonStyle(.bordered)
            }
        }
        .tesseraeCard()
    }

    @ViewBuilder
    private var previewHeader: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                previewTitle
                changePhotoButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                previewTitle
                Spacer(minLength: 8)
                changePhotoButton
            }
        }
    }

    private var previewTitle: some View {
        HStack(spacing: 8) {
            Text("Preview")
                .font(.headline)
                .accessibilityIdentifier("send-preview-title")
            if isPreparingImage {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading photo or video…")
            }
        }
    }

    @ViewBuilder
    private var changePhotoButton: some View {
        if imageData != nil {
            Button {
                isPhotoPickerPresented = true
            } label: {
                Text("Change Photo")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(TesseraeTheme.accent)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 7)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("send-change-photo")
        }
    }

    @ViewBuilder
    private var simulatedPanel: some View {
        VStack(spacing: 9) {
            if let panel = previewPanel {
                TesseraePanelImagePreview(
                    image: mediaFrames.scrubbingPreview ?? previewImage,
                    panel: panel,
                    fit: fitMode,
                    maximumCanvasHeight: max(1, previewHeight - 2 * TesseraePanelImagePreview.canvasPadding),
                    emptyTitle: imageSelectionLabel,
                    accessibilityIdentifier: "send-panel-preview",
                    imageAccessibilityIdentifier: "selected-image-preview",
                    framing: previewImageFramingBinding,
                    maximumFramingZoom: maximumFramingZoom,
                    onCanvasTap: choosePhotoFromPreview,
                    prioritizesFramingGesture: prioritizesFramingGesture,
                    framingEditingEnabled: !framingSession.isFrozen && !mediaFrames.isBusy && !isPreparingImage,
                    onAutoFrame: canAutoFrame ? { autoFrame() } : nil,
                    isAutoFraming: framingSession.isAnalyzing,
                    autoFramingFeedback: framingSession.feedback,
                    onFramingInteraction: { framingInteractionStarted() }
                )
                .accessibilityValue(
                    previewAccessibilityValue(
                        panel: panel
                    )
                )
                .accessibilityAddTraits(
                    framingEditorIsActive ? AccessibilityTraits() : .isButton
                )
                .accessibilityHint(
                    framingEditorIsActive
                        ? "Drag to reposition the photo and pinch to zoom."
                        : "Tap to choose a photo."
                )
                .accessibilityAction {
                    choosePhotoFromPreview()
                }
                .frame(maxWidth: .infinity)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? nil : previewHeight, alignment: .center)
            } else if let previewImage = mediaFrames.scrubbingPreview ?? previewImage {
                Image(uiImage: previewImage)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity)
                    .frame(height: previewHeight)
                    .accessibilityLabel("Shared photo")
            } else {
                ContentUnavailableView {
                    Label("No display selected", systemImage: "rectangle.slash")
                } description: {
                    Text("Connect a display to preview its panel shape.")
                }
                .frame(maxWidth: .infinity)
                .frame(height: previewHeight, alignment: .center)
            }

            MediaFrameControls(session: mediaFrames, isSending: submission.isSubmitting || isPreparingImage)
            previewFooter
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize || mediaFrames.hasTimeline ? nil : previewSlotHeight)
    }

    private var previewFooter: some View {
        previewTargetPicker
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityElement(children: .contain)
    }

    private func choosePhotoFromPreview() {
        guard !framingEditorIsActive else { return }
        isPhotoPickerPresented = true
    }

    @ViewBuilder
    private var previewTargetPicker: some View {
        if selectedDisplays.count > 1 {
            Menu {
                ForEach(selectedDisplays) { display in
                    Button {
                        previewDeviceID = display.id
                    } label: {
                        Label(
                            "\(display.name) · \(PanelAspectRatio(panel: display.panel).displayName)",
                            systemImage: previewDisplay?.id == display.id
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                    }
                    .accessibilityIdentifier(
                        "send-preview-display-\(display.id)"
                    )
                }
            } label: {
                previewTargetLabel(showsChevron: true)
            }
            .menuIndicator(.hidden)
            .accessibilityIdentifier("send-preview-display-picker")
        } else {
            previewTargetLabel(showsChevron: false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(previewTargetSummary)
                .accessibilityIdentifier("send-preview-display-picker")
        }
    }

    private func previewTargetLabel(showsChevron: Bool) -> some View {
        HStack(spacing: 5) {
            if !dynamicTypeSize.isAccessibilitySize {
                Image(
                    systemName: !hasSelectedDestination
                        ? "rectangle.slash"
                        : "rectangle.on.rectangle"
                )
                .accessibilityHidden(true)
            }
            Text(previewTargetSummary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .truncationMode(.middle)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(1)
            if showsChevron {
                Image(systemName: "chevron.down")
                    .font(.caption2.weight(.bold))
            }
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(TesseraeTheme.accent)
        .padding(.horizontal, 2)
        .padding(.vertical, 7)
        .frame(height: dynamicTypeSize.isAccessibilitySize ? nil : 44)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .layoutPriority(1)
    }

    private var previewTargetName: String {
        if let bluetoothTarget { return bluetoothTarget.name }
        if selectedDisplays.isEmpty {
            return String(localized: "None selected")
        }
        return previewDisplay?.name ?? String(localized: "Preview Display")
    }

    private var previewTargetSummary: String {
        guard hasSelectedDestination, let panel = previewPanel else {
            return previewTargetName
        }
        let aspect = PanelAspectRatio(panel: panel).displayName
        return "\(previewTargetName) · \(panel.width) × \(panel.height) · \(aspect)"
    }


    private var fitCard: some View {
        VStack(
            alignment: .leading,
            spacing: TesseraeComposerLayout.controlCardSpacing
        ) {
            Text("Image Fit")
                .font(.headline)
            Picker("Image Fit", selection: $fitMode) {
                ForEach(availableFitModes, id: \.self) { mode in
                    Text(LocalizedStringKey(mode.displayName)).tag(mode)
                }
            }
            .tesseraeAdaptivePickerStyle()
            .accessibilityIdentifier("send-image-fit-picker")
            Text(LocalizedStringKey(fitDescription))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .tesseraeCard()
    }

    private var targetCard: some View {
        VStack(
            alignment: .leading,
            spacing: TesseraeComposerLayout.selectionCardSpacing
        ) {
            Text("Displays")
                .font(.headline)

            if sendTargets.isEmpty {
                ContentUnavailableView {
                    Label("No Displays", systemImage: "rectangle.slash")
                } description: {
                    Text("Refresh Displays before sending an image.")
                } actions: {
                    Button("Refresh") {
                        Task { await model.refresh() }
                    }
                    .buttonStyle(.bordered)
                }
                .frame(maxWidth: .infinity)
            } else {
                VStack(spacing: 0) {
                    ForEach(sendTargets) { target in
                        let panel = bluetoothSession?.panel(for: target) ?? target.panel
                        Button {
                            select(target)
                            hapticEvent.trigger(.selection)
                        } label: {
                            TesseraeDisplaySelectionRow(
                                name: target.name,
                                resolution: panel.map { "\($0.width)×\($0.height)" } ?? "—",
                                isSelected: target.isBluetooth ? bluetoothTargetID == target.id
                                    : selectedDeviceIDs.contains(target.id),
                                transport: target.isBluetooth ? String(localized: "Bluetooth") : nil,
                                isAvailable: canSelect(target)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSelect(target))
                        .accessibilityIdentifier("send-display-\(target.id)")
                    }
                }
            }
        }
        .tesseraeCard()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("send-displays-card")
    }

    private var imageSelectionLabel: String {
        if isPreparingImage { return String(localized: "Loading photo or video…") }
        return imageData == nil
            ? String(localized: "Choose a photo or video")
            : String(localized: "Image ready")
    }

    private var isSending: Bool {
        bluetoothSession?.isBusy == true || model.activeOperationIDs.contains(
            source == .photo ? "image" : "link"
        )
    }

    private var sourceIsReady: Bool {
        switch source {
        case .photo:
            imageData != nil && !isPreparingImage && !mediaFrames.isBusy
                && (mediaFrames.source == nil || appliedMediaRevision == mediaFrames.outputRevision)
        case .link:
            linkURL != nil && supportedLinkKinds.contains(linkKind)
        }
    }

    private var linkURL: URL? {
        let trimmed = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            let url = URL(string: trimmed),
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host() != nil,
            url.user() == nil,
            url.password() == nil
        else {
            return nil
        }
        return url
    }

    private var supportsLinks: Bool {
        !supportedLinkKinds.isEmpty
    }

    private var supportedLinkKinds: [LinkPushKind] {
        model.supportedLinkPushKinds
    }

    private var supportedLinkKindsID: String {
        supportedLinkKinds.map(\.capability).joined(separator: ",")
    }

    private var confirmationMessage: String {
        String(localized: "Sent to Displays")
    }

    private func showSentConfirmation(_ message: String) {
        messageCenter.post(
            TesseraeMessage(
                id: "send.submission",
                text: message,
                kind: .success,
                lifetime: .automatic(seconds: 3),
                survivesPresentationChange: true,
                priority: .normal,
                accessibilityIdentifier: "send-success-banner",
                haptic: .success
            )
        )
    }

    private func showSendingMessage() {
        messageCenter.post(
            TesseraeMessage(
                id: "send.submission",
                text: String(localized: "Sending…"),
                kind: .progress(fraction: nil),
                lifetime: .persistent,
                priority: .normal,
                accessibilityIdentifier: "send-progress-capsule"
            )
        )
    }

    private var previewDisplay: DisplaySummary? {
        if let previewDeviceID,
           selectedDeviceIDs.contains(previewDeviceID),
           let preview = model.displays.first(
               where: { $0.id == previewDeviceID }
           ) {
            return preview
        }
        return model.sortedDisplays.first {
            selectedDeviceIDs.contains($0.id)
        } ?? model.sortedDisplays.first
    }

    private var previewPanel: PanelProfile? {
        if let bluetoothTarget {
            return bluetoothSession?.panel(for: bluetoothTarget) ?? bluetoothTarget.panel
        }
        return previewDisplay?.panel
    }

    private var selectedDisplays: [DisplaySummary] {
        model.sortedDisplays.filter { selectedDeviceIDs.contains($0.id) }
    }

    private var supportsImageFraming: Bool {
        bluetoothTargetID != nil || model.capabilities?.supportsImageFraming == true
    }

    private var maximumFramingZoom: Double {
        bluetoothTargetID != nil ? 4 : max(model.capabilities?.limits.imageFramingMaxZoom ?? 1, 1)
    }

    private var framingEditorIsActive: Bool {
        source == .photo
            && fitMode == .fill
            && previewImage != nil
            && supportsImageFraming
    }

    private var canAutoFrame: Bool {
        framingEditorIsActive && hasSelectedDestination && !isPreparingImage && !mediaFrames.isBusy
    }

    private var automaticFramingContext: PhotoFramingSession.AutomaticContext {
        .init(
            imageID: framingSession.imageID, instanceID: model.activeInstance?.id,
            aspect: previewAspectRatio, targetIDs: bluetoothTargetID.map { [$0] } ?? selectedDeviceIDs, maximumZoom: maximumFramingZoom,
            isReady: canAutoFrame && didLoadSendPreferences && !submission.isSubmitting
        )
    }

    private func framingInteractionStarted() {
        guard let previewAspectRatio else { return }
        framingSession.userDidInteract(with: previewAspectRatio)
    }

    private func autoFrame() {
        guard canAutoFrame, let imageData, let previewAspectRatio else { return }
        framingSession.request(data: imageData, aspect: previewAspectRatio, maximumZoom: maximumFramingZoom)
    }

    private var previewAspectRatio: PanelAspectRatio? {
        previewPanel.map(PanelAspectRatio.init(panel:))
    }

    private var previewImageFraming: ImageFraming {
        guard let previewAspectRatio else { return .centeredFill }
        return framingSession.framing(for: previewAspectRatio)
    }

    private var previewImageFramingBinding: Binding<ImageFraming>? {
        guard framingEditorIsActive, let previewAspectRatio else { return nil }
        return Binding(
            get: {
                framingSession.framing(for: previewAspectRatio)
            },
            set: { framing in
                framingSession.setFraming(framing, for: previewAspectRatio)
            }
        )
    }

    private var outgoingImageTargetGroups: [ImageSendTargetGroup] {
        imageSendTargetGroups(
            displays: model.sortedDisplays,
            selectedDeviceIDs: selectedDeviceIDs,
            framingsByAspect: framingSession.framings,
            separatesByAspect: framingEditorIsActive,
            maximumZoom: maximumFramingZoom
        )
    }

    private func previewAccessibilityValue(panel: PanelProfile) -> String {
        if framingEditorIsActive {
            return "fill, \(panel.width) by \(panel.height), \(previewImageFraming.zoom.formatted(.number.precision(.fractionLength(1...2)))) times zoom"
        }
        return "\(fitMode.rawValue), \(panel.width) by \(panel.height)"
    }

    private var fitDescription: String {
        fitMode.helpText
    }

    private var availableFitModes: [ImageFitMode] {
        if bluetoothTargetID != nil { return [.fill, .fit] }
        let advertised = model.capabilities?.limits.imageFitModes
            ?? ImageFitMode.legacyModes
        let modes = ImageFitMode.allCases.filter(advertised.contains)
        return modes.isEmpty ? ImageFitMode.legacyModes : modes
    }

    private var sendPreferenceContextID: String {
        [
            model.activeInstance?.id ?? "none",
            model.displays.map(\.id).sorted().joined(separator: ","),
            (model.capabilities?.limits.imageFitModes ?? ImageFitMode.legacyModes)
                .map(\.rawValue).joined(separator: ","),
        ].joined(separator: "|")
    }

    private var sendPreferenceSelection: SendPreferenceSelection {
        SendPreferenceSelection(
            deviceIDs: Array(selectedDeviceIDs).sorted(),
            fit: fitMode
        )
    }

    private func loadSendPreferences() async {
        guard bluetoothTargetID == nil else { return }
        didLoadSendPreferences = false
        defer { if !Task.isCancelled { didLoadSendPreferences = true } }
        let preferences = await model.savedSendPreferences()
        let availableIDs = Set(sendTargets.filter { !$0.isBluetooth }.map(\.id))
        let preferredIDs = Set(preferences?.deviceIDs ?? [])
            .intersection(availableIDs)

        guard !Task.isCancelled, bluetoothTargetID == nil else { return }
        if !preferredIDs.isEmpty {
            selectedDeviceIDs = preferredIDs
        } else {
            selectedDeviceIDs = Set(sendTargets.filter { !$0.isBluetooth }.prefix(1).map(\.id))
        }

        if let preferredFit = preferences?.imageFitMode,
           availableFitModes.contains(preferredFit)
        {
            fitMode = preferredFit
        } else if !availableFitModes.contains(fitMode) {
            fitMode = availableFitModes.contains(.fill)
                ? .fill
                : availableFitModes.first ?? .fill
        }

        previewDeviceID = model.sortedDisplays.first {
            selectedDeviceIDs.contains($0.id)
        }?.id ?? model.sortedDisplays.first?.id
        didLoadSendPreferences = true
    }

    private func normalizeLinkSelection() {
        guard supportsLinks else {
            source = .photo
            return
        }
        if !supportedLinkKinds.contains(linkKind) {
            linkKind = supportedLinkKinds.first ?? .webpage
        }
    }

    private func load(_ item: MediaPickerSelection?) async {
        guard let item else { return }
        let revision = UUID()
        imageLoadRevision = revision
        isPreparingImage = true
        defer { if imageLoadRevision == revision { isPreparingImage = false } }
        do {
            let source = try await item.load(maximumPixelSize: imagePreparationMaxEdge)
            guard imageLoadRevision == revision, !Task.isCancelled else { return }
            mediaFrames.adopt(source)
            applyMediaFrame()
            loadedPickerItem = item
        } catch {
            guard imageLoadRevision == revision, !Task.isCancelled else { return }
            model.lastError = error.localizedDescription
        }
    }

    private func applyMediaFrame() {
        guard appliedMediaRevision != mediaFrames.outputRevision else { return }
        guard let prepared = mediaFrames.output, let source = mediaFrames.source else { return }
        appliedMediaRevision = mediaFrames.outputRevision
        imageData = prepared.data
        imageContentType = prepared.contentType
        previewImage = UIImage(data: prepared.data)
        if appliedMediaSourceID != source.id {
            resetImageFramingState()
            appliedMediaSourceID = source.id
        } else {
            framingSession.discardAnalysis()
            imageRevision = UUID()
            imageSendAttempt = nil
        }
    }

    private func prepareInitialImage(_ draft: SendImageDraft) async {
        let revision = beginImageLoad()
        defer { if imageLoadRevision == revision { isPreparingImage = false } }
        do {
            try await finishImageLoad(data: draft.data, contentType: draft.contentType, revision: revision)
            if imageLoadRevision == revision, !Task.isCancelled { initialImageWasPrepared = true }
        } catch {
            guard imageLoadRevision == revision, !Task.isCancelled else { return }
            model.lastError = error.localizedDescription
        }
    }

    private func beginImageLoad() -> UUID {
        imageLoadRevision = UUID()
        imageData = nil
        previewImage = nil
        isPreparingImage = true
        resetImageFramingState()
        return imageLoadRevision
    }

    private func finishImageLoad(data: Data, contentType: String, revision: UUID) async throws {
        let maximumPixelSize = imagePreparationMaxEdge
        let prepared = try await Task.detached(priority: .userInitiated) {
            try UploadImagePreparer.prepare(
                data: data, fallbackContentType: contentType, maximumPixelSize: maximumPixelSize
            )
        }.value
        guard imageLoadRevision == revision, !Task.isCancelled else { return }
        imageData = prepared.data
        imageContentType = prepared.contentType
        previewImage = UIImage(data: prepared.data)
    }

    private func resetImageFramingState() {
        framingSession.replaceImage()
        imageRevision = UUID()
        imageSendAttempt = nil
    }

    private func imageIdempotencyKeys(
        for groups: [ImageSendTargetGroup]
    ) -> [String: String] {
        let signature = ImageSendBatchSignature(
            imageRevision: imageRevision,
            fit: fitMode,
            groups: groups
        )
        if let imageSendAttempt, imageSendAttempt.signature == signature {
            return imageSendAttempt.idempotencyKeys
        }
        let keys = Dictionary(uniqueKeysWithValues: groups.map {
            ($0.id, UUID().uuidString)
        })
        imageSendAttempt = ImageSendAttempt(
            signature: signature,
            idempotencyKeys: keys
        )
        return keys
    }

    private var imagePreparationMaxEdge: Int {
        let displayMaxEdge = model.displays
            .map { max($0.panel.width, $0.panel.height) }
            .max() ?? 2_048
        return min(
            displayMaxEdge,
            model.capabilities?.limits.imageMaxEdge ?? displayMaxEdge
        )
    }
}

private enum SendSource: Hashable {
    case photo
    case link
}

private extension LinkPushKind {
    var displayName: String {
        switch self {
        case .imageURL:
            String(localized: "Image URL")
        case .webpage:
            String(localized: "Webpage Snapshot")
        }
    }

    var systemImage: String {
        switch self {
        case .imageURL:
            "photo.badge.arrow.down"
        case .webpage:
            "safari"
        }
    }

    var helpText: String {
        switch self {
        case .imageURL:
            String(
                localized: "Fetch the link as an image, then apply the selected layout."
            )
        case .webpage:
            String(
                localized: "Render a desktop-width webpage snapshot, then apply the selected layout."
            )
        }
    }
}

private struct SendPreferenceSelection: Equatable {
    let deviceIDs: [String]
    let fit: ImageFitMode
}

private struct ImageSendBatchSignature: Hashable {
    let imageRevision: UUID
    let fit: ImageFitMode
    let groups: [ImageSendTargetGroup]
}

private struct ImageSendAttempt {
    let signature: ImageSendBatchSignature
    let idempotencyKeys: [String: String]
}
