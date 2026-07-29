import AppIntents
import Foundation
import TesseraeKit
import UniformTypeIdentifiers

struct TesseraeDashboardEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Tesserae Dashboard"
    )
    static let defaultQuery = TesseraeDashboardQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "Tesserae dashboard"
        )
    }
}

struct TesseraeDashboardQuery: EntityQuery {
    func entities(
        for identifiers: [TesseraeDashboardEntity.ID]
    ) async throws -> [TesseraeDashboardEntity] {
        let wanted = Set(identifiers)
        return try await suggestedEntities().filter {
            wanted.contains($0.id)
        }
    }

    func suggestedEntities() async throws -> [TesseraeDashboardEntity] {
        let snapshot = try await TesseraeIntentRuntime.snapshot()
        return snapshot.dashboards.map {
            TesseraeDashboardEntity(id: $0.id, name: $0.name)
        }
    }
}

struct TesseraeDisplayEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Tesserae Display"
    )
    static let defaultQuery = TesseraeDisplayQuery()

    let id: String
    let name: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "Tesserae display"
        )
    }
}

struct TesseraeDisplayQuery: EntityQuery {
    func entities(
        for identifiers: [TesseraeDisplayEntity.ID]
    ) async throws -> [TesseraeDisplayEntity] {
        let wanted = Set(identifiers)
        return try await suggestedEntities().filter {
            wanted.contains($0.id)
        }
    }

    func suggestedEntities() async throws -> [TesseraeDisplayEntity] {
        let snapshot = try await TesseraeIntentRuntime.snapshot()
        return snapshot.displays.map {
            TesseraeDisplayEntity(id: $0.id, name: $0.name)
        }
    }
}

enum TesseraeIntentFit: String, AppEnum {
    case fit
    case fill
    case blur
    case stretch
    case center

    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Image Layout"
    )
    static let caseDisplayRepresentations: [TesseraeIntentFit: DisplayRepresentation] = [
        .fit: "Fit",
        .fill: "Fill",
        .blur: "Blur",
        .stretch: "Stretch",
        .center: "Center",
    ]

    var modelValue: ImageFitMode {
        switch self {
        case .fit: .fit
        case .fill: .fill
        case .blur: .blur
        case .stretch: .stretch
        case .center: .center
        }
    }
}

struct PushTesseraeDashboardIntent: AppIntent {
    static let title: LocalizedStringResource = "Push Tesserae Dashboard"
    static let description = IntentDescription(
        "Render a saved dashboard and send it to its bound or selected displays."
    )

    @Parameter(title: "Dashboard")
    var dashboard: TesseraeDashboardEntity

    @Parameter(
        title: "Displays",
        description: "Leave empty to use the dashboard's bound displays."
    )
    var displays: [TesseraeDisplayEntity]?

    @Parameter(title: "Override Quiet Hours", default: false)
    var overrideQuietHours: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Push \(\.$dashboard)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot = try await TesseraeIntentRuntime.snapshot()
        guard let selectedDashboard = snapshot.dashboards.first(
            where: { $0.id == dashboard.id }
        ) else {
            throw TesseraeIntentError.deletedEntity("dashboard")
        }
        let explicitIDs = displays?.map(\.id)
        let targetIDs = explicitIDs?.isEmpty == false
            ? explicitIDs
            : selectedDashboard.deviceIDs
        guard let targetIDs, !targetIDs.isEmpty else {
            throw TesseraeIntentError.noDisplays
        }

        let client = TesseraeIntentRuntime.client()
        let job = try await client.pushDashboard(
            id: selectedDashboard.id,
            deviceIDs: targetIDs,
            overrideQuietHours: overrideQuietHours,
            idempotencyKey: UUID().uuidString,
            instance: snapshot.activeInstance
        )
        try await TesseraeIntentRuntime.record(job, in: snapshot)
        return .result(
            dialog: "Tesserae accepted \(selectedDashboard.name)."
        )
    }
}

struct SendImageToTesseraeIntent: AppIntent {
    static let title: LocalizedStringResource = "Send Image to Tesserae"
    static let description = IntentDescription(
        "Send one still image to selected Tesserae displays."
    )

    @Parameter(
        title: "Image",
        supportedTypeIdentifiers: ["public.image"]
    )
    var image: IntentFile

    @Parameter(title: "Displays")
    var displays: [TesseraeDisplayEntity]

    @Parameter(title: "Layout", default: .fit)
    var layout: TesseraeIntentFit

    @Parameter(title: "Override Quiet Hours", default: false)
    var overrideQuietHours: Bool

    static var parameterSummary: some ParameterSummary {
        Summary("Send \(\.$image) to \(\.$displays)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot = try await TesseraeIntentRuntime.snapshot()
        let displayIDs = displays.map(\.id)
        guard !displayIDs.isEmpty else {
            throw TesseraeIntentError.noDisplays
        }
        let knownIDs = Set(snapshot.displays.map(\.id))
        guard displayIDs.allSatisfy(knownIDs.contains) else {
            throw TesseraeIntentError.deletedEntity("display")
        }

        let contentType = image.type?.preferredMIMEType ?? "image/jpeg"
        try TesseraeIntentRuntime.validate(
            data: image.data,
            contentType: contentType,
            fit: layout.modelValue,
            capabilities: snapshot.capabilities
        )
        let request = SharedImageRequest(
            instanceID: snapshot.activeInstance.id,
            fileName: image.filename,
            contentType: contentType,
            fit: layout.modelValue,
            deviceIDs: displayIDs,
            overrideQuietHours: overrideQuietHours
        )
        let queue = TesseraeIntentRuntime.queue()
        try await queue.enqueue(imageData: image.data, request: request)

        do {
            let submitting = request.updating(status: .submitting)
            try await queue.update(submitting)
            let job = try await TesseraeIntentRuntime.client().sendImage(
                data: image.data,
                fileName: image.filename,
                contentType: contentType,
                fit: layout.modelValue,
                deviceIDs: displayIDs,
                overrideQuietHours: overrideQuietHours,
                idempotencyKey: request.idempotencyKey,
                instance: snapshot.activeInstance
            )
            await TesseraeIntentRuntime.recordThumbnail(
                image.data,
                for: job,
                instanceID: snapshot.activeInstance.id
            )
            try await TesseraeIntentRuntime.record(job, in: snapshot)
            try await queue.remove(submitting)
            return .result(dialog: "Tesserae accepted the image.")
        } catch {
            try? await queue.update(
                request.updating(
                    status: .failed,
                    error: error.localizedDescription
                )
            )
            throw TesseraeIntentError.queuedForRetry(error.localizedDescription)
        }
    }
}

struct OpenTesseraeWebIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Tesserae Web"
    static let description = IntentDescription(
        "Open the paired Tesserae server for dashboard editing and management."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let snapshot = try await TesseraeIntentRuntime.snapshot()
        guard URL(string: snapshot.activeInstance.webURL) != nil else {
            throw TesseraeIntentError.invalidWebURL
        }
        TesseraeIntentRuntime.requestOpenWeb()
        return .result(dialog: "Opening Tesserae.")
    }
}

struct TesseraeAppShortcuts: AppShortcutsProvider {
    static var shortcutTileColor: ShortcutTileColor {
        .teal
    }

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: PushTesseraeDashboardIntent(),
            phrases: [
                "Push a dashboard with \(.applicationName)",
                "Refresh my display with \(.applicationName)",
            ],
            shortTitle: "Push Dashboard",
            systemImageName: "rectangle.on.rectangle.angled"
        )
        AppShortcut(
            intent: SendImageToTesseraeIntent(),
            phrases: [
                "Send an image with \(.applicationName)",
            ],
            shortTitle: "Send Image",
            systemImageName: "photo.badge.arrow.down"
        )
        AppShortcut(
            intent: OpenTesseraeWebIntent(),
            phrases: [
                "Open \(.applicationName)",
            ],
            shortTitle: "Open Tesserae",
            systemImageName: "globe"
        )
    }
}

private enum TesseraeIntentRuntime {
    static func snapshot() async throws -> CompanionSnapshot {
        guard let snapshot = try await stateStore().load() else {
            throw TesseraeIntentError.notPaired
        }
        guard try await credentialStore().token(
            for: snapshot.activeInstance.id
        ) != nil else {
            throw TesseraeIntentError.notPaired
        }
        return snapshot
    }

    static func client() -> LiveTesseraeClient {
        LiveTesseraeClient(
            credentials: credentialStore(),
            identity: TesseraeClientIdentity(
                appVersion: AppConfiguration.appVersion,
                installationID: AppConfiguration.installationID
            )
        )
    }

    static func queue() -> FileShareQueueStore {
        FileShareQueueStore(
            directoryURL: AppConfiguration.sharedContainerURL
        )
    }

    static func recordThumbnail(
        _ imageData: Data,
        for job: PushJob,
        instanceID: String
    ) async {
        let store = FileActivityThumbnailStore(
            directoryURL: AppConfiguration.sharedContainerURL
        )
        _ = try? await store.save(
            imageData: imageData,
            jobID: job.id,
            instanceID: instanceID,
            createdAt: job.createdAt
        )
    }

    static func requestOpenWeb() {
        UserDefaults(
            suiteName: AppConfiguration.appGroupIdentifier
        )?.set(true, forKey: "TesseraeOpenWebRequested")
    }

    static func record(
        _ job: PushJob,
        in snapshot: CompanionSnapshot
    ) async throws {
        let retainedJobs = snapshot.jobs.filter { existing in
            guard existing.id != job.id else {
                return false
            }
            guard let activityClearedBefore = snapshot.activityClearedBefore else {
                return true
            }
            return existing.createdAt > activityClearedBefore
        }
        let jobs = [job] + retainedJobs
        try await stateStore().save(
            CompanionSnapshot(
                activeInstance: snapshot.activeInstance,
                capabilities: snapshot.capabilities,
                displays: snapshot.displays,
                dashboards: snapshot.dashboards,
                jobs: jobs,
                activityClearedBefore: snapshot.activityClearedBefore
            )
        )
    }

    static func validate(
        data: Data,
        contentType: String,
        fit: ImageFitMode,
        capabilities: ServerCapabilities?
    ) throws {
        guard let capabilities else { return }
        guard data.count <= capabilities.limits.imageUploadBytes else {
            throw TesseraeIntentError.imageTooLarge
        }
        guard capabilities.limits.imageContentTypes.contains(contentType) else {
            throw TesseraeIntentError.unsupportedImage
        }
        guard capabilities.limits.imageFitModes.contains(fit) else {
            throw TesseraeIntentError.unsupportedImageLayout(fit.displayName)
        }
    }

    private static func stateStore() -> UserDefaultsCompanionStateStore {
        UserDefaultsCompanionStateStore(
            suiteName: AppConfiguration.appGroupIdentifier
        )
    }

    private static func credentialStore() -> KeychainCredentialStore {
        KeychainCredentialStore(
            service: AppConfiguration.keychainService,
            accessGroup: AppConfiguration.keychainAccessGroup
        )
    }
}

private enum TesseraeIntentError: Error, LocalizedError {
    case deletedEntity(String)
    case imageTooLarge
    case invalidWebURL
    case noDisplays
    case notPaired
    case queuedForRetry(String)
    case unsupportedImage
    case unsupportedImageLayout(String)

    var errorDescription: String? {
        switch self {
        case let .deletedEntity(kind):
            "The selected Tesserae \(kind) no longer exists. Choose it again."
        case .imageTooLarge:
            "The image exceeds the Tesserae server's upload limit."
        case .invalidWebURL:
            "The paired Tesserae server does not provide a valid web URL."
        case .noDisplays:
            "Choose at least one Tesserae display."
        case .notPaired:
            "Open Tesserae Companion and pair a server first."
        case let .queuedForRetry(message):
            "\(message) The image is queued for retry in Tesserae Companion."
        case .unsupportedImage:
            "The Tesserae server does not accept this image format."
        case let .unsupportedImageLayout(layout):
            "The Tesserae server does not support the \(layout) image layout."
        }
    }
}
