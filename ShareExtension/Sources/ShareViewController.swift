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
        case failed
    }

    enum ContentKind {
        case image
        case link
    }

    @Published var phase: Phase = .loading
    @Published var snapshot: CompanionSnapshot?
    @Published var selectedDeviceIDs: Set<String> = []
    @Published var previewDeviceID: String?
    @Published var fit: ImageFitMode = .fit
    @Published var previewImage: UIImage?
    @Published var contentKind: ContentKind?
    @Published var sharedURL: URL?
    @Published var linkKind: LinkPushKind = .webpage
    @Published var errorMessage: String?

    private weak var extensionContext: NSExtensionContext?
    private var imageData: Data?
    private var contentType = "image/jpeg"
    private var fileName = "shared-photo.jpg"
    private var queuedImageRequests: [SharedImageRequest] = []
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
        if let previewDeviceID,
           selectedDeviceIDs.contains(previewDeviceID),
           let preview = displays.first(where: { $0.id == previewDeviceID })
        {
            return preview
        }
        return displays.first { selectedDeviceIDs.contains($0.id) }
    }

    var selectedDisplays: [DisplaySummary] {
        displays.filter { selectedDeviceIDs.contains($0.id) }
    }

    var supportsImageFraming: Bool {
        snapshot?.capabilities?.supportsImageFraming == true
    }

    var maximumFramingZoom: Double {
        max(snapshot?.capabilities?.limits.imageFramingMaxZoom ?? 1, 1)
    }

    var framingEditorIsActive: Bool {
        contentKind == .image
            && fit == .fill
            && previewImage != nil
            && supportsImageFraming
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
            previewDeviceID = snapshot.displays.first {
                selectedDeviceIDs.contains($0.id)
            }?.id
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

    func send(imageTargetGroups: [ImageSendTargetGroup] = []) async {
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
            let submittedJobs: [PushJob]
            var submissionError: (any Error)?
            switch contentKind {
            case .image:
                guard let imageData else { return }
                let outcome = try await submitImages(
                    imageData,
                    targetGroups: imageTargetGroups,
                    snapshot: snapshot
                )
                submittedJobs = outcome.jobs
                submissionError = outcome.firstError
            case .link:
                guard let sharedURL else { return }
                submittedJobs = [
                    try await submitLink(
                        sharedURL,
                        snapshot: snapshot
                    ),
                ]
            case nil:
                return
            }
            let submittedIDs = Set(submittedJobs.map(\.id))
            let jobs = submittedJobs
                + snapshot.jobs.filter { !submittedIDs.contains($0.id) }
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
            if let submissionError {
                errorMessage = failedRequestRetained
                    ? [
                        submissionError.localizedDescription,
                        queuedRetryMessage,
                    ].joined(separator: " ")
                    : submissionError.localizedDescription
                phase = .failed
                return
            }
            complete()
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

    private func submitImages(
        _ imageData: Data,
        targetGroups: [ImageSendTargetGroup],
        snapshot: CompanionSnapshot
    ) async throws -> ImageSubmissionOutcome {
        if queuedImageRequests.isEmpty {
            guard !targetGroups.isEmpty else {
                throw TesseraeClientError.noTargets
            }
            queuedImageRequests = targetGroups.map { group in
                SharedImageRequest(
                    instanceID: snapshot.activeInstance.id,
                    fileName: fileName,
                    contentType: contentType,
                    fit: fit,
                    framing: group.framing,
                    deviceIDs: group.deviceIDs,
                    overrideQuietHours: ManualSendPolicy.overridesQuietHours
                )
            }
        }

        var jobs: [PushJob] = []
        var remaining: [SharedImageRequest] = []
        var firstError: (any Error)?
        for request in queuedImageRequests {
            let submitting = request.updating(
                status: .submitting,
                error: nil
            )
            do {
                // Re-enqueueing is intentional: it gives every ratio group a
                // stable request and idempotency key even if persistence failed
                // part-way through the previous attempt.
                try await queueStore.enqueue(
                    imageData: imageData,
                    request: request
                )
                try await queueStore.update(submitting)
                let job = try await client.sendImage(
                    data: imageData,
                    fileName: submitting.fileName,
                    contentType: submitting.contentType,
                    fit: submitting.fit,
                    framing: submitting.framing,
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
                jobs.append(job)
            } catch {
                let failed = request.updating(
                    status: .failed,
                    error: error.localizedDescription
                )
                try? await queueStore.update(failed)
                remaining.append(failed)
                if firstError == nil {
                    firstError = error
                }
            }
        }
        queuedImageRequests = remaining
        failedRequestRetained = !remaining.isEmpty
        return ImageSubmissionOutcome(jobs: jobs, firstError: firstError)
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
             .forbidden,
             .incompatibleServer,
             .invalidResponse,
             .missingCredential,
             .offlineAlbumConflict,
             .offlineAlbumUnsupportedTargets,
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

private struct ImageSubmissionOutcome {
    let jobs: [PushJob]
    let firstError: (any Error)?
}

private struct ShareComposerView: View {
    @ObservedObject var model: ShareComposerModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var imageFramingsByAspect: [PanelAspectRatio: ImageFraming] = [:]

    var body: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading:
                    ProgressView("Loading shared item…")
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
                if model.phase == .failed && model.snapshot == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { model.complete() }
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.cancel() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        sendToolbarButton
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
            VStack(spacing: TesseraeComposerLayout.sectionSpacing) {
                displaysCard
                contentCard
                layoutCard

                if let errorMessage = model.errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .font(.footnote)
                        .foregroundStyle(TesseraeTheme.terracotta)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tesseraeCard()
                }
            }
            .padding(TesseraeComposerLayout.pagePadding)
        }
    }

    private var sendToolbarButton: some View {
        Button {
            Task {
                await model.send(imageTargetGroups: outgoingImageTargetGroups)
            }
        } label: {
            if model.phase == .submitting {
                ProgressView()
                    .controlSize(.small)
                    .frame(minWidth: 32)
            } else {
                Text(model.phase == .failed ? "Retry" : "Send")
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(!model.canSend && model.phase != .failed)
        .accessibilityLabel(
            model.phase == .submitting
                ? "Sending"
                : model.phase == .failed ? "Retry" : "Send"
        )
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
        VStack(
            alignment: .leading,
            spacing: TesseraeComposerLayout.contentCardSpacing
        ) {
            Text("Preview")
                .font(.headline)

            if let previewDisplay = model.previewDisplay {
                TesseraePanelImagePreview(
                    image: model.previewImage,
                    panel: previewDisplay.panel,
                    fit: model.fit,
                    maximumCanvasHeight: 220,
                    emptyTitle: String(localized: "Loading shared image…"),
                    accessibilityIdentifier: "share-panel-preview",
                    imageAccessibilityIdentifier: "shared-image-preview",
                    framing: previewImageFramingBinding,
                    maximumFramingZoom: model.maximumFramingZoom,
                    prioritizesFramingGesture: true
                )
                .accessibilityLabel("Display image preview")
                .accessibilityValue(
                    previewAccessibilityValue(panel: previewDisplay.panel)
                )
                .accessibilityHint(
                    model.framingEditorIsActive
                        ? "Drag to reposition the photo and pinch to zoom."
                        : ""
                )

                previewTargetPicker
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
        VStack(
            alignment: .leading,
            spacing: TesseraeComposerLayout.contentCardSpacing
        ) {
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
        VStack(
            alignment: .leading,
            spacing: TesseraeComposerLayout.controlCardSpacing
        ) {
            Text("Image Fit")
                .font(.headline)
            Picker("Image Fit", selection: $model.fit) {
                ForEach(model.fitModes, id: \.self) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            Text(model.fit.helpText)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .tesseraeCard()
    }

    private var displaysCard: some View {
        VStack(
            alignment: .leading,
            spacing: TesseraeComposerLayout.selectionCardSpacing
        ) {
            Text("Displays")
                .font(.headline)
            ForEach(model.displays) { display in
                Button {
                    if model.selectedDeviceIDs.contains(display.id) {
                        model.selectedDeviceIDs.remove(display.id)
                        if model.previewDeviceID == display.id {
                            model.previewDeviceID = model.displays.first {
                                model.selectedDeviceIDs.contains($0.id)
                            }?.id
                        }
                    } else {
                        model.selectedDeviceIDs.insert(display.id)
                        model.previewDeviceID = display.id
                    }
                } label: {
                    TesseraeDisplaySelectionRow(
                        name: display.name,
                        resolution: "\(display.panel.width)×\(display.panel.height)",
                        isSelected: model.selectedDeviceIDs.contains(display.id)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .tesseraeCard()
    }

    @ViewBuilder
    private var previewTargetPicker: some View {
        if model.selectedDisplays.count > 1 {
            Menu {
                ForEach(model.selectedDisplays) { display in
                    Button {
                        model.previewDeviceID = display.id
                    } label: {
                        Label(
                            "\(display.name) · \(PanelAspectRatio(panel: display.panel).displayName)",
                            systemImage: model.previewDisplay?.id == display.id
                                ? "checkmark.circle.fill"
                                : "circle"
                        )
                    }
                }
            } label: {
                previewTargetLabel(showsChevron: true)
            }
            .menuIndicator(.hidden)
            .accessibilityIdentifier("share-preview-display-picker")
        } else {
            previewTargetLabel(showsChevron: false)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(previewTargetSummary)
                .accessibilityIdentifier("share-preview-display-picker")
        }
    }

    private func previewTargetLabel(showsChevron: Bool) -> some View {
        HStack(spacing: 5) {
            Image(
                systemName: model.selectedDisplays.isEmpty
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
        .frame(
            maxWidth: .infinity,
            minHeight: previewTargetPickerHeight,
            alignment: .center
        )
        .contentShape(Rectangle())
        .layoutPriority(1)
    }

    private var previewTargetSummary: String {
        guard let display = model.previewDisplay else {
            return String(localized: "None selected")
        }
        let aspect = PanelAspectRatio(panel: display.panel).displayName
        return "\(display.name) · \(display.panel.width) × \(display.panel.height) · \(aspect)"
    }

    private var previewTargetPickerHeight: CGFloat {
        let lineHeight = UIFont.preferredFont(
            forTextStyle: .footnote
        ).lineHeight
        let lineCount: CGFloat = dynamicTypeSize.isAccessibilitySize ? 2 : 1
        return max(32, ceil(lineHeight * lineCount + 14))
    }

    private func previewAccessibilityValue(panel: PanelProfile) -> String {
        if model.framingEditorIsActive {
            return "fill, \(panel.width) by \(panel.height), \(previewImageFraming.zoom.formatted(.number.precision(.fractionLength(1...2)))) times zoom"
        }
        return "\(model.fit.rawValue), \(panel.width) by \(panel.height)"
    }

    private var previewAspectRatio: PanelAspectRatio? {
        model.previewDisplay.map { PanelAspectRatio(panel: $0.panel) }
    }

    private var previewImageFraming: ImageFraming {
        guard let previewAspectRatio else { return .centeredFill }
        return imageFramingsByAspect[previewAspectRatio] ?? .centeredFill
    }

    private var previewImageFramingBinding: Binding<ImageFraming>? {
        guard model.framingEditorIsActive, let previewAspectRatio else {
            return nil
        }
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
            displays: model.displays,
            selectedDeviceIDs: model.selectedDeviceIDs,
            framingsByAspect: imageFramingsByAspect,
            separatesByAspect: model.framingEditorIsActive,
            maximumZoom: model.maximumFramingZoom
        )
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
