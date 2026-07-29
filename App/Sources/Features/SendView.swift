import PhotosUI
import SwiftUI
import TesseraeKit
import UIKit
import UniformTypeIdentifiers

struct SendView: View {
    @Environment(AppModel.self) private var model
    @State private var pickerItem: PhotosPickerItem?
    @State private var isPhotoPickerPresented = false
    @State private var imageData: Data?
    @State private var previewImage: UIImage?
    @State private var imageContentType = "image/jpeg"
    @State private var fitMode: ImageFitMode = .fit
    @State private var selectedDeviceIDs: Set<String> = []
    @State private var previewDeviceID: String?
    @State private var sentConfirmationPresented = false
    private let previewSlotHeight: CGFloat = 310

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                imagePickerCard
                fitCard
                targetCard

                Button {
                    guard let imageData else { return }
                    Task {
                        let sent = await model.sendImage(
                            data: imageData,
                            fit: fitMode,
                            deviceIDs: Array(selectedDeviceIDs),
                            contentType: imageContentType
                        )
                        if sent {
                            sentConfirmationPresented = true
                            self.imageData = nil
                            previewImage = nil
                            pickerItem = nil
                        }
                    }
                } label: {
                    Label("Send to Displays", systemImage: "paperplane.fill")
                        .frame(maxWidth: .infinity)
                        .opacity(isSending ? 0 : 1)
                        .overlay {
                            if isSending {
                                ProgressView()
                                    .tint(.white)
                                    .transition(.opacity)
                            }
                        }
                        .animation(
                            .easeInOut(duration: 0.18),
                            value: isSending
                        )
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    imageData == nil
                        || selectedDeviceIDs.isEmpty
                        || isSending
                )
            }
            .padding(16)
        }
        .task {
            if !availableFitModes.contains(fitMode) {
                fitMode = availableFitModes.first ?? .fit
            }
            if selectedDeviceIDs.isEmpty {
                selectedDeviceIDs = Set(model.displays.prefix(1).map(\.id))
            }
            if previewDeviceID == nil {
                previewDeviceID = selectedDeviceIDs.first
                    ?? model.displays.first?.id
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
        .alert("Sent", isPresented: $sentConfirmationPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Tesserae accepted the image. Follow its progress in Activity.")
        }
        .tesseraeScreenBackground()
    }

    private var imagePickerCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Preview")
                    .font(.headline)
                Spacer()
                if let imageData {
                    Text(
                        ByteCountFormatter.string(
                            fromByteCount: Int64(imageData.count),
                            countStyle: .file
                        )
                    )
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

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
                }
                .buttonStyle(.bordered)
            }
        }
        .tesseraeCard()
    }

    @ViewBuilder
    private var simulatedPanel: some View {
        Group {
            if let previewDisplay {
                let panel = previewDisplay.panel

                VStack(spacing: 9) {
                    ZStack {
                        TesseraePanelImagePreview(
                            image: previewImage,
                            panel: panel,
                            fit: fitMode,
                            maximumCanvasHeight: 250,
                            emptyTitle: imageSelectionLabel,
                            accessibilityIdentifier: "send-panel-preview",
                            imageAccessibilityIdentifier: "selected-image-preview"
                        )
                        .accessibilityLabel("Display image preview")
                        .accessibilityValue(
                            "\(fitMode.rawValue), \(panel.width) by \(panel.height)"
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 276)

                    Text(
                        "\(previewDisplay.name) · \(panel.width) × \(panel.height)"
                    )
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                }
            } else {
                ContentUnavailableView {
                    Label("No display selected", systemImage: "rectangle.slash")
                } description: {
                    Text("Connect a display to preview its panel shape.")
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(height: previewSlotHeight)
        .contentShape(Rectangle())
        .onTapGesture {
            isPhotoPickerPresented = true
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Tap to choose a photo.")
        .accessibilityAction {
            isPhotoPickerPresented = true
        }
    }

    private var fitCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Image Fit")
                .font(.headline)
            HStack(spacing: 10) {
                Picker("Image Fit", selection: $fitMode) {
                    ForEach(primaryFitModes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if !advancedFitModes.isEmpty {
                    Menu {
                        ForEach(advancedFitModes, id: \.self) { mode in
                            Button {
                                fitMode = mode
                            } label: {
                                if fitMode == mode {
                                    Label(mode.displayName, systemImage: "checkmark")
                                } else {
                                    Text(mode.displayName)
                                }
                            }
                        }
                    } label: {
                        Label(
                            advancedFitModes.contains(fitMode)
                                ? fitMode.displayName
                                : "More",
                            systemImage: "ellipsis.circle"
                        )
                        .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text(fitDescription)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .tesseraeCard()
    }

    private var targetCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Displays")
                .font(.headline)
                .padding(.bottom, 2)

            if model.displays.isEmpty {
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
                ForEach(model.displays) { display in
                    Button {
                        if selectedDeviceIDs.contains(display.id) {
                            selectedDeviceIDs.remove(display.id)
                            if previewDeviceID == display.id,
                               let remainingPreview = model.displays.first(
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
                        HStack {
                            Image(
                                systemName: selectedDeviceIDs.contains(display.id)
                                    ? "checkmark.circle.fill"
                                    : "circle"
                            )
                            .foregroundStyle(
                                selectedDeviceIDs.contains(display.id)
                                    ? TesseraeTheme.accent
                                    : .secondary
                            )
                            Text(display.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            Text("\(display.panel.width)×\(display.panel.height)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        .contentShape(Rectangle())
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
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
        model.activeOperationIDs.contains("image")
    }

    private var previewDisplay: DisplaySummary? {
        if let previewDeviceID,
           let preview = model.displays.first(
               where: { $0.id == previewDeviceID }
           ) {
            return preview
        }
        return model.displays.first {
            selectedDeviceIDs.contains($0.id)
        } ?? model.displays.first
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

    private var primaryFitModes: [ImageFitMode] {
        availableFitModes.filter { $0 != .stretch && $0 != .center }
    }

    private var advancedFitModes: [ImageFitMode] {
        availableFitModes.filter { $0 == .stretch || $0 == .center }
    }

    private func load(_ item: PhotosPickerItem?) async {
        guard let item else {
            imageData = nil
            previewImage = nil
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
        } catch {
            imageData = nil
            previewImage = nil
            model.lastError = error.localizedDescription
        }
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
