import PhotosUI
import SwiftUI
import TesseraeKit

struct NearbyDeviceSheet: View {
    let device: NearbyTesseraeDevice
    var body: some View {
        if device.mode == .photo { NearbyPhotoSendView(device: device) }
        else { NearbyDeviceSetupView(device: device) }
    }
}

struct NearbyPhotoSendView: View {
    private enum Phase: Equatable {
        case invitation, connecting, editing, received, failed
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(NearbyDeviceManager.self) private var nearby
    let device: NearbyTesseraeDevice
    private var isUnifiedPhoto: Bool { device.photoProtocol == .tesseraeV2 }
    @State private var hasStarted = false
    @State private var didConnect = false
    @State private var loadedSelection: PhotosPickerItem?
    @State private var deviceDetailsExpanded = false
    @State private var photoPickerPresented = false
    @State private var selection: PhotosPickerItem?
    @State private var previewHeight: CGFloat = 250
    @State private var image: UIImage?
    @State private var imageData: Data?
    @State private var fit: ImageFitMode = .fill
    @State private var framing = PhotoFramingSession()
    @State private var preparing = false
    @State private var localError: String?
    @State private var sendTask: Task<Void, Never>?
    private var panel: PanelProfile {
        nearby.photoCapabilities?.panel
            ?? PanelProfile(width: 400, height: 300, gamut: "bwry_4", orientation: "landscape")
    }
    private var sendTitle: String {
        isUnifiedPhoto ? String(localized: "Send Photo over Bluetooth") : String(localized: "Send to PicPak")
    }
    private var aspect: PanelAspectRatio { PanelAspectRatio(panel: panel) }
    private var busy: Bool { preparing || nearby.photoState == .sending }
    private var canEditFraming: Bool { image != nil && fit == .fill }
    private var phase: Phase {
        guard hasStarted else { return .invitation }
        if nearby.photoState == .received { return .received }
        if case .failed = nearby.connectionState { return .failed }
        return nearby.connectionState == .ready ? .editing : .connecting
    }
    private var preferredDetent: PresentationDetent {
        phase == .editing || dynamicTypeSize.isAccessibilitySize ? .large : .height(360)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .invitation: introduction
                case .editing: composer
                case .connecting, .received, .failed: centeredStatus
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tesseraeScreenBackground()
            .navigationTitle(phase == .editing ? sendTitle : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(phase == .received ? .hidden : .visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { close() }.labelStyle(.iconOnly)
                }
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            previewHeight = composerCanvasHeight(in: size)
        }
        .frame(idealWidth: 960, idealHeight: 760)
        .presentationSizing(.fitted)
        .presentationDetents([preferredDetent])
        .animation(.snappy, value: phase)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .interactiveDismissDisabled(busy)
        .photosPicker(isPresented: $photoPickerPresented, selection: $selection, matching: .images)
        .task(id: hasStarted) {
            // Discovery only offers the invitation. Connect once the user chooses Send.
            guard hasStarted, !didConnect else { return }
            didConnect = true
            nearby.connect(to: device, qrCode: nil)
#if DEBUG
            if ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_PICPAK_PHOTO"] == "1"
                || ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_UNIFIED_PHOTO"] == "1" {
                let format = UIGraphicsImageRendererFormat(); format.scale = 1
                image = UIGraphicsImageRenderer(size: CGSize(width: 600, height: 300), format: format).image { c in
                    UIColor.systemYellow.setFill(); c.fill(CGRect(x: 0, y: 0, width: 600, height: 300))
                    UIColor.systemRed.setFill(); c.fill(CGRect(x: 70, y: 60, width: 150, height: 160))
                    UIColor.black.setFill(); c.fill(CGRect(x: 240, y: 100, width: 100, height: 100))
                }
                imageData = image?.pngData()
            }
#endif
        }
        .task(id: selection) { await loadPhoto() }

    }

    private var introduction: some View {
        VStack(spacing: 14) {
            Spacer(minLength: 0)
            TesseraeEInkDisplayArtwork(isMaintenance: false)
            VStack(spacing: 5) {
                Text("Ready to Receive").font(.title2.bold())
                DisplayHardwareBadge(presentation: DisplayHardwarePresentation(kind: nearby.resolvedHardware?.catalogKind ?? device.hardware.catalogKind))
                Text(device.name).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Send") {
                withAnimation(.snappy) { hasStarted = true }
            }
            .buttonStyle(.borderedProminent)
            .tint(TesseraeTheme.accentFill)
            .foregroundStyle(.white)
            .controlSize(.large)
            .accessibilityIdentifier("ble-photo-start")
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 18)
    }

    private var composer: some View {
        AdaptiveComposerLayout {
            previewCard
        } controls: {
            fitCard
            if nearby.photoState == .sending {
                VStack(spacing: 8) {
                    Text("Sending photo…").font(.subheadline)
                    ProgressView(value: nearby.photoProgress)
                        .tint(TesseraeTheme.info)
                }
                .frame(maxWidth: .infinity)
            }
            Button { send() } label: {
                Label(preparing ? String(localized: "Preparing…") : sendTitle, systemImage: "paperplane.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(TesseraeTheme.accentFill).controlSize(.large)
            .foregroundStyle(.white)
            .disabled(image == nil || busy)
            .accessibilityIdentifier("ble-send-photo")
            if let localError { Text(localError).font(.footnote).foregroundStyle(.secondary) }
            Text(isUnifiedPhoto
                 ? String(localized: "Keep this app open and close to the display. Automatic updates stay paused in Bluetooth mode.")
                 : String(localized: "Keep this app open and your device close to PicPak."))
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
    }

    private var centeredStatus: some View {
        GeometryReader { proxy in
            ScrollView {
                VStack(spacing: 18) {
                    if phase == .received {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 52)).foregroundStyle(TesseraeTheme.success)
                        VStack(spacing: 8) {
                            Text("Photo Sent").font(.title2.bold())
                            Text(isUnifiedPhoto
                                 ? String(localized: "The display received your photo and will now refresh its screen.")
                                 : String(localized: "PicPak received your photo and will now refresh its screen."))
                                .foregroundStyle(.secondary)
                        }
                        if let error = nearby.displayRecords.storageError {
                            Text(error).font(.footnote).foregroundStyle(TesseraeTheme.warning)
                        }
                        Button("Done", systemImage: "checkmark") { close() }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderedProminent)
                            .tint(TesseraeTheme.accentFill).controlSize(.large)
                            .foregroundStyle(.white)
                            .padding(.top, 4)
                    } else if case .failed(let message) = nearby.connectionState {
                        Image(systemName: "exclamationmark.circle")
                            .font(.system(size: 44)).foregroundStyle(TesseraeTheme.danger)
                        Text(message).foregroundStyle(.secondary)
                    } else {
                        ProgressView()
                            .tint(TesseraeTheme.info)
                            .controlSize(.large)
                        Text(nearby.statusMessage ?? "Connecting securely…")
                            .font(.headline)
                        Text("Keep your device close.").foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
                .padding(.horizontal, 28)
                .padding(.vertical, 24)
                .frame(maxWidth: .infinity, minHeight: proxy.size.height)
                .accessibilityIdentifier("ble-photo-status")
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var previewCard: some View {
        VStack(alignment: .leading, spacing: TesseraeComposerLayout.contentCardSpacing) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) { previewHeader }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 10) { previewHeader }
            }

            TesseraePanelImagePreview(
                image: image, panel: panel, fit: fit, maximumCanvasHeight: previewHeight,
                emptyTitle: preparing ? "Loading photo…" : "Choose a photo",
                accessibilityIdentifier: "ble-photo-preview",
                imageAccessibilityIdentifier: "ble-photo-image",
                framing: canEditFraming ? Binding(
                    get: { framing.framing(for: aspect) },
                    set: { framing.setFraming($0, for: aspect) }
                ) : nil,
                maximumFramingZoom: 4,
                onCanvasTap: { if !canEditFraming && !busy { photoPickerPresented = true } },
                prioritizesFramingGesture: true,
                framingEditingEnabled: !busy,
                onAutoFrame: canEditFraming ? {
                    if let imageData { framing.request(data: imageData, aspect: aspect, maximumZoom: 4) }
                } : nil,
                isAutoFraming: framing.isAnalyzing, autoFramingFeedback: framing.feedback,
                onFramingInteraction: { framing.userDidInteract(with: aspect) }
            )
            .accessibilityHint(canEditFraming ? "Drag to reposition the photo and pinch to zoom." : "Tap to choose a photo.")

            Label("\(device.name) · \(panel.width) × \(panel.height)", systemImage: "rectangle.on.rectangle")
                .accessibilityIdentifier("ble-photo-resolution")
                .font(.footnote.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)

            deviceStatus
        }
        .tesseraeCard()
    }

    private var deviceStatus: some View {
        DisclosureGroup(isExpanded: $deviceDetailsExpanded) {
            VStack(spacing: 8) {
                if let mode = nearby.photoDeviceStatus?.screenMode {
                    LabeledContent("Screen Mode", value: mode.title)
                }
                if let firmware = nearby.deviceInfo?.firmware {
                    LabeledContent("Firmware", value: firmware)
                }
                if let voltage = nearby.photoDeviceStatus?.voltageText {
                    LabeledContent("Voltage", value: voltage)
                }
            }
            .font(.footnote)
            .padding(.top, 8)
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { deviceStatusLabels }
                VStack(alignment: .leading, spacing: 6) { deviceStatusLabels }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("ble-photo-device-info")
    }

    @ViewBuilder
    private var deviceStatusLabels: some View {
        if let battery = nearby.photoDeviceStatus?.batteryText {
            Label(battery, systemImage: "battery.100")
                .accessibilityLabel("Battery: \(battery)")
        }
        if nearby.photoDeviceStatus?.lowBattery == true {
            Label("Low Battery", systemImage: "exclamationmark.battery")
                .foregroundStyle(TesseraeTheme.warning)
        }
        if let speed = nearby.photoDeviceStatus?.refreshSpeed {
            Label(speed.displayName, systemImage: "arrow.clockwise")
                .accessibilityLabel("Refresh speed: \(speed.displayName)")
        }
        if nearby.photoDeviceStatus?.batteryText == nil,
           nearby.photoDeviceStatus?.refreshSpeed == nil {
            Label("Display Info", systemImage: "info.circle")
        }
    }

    @ViewBuilder
    private var previewHeader: some View {
        Text("Preview").font(.headline)
        if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
        if image != nil {
            Button { photoPickerPresented = true } label: {
                Text("Change Photo")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(TesseraeTheme.accent)
                    .padding(.horizontal, 2).padding(.vertical, 7)
            }
            .buttonStyle(.plain).disabled(busy)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier("ble-change-photo")
        }
    }

    private var fitCard: some View {
        VStack(alignment: .leading, spacing: TesseraeComposerLayout.controlCardSpacing) {
            Text("Image Fit").font(.headline)
            Picker("Image Fit", selection: $fit) {
                Text("Fill").tag(ImageFitMode.fill)
                Text("Fit").tag(ImageFitMode.fit)
            }
            .tesseraeAdaptivePickerStyle().disabled(busy)
            Text(LocalizedStringKey(fit.helpText)).font(.footnote).foregroundStyle(.secondary)
        }
        .tesseraeCard()
    }

    private func loadPhoto() async {
        guard let selection, selection != loadedSelection else { return }
        preparing = true
        localError = nil
        image = nil
        imageData = nil
        framing.replaceImage()
        do {
            guard let data = try await selection.loadTransferable(type: Data.self) else {
                throw UploadImagePreparationError.decoding
            }
            let maximumPixelSize = max(1536, panel.width, panel.height)
            let prepared = try await Task.detached(priority: .userInitiated) {
                try UploadImagePreparer.prepare(data: data, fallbackContentType: "image/jpeg", maximumPixelSize: maximumPixelSize)
            }.value
            try Task.checkCancellation()
            loadedSelection = selection
            imageData = prepared.data
            image = UIImage(data: prepared.data)
            framing.requestAutomatically(data: prepared.data, aspect: aspect, maximumZoom: 4)
        } catch {
            if !Task.isCancelled { localError = error.localizedDescription }
        }
        if !Task.isCancelled { preparing = false }
    }

    private func send() {
        guard let image, !busy else { return }
        preparing = true
        localError = nil
        framing.freeze()
        sendTask = Task { @MainActor in
            defer { preparing = false; framing.resumeEditing() }
            do {
                let data: Data
                let rgba: Data
                let capabilities = isUnifiedPhoto ? nearby.photoCapabilities : nil
                if isUnifiedPhoto {
                    guard let capabilities, nearby.connectionState == .ready else {
                        throw BLESetupProtocolError.unsupportedVersion
                    }
                    rgba = try LocalBluetoothPhotoRenderer.raster(image: image, fit: fit,
                        framing: framing.framing(for: aspect), capabilities: capabilities)
                    data = try await LocalBluetoothPhotoRenderer.encode(rgba: rgba, capabilities: capabilities)
                } else {
                    rgba = try PicPakPhotoEncoder.raster(image: image, fit: fit, framing: framing.framing(for: aspect))
                    data = try await Task.detached(priority: .userInitiated) { try PicPakPhotoEncoder.encode(rgba: rgba) }.value
                }
                try Task.checkCancellation()
                let preview = try LocalBluetoothPhotoRenderer.previewPNG(rgba: rgba,
                    width: capabilities?.visibleWidth ?? PicPakPhotoEncoder.width,
                    height: capabilities?.visibleHeight ?? PicPakPhotoEncoder.height)
                try nearby.sendPhoto(data, to: device, capabilityDigest: capabilities?.digest, previewPNG: preview)
            } catch { if !Task.isCancelled { localError = error.localizedDescription } }
        }
    }
    private func close() {
        sendTask?.cancel()
        framing.discardAnalysis()
        nearby.endSession(for: device)
        dismiss()
    }
}
