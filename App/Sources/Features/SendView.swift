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

struct SendView: View {
    @Environment(AppModel.self) private var model
    @Environment(TesseraeMessageCenter.self) private var messageCenter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.presentTesseraeSettings) private var presentSettings
    @State private var source: SendSource = .photo
    @State private var pickerItem: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var imageData: Data?
    @State private var previewImage: UIImage?
    @State private var imageContentType = "image/jpeg"
    @State private var linkText = ""
    @State private var linkKind: LinkPushKind = .webpage
    @State private var fitMode: ImageFitMode = .fill
    @State private var imageFramingsByAspect: [PanelAspectRatio: ImageFraming] = [:]
    @State private var imageRevision = UUID()
    @State private var imageSendAttempt: ImageSendAttempt?
    @State private var selectedDeviceIDs: Set<String> = []
    @State private var previewDeviceID: String?
    @State private var didLoadSendPreferences = false
    @FocusState private var linkFieldIsFocused: Bool
    private let prioritizesFramingGesture: Bool

    init(
        initialImage: SendImageDraft? = nil,
        prioritizesFramingGesture: Bool = false
    ) {
        self.prioritizesFramingGesture = prioritizesFramingGesture
        _imageData = State(initialValue: initialImage?.data)
        _previewImage = State(
            initialValue: initialImage.flatMap { UIImage(data: $0.data) }
        )
        _imageContentType = State(
            initialValue: initialImage?.contentType ?? "image/jpeg"
        )
    }

    private var previewSlotHeight: CGFloat {
        276 + 9 + previewTargetPickerHeight
    }

    var body: some View {
        ScrollView {
            VStack(spacing: TesseraeComposerLayout.sectionSpacing) {
                if supportsLinks {
                    sourceCard
                }
                targetCard
                if source == .photo {
                    imagePickerCard
                } else {
                    linkCard
                }
                fitCard

                Button {
                    Task {
                        showSendingMessage()
                        let sent: Bool
                        switch source {
                        case .photo:
                            guard let imageData else {
                                messageCenter.dismiss(id: "send.submission")
                                return
                            }
                            let targetGroups = outgoingImageTargetGroups
                            sent = await model.sendImage(
                                data: imageData,
                                fit: fitMode,
                                targetGroups: targetGroups,
                                idempotencyKeys: imageIdempotencyKeys(
                                    for: targetGroups
                                ),
                                contentType: imageContentType
                            )
                        case .link:
                            guard let linkURL else {
                                messageCenter.dismiss(id: "send.submission")
                                return
                            }
                            sent = await model.sendLink(
                                url: linkURL,
                                kind: linkKind,
                                fit: fitMode,
                                deviceIDs: Array(selectedDeviceIDs)
                            )
                        }
                        if sent {
                            linkFieldIsFocused = false
                            showSentConfirmation(confirmationMessage)
                            clearSubmittedSource()
                        } else {
                            messageCenter.dismiss(id: "send.submission")
                        }
                    }
                } label: {
                    Label("Send to Displays", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    !sourceIsReady
                        || selectedDeviceIDs.isEmpty
                        || isSending
                )
            }
            .padding(TesseraeComposerLayout.pagePadding)
        }
        .task(id: sendPreferenceContextID) {
            await loadSendPreferences()
        }
        .task(id: supportedLinkKindsID) {
            normalizeLinkSelection()
        }
        .onChange(of: sendPreferenceSelection) { _, selection in
            guard didLoadSendPreferences else { return }
            Task {
                await model.saveSendPreferences(
                    deviceIDs: selection.deviceIDs,
                    fit: selection.fit
                )
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            Task {
                await load(newItem)
            }
        }
        .photosPicker(
            isPresented: $isPhotoPickerPresented,
            selection: $pickerItem,
            matching: .images
        )
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                TesseraeSettingsToolbarButton(openSettings: presentSettings)
            }
        }
        .tesseraeScreenBackground()
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
            .pickerStyle(.segmented)
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
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("send-link-url")

            if supportedLinkKinds.count > 1 {
                Picker("Link Action", selection: $linkKind) {
                    ForEach(supportedLinkKinds, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
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
                .foregroundStyle(TesseraeTheme.terracotta)
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
                    let renderer = UIGraphicsImageRenderer(
                        size: CGSize(width: 800, height: 600)
                    )
                    let sample = renderer.image { context in
                        UIColor.systemTeal.setFill()
                        context.fill(
                            CGRect(x: 0, y: 0, width: 800, height: 600)
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
        Text("Preview")
            .font(.headline)
            .accessibilityIdentifier("send-preview-title")
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
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("send-change-photo")
        }
    }

    @ViewBuilder
    private var simulatedPanel: some View {
        VStack(spacing: 9) {
            if let previewDisplay {
                let panel = previewDisplay.panel

                TesseraePanelImagePreview(
                    image: previewImage,
                    panel: panel,
                    fit: fitMode,
                    maximumCanvasHeight: 250,
                    emptyTitle: imageSelectionLabel,
                    accessibilityIdentifier: "send-panel-preview",
                    imageAccessibilityIdentifier: "selected-image-preview",
                    framing: previewImageFramingBinding,
                    maximumFramingZoom: maximumFramingZoom,
                    onCanvasTap: choosePhotoFromPreview,
                    prioritizesFramingGesture: prioritizesFramingGesture
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
                .frame(height: 276, alignment: .top)
            } else {
                ContentUnavailableView {
                    Label("No display selected", systemImage: "rectangle.slash")
                } description: {
                    Text("Connect a display to preview its panel shape.")
                }
                .frame(maxWidth: .infinity)
                .frame(height: 276, alignment: .top)
            }

            previewFooter
        }
        .frame(height: previewSlotHeight)
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
            Image(
                systemName: selectedDisplays.isEmpty
                    ? "rectangle.slash"
                    : "rectangle.on.rectangle"
            )
            Text(previewTargetSummary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
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
        .frame(height: previewTargetPickerHeight)
        .contentShape(Rectangle())
        .layoutPriority(1)
    }

    private var previewTargetName: String {
        if selectedDisplays.isEmpty {
            return String(localized: "None selected")
        }
        return previewDisplay?.name ?? String(localized: "Preview Display")
    }

    private var previewTargetSummary: String {
        guard !selectedDisplays.isEmpty, let panel = previewDisplay?.panel else {
            return previewTargetName
        }
        let aspect = PanelAspectRatio(panel: panel).displayName
        return "\(previewTargetName) · \(panel.width) × \(panel.height) · \(aspect)"
    }

    private var previewTargetPickerHeight: CGFloat {
        let lineHeight = UIFont.preferredFont(
            forTextStyle: .footnote
        ).lineHeight
        let lineCount: CGFloat = dynamicTypeSize.isAccessibilitySize ? 2 : 1
        return max(32, ceil(lineHeight * lineCount + 14))
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
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(fitDescription)
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

            if model.sortedDisplays.isEmpty {
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
                ForEach(model.sortedDisplays) { display in
                    Button {
                        if selectedDeviceIDs.contains(display.id) {
                            selectedDeviceIDs.remove(display.id)
                            if previewDeviceID == display.id,
                               let remainingPreview = model.sortedDisplays.first(
                                   where: {
                                       selectedDeviceIDs.contains($0.id)
                                   }
                               ) {
                                previewDeviceID = remainingPreview.id
                            }
                        } else {
                            selectedDeviceIDs.insert(display.id)
                            previewDeviceID = display.id
                        }
                    } label: {
                        TesseraeDisplaySelectionRow(
                            name: display.name,
                            resolution: "\(display.panel.width)×\(display.panel.height)",
                            isSelected: selectedDeviceIDs.contains(display.id)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("send-display-\(display.id)")
                }
            }
        }
        .tesseraeCard()
    }

    private var imageSelectionLabel: String {
        imageData == nil
            ? String(localized: "Choose one still image")
            : String(localized: "Image ready")
    }

    private var isSending: Bool {
        model.activeOperationIDs.contains(
            source == .photo ? "image" : "link"
        )
    }

    private var sourceIsReady: Bool {
        switch source {
        case .photo:
            imageData != nil
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
        switch source {
        case .photo:
            String(
                localized: "Tesserae accepted the image. Follow its progress in Activity."
            )
        case .link:
            String(
                localized: "Tesserae accepted the link. Follow its progress in Activity."
            )
        }
    }

    private func showSentConfirmation(_ message: String) {
        messageCenter.post(
            TesseraeMessage(
                id: "send.submission",
                text: message,
                kind: .success,
                lifetime: .automatic(seconds: 3),
                priority: .normal,
                accessibilityIdentifier: "send-success-banner"
            )
        )
    }

    private func showSendingMessage() {
        messageCenter.post(
            TesseraeMessage(
                id: "send.submission",
                text: String(localized: "Sending to Displays…"),
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

    private var selectedDisplays: [DisplaySummary] {
        model.sortedDisplays.filter { selectedDeviceIDs.contains($0.id) }
    }

    private var supportsImageFraming: Bool {
        model.capabilities?.supportsImageFraming == true
    }

    private var maximumFramingZoom: Double {
        max(model.capabilities?.limits.imageFramingMaxZoom ?? 1, 1)
    }

    private var framingEditorIsActive: Bool {
        source == .photo
            && fitMode == .fill
            && previewImage != nil
            && supportsImageFraming
    }

    private var previewAspectRatio: PanelAspectRatio? {
        previewDisplay.map { PanelAspectRatio(panel: $0.panel) }
    }

    private var previewImageFraming: ImageFraming {
        guard let previewAspectRatio else { return .centeredFill }
        return imageFramingsByAspect[previewAspectRatio] ?? .centeredFill
    }

    private var previewImageFramingBinding: Binding<ImageFraming>? {
        guard framingEditorIsActive, let previewAspectRatio else { return nil }
        return Binding(
            get: {
                imageFramingsByAspect[previewAspectRatio] ?? .centeredFill
            },
            set: { framing in
                imageFramingsByAspect[previewAspectRatio] = framing
            }
        )
    }

    private var outgoingImageTargetGroups: [ImageSendTargetGroup] {
        imageSendTargetGroups(
            displays: model.sortedDisplays,
            selectedDeviceIDs: selectedDeviceIDs,
            framingsByAspect: imageFramingsByAspect,
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
        let advertised = model.capabilities?.limits.imageFitModes
            ?? ImageFitMode.legacyModes
        let modes = ImageFitMode.allCases.filter(advertised.contains)
        return modes.isEmpty ? ImageFitMode.legacyModes : modes
    }

    private var sendPreferenceContextID: String {
        [
            model.activeInstance?.id ?? "none",
            model.displays.map(\.id).sorted().joined(separator: ","),
            availableFitModes.map(\.rawValue).joined(separator: ","),
        ].joined(separator: "|")
    }

    private var sendPreferenceSelection: SendPreferenceSelection {
        SendPreferenceSelection(
            deviceIDs: Array(selectedDeviceIDs).sorted(),
            fit: fitMode
        )
    }

    private func loadSendPreferences() async {
        didLoadSendPreferences = false
        let availableIDs = Set(model.displays.map(\.id))
        let preferences = await model.savedSendPreferences()
        let preferredIDs = Set(preferences?.deviceIDs ?? [])
            .intersection(availableIDs)

        if !preferredIDs.isEmpty {
            selectedDeviceIDs = preferredIDs
        } else {
            selectedDeviceIDs = Set(model.sortedDisplays.prefix(1).map(\.id))
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

    private func clearSubmittedSource() {
        switch source {
        case .photo:
            imageData = nil
            previewImage = nil
            pickerItem = nil
            resetImageFramingState()
        case .link:
            linkText = ""
        }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else {
            imageData = nil
            previewImage = nil
            resetImageFramingState()
            return
        }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                throw UploadImagePreparationError.decoding
            }
            let fallbackContentType = item.supportedContentTypes
                .compactMap(\.preferredMIMEType)
                .first ?? "image/jpeg"
            let maximumPixelSize = imagePreparationMaxEdge
            let prepared = try await Task.detached(priority: .userInitiated) {
                try UploadImagePreparer.prepare(
                    data: data,
                    fallbackContentType: fallbackContentType,
                    maximumPixelSize: maximumPixelSize
                )
            }.value
            imageData = prepared.data
            imageContentType = prepared.contentType
            previewImage = UIImage(data: prepared.data)
            resetImageFramingState()
        } catch {
            imageData = nil
            previewImage = nil
            resetImageFramingState()
            model.lastError = error.localizedDescription
        }
    }

    private func resetImageFramingState() {
        imageFramingsByAspect = [:]
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
