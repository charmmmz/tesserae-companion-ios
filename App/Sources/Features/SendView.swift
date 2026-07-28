import PhotosUI
import SwiftUI
import TesseraeKit
import UniformTypeIdentifiers

struct SendView: View {
    @Environment(AppModel.self) private var model
    @State private var pickerItem: PhotosPickerItem?
    @State private var imageData: Data?
    @State private var imageContentType = "image/jpeg"
    @State private var fitMode: ImageFitMode = .fit
    @State private var selectedDeviceIDs: Set<String> = []
    @State private var sentConfirmationPresented = false

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
                            pickerItem = nil
                        }
                    }
                } label: {
                    if model.activeOperationIDs.contains("image") {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label("Send to Displays", systemImage: "paperplane.fill")
                            .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(
                    imageData == nil
                        || selectedDeviceIDs.isEmpty
                        || model.activeOperationIDs.contains("image")
                )
            }
            .padding(16)
        }
        .task {
            if selectedDeviceIDs.isEmpty {
                selectedDeviceIDs = Set(model.displays.prefix(1).map(\.id))
            }
        }
        .onChange(of: pickerItem) { _, newItem in
            Task {
                imageData = try? await newItem?.loadTransferable(type: Data.self)
                imageContentType = newItem?
                    .supportedContentTypes
                    .compactMap(\.preferredMIMEType)
                    .first ?? "image/jpeg"
            }
        }
        .alert("Sent", isPresented: $sentConfirmationPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Tesserae accepted the image. Follow its progress in Activity.")
        }
        .tesseraeScreenBackground()
    }

    private var imagePickerCard: some View {
        VStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(TesseraeTheme.accentSoft)
                .frame(height: 180)
                .overlay {
                    VStack(spacing: 8) {
                        Image(systemName: imageData == nil ? "photo.badge.plus" : "photo.fill")
                            .font(.system(size: 40))
                        Text(imageSelectionLabel)
                            .font(.headline)
                        if let imageData {
                            Text(ByteCountFormatter.string(fromByteCount: Int64(imageData.count), countStyle: .file))
                                .font(.caption)
                        }
                    }
                    .foregroundStyle(TesseraeTheme.accent)
                }

            HStack {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("Choose Photo", systemImage: "photo.on.rectangle")
                }
                .buttonStyle(.bordered)

                Button("Use Sample") {
                    imageData = Data("fixture-image".utf8)
                    imageContentType = "image/jpeg"
                }
                .buttonStyle(.bordered)
            }
        }
        .tesseraeCard()
    }

    private var fitCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Image Fit")
                .font(.headline)
            Picker("Image Fit", selection: $fitMode) {
                ForEach(ImageFitMode.allCases, id: \.self) { mode in
                    Text(mode == .fit ? "Fit" : "Fill").tag(mode)
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
                        } else {
                            selectedDeviceIDs.insert(display.id)
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

    private var fitDescription: String {
        fitMode == .fit
            ? String(localized: "Show the whole image with space around it.")
            : String(localized: "Fill the display and crop the edges.")
    }
}
