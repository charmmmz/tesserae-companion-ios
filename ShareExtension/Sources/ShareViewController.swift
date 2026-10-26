import SwiftUI
import TesseraeKit
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        // A preferred size only; the host still constrains this for compact and
        // folded presentations, which use the same scrollable composer.
        preferredContentSize = CGSize(width: 960, height: 760)

        let model = ShareComposerModel(extensionContext: extensionContext) { [weak self] busy in
            self?.isModalInPresentation = busy
        }
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
    enum Phase: Equatable {
        case loading
        case ready
        case submitting
        case succeeded
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
    @Published private(set) var bluetoothSession: BluetoothShareSession?
    @Published private(set) var bluetoothTargetID: String?
    @Published private(set) var bluetoothIsBusy = false
    let framingSession = PhotoFramingSession()
    let mediaFrames: MediaFrameSession
#if DEBUG
    private var testCompletion: (() -> Void)?
#endif
    private var appliedMediaRevision: UUID?

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
    private let protectDismissal: (Bool) -> Void

    init(extensionContext: NSExtensionContext?, mediaFrames: MediaFrameSession? = nil,
         protectDismissal: @escaping (Bool) -> Void) {
        self.extensionContext = extensionContext
        self.mediaFrames = mediaFrames ?? MediaFrameSession()
        self.protectDismissal = protectDismissal

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
        (phase == .ready || (phase == .failed && bluetoothTargetID == nil))
            && !mediaFrames.isBusy
            && (mediaFrames.source == nil || appliedMediaRevision == mediaFrames.outputRevision)
            && (
                contentKind == .image && imageData != nil
                    || contentKind == .link && sharedURL != nil
            )
            && (bluetoothTargetID != nil
                ? bluetoothSession?.canSend == true
                : !selectedDeviceIDs.isEmpty && snapshot != nil)
    }

    var sendTargets: [ShareDisplayTarget] {
        guard let bluetoothSession else {
            return displays.map { .init(id: $0.id, name: $0.name, display: $0, record: nil, nearby: nil) }
        }
        return ShareDisplayTarget.catalog(displays: displays, serverID: snapshot?.activeInstance.id,
            records: bluetoothSession.nearby.displayRecords, nearby: bluetoothSession.devices)
    }

    var bluetoothTarget: ShareDisplayTarget? { sendTargets.first { $0.id == bluetoothTargetID } }
    var previewPanel: PanelProfile? {
        if let bluetoothTarget {
            if bluetoothSession?.nearby.connectionState == .ready { return bluetoothSession?.panel }
            return bluetoothTarget.panel
        }
        return previewDisplay?.panel
    }
    var previewName: String? { bluetoothTarget?.name ?? previewDisplay?.name }

    func select(_ target: ShareDisplayTarget) {
        guard !isBusy, !mediaFrames.isBusy, !framingSession.isFrozen else { return }
        errorMessage = nil
        if target.isBluetooth {
            selectedDeviceIDs = []
            if bluetoothTargetID == target.id, bluetoothSession?.failure == nil {
                bluetoothTargetID = nil
                bluetoothSession?.changeDisplay()
            } else {
                bluetoothTargetID = target.id
                if let device = target.nearby { bluetoothSession?.select(device) }
                else { bluetoothSession?.changeDisplay() }
            }
        } else {
            if bluetoothTargetID != nil { bluetoothSession?.changeDisplay() }
            bluetoothTargetID = nil
            if selectedDeviceIDs.contains(target.id) { selectedDeviceIDs.remove(target.id) }
            else { selectedDeviceIDs.insert(target.id); previewDeviceID = target.id }
        }
        if !fitModes.contains(fit) { fit = .fill }
    }

    func reconcileBluetoothSelection() {
        guard let session = bluetoothSession, bluetoothTargetID != nil, !isBusy else { return }
        // Once authenticated info supplies a full identity, fold a discovery row into its saved row.
        if bluetoothTarget == nil, let id = session.selectedDevice?.id,
           let resolved = sendTargets.first(where: { $0.nearby?.id == id }) {
            bluetoothTargetID = resolved.id
        }
        if let device = bluetoothTarget?.nearby,
           session.selectedDevice?.id != device.id {
            session.select(device)
        }
    }

    func sendBluetooth() {
        guard canSend, bluetoothTargetID != nil, let session = bluetoothSession,
              let image = previewImage, let panel = previewPanel else { return }
        phase = .submitting
        framingSession.freeze()
        errorMessage = nil
        protectDismissal(true)
        session.send(image: image, fit: fit,
            framing: framingSession.framing(for: PanelAspectRatio(panel: panel)),
            preparationChanged: setBluetoothBusy)
    }

    var sharedImageData: Data? { imageData }
    var isBusy: Bool { bluetoothIsBusy || phase == .submitting }

    func setBluetoothBusy(_ busy: Bool) {
        bluetoothIsBusy = busy
        if !busy, phase == .submitting, let failure = bluetoothSession?.failure {
            phase = .ready
            errorMessage = failure
            framingSession.resumeEditing()
        }
        protectDismissal(isBusy)
    }

    func bluetoothSent() {
        phase = .succeeded
        complete()
    }

    func applyMediaFrame() {
        guard phase != .submitting, !framingSession.isFrozen,
              appliedMediaRevision != mediaFrames.outputRevision,
              let image = mediaFrames.output else { return }
        appliedMediaRevision = mediaFrames.outputRevision
        imageData = image.data
        previewImage = UIImage(data: image.data)
        contentType = image.contentType
        fileName = "shared-photo.\(image.fileExtension)"
        framingSession.discardAnalysis()
    }

    func autoFrame(aspect: PanelAspectRatio) {
        guard phase == .ready, framingEditorIsActive,
              !selectedDeviceIDs.isEmpty || bluetoothTargetID != nil,
              let imageData else { return }
        framingSession.request(data: imageData, aspect: aspect, maximumZoom: maximumFramingZoom)
    }

    var automaticFramingContext: PhotoFramingSession.AutomaticContext {
        .init(
            imageID: framingSession.imageID, instanceID: snapshot?.activeInstance.id,
            aspect: previewPanel.map(PanelAspectRatio.init(panel:)),
            targetIDs: bluetoothTargetID.map { [$0] } ?? selectedDeviceIDs, maximumZoom: maximumFramingZoom,
            isReady: phase == .ready && framingEditorIsActive
        )
    }

    func updateAutomaticFraming(_ context: PhotoFramingSession.AutomaticContext) {
        framingSession.updateAutomaticContext(context, data: imageData)
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
        bluetoothTargetID != nil || snapshot?.capabilities?.supportsImageFraming == true
    }

    var maximumFramingZoom: Double {
        bluetoothTargetID != nil ? 4 : max(snapshot?.capabilities?.limits.imageFramingMaxZoom ?? 1, 1)
    }

    var framingEditorIsActive: Bool {
        contentKind == .image
            && fit == .fill
            && previewImage != nil
            && supportsImageFraming
    }

    var fitModes: [ImageFitMode] {
        if bluetoothTargetID != nil { return [.fill, .fit] }
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
            try? await queueStore.purge(
                expiredBefore: Date().addingTimeInterval(-24 * 60 * 60)
            )
            try? await linkQueueStore.purge(
                expiredBefore: Date().addingTimeInterval(-24 * 60 * 60)
            )
            // Bluetooth photo sharing is independent of server pairing and reachability.
            if let saved = try? await stateStore.load(),
               (try? await credentials.token(for: saved.activeInstance.id)) != nil {
                snapshot = saved
            }
            let snapshot = self.snapshot
            let availableLinkKinds = LinkPushKind.allCases.filter {
                snapshot?.capabilities?.supports($0) == true
            }
            if let url = try await loadSharedURLIfPresent() {
                guard snapshot != nil else { throw ShareComposerError.notPaired }
                guard !availableLinkKinds.isEmpty else {
                    throw ShareComposerError.linkUnsupported
                }
                sharedURL = url
                contentKind = .link
                linkKind = availableLinkKinds.contains(.webpage)
                    ? .webpage
                    : availableLinkKinds[0]
            } else {
                let displayMaxEdge = snapshot?.displays
                    .map { max($0.panel.width, $0.panel.height) }
                    .max() ?? 2_048
                let loaded = try await loadSharedImage(
                    maximumPixelSize: max(2_048, displayMaxEdge)
                )
                imageData = loaded.data
                framingSession.replaceImage()
                previewImage = UIImage(data: loaded.data)
                contentType = loaded.contentType
                fileName = loaded.fileName
                contentKind = .image
                fit = .fill
                bluetoothSession = BluetoothShareSession()
                bluetoothSession?.start()
            }
            guard let snapshot else {
                phase = .ready
                return
            }
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
            if let preferredBluetooth = sendTargets.first(where: { selectedDeviceIDs.contains($0.id) && $0.isBluetooth }) {
                selectedDeviceIDs = []
                bluetoothTargetID = preferredBluetooth.id
                if let device = preferredBluetooth.nearby { bluetoothSession?.select(device) }
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

    func send(imageTargetGroups: [ImageSendTargetGroup] = []) async {
        guard
            let snapshot,
            phase == .ready || phase == .failed,
            !mediaFrames.isBusy,
            mediaFrames.source == nil || appliedMediaRevision == mediaFrames.outputRevision,
            !selectedDeviceIDs.isEmpty
        else {
            return
        }
        phase = .submitting
        protectDismissal(true)
        defer { protectDismissal(false) }
        if contentKind == .image { framingSession.freeze() }
        errorMessage = nil
        failedRequestRetained = false
        await savePreferences()

        do {
            let submittedJobs: [PushJob]
            var submissionError: (any Error)?
            switch contentKind {
            case .image:
                guard let imageData else { return }
                let maximumPixelSize = snapshot.capabilities?.limits.imageMaxEdge
                    ?? snapshot.displays.map { max($0.panel.width, $0.panel.height) }.max() ?? 2_048
                let sourceType = contentType
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try UploadImagePreparer.prepare(data: imageData, fallbackContentType: sourceType,
                                                   maximumPixelSize: maximumPixelSize)
                }.value
                try validate(data: prepared.data, contentType: prepared.contentType, capabilities: snapshot.capabilities)
                contentType = prepared.contentType
                fileName = "shared-photo.\(prepared.fileExtension)"
                let outcome = try await submitImages(
                    prepared.data,
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
            phase = .succeeded
            try? await Task.sleep(for: .milliseconds(220))
            guard phase == .succeeded else { return }
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
        guard bluetoothTargetID == nil, let snapshot, !selectedDeviceIDs.isEmpty else { return }
        try? await sendPreferences.save(
            CompanionSendPreferences(
                instanceID: snapshot.activeInstance.id,
                deviceIDs: Array(selectedDeviceIDs),
                imageFitMode: fit
            )
        )
    }

    func complete() {
        mediaFrames.cancelWork()
        protectDismissal(false)
        framingSession.discardAnalysis()
        bluetoothSession?.stop()
#if DEBUG
        if let testCompletion { testCompletion(); return }
#endif
        extensionContext?.completeRequest(returningItems: nil)
    }

    func cancel() {
        mediaFrames.cancelWork()
        guard !isBusy else { return }
        framingSession.discardAnalysis()
        bluetoothSession?.stop()
        extensionContext?.cancelRequest(
            withError: ShareComposerError.cancelled
        )
    }

    private func loadSharedURLIfPresent() async throws -> URL? {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            throw ShareComposerError.noSharedItem
        }
        let providers = items.flatMap { $0.attachments ?? [] }
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier) }) { return nil }
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
                || $0.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
        }) else {
            throw ShareComposerError.noSharedItem
        }

        let selection = MediaPickerSelection(provider: provider)
        if selection.kind != .photo {
            let source = try await selection.load(maximumPixelSize: maximumPixelSize)
            mediaFrames.adopt(source)
            appliedMediaRevision = mediaFrames.outputRevision
            let prepared = source.primaryImage
            return (prepared.data, prepared.contentType, "shared-photo.\(prepared.fileExtension)")
        }

        let type = provider.registeredTypeIdentifiers
            .compactMap(UTType.init)
            .first(where: { $0.conforms(to: UTType.image) }) ?? .jpeg
        let data = try await loadData(
            from: provider,
            typeIdentifier: type.identifier
        )
        let prepared: PreparedUploadImage
        do {
            prepared = try await Task.detached(priority: .userInitiated) {
                try UploadImagePreparer.prepare(
                    data: data,
                    fallbackContentType: type.preferredMIMEType ?? "image/jpeg",
                    maximumPixelSize: maximumPixelSize
                )
            }.value
        } catch UploadImagePreparationError.decoding {
            // UIKit share sources may vend an archived UIImage rather than image-file bytes.
            let pixels = try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Data, Error>) in
                provider.loadItem(forTypeIdentifier: type.identifier, options: nil) { object, error in
                    if let image = object as? UIImage, let data = image.pngData() {
                        continuation.resume(returning: data)
                    } else if let url = object as? URL, url.isFileURL {
                        do { continuation.resume(returning: try Data(contentsOf: url)) }
                        catch { continuation.resume(throwing: error) }
                    } else { continuation.resume(throwing: error ?? ShareComposerError.noImage) }
                }
            }
            prepared = try await Task.detached(priority: .userInitiated) {
                try UploadImagePreparer.prepare(data: pixels, fallbackContentType: "image/png",
                                               maximumPixelSize: maximumPixelSize)
            }.value
        }
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

#if DEBUG
extension ShareComposerModel {
    static func fixture(image: UIImage, data: Data, mediaFrames: MediaFrameSession,
                        onBusy: @escaping (Bool) -> Void, onSent: @escaping () -> Void) -> ShareComposerModel {
        let model = ShareComposerModel(extensionContext: nil, mediaFrames: mediaFrames, protectDismissal: onBusy)
        model.imageData = data
        model.previewImage = image
        model.contentKind = .image
        model.fit = .fill
        model.phase = .ready
        model.testCompletion = onSent
        let records = BluetoothDisplayStore(fileURL: nil)
        let nearby = NearbyDeviceManager(displayRecords: records, photoSharingOnly: true)
        if ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_UNIFIED_SHARE_TARGETS"] == "1",
           let device = nearby.nearbyDevices.first {
            let instance = TesseraeInstance(id: "share-test", name: "Test Server",
                baseURL: URL(string: "http://127.0.0.1")!, serverVersion: "test", timezone: "UTC", webURL: "/")
            records.activeServerID = instance.id
            records.observe(deviceID: "picpak-f85b1ba1b2c3", name: "Kitchen", mode: .bluetooth,
                batteryMillivolts: nil, peripheralID: device.id)
            let panel = PanelProfile(width: 400, height: 300, gamut: "bwry_4", orientation: "landscape")
            model.snapshot = CompanionSnapshot(activeInstance: instance, capabilities: nil, displays: [
                DisplaySummary(id: "picpak-f85b1ba1b2c3", name: "Kitchen", kind: "picpak_4_2", iconName: "display",
                    panel: panel, freshness: .stale),
                DisplaySummary(id: "living-room", name: "Living Room", kind: "test_panel", iconName: "display",
                    panel: panel, freshness: .stale)
            ], dashboards: [], jobs: [])
        }
        model.bluetoothSession = BluetoothShareSession(nearby: nearby)
        model.bluetoothSession?.start()
        model.applyMediaFrame()
        return model
    }
}

/// Hosts the production share composer, so fixture tests exercise its actual selection and send actions.
struct ShareComposerTestView: View {
    @StateObject private var model: ShareComposerModel
    init(image: UIImage, imageData: Data, mediaFrames: MediaFrameSession,
         onBusyChange: @escaping (Bool) -> Void, onSent: @escaping () -> Void) {
        _model = StateObject(wrappedValue: .fixture(image: image, data: imageData, mediaFrames: mediaFrames,
            onBusy: onBusyChange, onSent: onSent))
    }
    var body: some View { ShareComposerView(model: model) }
}
#endif

private struct ImageSubmissionOutcome {
    let jobs: [PushJob]
    let firstError: (any Error)?
}

private struct ShareComposerView: View {
    @ObservedObject var model: ShareComposerModel
    @State private var previewHeight: CGFloat = 220
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var hapticEvent = TesseraeHapticEvent()
    @Environment(\.scenePhase) private var scenePhase

    private var page: some View {
        NavigationStack {
            Group {
                switch model.phase {
                case .loading:
                    ProgressView("Loading shared item…")
                case .failed where model.contentKind == nil:
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
                TesseraeTheme.background,
                for: .navigationBar
            )
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                if model.phase == .failed && model.contentKind == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", systemImage: "checkmark") { model.complete() }
                            .labelStyle(.iconOnly)
                    }
                } else if model.phase == .succeeded {
                    ToolbarItem(placement: .confirmationAction) {
                        Image(systemName: "checkmark")
                            .foregroundStyle(TesseraeTheme.success)
                            .accessibilityLabel("Sent")
                    }
                } else {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark") { model.cancel() }
                            .labelStyle(.iconOnly)
                            .disabled(model.isBusy)
                            .accessibilityIdentifier("share-cancel")
                    }
                    if model.contentKind != nil {
                        ToolbarItem(placement: .confirmationAction) {
                            sendToolbarButton
                        }
                    }
                }
            }
        }
    }

    private var bluetoothPage: some View {
        page
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            previewHeight = composerCanvasHeight(in: size)
        }
        .tint(TesseraeTheme.accent)
        .interactiveDismissDisabled(model.isBusy)
        .tesseraeHapticFeedback(trigger: hapticEvent)
        .onDisappear {
            model.mediaFrames.cancelWork()
            model.bluetoothSession?.stop()
        }
        .onChange(of: scenePhase) { _, phase in
            model.bluetoothSession?.nearby.updateApplicationActivity(phase == .active)
        }
        .onChange(of: model.sendTargets) { _, _ in model.reconcileBluetoothSelection() }
        .onChange(of: model.bluetoothSession?.isBusy) { _, busy in model.setBluetoothBusy(busy == true) }
        .onChange(of: model.bluetoothSession?.failure) { _, _ in
            model.setBluetoothBusy(model.bluetoothSession?.isBusy == true)
        }
        .onChange(of: model.bluetoothSession?.nearby.photoState) { _, state in
            if state == .received, model.bluetoothTargetID != nil, model.phase == .submitting {
                model.bluetoothSent()
            }
        }
    }

    var body: some View {
        bluetoothPage
        .onChange(of: model.mediaFrames.outputRevision) { _, _ in model.applyMediaFrame() }
        .onAppear { if model.mediaFrames.isExpanded { model.mediaFrames.expand() } }
        .onChange(of: model.automaticFramingContext, initial: true) { _, context in
            model.updateAutomaticFraming(context)
        }
        .onChange(of: model.phase) { oldValue, newValue in
            guard oldValue == .submitting else { return }
            switch newValue {
            case .succeeded:
                hapticEvent.trigger(.success)
            case .failed:
                hapticEvent.trigger(.error)
            default:
                break
            }
        }
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
        AdaptiveComposerLayout {
            contentCard
        } controls: {
            displaysCard
                .disabled(model.framingSession.isFrozen || model.mediaFrames.isBusy)
            layoutCard
                .disabled(model.framingSession.isFrozen || model.mediaFrames.isBusy)

            bluetoothStatus

            if let errorMessage = model.errorMessage, model.bluetoothTargetID == nil {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(TesseraeTheme.danger)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tesseraeCard()
            }
        }
    }

    private var sendToolbarButton: some View {
        Button {
            guard !model.mediaFrames.isBusy, model.canSend || model.phase == .failed else { return }
            if model.bluetoothTargetID != nil {
                model.sendBluetooth()
                return
            }
            if model.contentKind == .image { model.framingSession.freeze() }
            let groups = outgoingImageTargetGroups
            Task {
                await model.send(imageTargetGroups: groups)
            }
        } label: {
            if model.isBusy {
                ProgressView()
                    .tint(.white)
                    .controlSize(.small)
                    .frame(minWidth: 32)
            } else {
                Text(model.phase == .failed ? "Retry" : "Send")
            }
        }
        .buttonStyle(.borderedProminent)
        .tint(TesseraeTheme.accentFill)
        .foregroundStyle(.white)
        .accessibilityIdentifier("share-send")
        .disabled(model.isBusy || model.mediaFrames.isBusy || !model.canSend)
        .accessibilityLabel(
            model.phase == .submitting
                ? "Sending"
                : model.phase == .failed ? "Retry" : "Send"
        )
    }

    @ViewBuilder private var bluetoothStatus: some View {
        if model.bluetoothTargetID != nil, let session = model.bluetoothSession {
            if let failure = session.failure {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(TesseraeTheme.danger).tesseraeCard()
                    .accessibilityIdentifier("share-bluetooth-error")
            } else if let message = session.nearby.bluetoothUnavailableMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(TesseraeTheme.warning).tesseraeCard()
            } else if session.isBusy {
                VStack(alignment: .leading, spacing: 10) {
                    if session.isPreparing { ProgressView("Preparing photo…") }
                    else {
                        ProgressView(value: session.nearby.photoProgress) {
                            Text(session.nearby.photoProgress >= 1 ? "Waiting for display confirmation…" : "Sending photo…")
                        }
                    }
                }
                .tesseraeCard()
            } else if model.bluetoothTarget?.nearby == nil {
                Text("Not nearby")
                    .font(.footnote).foregroundStyle(.secondary).tesseraeCard()
            } else if session.nearby.connectionState != .ready {
                ProgressView(session.nearby.statusMessage ?? String(localized: "Connecting securely…"))
                    .tesseraeCard()
            }
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
        VStack(
            alignment: .leading,
            spacing: TesseraeComposerLayout.contentCardSpacing
        ) {
            Text("Preview")
                .font(.headline)

            if let panel = model.previewPanel {
                TesseraePanelImagePreview(
                    image: model.previewImage,
                    panel: panel,
                    fit: model.fit,
                    maximumCanvasHeight: previewHeight,
                    emptyTitle: String(localized: "Loading shared image…"),
                    accessibilityIdentifier: "share-panel-preview",
                    imageAccessibilityIdentifier: "shared-image-preview",
                    framing: previewImageFramingBinding,
                    maximumFramingZoom: model.maximumFramingZoom,
                    prioritizesFramingGesture: true,
                    framingEditingEnabled: !model.framingSession.isFrozen && !model.mediaFrames.isBusy,
                    onAutoFrame: model.framingEditorIsActive ? { autoFrame() } : nil,
                    isAutoFraming: model.framingSession.isAnalyzing,
                    autoFramingFeedback: model.framingSession.feedback,
                    onFramingInteraction: { framingInteractionStarted() }
                )
                .accessibilityLabel("Display image preview")
                .accessibilityValue(
                    previewAccessibilityValue(panel: panel)
                )
                .accessibilityHint(
                    model.framingEditorIsActive && !model.framingSession.isFrozen
                        ? "Drag to reposition the photo and pinch to zoom."
                        : ""
                )

                previewTargetPicker
            } else {
                if let image = model.previewImage {
                    Image(uiImage: image).resizable().scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: previewHeight)
                        .accessibilityLabel("Shared photo")
                }
                Text("Select a display to preview its panel shape.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            MediaFrameControls(session: model.mediaFrames, isSending: model.framingSession.isFrozen)
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
                .tesseraeAdaptivePickerStyle()
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
                    Text(LocalizedStringKey(mode.displayName)).tag(mode)
                }
            }
            .tesseraeAdaptivePickerStyle()
            .accessibilityIdentifier("share-image-fit-picker")
            Text(LocalizedStringKey(model.fit.helpText))
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
            ForEach(model.sendTargets) { target in
                Button {
                    model.select(target)
                    hapticEvent.trigger(.selection)
                } label: {
                    TesseraeDisplaySelectionRow(
                        name: target.name,
                        resolution: target.panel.map { "\($0.width)×\($0.height)" }
                            ?? (target.nearby == nil ? String(localized: "Not nearby") : String(localized: "Nearby")),
                        isSelected: target.isBluetooth ? model.bluetoothTargetID == target.id
                            : model.selectedDeviceIDs.contains(target.id),
                        transport: target.isBluetooth ? String(localized: "Bluetooth") : nil
                    )
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("share-display-\(target.id)")
            }
            if let session = model.bluetoothSession, model.sendTargets.isEmpty {
                if let message = session.nearby.bluetoothUnavailableMessage {
                    Text(message).font(.footnote).foregroundStyle(.secondary)
                } else if session.devices.isEmpty && session.selectedDevice == nil {
                    ProgressView("Looking for nearby displays…").font(.footnote)
                }
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
            if !dynamicTypeSize.isAccessibilitySize {
                Image(
                    systemName: model.previewPanel == nil
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
        .frame(
            maxWidth: .infinity,
            minHeight: 44,
            alignment: .center
        )
        .contentShape(Rectangle())
        .layoutPriority(1)
    }

    private var previewTargetSummary: String {
        guard let panel = model.previewPanel, let name = model.previewName else {
            return String(localized: "None selected")
        }
        let aspect = PanelAspectRatio(panel: panel).displayName
        return "\(name) · \(panel.width) × \(panel.height) · \(aspect)"
    }


    private func previewAccessibilityValue(panel: PanelProfile) -> String {
        if model.framingEditorIsActive {
            return "fill, \(panel.width) by \(panel.height), \(previewImageFraming.zoom.formatted(.number.precision(.fractionLength(1...2)))) times zoom"
        }
        return "\(model.fit.rawValue), \(panel.width) by \(panel.height)"
    }

    private var previewAspectRatio: PanelAspectRatio? {
        model.previewPanel.map(PanelAspectRatio.init(panel:))
    }

    private var previewImageFraming: ImageFraming {
        guard let previewAspectRatio else { return .centeredFill }
        return model.framingSession.framing(for: previewAspectRatio)
    }

    private var previewImageFramingBinding: Binding<ImageFraming>? {
        guard model.framingEditorIsActive, let previewAspectRatio else {
            return nil
        }
        return Binding(
            get: {
                model.framingSession.framing(for: previewAspectRatio)
            },
            set: { framing in
                model.framingSession.setFraming(framing, for: previewAspectRatio)
            }
        )
    }

    private var outgoingImageTargetGroups: [ImageSendTargetGroup] {
        imageSendTargetGroups(
            displays: model.displays,
            selectedDeviceIDs: model.selectedDeviceIDs,
            framingsByAspect: model.framingSession.framings,
            separatesByAspect: model.framingEditorIsActive,
            maximumZoom: model.maximumFramingZoom
        )
    }

    private func autoFrame() {
        guard let previewAspectRatio else { return }
        model.autoFrame(aspect: previewAspectRatio)
    }

    private func framingInteractionStarted() {
        guard let previewAspectRatio else { return }
        model.framingSession.userDidInteract(with: previewAspectRatio)
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
