import SwiftUI
import TesseraeKit
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()

        let model = ShareComposerModel(extensionContext: extensionContext)
        let host = UIHostingController(rootView: ShareComposerView(model: model))
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)

        Task {
            await model.load()
        }
    }
}

@MainActor
private final class ShareComposerModel: ObservableObject {
    enum Phase {
        case loading
        case ready
        case submitting
        case accepted
        case failed
    }

    @Published var phase: Phase = .loading
    @Published var snapshot: CompanionSnapshot?
    @Published var selectedDeviceIDs: Set<String> = []
    @Published var fit: ImageFitMode = .fit
    @Published var overrideQuietHours = false
    @Published var imageByteCount = 0
    @Published var previewImage: UIImage?
    @Published var errorMessage: String?

    private weak var extensionContext: NSExtensionContext?
    private var imageData: Data?
    private var contentType = "image/jpeg"
    private var fileName = "shared-photo.jpg"
    private var queuedRequest: SharedImageRequest?

    private let stateStore: any CompanionStateStoring
    private let queueStore: any ShareQueueStoring
    private let activityThumbnails: any ActivityThumbnailStoring
    private let credentials: any CredentialStoring
    private let client: any TesseraeServing

    init(extensionContext: NSExtensionContext?) {
        self.extensionContext = extensionContext

        let appGroup = Bundle.main.object(
            forInfoDictionaryKey: "TesseraeAppGroupIdentifier"
        ) as? String
        let containerURL = appGroup.flatMap {
            FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: $0
            )
        }
        let accessGroup: String? = {
#if targetEnvironment(simulator)
            return nil
#else
            guard
                let value = Bundle.main.object(
                    forInfoDictionaryKey: "TesseraeKeychainAccessGroup"
                ) as? String,
                !value.contains("$(")
            else {
                return nil
            }
            return value
#endif
        }()

        stateStore = UserDefaultsCompanionStateStore(suiteName: appGroup)
        queueStore = FileShareQueueStore(directoryURL: containerURL)
        activityThumbnails = FileActivityThumbnailStore(
            directoryURL: containerURL
        )
        let keychain = KeychainCredentialStore(
            service: "com.charmmmz.tesseraecompanion.credentials",
            accessGroup: accessGroup
        )
        credentials = keychain
        client = LiveTesseraeClient(
            credentials: keychain,
            identity: TesseraeClientIdentity(
                appVersion: Bundle.main.object(
                    forInfoDictionaryKey: "CFBundleShortVersionString"
                ) as? String ?? "0.1.0",
                installationID: "share-extension"
            )
        )
    }

    var displays: [DisplaySummary] {
        snapshot?.displays ?? []
    }

    var canSend: Bool {
        phase == .ready
            && imageData != nil
            && !selectedDeviceIDs.isEmpty
            && snapshot != nil
    }

    var previewDisplay: DisplaySummary? {
        displays.first { selectedDeviceIDs.contains($0.id) }
    }

    func load() async {
        do {
            try await queueStore.purge(
                expiredBefore: Date().addingTimeInterval(-24 * 60 * 60)
            )
            guard let snapshot = try await stateStore.load() else {
                throw ShareComposerError.notPaired
            }
            guard try await credentials.token(
                for: snapshot.activeInstance.id
            ) != nil else {
                throw ShareComposerError.notPaired
            }
            guard !snapshot.displays.isEmpty else {
                throw ShareComposerError.noDisplays
            }

            let displayMaxEdge = snapshot.displays
                .map { max($0.panel.width, $0.panel.height) }
                .max() ?? 2_048
            let preparationMaxEdge = min(
                displayMaxEdge,
                snapshot.capabilities?.limits.imageMaxEdge ?? displayMaxEdge
            )
            let loaded = try await loadSharedImage(
                maximumPixelSize: preparationMaxEdge
            )
            try validate(
                data: loaded.data,
                contentType: loaded.contentType,
                capabilities: snapshot.capabilities
            )

            self.snapshot = snapshot
            imageData = loaded.data
            imageByteCount = loaded.data.count
            previewImage = UIImage(data: loaded.data)
            contentType = loaded.contentType
            fileName = loaded.fileName
            selectedDeviceIDs = Set(snapshot.displays.prefix(1).map(\.id))
            phase = .ready
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
        }
    }

    func send() async {
        guard
            let snapshot,
            let imageData,
            !selectedDeviceIDs.isEmpty
        else {
            return
        }
        phase = .submitting
        errorMessage = nil

        let request = queuedRequest ?? SharedImageRequest(
            instanceID: snapshot.activeInstance.id,
            fileName: fileName,
            contentType: contentType,
            fit: fit,
            deviceIDs: Array(selectedDeviceIDs).sorted(),
            overrideQuietHours: overrideQuietHours
        )

        do {
            if queuedRequest == nil {
                try await queueStore.enqueue(
                    imageData: imageData,
                    request: request
                )
                queuedRequest = request
            }
            let submitting = request.updating(
                status: .submitting,
                error: nil
            )
            try await queueStore.update(submitting)
            queuedRequest = submitting

            let job = try await client.sendImage(
                data: imageData,
                fileName: submitting.fileName,
                contentType: submitting.contentType,
                fit: submitting.fit,
                deviceIDs: submitting.deviceIDs,
                overrideQuietHours: submitting.overrideQuietHours,
                idempotencyKey: submitting.idempotencyKey,
                instance: snapshot.activeInstance
            )
            let jobs = [job] + snapshot.jobs.filter { $0.id != job.id }
            _ = try? await activityThumbnails.save(
                imageData: imageData,
                jobID: job.id,
                instanceID: snapshot.activeInstance.id,
                createdAt: job.createdAt
            )
            try await stateStore.save(
                CompanionSnapshot(
                    activeInstance: snapshot.activeInstance,
                    capabilities: snapshot.capabilities,
                    displays: snapshot.displays,
                    dashboards: snapshot.dashboards,
                    jobs: jobs
                )
            )
            try await queueStore.remove(submitting)
            queuedRequest = nil
            phase = .accepted
        } catch {
            let failed = request.updating(
                status: .failed,
                error: error.localizedDescription
            )
            try? await queueStore.update(failed)
            queuedRequest = failed
            errorMessage = [
                error.localizedDescription,
                String(
                    localized: "The image is saved for up to 24 hours and the app will retry with the same request key."
                ),
            ].joined(separator: " ")
            phase = .failed
        }
    }

    func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    func cancel() {
        extensionContext?.cancelRequest(
            withError: ShareComposerError.cancelled
        )
    }

    private func loadSharedImage(
        maximumPixelSize: Int
    ) async throws -> (
        data: Data,
        contentType: String,
        fileName: String
    ) {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            throw ShareComposerError.noImage
        }
        let providers = items.flatMap { item in
            item.attachments ?? []
        }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }) else {
            throw ShareComposerError.noImage
        }

        let type = provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .first(where: { $0.conforms(to: UTType.image) }) ?? .jpeg
        let data = try await loadData(
            from: provider,
            typeIdentifier: type.identifier
        )
        let prepared = try await Task.detached(priority: .userInitiated) {
            try UploadImagePreparer.prepare(
                data: data,
                fallbackContentType: type.preferredMIMEType ?? "image/jpeg",
                maximumPixelSize: maximumPixelSize
            )
        }.value
        return (
            prepared.data,
            prepared.contentType,
            "shared-photo.\(prepared.fileExtension)"
        )
    }

    private func loadData(
        from provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(
                forTypeIdentifier: typeIdentifier
            ) { data, error in
                if let data {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(
                        throwing: error ?? ShareComposerError.noImage
                    )
                }
            }
        }
    }

    private func validate(
        data: Data,
        contentType: String,
        capabilities: ServerCapabilities?
    ) throws {
        guard let capabilities else { return }
        guard data.count <= capabilities.limits.imageUploadBytes else {
            throw ShareComposerError.imageTooLarge(
                capabilities.limits.imageUploadBytes
            )
        }
        guard capabilities.limits.imageContentTypes.contains(contentType) else {
            throw ShareComposerError.unsupportedImageType(contentType)
        }
        if
            let image = UIImage(data: data),
            max(
                image.size.width * image.scale,
                image.size.height * image.scale
            ) > CGFloat(capabilities.limits.imageMaxEdge)
        {
            throw ShareComposerError.imageDimensionsTooLarge(
                capabilities.limits.imageMaxEdge
            )
        }
    }
}

private struct ShareComposerView: View {
    @ObservedObject var model: ShareComposerModel
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading:
                    ProgressView("Loading shared image…")
                case .accepted:
                    ContentUnavailableView(
                        "Accepted by Tesserae",
                        systemImage: "checkmark.circle.fill",
                        description: Text("The server will render and publish the image.")
                    )
                case .failed where model.snapshot == nil:
                    ContentUnavailableView(
                        "Open Tesserae Companion",
                        systemImage: "iphone.and.arrow.forward",
                        description: Text(
                            model.errorMessage
                                ?? String(localized: "Pair the app before sharing an image.")
                        )
                    )
                default:
                    composer
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tesseraeScreenBackground()
            .navigationTitle("Send to Tesserae")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(
                TesseraeTheme.background(for: colorScheme),
                for: .navigationBar
            )
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancel() }
                }
                if model.phase == .accepted || model.phase == .failed {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.complete() }
                    }
                }
            }
        }
        .tint(TesseraeTheme.accent)
    }

    private var composer: some View {
        ScrollView {
            VStack(spacing: 14) {
                imageCard
                layoutCard
                displaysCard
                quietHoursCard

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(TesseraeTheme.terracotta)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tesseraeCard()
                }

                Button {
                    Task { await model.send() }
                } label: {
                    if model.phase == .submitting {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    } else {
                        Label(
                            model.phase == .failed ? "Retry Now" : "Send",
                            systemImage: "paperplane.fill"
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!model.canSend && model.phase != .failed)
            }
            .padding(16)
        }
    }

    private var imageCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Image")
                    .font(.headline)
                Spacer()
                Label(
                    ByteCountFormatter.string(
                        fromByteCount: Int64(model.imageByteCount),
                        countStyle: .file
                    ),
                    systemImage: "photo"
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let previewDisplay = model.previewDisplay {
                TesseraePanelImagePreview(
                    image: model.previewImage,
                    panel: previewDisplay.panel,
                    fit: model.fit,
                    maximumCanvasHeight: 220,
                    emptyTitle: String(localized: "Loading shared image…"),
                    accessibilityIdentifier: "share-panel-preview",
                    imageAccessibilityIdentifier: "shared-image-preview"
                )
                .accessibilityLabel("Display image preview")
                .accessibilityValue(
                    "\(model.fit.rawValue), \(previewDisplay.panel.width) by \(previewDisplay.panel.height)"
                )

                Text(
                    "\(previewDisplay.name) · \(previewDisplay.panel.width) × \(previewDisplay.panel.height)"
                )
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            } else {
                ContentUnavailableView {
                    Label("No display selected", systemImage: "rectangle.slash")
                } description: {
                    Text("Select a display to preview its panel shape.")
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
        .tesseraeCard()
    }

    private var layoutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Layout")
                .font(.headline)
            Picker("Layout", selection: $model.fit) {
                Text("Fit").tag(ImageFitMode.fit)
                Text("Fill").tag(ImageFitMode.fill)
            }
            .pickerStyle(.segmented)
        }
        .tesseraeCard()
    }

    private var displaysCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Displays")
                .font(.headline)
            ForEach(model.displays) { display in
                Button {
                    if model.selectedDeviceIDs.contains(display.id) {
                        model.selectedDeviceIDs.remove(display.id)
                    } else {
                        model.selectedDeviceIDs.insert(display.id)
                    }
                } label: {
                    HStack {
                        Image(
                            systemName: model.selectedDeviceIDs.contains(display.id)
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                        .foregroundStyle(
                            model.selectedDeviceIDs.contains(display.id)
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
        .tesseraeCard()
    }

    private var quietHoursCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(
                "Override quiet hours",
                isOn: $model.overrideQuietHours
            )
            Text("Leave this off unless the image should be sent immediately.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .tesseraeCard()
    }
}

private enum ShareComposerError: Error, LocalizedError {
    case cancelled
    case imageDimensionsTooLarge(Int)
    case imageTooLarge(Int)
    case noDisplays
    case noImage
    case notPaired
    case unsupportedImageType(String)

    var errorDescription: String? {
        switch self {
        case .cancelled:
            String(localized: "Sharing was cancelled.")
        case let .imageDimensionsTooLarge(maxEdge):
            String(
                localized: "This image exceeds the server limit of \(maxEdge) pixels on its longest edge."
            )
        case let .imageTooLarge(bytes):
            String(
                localized: "This image exceeds the server upload limit of \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))."
            )
        case .noDisplays:
            String(
                localized: "No Tesserae displays are available. Refresh the main app first."
            )
        case .noImage:
            String(
                localized: "The shared item does not contain one readable still image."
            )
        case .notPaired:
            String(
                localized: "Pair Tesserae Companion with a server before using the Share Sheet."
            )
        case let .unsupportedImageType(type):
            String(
                localized: "The Tesserae server does not accept \(type) images."
            )
        }
    }
}
