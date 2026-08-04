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

    enum ContentKind {
        case image
        case link
    }

    @Published var phase: Phase = .loading
    @Published var snapshot: CompanionSnapshot?
    @Published var selectedDeviceIDs: Set<String> = []
    @Published var fit: ImageFitMode = .fit
    @Published var imageByteCount = 0
    @Published var previewImage: UIImage?
    @Published var contentKind: ContentKind?
    @Published var sharedURL: URL?
    @Published var linkKind: LinkPushKind = .webpage
    @Published var errorMessage: String?

    private weak var extensionContext: NSExtensionContext?
    private var imageData: Data?
    private var contentType = "image/jpeg"
    private var fileName = "shared-photo.jpg"
    private var queuedRequest: SharedImageRequest?
    private var queuedLinkRequest: SharedLinkRequest?
    private var failedRequestRetained = false

    private let stateStore: any CompanionStateStoring
    private let sendPreferences: any CompanionSendPreferencesStoring
    private let queueStore: any ShareQueueStoring
    private let linkQueueStore: any LinkShareQueueStoring
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
        sendPreferences = UserDefaultsCompanionSendPreferencesStore(
            suiteName: appGroup
        )
        queueStore = FileShareQueueStore(directoryURL: containerURL)
        linkQueueStore = FileLinkShareQueueStore(directoryURL: containerURL)
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
            && (
                contentKind == .image && imageData != nil
                    || contentKind == .link && sharedURL != nil
            )
            && !selectedDeviceIDs.isEmpty
            && snapshot != nil
    }

    var previewDisplay: DisplaySummary? {
        displays.first { selectedDeviceIDs.contains($0.id) }
    }

    var fitModes: [ImageFitMode] {
        let advertised = snapshot?.capabilities?.limits.imageFitModes
            ?? ImageFitMode.legacyModes
        let modes = ImageFitMode.allCases.filter(advertised.contains)
        return modes.isEmpty ? ImageFitMode.legacyModes : modes
    }

    var supportedLinkKinds: [LinkPushKind] {
        guard let capabilities = snapshot?.capabilities else { return [] }
        return LinkPushKind.allCases.filter(capabilities.supports)
    }

    func load() async {
        do {
            try await queueStore.purge(
                expiredBefore: Date().addingTimeInterval(-24 * 60 * 60)
            )
            try await linkQueueStore.purge(
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

            let availableLinkKinds = LinkPushKind.allCases.filter {
                snapshot.capabilities?.supports($0) == true
            }
            if let url = try await loadSharedURLIfPresent() {
                guard !availableLinkKinds.isEmpty else {
                    throw ShareComposerError.linkUnsupported
                }
                sharedURL = url
                contentKind = .link
                linkKind = availableLinkKinds.contains(.webpage)
                    ? .webpage
                    : availableLinkKinds[0]
            } else {
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
                imageData = loaded.data
                imageByteCount = loaded.data.count
                previewImage = UIImage(data: loaded.data)
                contentType = loaded.contentType
                fileName = loaded.fileName
                contentKind = .image
            }

            self.snapshot = snapshot
            let savedPreferences = try? await sendPreferences.preferences(
                for: snapshot.activeInstance.id
            )
            let availableDeviceIDs = Set(snapshot.displays.map(\.id))
            let preferredDeviceIDs = Set(savedPreferences?.deviceIDs ?? [])
                .intersection(availableDeviceIDs)
            if !preferredDeviceIDs.isEmpty {
                selectedDeviceIDs = preferredDeviceIDs
            } else {
                selectedDeviceIDs = Set(snapshot.displays.prefix(1).map(\.id))
            }
            if let preferredFit = savedPreferences?.imageFitMode,
               fitModes.contains(preferredFit)
            {
                fit = preferredFit
            } else if !fitModes.contains(fit) {
                fit = fitModes.first ?? .fit
            }
            phase = .ready
        } catch {
            errorMessage = error.localizedDescription
            phase = .failed
        }
    }

    func send() async {
        guard
            let snapshot,
            !selectedDeviceIDs.isEmpty
        else {
            return
        }
        phase = .submitting
        errorMessage = nil
        failedRequestRetained = false
        await savePreferences()

        do {
            let job: PushJob
            switch contentKind {
            case .image:
                guard let imageData else { return }
                job = try await submitImage(
                    imageData,
                    snapshot: snapshot
                )
            case .link:
                guard let sharedURL else { return }
                job = try await submitLink(
                    sharedURL,
                    snapshot: snapshot
                )
            case nil:
                return
            }
            let jobs = [job] + snapshot.jobs.filter { $0.id != job.id }
            try await stateStore.save(
                CompanionSnapshot(
                    activeInstance: snapshot.activeInstance,
                    capabilities: snapshot.capabilities,
                    displays: snapshot.displays,
                    dashboards: snapshot.dashboards,
                    jobs: jobs,
                    activityClearedBefore: snapshot.activityClearedBefore
                )
            )
            phase = .accepted
        } catch {
            errorMessage = failedRequestRetained
                ? [
                    error.localizedDescription,
                    queuedRetryMessage,
                ].joined(separator: " ")
                : error.localizedDescription
            phase = .failed
        }
    }

    private func submitImage(
        _ imageData: Data,
        snapshot: CompanionSnapshot
    ) async throws -> PushJob {
        let request = queuedRequest ?? SharedImageRequest(
            instanceID: snapshot.activeInstance.id,
            fileName: fileName,
            contentType: contentType,
            fit: fit,
            deviceIDs: Array(selectedDeviceIDs).sorted(),
            overrideQuietHours: ManualSendPolicy.overridesQuietHours
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
            _ = try? await activityThumbnails.save(
                imageData: imageData,
                jobID: job.id,
                instanceID: snapshot.activeInstance.id,
                createdAt: job.createdAt
            )
            try await queueStore.remove(submitting)
            queuedRequest = nil
            return job
        } catch {
            let failed = request.updating(
                status: .failed,
                error: error.localizedDescription
            )
            try? await queueStore.update(failed)
            queuedRequest = failed
            failedRequestRetained = true
            throw error
        }
    }

    private func submitLink(
        _ url: URL,
        snapshot: CompanionSnapshot
    ) async throws -> PushJob {
        guard supportedLinkKinds.contains(linkKind) else {
            throw ShareComposerError.linkUnsupported
        }
        let request = queuedLinkRequest ?? SharedLinkRequest(
            instanceID: snapshot.activeInstance.id,
            url: url,
            kind: linkKind,
            fit: fit,
            deviceIDs: Array(selectedDeviceIDs).sorted(),
            overrideQuietHours: ManualSendPolicy.overridesQuietHours
        )
        do {
            if queuedLinkRequest == nil {
                try await linkQueueStore.enqueue(request)
                queuedLinkRequest = request
            }
            let submitting = request.updating(
                status: .submitting,
                error: nil
            )
            try await linkQueueStore.update(submitting)
            queuedLinkRequest = submitting

            let job: PushJob
            switch submitting.kind {
            case .imageURL:
                job = try await client.sendImageURL(
                    url: submitting.url,
                    fit: submitting.fit,
                    deviceIDs: submitting.deviceIDs,
                    overrideQuietHours: submitting.overrideQuietHours,
                    idempotencyKey: submitting.idempotencyKey,
                    instance: snapshot.activeInstance
                )
            case .webpage:
                job = try await client.sendWebpage(
                    url: submitting.url,
                    fit: submitting.fit,
                    viewportW: nil,
                    deviceIDs: submitting.deviceIDs,
                    overrideQuietHours: submitting.overrideQuietHours,
                    idempotencyKey: submitting.idempotencyKey,
                    instance: snapshot.activeInstance
                )
            }
            try await linkQueueStore.remove(submitting)
            queuedLinkRequest = nil
            return job
        } catch {
            if shouldRetainLinkRequest(after: error) {
                let failed = request.updating(
                    status: .failed,
                    error: error.localizedDescription
                )
                try? await linkQueueStore.update(failed)
                queuedLinkRequest = failed
                failedRequestRetained = true
            } else {
                try? await linkQueueStore.remove(request)
                queuedLinkRequest = nil
            }
            throw error
        }
    }

    private func shouldRetainLinkRequest(after error: Error) -> Bool {
        guard let clientError = error as? TesseraeClientError else {
            return true
        }
        switch clientError {
        case let .server(code, _, _):
            return ![
                "invalid_request",
                "invalid_target",
                "url_blocked",
            ].contains(code)
        case let .httpStatus(status):
            return status == 408 || status == 429 || status >= 500
        case .invalidPairingCode,
             .invalidServerURL,
             .missingFeatures,
             .noTargets,
             .pairingUnavailable:
            return false
        case .decoding,
             .incompatibleServer,
             .invalidResponse,
             .missingCredential,
             .transport,
             .unauthorized,
             .unavailable:
            return true
        }
    }

    private var queuedRetryMessage: String {
        switch contentKind {
        case .image:
            String(
                localized: "The image is saved for up to 24 hours and the app will retry with the same request key."
            )
        case .link:
            String(
                localized: "The link is saved for up to 24 hours and the app will retry with the same request key."
            )
        case nil:
            ""
        }
    }

    func savePreferences() async {
        guard let snapshot, !selectedDeviceIDs.isEmpty else { return }
        try? await sendPreferences.save(
            CompanionSendPreferences(
                instanceID: snapshot.activeInstance.id,
                deviceIDs: Array(selectedDeviceIDs),
                imageFitMode: fit
            )
        )
    }

    func complete() {
        extensionContext?.completeRequest(returningItems: nil)
    }

    func cancel() {
        extensionContext?.cancelRequest(
            withError: ShareComposerError.cancelled
        )
    }

    private func loadSharedURLIfPresent() async throws -> URL? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            throw ShareComposerError.noSharedItem
        }
        let providers = items.flatMap { $0.attachments ?? [] }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) else {
            return nil
        }

        let url = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<URL, Error>) in
            provider.loadItem(
                forTypeIdentifier: UTType.url.identifier,
                options: nil
            ) { item, error in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else {
                    continuation.resume(
                        throwing: error ?? ShareComposerError.invalidURL
                    )
                }
            }
        }
        guard
            let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            url.host() != nil,
            url.user() == nil,
            url.password() == nil
        else {
            throw ShareComposerError.invalidURL
        }
        return url
    }

    private func loadSharedImage(
        maximumPixelSize: Int
    ) async throws -> (
        data: Data,
        contentType: String,
        fileName: String
    ) {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            throw ShareComposerError.noSharedItem
        }
        let providers = items.flatMap { item in
            item.attachments ?? []
        }
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.image.identifier)
        }) else {
            throw ShareComposerError.noSharedItem
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
                    ProgressView("Loading shared item…")
                case .accepted:
                    ContentUnavailableView(
                        "Accepted by Tesserae",
                        systemImage: "checkmark.circle.fill",
                        description: Text(acceptedDescription)
                    )
                case .failed where model.snapshot == nil:
                    ContentUnavailableView(
                        "Open Tesserae Companion",
                        systemImage: "iphone.and.arrow.forward",
                        description: Text(
                            model.errorMessage
                                ?? String(localized: "Pair the app before sharing an item.")
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
        .onChange(of: model.selectedDeviceIDs) {
            guard model.phase == .ready else { return }
            Task { await model.savePreferences() }
        }
        .onChange(of: model.fit) {
            guard model.phase == .ready else { return }
            Task { await model.savePreferences() }
        }
    }

    private var composer: some View {
        ScrollView {
            VStack(spacing: 14) {
                contentCard
                layoutCard
                displaysCard

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

    @ViewBuilder
    private var contentCard: some View {
        switch model.contentKind {
        case .image:
            imageCard
        case .link:
            linkCard
        case nil:
            EmptyView()
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

    private var linkCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Link")
                .font(.headline)

            if let url = model.sharedURL {
                Label {
                    Text(url.absoluteString)
                        .lineLimit(3)
                        .textSelection(.enabled)
                } icon: {
                    Image(systemName: "link")
                }
                .font(.subheadline)
            }

            if model.supportedLinkKinds.count > 1 {
                Picker("Link Action", selection: $model.linkKind) {
                    ForEach(model.supportedLinkKinds, id: \.self) { kind in
                        Text(linkKindName(kind)).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
            } else if let kind = model.supportedLinkKinds.first {
                Label(
                    linkKindName(kind),
                    systemImage: kind == .webpage
                        ? "safari"
                        : "photo.badge.arrow.down"
                )
                .font(.subheadline.weight(.semibold))
            }

            Text(linkKindHelp(model.linkKind))
                .font(.footnote)
                .foregroundStyle(.secondary)

            Text(
                "No Safari cookies or browsing session are shared. Private and local addresses are blocked."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .tesseraeCard()
    }

    private var layoutCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Layout")
                .font(.headline)
            HStack(spacing: 10) {
                Picker("Layout", selection: $model.fit) {
                    ForEach(primaryFitModes, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                if !advancedFitModes.isEmpty {
                    Menu {
                        ForEach(advancedFitModes, id: \.self) { mode in
                            Button {
                                model.fit = mode
                            } label: {
                                if model.fit == mode {
                                    Label(mode.displayName, systemImage: "checkmark")
                                } else {
                                    Text(mode.displayName)
                                }
                            }
                        }
                    } label: {
                        Label(
                            advancedFitModes.contains(model.fit)
                                ? model.fit.displayName
                                : "More",
                            systemImage: "ellipsis.circle"
                        )
                    }
                    .buttonStyle(.bordered)
                }
            }
            Text(model.fit.helpText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .tesseraeCard()
    }

    private var primaryFitModes: [ImageFitMode] {
        model.fitModes.filter { $0 != .stretch && $0 != .center }
    }

    private var advancedFitModes: [ImageFitMode] {
        model.fitModes.filter { $0 == .stretch || $0 == .center }
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

    private var acceptedDescription: String {
        switch model.contentKind {
        case .image:
            String(localized: "The server will render and publish the image.")
        case .link:
            String(localized: "The server will fetch or render and publish the link.")
        case nil:
            String(localized: "The server accepted the shared item.")
        }
    }

    private func linkKindName(_ kind: LinkPushKind) -> String {
        switch kind {
        case .imageURL:
            String(localized: "Image URL")
        case .webpage:
            String(localized: "Webpage Snapshot")
        }
    }

    private func linkKindHelp(_ kind: LinkPushKind) -> String {
        switch kind {
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

private enum ShareComposerError: Error, LocalizedError {
    case cancelled
    case imageDimensionsTooLarge(Int)
    case imageTooLarge(Int)
    case invalidURL
    case linkUnsupported
    case noDisplays
    case noImage
    case noSharedItem
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
        case .invalidURL:
            String(
                localized: "The shared link is not a valid HTTP or HTTPS URL."
            )
        case .linkUnsupported:
            String(
                localized: "This Tesserae server does not support sharing links from iOS."
            )
        case .noDisplays:
            String(
                localized: "No Tesserae displays are available. Refresh the main app first."
            )
        case .noImage:
            String(
                localized: "The shared item does not contain one readable still image."
            )
        case .noSharedItem:
            String(
                localized: "The shared item does not contain one readable image or web link."
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
