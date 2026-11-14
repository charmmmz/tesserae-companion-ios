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
        try await TesseraeIntentRuntime.live().dashboards(identifiers: identifiers)
    }

    func suggestedEntities() async throws -> [TesseraeDashboardEntity] {
        try await TesseraeIntentRuntime.live().dashboards(identifiers: nil)
    }
}

struct TesseraeDisplayEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Tesserae Display"
    )
    static let defaultQuery = TesseraeDisplayQuery()

    let id: String
    let name: String
    var connectionName: String? = nil
    var resourceID: String { ConnectionResourceID(encoded: id)?.resourceID ?? id }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(connectionName ?? String(localized: "Tesserae display"))"
        )
    }
}

struct TesseraeDisplayQuery: EntityQuery {
    func entities(
        for identifiers: [TesseraeDisplayEntity.ID]
    ) async throws -> [TesseraeDisplayEntity] {
        try await TesseraeIntentRuntime.live().displays(identifiers: identifiers)
    }

    func suggestedEntities() async throws -> [TesseraeDisplayEntity] {
        try await TesseraeIntentRuntime.live().displays(identifiers: nil)
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
        try await perform(using: TesseraeIntentRuntime.live())
    }

    func perform(using environment: TesseraeIntentRuntime) async throws -> some IntentResult & ProvidesDialog {
        let destination = try await environment.resolve([dashboard.id], kind: .dashboard)
        if let displays, !displays.isEmpty {
            let targets = try await environment.resolve(displays.map(\.id), kind: .display)
            guard targets.connection.id == destination.connection.id else { throw ConnectionError.invalidIdentity }
        }
        guard destination.connection.localInstance != nil else { throw TesseraeIntentError.cloudDashboardUnsupported }
        let snapshot = try await environment.snapshot(for: destination.connection.id)
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

        let client = try environment.client(for: snapshot)
        let job = try await client.pushDashboard(
            id: selectedDashboard.id,
            deviceIDs: targetIDs,
            overrideQuietHours: overrideQuietHours,
            idempotencyKey: UUID().uuidString,
            instance: snapshot.activeInstance
        )
        try await environment.record(job, in: snapshot)
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
        try await perform(using: TesseraeIntentRuntime.live())
    }

    func perform(using environment: TesseraeIntentRuntime) async throws -> some IntentResult & ProvidesDialog {
        let destination = try await environment.resolve(displays.map(\.id), kind: .display)
        let displayIDs = destination.resourceIDs
        if case .cloud = destination.connection.identity {
            guard !overrideQuietHours else { throw TesseraeIntentError.cloudQuietHoursUnsupported }
            let targets = try CloudEntryTargets(connectionID: destination.connection.id, deviceIDs: displayIDs)
            let decision = UUID()
#if DEBUG
            AppConfiguration.recordSystemDiagnostic("intent.photo.begin")
            AppConfiguration.recordSystemInput(decision: decision, data: image.data,
                contentType: image.type?.preferredMIMEType ?? "image/jpeg", recipe: .init(fit: layout.modelValue),
                deviceIDs: displayIDs, sourceKind: "shortcut-still", requestedSeconds: nil, outputRevision: nil)
#endif
            let outcome = try await environment.systemEntry().submit(
                .photo(targets: targets, data: image.data,
                       contentType: image.type?.preferredMIMEType ?? "image/jpeg",
                       recipe: CloudPhotoRecipe(fit: layout.modelValue)), decision: decision)
            try environment.requireGenerated(outcome)
            return .result(dialog: "Frame generated. The physical display update is not confirmed.")
        }
        let snapshot = try await environment.snapshot(for: destination.connection.id)
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
        let queue = environment.queue()
        try await queue.enqueue(imageData: image.data, request: request)

        do {
            let submitting = request.updating(status: .submitting)
            try await queue.update(submitting)
            let job = try await environment.client(for: snapshot).sendImage(
                data: image.data,
                fileName: image.filename,
                contentType: contentType,
                fit: layout.modelValue,
                deviceIDs: displayIDs,
                overrideQuietHours: overrideQuietHours,
                idempotencyKey: request.idempotencyKey,
                instance: snapshot.activeInstance
            )
            await environment.recordThumbnail(
                image.data,
                for: job,
                instanceID: snapshot.activeInstance.storageID
            )
            try await environment.record(job, in: snapshot)
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

struct RefreshCurrentCloudPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Current Cloud Page"
    static let description = IntentDescription("Generate a new frame from the page currently assigned to a fixed Cloud display.")

    @Parameter(title: "Display") var display: TesseraeDisplayEntity
    static var parameterSummary: some ParameterSummary { Summary("Refresh the current page on \(\.$display)") }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await perform(using: TesseraeIntentRuntime.live())
    }
    func perform(using environment: TesseraeIntentRuntime) async throws -> some IntentResult & ProvidesDialog {
        let destination = try await environment.resolve([display.id], kind: .display)
        guard case .cloud = destination.connection.identity else { throw TesseraeIntentError.cloudCurrentPageOnly }
        let targets = try CloudEntryTargets(connectionID: destination.connection.id, deviceIDs: destination.resourceIDs)
#if DEBUG
        AppConfiguration.recordSystemDiagnostic("intent.current-page.begin")
#endif
        let outcome = try await environment.systemEntry().submit(.currentPage(targets), decision: UUID())
        try environment.requireGenerated(outcome)
        return .result(dialog: "Frame generated. The physical display update is not confirmed.")
    }
}

struct OpenTesseraeWebIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Tesserae Web"
    static let description = IntentDescription(
        "Open the paired Tesserae server for dashboard editing and management."
    )
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await perform(using: TesseraeIntentRuntime.live())
    }

    func perform(using environment: TesseraeIntentRuntime) async throws -> some IntentResult & ProvidesDialog {
        if let id = try environment.runtime.registry.selectedID(),
           let saved = try environment.runtime.registry.connection(id), case .cloud = saved.identity {
            throw TesseraeIntentError.cloudWebUnsupported
        }
        let snapshot = try await environment.snapshot()
        guard URL(string: snapshot.activeInstance.webURL) != nil else {
            throw TesseraeIntentError.invalidWebURL
        }
        environment.requestOpenWeb()
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
            intent: RefreshCurrentCloudPageIntent(),
            phrases: ["Refresh the current Cloud page with \(.applicationName)"],
            shortTitle: "Refresh Cloud Page", systemImageName: "arrow.clockwise"
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

struct TesseraeIntentRuntime: Sendable {
    let runtime: ConnectionRuntime
    let directory: URL
    let suiteName: String?

    static func live() throws -> Self {
        guard let directory = AppConfiguration.sharedContainerURL else { throw ConnectionError.unavailable }
        return Self(runtime: ConnectionRuntime(directory: directory, suiteName: AppConfiguration.stateSuiteName,
            keychainService: AppConfiguration.keychainService, accessGroup: AppConfiguration.keychainAccessGroup,
            identity: TesseraeClientIdentity(appVersion: AppConfiguration.appVersion,
                                             installationID: AppConfiguration.installationID), isPrimary: false,
            transport: AppConfiguration.cloudReadTestTransport),
            directory: directory, suiteName: AppConfiguration.stateSuiteName)
    }

    func resolve(_ identifiers: [String], kind: ConnectionResourceKind) async throws -> ResolvedConnectionResources {
        if identifiers.contains(where: { !$0.hasPrefix("tesserae-resource-v2:") }) {
            _ = try await runtime.stateStore.load()
        }
        return try ConnectionResourceResolver(registry: runtime.registry).resolve(identifiers, kind: kind)
    }

    func snapshot(for id: ConnectionID? = nil) async throws -> CompanionSnapshot {
        let value: CompanionSnapshot?
        if let id { value = try await runtime.stateStore.load(for: id) }
        else { value = try await runtime.stateStore.load() }
        guard let value, let fence = value.connectionFence else { throw TesseraeIntentError.notPaired }
        try await runtime.sessions.validate(fence)
        return value
    }

    func systemEntry() -> CloudSystemEntry { CloudPhotoPreparer.systemEntry(runtime: runtime, directory: directory) }

    func requireGenerated(_ completion: CloudEntryCompletion) throws {
        switch completion {
        case .finished(let batch):
            guard !batch.targets.isEmpty, batch.results.count == batch.targets.count,
                  batch.results.allSatisfy({ $0.outcome.isCleanGenerated }) else {
                throw TesseraeIntentError.cloudOutcome(String(localized: "Check this send's results in Tesserae Companion. It will not be sent again automatically."))
            }
        case .retained(_, let message), .notConfirmed(_, let message):
            throw TesseraeIntentError.cloudOutcome(message + " " + String(localized: "Open Tesserae Companion to review this item. It will not be sent again automatically."))
        case .inProgress:
            throw TesseraeIntentError.cloudOutcome(String(localized: "This send is still in progress. View its result in Tesserae Companion."))
        }
    }

    private struct ResourceReference {
        let identifier: String
        let resourceID: String
    }
    private func destinations(_ identifiers: [String]?, kind: ConnectionResourceKind) async throws -> [(SavedConnection, [ResourceReference]?)] {
        guard let identifiers else {
            _ = try await runtime.stateStore.load()
            guard let id = try runtime.registry.selectedID(), let connection = try runtime.registry.connection(id) else {
                throw TesseraeIntentError.notPaired
            }
            return [(connection, nil)]
        }
        var grouped: [(SavedConnection, [ResourceReference])] = []
        for identifier in identifiers {
            let resolved = try await resolve([identifier], kind: kind)
            let reference = ResourceReference(identifier: identifier, resourceID: resolved.resourceIDs[0])
            if let index = grouped.firstIndex(where: { $0.0.id == resolved.connection.id }) {
                grouped[index].1.append(reference)
            } else {
                grouped.append((resolved.connection, [reference]))
            }
        }
        return grouped.map { ($0.0, $0.1) }
    }

    func displays(identifiers: [String]?) async throws -> [TesseraeDisplayEntity] {
        var result: [TesseraeDisplayEntity] = []
        for (connection, requested) in try await destinations(identifiers, kind: .display) {
            let values: [(String, String)]
            if case .cloud = connection.identity {
                let client = CloudReadClient(transport: try await runtime.cloudTransport(for: connection.id))
                values = try await client.bootstrap().devices.map { ($0.id, $0.name) }
            } else {
                values = try await snapshot(for: connection.id).displays.map { ($0.id, $0.name) }
            }
            let references = requested ?? values.map {
                ResourceReference(identifier: ConnectionResourceID(connectionID: connection.id, kind: "display", resourceID: $0.0).encoded,
                                  resourceID: $0.0)
            }
            for reference in references {
                guard let value = values.first(where: { $0.0 == reference.resourceID }) else { continue }
                result.append(.init(id: reference.identifier, name: value.1, connectionName: connection.name))
            }
        }
        return result
    }

    func dashboards(identifiers: [String]?) async throws -> [TesseraeDashboardEntity] {
        var result: [TesseraeDashboardEntity] = []
        for (connection, requested) in try await destinations(identifiers, kind: .dashboard) {
            guard connection.localInstance != nil else {
                if identifiers != nil { throw TesseraeIntentError.cloudDashboardUnsupported }
                continue
            }
            let dashboards = try await snapshot(for: connection.id).dashboards
            let references = requested ?? dashboards.map {
                ResourceReference(identifier: ConnectionResourceID(connectionID: connection.id, kind: "dashboard", resourceID: $0.id).encoded,
                                  resourceID: $0.id)
            }
            for reference in references {
                guard let dashboard = dashboards.first(where: { $0.id == reference.resourceID }) else { continue }
                result.append(.init(id: reference.identifier, name: dashboard.name))
            }
        }
        return result
    }

    func client(for snapshot: CompanionSnapshot) throws -> LiveTesseraeClient {
        try runtime.client(for: snapshot)
    }

    func queue() -> FileShareQueueStore {
        FileShareQueueStore(
            directoryURL: directory
        )
    }

    func recordThumbnail(
        _ imageData: Data,
        for job: PushJob,
        instanceID: String
    ) async {
        let store = FileActivityThumbnailStore(
            directoryURL: directory
        )
        _ = try? await store.save(
            imageData: imageData,
            jobID: job.id,
            instanceID: instanceID,
            createdAt: job.createdAt
        )
    }

    func requestOpenWeb() {
        UserDefaults(
            suiteName: suiteName
        )?.set(true, forKey: "TesseraeOpenWebRequested")
    }

    func record(
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
        try await runtime.stateStore.save(
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


}

enum TesseraeIntentError: Error, LocalizedError, Equatable {
    case cloudDashboardUnsupported, cloudQuietHoursUnsupported, cloudCurrentPageOnly, cloudWebUnsupported
    case cloudOutcome(String)
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
        case .cloudWebUnsupported:
            String(localized: "This action does not support Cloud. Open Cloud management in Tesserae Companion.")
        case .cloudDashboardUnsupported:
            String(localized: "Cloud does not support pushing an arbitrary dashboard. Use Refresh Current Cloud Page instead.")
        case .cloudQuietHoursUnsupported:
            String(localized: "Quiet Hours override is not supported by Cloud. Turn it off before sending.")
        case .cloudCurrentPageOnly:
            String(localized: "Choose a Cloud display for this action.")
        case .cloudOutcome(let message): message
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
