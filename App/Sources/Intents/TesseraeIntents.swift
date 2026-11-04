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
    var resourceID: String { ConnectionResourceID(encoded: id)?.resourceID ?? id }

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
        var result: [TesseraeDashboardEntity] = []
        for identifier in identifiers {
            let snapshot = try await TesseraeIntentRuntime.snapshot(for: [identifier])
            let raw = ConnectionResourceID(encoded: identifier)?.resourceID ?? identifier
            if let value = snapshot.dashboards.first(where: { $0.id == raw }) {
                result.append(TesseraeDashboardEntity(id: identifier, name: value.name))
            }
        }
        return result
    }

    func suggestedEntities() async throws -> [TesseraeDashboardEntity] {
        let snapshot = try await TesseraeIntentRuntime.snapshot()
        return snapshot.dashboards.map {
            TesseraeDashboardEntity(id: ConnectionResourceID(connectionID: snapshot.activeInstance.connectionIdentity.id, kind: "dashboard", resourceID: $0.id).encoded, name: $0.name)
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
    var resourceID: String { ConnectionResourceID(encoded: id)?.resourceID ?? id }

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
        var result: [TesseraeDisplayEntity] = []
        for identifier in identifiers {
            let snapshot = try await TesseraeIntentRuntime.snapshot(for: [identifier])
            let raw = ConnectionResourceID(encoded: identifier)?.resourceID ?? identifier
            if let value = snapshot.displays.first(where: { $0.id == raw }) {
                result.append(TesseraeDisplayEntity(id: identifier, name: value.name))
            }
        }
        return result
    }

    func suggestedEntities() async throws -> [TesseraeDisplayEntity] {
        let snapshot = try await TesseraeIntentRuntime.snapshot()
        return snapshot.displays.map {
            TesseraeDisplayEntity(id: ConnectionResourceID(connectionID: snapshot.activeInstance.connectionIdentity.id, kind: "display", resourceID: $0.id).encoded, name: $0.name)
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
        let snapshot = try await TesseraeIntentRuntime.snapshot(for: [dashboard.id] + (displays?.map(\.id) ?? []))
        guard let selectedDashboard = snapshot.dashboards.first(
            where: { $0.id == dashboard.resourceID }
        ) else {
            throw TesseraeIntentError.deletedEntity("dashboard")
        }
        let explicitIDs = displays?.map(\.resourceID)
        let targetIDs = explicitIDs?.isEmpty == false
            ? explicitIDs
            : selectedDashboard.deviceIDs
        guard let targetIDs, !targetIDs.isEmpty else {
            throw TesseraeIntentError.noDisplays
        }

        let client = try TesseraeIntentRuntime.client(for: snapshot)
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
        supportedContentTypes: [UTType.image]
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
        let snapshot = try await TesseraeIntentRuntime.snapshot(for: displays.map(\.id))
        let displayIDs = displays.map(\.resourceID)
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
            instanceID: snapshot.activeInstance.storageID,
            connectionEpoch: snapshot.connectionFence?.epoch,
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
            let job = try await TesseraeIntentRuntime.client(for: snapshot).sendImage(
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
                instanceID: snapshot.activeInstance.storageID
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
        .red
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
    static func runtime() throws -> ConnectionRuntime {
        guard let directory = AppConfiguration.sharedContainerURL else { throw ConnectionError.unavailable }
        return ConnectionRuntime(directory: directory, suiteName: AppConfiguration.appGroupIdentifier,
            keychainService: AppConfiguration.keychainService, accessGroup: AppConfiguration.keychainAccessGroup,
            identity: TesseraeClientIdentity(appVersion: AppConfiguration.appVersion,
                                             installationID: AppConfiguration.installationID), isPrimary: false)
    }

    static func snapshot(for identifiers: [String] = []) async throws -> CompanionSnapshot {
        let runtime = try runtime()
        // Import first so old raw entity IDs can use only the recorded local binding.
        let current = try await runtime.stateStore.load()
        var resolved = Set<ConnectionID>()
        let legacy = try runtime.registry.savedConnections().filter { $0.legacyInstanceID != nil }
        for identifier in identifiers {
            if let value = ConnectionResourceID(encoded: identifier) {
                resolved.insert(value.connectionID)
            } else {
                guard legacy.count == 1 else { throw TesseraeIntentError.deletedEntity("destination") }
                resolved.insert(legacy[0].id)
            }
        }
        guard resolved.count <= 1 else { throw TesseraeIntentError.deletedEntity("destination") }
        let snapshot: CompanionSnapshot?
        if let id = resolved.first { snapshot = try await runtime.stateStore.load(for: id) }
        else { snapshot = current }
        guard let snapshot, let fence = snapshot.connectionFence else { throw TesseraeIntentError.notPaired }
        try await runtime.sessions.validate(fence)
        return snapshot
    }

    static func client(for snapshot: CompanionSnapshot) throws -> LiveTesseraeClient {
        try runtime().client(for: snapshot)
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
                activityClearedBefore: snapshot.activityClearedBefore,
                connectionFence: snapshot.connectionFence
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

    private static func stateStore() throws -> ConnectionStateStore { try runtime().stateStore }

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
