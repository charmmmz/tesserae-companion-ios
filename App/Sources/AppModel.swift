import Foundation
import Observation
import TesseraeKit
import UIKit

private enum QueuedLinkSubmissionError: Error, LocalizedError {
    case unsupported

    var errorDescription: String? {
        String(
            localized: "This Tesserae server does not support the queued link action."
        )
    }
}

private struct DashboardPreviewKey: Hashable {
    let dashboardID: String
    let deviceID: String?
}

struct CompanionConnectionSession: Equatable, Sendable {
    let instanceID: String
    let revision: UUID
}

@MainActor
@Observable
final class AppModel {
    private static let displayOrderKeyPrefix = "display-order."
    private static let dashboardOrderKeyPrefix = "dashboard-order."
    private static let collapsedDashboardSectionsKeyPrefix =
        "dashboard-collapsed-sections."

    enum ConnectionMode {
        case live
        case demo
    }

    enum ConnectionHealth {
        case idle
        case restoring
        case connected
        case offline
        case requiresPairing
    }

    enum LineupAuthoringPermission: Equatable {
        case unavailable
        case unknown
        case checking
        case granted
        case denied
    }

    enum GalleryWritePermission: Equatable {
        case unavailable
        case unknown
        case checking
        case granted
        case denied
    }

    enum OfflineAlbumAuthoringPermission: Equatable {
        case unavailable
        case unknown
        case checking
        case granted
        case denied
    }

    enum LineupSaveOutcome {
        case saved(Lineup)
        case conflict
        case permissionRequired
        case failed(String)
    }

    private let liveClient: any TesseraeServing
    private let demoClient: any TesseraeServing
    private var activeClient: any TesseraeServing
    private let credentials: any CredentialStoring
    private let stateStore: any CompanionStateStoring
    private let sendPreferences: any CompanionSendPreferencesStoring
    private let shareQueue: any ShareQueueStoring
    private let linkShareQueue: any LinkShareQueueStoring
    private let activityThumbnails: any ActivityThumbnailStoring
    private let discovery: any TesseraeDiscovering
    private let connectionTimeout: Duration
    private(set) var connectionRevision = UUID()
    private var didAttemptRestore = false
    private var isDisconnecting = false
    private var isSynchronizingSharedState = false
    private var activityRefreshTask: Task<Void, Never>?
    private var displayPreviewRequestIDs: [String: UUID] = [:]
    private var pendingDisplayPreviewRequestIDs: [String: UUID] = [:]
    private var dashboardPreviewRequestIDs: [DashboardPreviewKey: UUID] = [:]

    var connectionSession: CompanionConnectionSession? {
        guard !isDisconnecting else { return nil }
        return activeInstance.map {
            CompanionConnectionSession(instanceID: $0.id, revision: connectionRevision)
        }
    }

    func checkConnectionSession(_ session: CompanionConnectionSession) throws {
        try Task.checkCancellation()
        guard connectionSession == session else { throw CancellationError() }
    }

    var activeInstance: TesseraeInstance?
    var connectionMode: ConnectionMode?
    var connectionHealth: ConnectionHealth = .restoring
    var connectionNotice: String?
    var discoveredInstances: [DiscoveredInstance] = []
    var discoveryError: String?
    var capabilities: ServerCapabilities?
    var displays: [DisplaySummary] = []
    var dashboards: [DashboardSummary] = []
    var lineups: [Lineup] = []
    var lineupAuthoringPermission: LineupAuthoringPermission = .unknown
    var lineupAuthoringSettingsURL: String?
    var galleryFolders: [GalleryFolder] = []
    var galleryFolderDetails: [String: GalleryFolderDetail] = [:]
    var galleryWritePermission: GalleryWritePermission = .unknown
    var galleryWriteSettingsURL: String?
    var offlineAlbumsByFolderID: [String: OfflineAlbumResponse] = [:]
    var offlineAlbumETagsByFolderID: [String: String] = [:]
    var offlineAlbumAuthoringPermission: OfflineAlbumAuthoringPermission = .unknown
    var offlineAlbumSettingsURL: String?
    var galleryThumbnailStates: [String: PreviewImageState] = [:]
    var jobs: [PushJob] = []
    var historyItems: [HistoryItem] = []
    var historyNextBeforeID: String?
    var activityClearedBefore: Date?
    var activityThumbnailData: [String: Data] = [:]
    var queuedImageRequests: [SharedImageRequest] = []
    var queuedLinkRequests: [SharedLinkRequest] = []
    var queuedImagePreviewData: [String: Data] = [:]
    var historyPreviews: [String: PreviewImageState] = [:]
    var displayPreviews: [String: PreviewImageState] = [:]
    var pendingDisplayPreviews: [String: PreviewImageState] = [:]
    var deviceUpcomingResponses: [String: DeviceUpcomingResponse] = [:]
    var loadingDeviceTimelineIDs: Set<String> = []
    var deviceTimelineErrors: [String: String] = [:]
    private var dashboardPreviews: [DashboardPreviewKey: PreviewImageState] = [:]
    var previewGeneration = 0
    var displayPreviewGeneration = 0
    var displayOrderIDs: [String] = []
    var dashboardOrderIDs: [String] = []
    var collapsedDashboardSectionIDs: Set<String> = []
    var activeOperationIDs: Set<String> = []
    var isRefreshing = false
    var isRefreshingDashboards = false
    var isRefreshingLineups = false
    var isRefreshingGallery = false
    var loadingGalleryFolderIDs: Set<String> = []
    var loadingOfflineAlbumFolderIDs: Set<String> = []
    var isDiscovering = false
    var isRestoringConnection = true
    var isRetryingSharedImages = false
    var isRetryingSharedLinks = false
    var isLoadingMoreHistory = false
    var isClearingLocalActivity = false
    var activeQueuedImageRequestIDs: Set<String> = []
    var activeQueuedLinkRequestIDs: Set<String> = []
    var lastError: String?

    var supportsPreviews: Bool {
        capabilities?.features.contains("previews") == true
    }

    var supportsHistory: Bool {
        capabilities?.features.contains("history") == true
    }

    var supportsLineups: Bool {
        capabilities?.features.contains("lineups") == true
    }

    var supportsLineupControl: Bool {
        capabilities?.features.contains("lineup_control") == true
    }

    var supportsLineupAuthoring: Bool {
        capabilities?.features.contains("lineup_authoring") == true
    }

    var supportsSessionRead: Bool {
        capabilities?.features.contains("session_read") == true
    }

    var supportsGallery: Bool {
        capabilities?.supportsGallery == true
    }

    var supportsOfflineAlbums: Bool {
        supportsGallery && capabilities?.supportsOfflineAlbums == true
    }

    var supportsRemindersPersonalData: Bool {
        connectionMode == .live
            && capabilities?.supports(personalDataSource: .reminders) == true
    }

    var supportsHealthSummaryPersonalData: Bool {
        connectionMode == .live
            && capabilities?.supportsHealthSummary == true
    }

    var supportsDeviceSetup: Bool {
        connectionMode == .live
            && capabilities?.supportsDeviceSetup == true
    }

    var supportsDeviceTimeline: Bool {
        capabilities?.supportsDeviceTimeline == true
    }

    var activeHealthInstanceID: String? {
        activeInstance?.id
    }

    var activeHealthTimeZone: String? {
        activeInstance?.timezone
    }

    var personalDataMaximumTTLSeconds: Int? {
        capabilities?.limits.personalDataMaxTTLSeconds
    }

    var supportedLinkPushKinds: [LinkPushKind] {
        guard let capabilities else { return [] }
        return LinkPushKind.allCases.filter(capabilities.supports)
    }

    func createFirmwareDevicePairing() async throws -> FirmwareDevicePairing {
        guard supportsDeviceSetup, let activeInstance else {
            throw NearbyDeviceSetupError.serverUpdateRequired
        }
        return try await activeClient.createFirmwareDevicePairing(
            instance: activeInstance
        )
    }

    init(
        liveClient: any TesseraeServing,
        demoClient: any TesseraeServing,
        credentials: any CredentialStoring,
        stateStore: any CompanionStateStoring,
        sendPreferences: any CompanionSendPreferencesStoring,
        shareQueue: any ShareQueueStoring,
        linkShareQueue: any LinkShareQueueStoring,
        activityThumbnails: any ActivityThumbnailStoring,
        discovery: any TesseraeDiscovering,
        connectionTimeout: Duration = .seconds(8)
    ) {
        self.liveClient = liveClient
        self.demoClient = demoClient
        activeClient = liveClient
        self.credentials = credentials
        self.stateStore = stateStore
        self.sendPreferences = sendPreferences
        self.shareQueue = shareQueue
        self.linkShareQueue = linkShareQueue
        self.activityThumbnails = activityThumbnails
        self.discovery = discovery
        self.connectionTimeout = connectionTimeout
    }

    var sortedDashboards: [DashboardSummary] {
        var ranking: [String: Int] = [:]
        for dashboardID in dashboardOrderIDs where ranking[dashboardID] == nil {
            ranking[dashboardID] = ranking.count
        }

        return dashboards.sorted { lhs, rhs in
            switch (ranking[lhs.id], ranking[rhs.id]) {
            case let (lhsRank?, rhsRank?):
                return lhsRank < rhsRank
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.id < rhs.id
            }
        }
    }

    var sortedDisplays: [DisplaySummary] {
        var ranking: [String: Int] = [:]
        for displayID in displayOrderIDs where ranking[displayID] == nil {
            ranking[displayID] = ranking.count
        }

        return displays.sorted { lhs, rhs in
            switch (ranking[lhs.id], ranking[rhs.id]) {
            case let (lhsRank?, rhsRank?):
                return lhsRank < rhsRank
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.id < rhs.id
            }
        }
    }

    func discoverNearby() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        discoveryError = nil
        defer { isDiscovering = false }
        do {
            discoveredInstances = try await discovery.instances()
        } catch {
            discoveredInstances = []
            discoveryError = error.localizedDescription
        }
    }

    func connectDemo(baseURL: URL? = nil) async {
        let fallbackURL = URL(string: "http://tesserae.local:8765")
        guard let resolvedURL = baseURL ?? fallbackURL else {
            lastError = String(localized: "The server URL is invalid.")
            return
        }

        _ = await connect(
            using: demoClient,
            mode: .demo,
            baseURL: resolvedURL,
            code: "482193",
            clientName: "Demo iPhone"
        )
    }

    @discardableResult
    func connectLive(
        baseURL: URL, code: String, clientName: String,
        onFailure: ((String) -> Void)? = nil
    ) async -> Bool {
        await connect(
            using: liveClient,
            mode: .live,
            baseURL: baseURL,
            code: code,
            clientName: clientName,
            onFailure: onFailure
        )
    }

    private func connect(
        using candidate: any TesseraeServing,
        mode: ConnectionMode,
        baseURL: URL,
        code: String,
        clientName: String,
        onFailure: ((String) -> Void)? = nil
    ) async -> Bool {
        guard !activeOperationIDs.contains("pair") else { return false }
        activeOperationIDs.insert("pair")
        defer { activeOperationIDs.remove("pair") }
        do {
            let capabilities = try await probeConnection(using: candidate, baseURL: baseURL)
            let session = try await candidate.pair(
                baseURL: baseURL,
                code: code,
                clientName: clientName
            )
            try Task.checkCancellation()
            if mode == .live {
                try await credentials.save(
                    token: session.token,
                    for: session.instance.id
                )
            }
            isDisconnecting = false
            connectionRevision = UUID()
            isRestoringConnection = false
            isRefreshing = false
            isRefreshingDashboards = false
            isRefreshingLineups = false
            isRefreshingGallery = false
            isLoadingMoreHistory = false
            loadingGalleryFolderIDs = []
            loadingOfflineAlbumFolderIDs = []
            activeOperationIDs = ["pair"]
            connectionNotice = nil
            activeClient = candidate
            connectionMode = mode
            connectionHealth = .connected
            self.capabilities = capabilities
            lineupAuthoringPermission = if capabilities.features.contains(
                "lineup_authoring"
            ) {
                session.scopes.contains("lineups:write") ? .granted : .denied
            } else {
                .unavailable
            }
            lineupAuthoringSettingsURL = nil
            galleryWritePermission = if capabilities.supportsGallery {
                session.scopes.contains("gallery:write") ? .granted : .denied
            } else {
                .unavailable
            }
            galleryWriteSettingsURL = nil
            offlineAlbumAuthoringPermission = capabilities.supportsOfflineAlbums
                ? .unknown
                : .unavailable
            offlineAlbumSettingsURL = nil
            activeInstance = session.instance.updatingServerVersion(
                to: capabilities.serverVersion
            )
            displays = []
            dashboards = []
            activityThumbnailData = [:]
            queuedImageRequests = []
            queuedLinkRequests = []
            queuedImagePreviewData = [:]
            historyItems = []
            historyNextBeforeID = nil
            activityClearedBefore = nil
            lineups = []
            galleryFolders = []
            galleryFolderDetails = [:]
            offlineAlbumsByFolderID = [:]
            offlineAlbumETagsByFolderID = [:]
            galleryThumbnailStates = [:]
            historyPreviews = [:]
            displayPreviews = [:]
            displayPreviewRequestIDs = [:]
            pendingDisplayPreviews = [:]
            pendingDisplayPreviewRequestIDs = [:]
            deviceUpcomingResponses = [:]
            loadingDeviceTimelineIDs = []
            deviceTimelineErrors = [:]
            dashboardPreviews = [:]
            dashboardPreviewRequestIDs = [:]
            loadDisplayOrder(for: session.instance.id)
            loadDashboardOrder(for: session.instance.id)
            loadCollapsedDashboardSections(for: session.instance.id)
            if mode == .live {
                await persistSnapshot()
            }
            await refresh(probeCapabilities: false)
            await reloadQueuedImages()
            await reloadQueuedLinks()
            await retryPendingSharedImages()
            await retryPendingSharedLinks()
            return true
        } catch is CancellationError {
            return false
        } catch {
            if !Task.isCancelled {
                if let onFailure {
                    onFailure(error.localizedDescription)
                } else {
                    lastError = error.localizedDescription
                }
            }
            return false
        }
    }

    private func probeConnection(
        using client: any TesseraeServing,
        baseURL: URL
    ) async throws -> ServerCapabilities {
        let timeout = connectionTimeout
        return try await withThrowingTaskGroup(of: ServerCapabilities.self) { group in
            group.addTask { try await client.probe(baseURL: baseURL) }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw URLError(.timedOut)
            }
            defer { group.cancelAll() }
            return try await group.next()!
        }
    }

    private func checkConnectionRevision(_ revision: UUID) throws {
        try Task.checkCancellation()
        guard connectionRevision == revision else { throw CancellationError() }
    }

    func restoreConnectionIfNeeded() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        isRestoringConnection = true
        connectionHealth = .restoring
        let revision = connectionRevision
        defer {
            if connectionRevision == revision { isRestoringConnection = false }
        }

        do {
#if DEBUG
            if ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_OFFLINE_RESTORE"] == "1",
                credentials is InMemoryCredentialStore, stateStore is InMemoryCompanionStateStore {
                let instance = TesseraeInstance(
                    id: "offline-ui-test", name: "Saved Tesserae",
                    baseURL: URL(string: "http://127.0.0.1:9")!,
                    serverVersion: "0.311.0", timezone: "Asia/Shanghai", webURL: "/"
                )
                try await credentials.save(token: "offline-ui-test", for: instance.id)
                let cachedDisplays = try await MockTesseraeClient(latency: .zero)
                    .fetchDisplays(instance: instance)
                try await stateStore.save(CompanionSnapshot(
                    activeInstance: instance, capabilities: nil,
                    displays: cachedDisplays, dashboards: [], jobs: [], updatedAt: Date()
                ))
            }
#endif
            guard let snapshot = try await stateStore.load() else {
                connectionHealth = .idle
                return
            }
            try checkConnectionRevision(revision)
            guard try await credentials.token(for: snapshot.activeInstance.id) != nil else {
                try await stateStore.clear()
                connectionHealth = .requiresPairing
                connectionNotice = String(
                    localized: "The saved Tesserae pairing is no longer available. Pair again to reconnect."
                )
                return
            }
            try checkConnectionRevision(revision)

            activeClient = liveClient
            connectionMode = .live
            activeInstance = snapshot.activeInstance
            loadDisplayOrder(for: snapshot.activeInstance.id)
            loadDashboardOrder(for: snapshot.activeInstance.id)
            loadCollapsedDashboardSections(for: snapshot.activeInstance.id)
            capabilities = snapshot.capabilities
            lineupAuthoringPermission = supportsLineupAuthoring
                ? .unknown
                : .unavailable
            lineupAuthoringSettingsURL = nil
            galleryWritePermission = supportsGallery ? .unknown : .unavailable
            galleryWriteSettingsURL = nil
            offlineAlbumAuthoringPermission = supportsOfflineAlbums
                ? .unknown
                : .unavailable
            offlineAlbumSettingsURL = nil
            displays = snapshot.displays
            dashboards = snapshot.dashboards
            lineups = snapshot.lineups ?? []
            activityClearedBefore = snapshot.activityClearedBefore
            jobs = retainedActivityJobs(snapshot.jobs)
            // Cached screens and Bluetooth maintenance do not depend on the server.
            isRestoringConnection = false
            await reloadActivityThumbnails(instanceID: snapshot.activeInstance.id)
            await reloadQueuedImages()
            await reloadQueuedLinks()

            try checkConnectionRevision(revision)
            let currentCapabilities = try await probeConnection(
                using: liveClient,
                baseURL: snapshot.activeInstance.baseURL
            )
            try checkConnectionRevision(revision)
            capabilities = currentCapabilities
            if !supportsLineupAuthoring {
                lineupAuthoringPermission = .unavailable
                lineupAuthoringSettingsURL = nil
            }
            if !supportsOfflineAlbums {
                offlineAlbumAuthoringPermission = .unavailable
                offlineAlbumSettingsURL = nil
                offlineAlbumsByFolderID = [:]
                offlineAlbumETagsByFolderID = [:]
            }
            activeInstance = snapshot.activeInstance.updatingServerVersion(
                to: currentCapabilities.serverVersion
            )
            await refresh(
                showErrors: false,
                probeCapabilities: false
            )
            try checkConnectionRevision(revision)
            guard connectionHealth == .connected else { return }
            await retryPendingSharedImages()
            await retryPendingSharedLinks()
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            await handleConnectionError(error)
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            connectionHealth = .offline
            connectionNotice = error.localizedDescription
        }
    }

    func refresh(
        showErrors: Bool = true,
        probeCapabilities: Bool = true
    ) async {
        guard
            var currentInstance = activeInstance,
            !isRefreshing,
            !(connectionHealth == .restoring && probeCapabilities)
        else {
            return
        }
        isRefreshing = true
        let revision = connectionRevision
        let client = activeClient
        defer {
            if connectionRevision == revision { isRefreshing = false }
        }

        do {
            if probeCapabilities, connectionMode == .live {
                let currentCapabilities = try await probeConnection(
                    using: client,
                    baseURL: currentInstance.baseURL
                )
                try checkConnectionRevision(revision)
                capabilities = currentCapabilities
                currentInstance = currentInstance.updatingServerVersion(
                    to: currentCapabilities.serverVersion
                )
                activeInstance = currentInstance
            }

            let refreshedDisplays = try await client.fetchDisplays(instance: currentInstance)
            try checkConnectionRevision(revision)
            displays = refreshedDisplays
            let refreshedDashboards = try await client.fetchDashboards(instance: currentInstance)
            try checkConnectionRevision(revision)
            dashboards = refreshedDashboards
            if supportsLineups {
                do {
                    let refreshedLineups = try await client.fetchLineups(
                        instance: currentInstance
                    )
                    try checkConnectionRevision(revision)
                    lineups = refreshedLineups
                } catch let error as TesseraeClientError {
                    try checkConnectionRevision(revision)
                    guard case .forbidden = error else { throw error }
                    lineups = []
                    if showErrors {
                        presentLineupsPermissionError()
                    }
                }
            } else {
                lineups = []
            }
            await refreshLineupAuthoringPermission(showErrors: false)
            try checkConnectionRevision(revision)
            if supportsHistory {
                let history = try await client.fetchHistory(
                    beforeID: nil,
                    limit: 30,
                    instance: currentInstance
                )
                try checkConnectionRevision(revision)
                let retainedHistory = retainedHistoryPage(history)
                historyItems = retainedHistory.items
                historyNextBeforeID = retainedHistory.nextBeforeID
                let historyIDs = Set(retainedHistory.items.map(\.id))
                historyPreviews = historyPreviews.filter {
                    historyIDs.contains($0.key)
                }
            } else {
                historyItems = []
                historyNextBeforeID = nil
                historyPreviews = [:]
            }
            await refreshTrackedJobs(instance: currentInstance)
            try checkConnectionRevision(revision)
            reconcileDisplayOrder()
            reconcileDashboardOrder()
            connectionHealth = .connected
            connectionNotice = nil
            if supportsPreviews {
                let displayIDs = Set(displays.map(\.id))
                let dashboardIDs = Set(dashboards.map(\.id))
                displayPreviews = displayPreviews.filter {
                    displayIDs.contains($0.key)
                }
                let pendingPreviewKeys = Set(
                    displays.compactMap(pendingDisplayPreviewKey)
                )
                pendingDisplayPreviews = pendingDisplayPreviews.filter {
                    pendingPreviewKeys.contains($0.key)
                }
                dashboardPreviews = dashboardPreviews.filter {
                    dashboardIDs.contains($0.key.dashboardID)
                }
                dashboardPreviewRequestIDs = dashboardPreviewRequestIDs.filter {
                    dashboardIDs.contains($0.key.dashboardID)
                }
            } else {
                displayPreviews = [:]
                pendingDisplayPreviews = [:]
                dashboardPreviews = [:]
                dashboardPreviewRequestIDs = [:]
            }
            reconcileDeviceTimelines()
            displayPreviewGeneration &+= 1
            previewGeneration &+= 1
            if connectionMode == .live {
                await persistSnapshot(showErrors: showErrors)
            }
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            await handleConnectionError(error)
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            connectionHealth = .offline
            connectionNotice = error.localizedDescription
            lastError = nil
        }
    }

    func refreshDisplays(
        showErrors: Bool = true,
        saveSnapshot: Bool = true
    ) async {
        guard
            let currentInstance = activeInstance,
            !isRefreshing,
            connectionHealth != .restoring
        else {
            return
        }
        let revision = connectionRevision
        isRefreshing = true
        defer {
            if connectionRevision == revision { isRefreshing = false }
        }

        do {
            let refreshedDisplays = try await activeClient.fetchDisplays(
                instance: currentInstance
            )
            guard connectionRevision == revision, !Task.isCancelled else {
                return
            }

            displays = refreshedDisplays
            reconcileDisplayOrder()
            connectionHealth = .connected
            connectionNotice = nil

            if supportsPreviews {
                let displayIDs = Set(refreshedDisplays.map(\.id))
                displayPreviews = displayPreviews.filter {
                    displayIDs.contains($0.key)
                }
                let pendingPreviewKeys = Set(
                    refreshedDisplays.compactMap(pendingDisplayPreviewKey)
                )
                pendingDisplayPreviews = pendingDisplayPreviews.filter {
                    pendingPreviewKeys.contains($0.key)
                }
            } else {
                displayPreviews = [:]
                pendingDisplayPreviews = [:]
            }
            reconcileDeviceTimelines()
            displayPreviewGeneration &+= 1

            if connectionMode == .live, saveSnapshot {
                await persistSnapshot(showErrors: showErrors)
            }
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if showErrors
                || error == .unauthorized
                || error == .missingCredential
            {
                await handleConnectionError(error)
            }
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if showErrors {
                connectionHealth = .offline
                connectionNotice = error.localizedDescription
                lastError = nil
            }
        }
    }

    func refreshDeviceUpcoming(
        displayID: String,
        showErrors: Bool = false
    ) async {
        guard
            supportsDeviceTimeline,
            let currentInstance = activeInstance,
            !loadingDeviceTimelineIDs.contains(displayID)
        else {
            return
        }

        loadingDeviceTimelineIDs.insert(displayID)
        deviceTimelineErrors[displayID] = nil
        defer { loadingDeviceTimelineIDs.remove(displayID) }

        let hours = min(
            24,
            max(capabilities?.limits.deviceTimelineMaxHours ?? 24, 1)
        )
        let limit = min(
            6,
            max(capabilities?.limits.deviceTimelineMaxEvents ?? 6, 1)
        )

        do {
            let response = try await activeClient.fetchDeviceUpcoming(
                id: displayID,
                hours: hours,
                limit: limit,
                instance: currentInstance
            )
            guard activeInstance?.id == currentInstance.id else { return }
            deviceUpcomingResponses[displayID] = response
            deviceTimelineErrors[displayID] = nil
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            guard activeInstance?.id == currentInstance.id else { return }
            if case .forbidden = error {
                deviceTimelineErrors[displayID] = String(
                    localized: "Pair again to view scheduled updates."
                )
            } else {
                deviceTimelineErrors[displayID] = String(
                    localized: "Scheduled updates are unavailable."
                )
            }
            if showErrors {
                await presentOperationError(error)
            }
        } catch {
            guard activeInstance?.id == currentInstance.id else { return }
            deviceTimelineErrors[displayID] = String(
                localized: "Scheduled updates are unavailable."
            )
            if showErrors {
                await presentOperationError(error)
            }
        }
    }

    private func refreshDeviceUpcomingIfSupported(deviceIDs: [String]) async {
        for deviceID in deviceIDs {
            await refreshDeviceUpcoming(displayID: deviceID)
        }
    }

    func refreshActivity(
        showErrors: Bool = true,
        saveSnapshot: Bool = true
    ) async {
        guard
            let currentInstance = activeInstance,
            !isRefreshing,
            connectionHealth != .restoring
        else {
            return
        }
        let revision = connectionRevision
        isRefreshing = true
        defer {
            if connectionRevision == revision { isRefreshing = false }
        }

        await reloadQueuedImages(showErrors: showErrors)
        await reloadQueuedLinks(showErrors: showErrors)

        do {
            if supportsHistory {
                let history = try await activeClient.fetchHistory(
                    beforeID: nil,
                    limit: 30,
                    instance: currentInstance
                )
                guard connectionRevision == revision, !Task.isCancelled else {
                    return
                }
                connectionHealth = .connected
                connectionNotice = nil
                let retainedHistory = retainedHistoryPage(history)
                historyItems = retainedHistory.items
                historyNextBeforeID = retainedHistory.nextBeforeID
                let historyIDs = Set(retainedHistory.items.map(\.id))
                historyPreviews = historyPreviews.filter {
                    historyIDs.contains($0.key)
                }
            }

            await refreshTrackedJobs(instance: currentInstance)
            guard connectionRevision == revision, !Task.isCancelled else {
                return
            }
            if connectionMode == .live, saveSnapshot {
                await persistSnapshot(showErrors: showErrors)
            }
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if showErrors
                || error == .unauthorized
                || error == .missingCredential
            {
                await handleConnectionError(error)
            }
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if showErrors {
                connectionHealth = .offline
                connectionNotice = error.localizedDescription
                lastError = nil
            }
        }
    }

    func refreshDashboards(
        showErrors: Bool = true,
        saveSnapshot: Bool = true
    ) async {
        guard
            let currentInstance = activeInstance,
            !isRefreshingDashboards,
            connectionHealth != .restoring
        else {
            return
        }
        let revision = connectionRevision
        isRefreshingDashboards = true
        defer {
            if connectionRevision == revision { isRefreshingDashboards = false }
        }

        do {
            let refreshedDashboards = try await activeClient.fetchDashboards(
                instance: currentInstance
            )
            guard
                connectionRevision == revision,
                !Task.isCancelled
            else {
                return
            }

            dashboards = refreshedDashboards
            reconcileDashboardOrder()
            connectionHealth = .connected
            connectionNotice = nil

            if supportsPreviews {
                let dashboardIDs = Set(refreshedDashboards.map(\.id))
                dashboardPreviews = dashboardPreviews.filter {
                    dashboardIDs.contains($0.key.dashboardID)
                }
                dashboardPreviewRequestIDs = dashboardPreviewRequestIDs.filter {
                    dashboardIDs.contains($0.key.dashboardID)
                }
            } else {
                dashboardPreviews = [:]
                dashboardPreviewRequestIDs = [:]
            }
            previewGeneration &+= 1

            if connectionMode == .live, saveSnapshot {
                await persistSnapshot(showErrors: showErrors)
            }
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if showErrors
                || error == .unauthorized
                || error == .missingCredential
            {
                await handleConnectionError(error)
            }
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if showErrors {
                connectionHealth = .offline
                connectionNotice = error.localizedDescription
                lastError = nil
            }
        }
    }

    func refreshLineups(
        showErrors: Bool = true,
        saveSnapshot: Bool = true
    ) async {
        guard
            supportsLineups,
            let currentInstance = activeInstance,
            !isRefreshingLineups,
            connectionHealth != .restoring
        else {
            return
        }
        let revision = connectionRevision
        isRefreshingLineups = true
        defer {
            if connectionRevision == revision { isRefreshingLineups = false }
        }

        do {
            let refreshedLineups = try await activeClient.fetchLineups(
                instance: currentInstance
            )
            guard
                connectionRevision == revision,
                !Task.isCancelled
            else {
                return
            }

            lineups = refreshedLineups
            connectionHealth = .connected
            connectionNotice = nil
            await refreshLineupAuthoringPermission(showErrors: false)

            if connectionMode == .live, saveSnapshot {
                await persistSnapshot(showErrors: showErrors)
            }
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if case .forbidden = error {
                connectionHealth = .connected
                connectionNotice = nil
                lineups = []
                if showErrors {
                    presentLineupsPermissionError()
                }
                return
            }
            if showErrors
                || error == .unauthorized
                || error == .missingCredential
            {
                await handleConnectionError(error)
            }
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if showErrors {
                connectionHealth = .offline
                connectionNotice = error.localizedDescription
                lastError = nil
            }
        }
    }

    func refreshLineupAuthoringPermission(
        showErrors: Bool = false
    ) async {
        let revision = connectionRevision
        let client = activeClient
        guard supportsLineupAuthoring, let currentInstance = activeInstance else {
            lineupAuthoringPermission = .unavailable
            lineupAuthoringSettingsURL = nil
            return
        }
        guard supportsSessionRead else {
            // Authoring servers before v0.295.0 enforce lineups:write at save
            // time but do not expose the token's current optional grants.
            lineupAuthoringPermission = .unknown
            lineupAuthoringSettingsURL = nil
            return
        }
        guard lineupAuthoringPermission != .checking else { return }

        lineupAuthoringPermission = .checking
        do {
            let authorization = try await client.fetchSessionAuthorization(
                instance: currentInstance
            )
            try checkConnectionRevision(revision)
            if let authorization {
                lineupAuthoringPermission = authorization.canAuthorLineups
                    ? .granted
                    : .denied
                lineupAuthoringSettingsURL = authorization.settingsURL
            } else {
                // Servers released before the authenticated session reader
                // still advertise authoring and enforce it on POST/PATCH.
                lineupAuthoringPermission = .unknown
                lineupAuthoringSettingsURL = nil
            }
        } catch is CancellationError {
            guard connectionRevision == revision else { return }
            lineupAuthoringPermission = .unknown
            lineupAuthoringSettingsURL = nil
        } catch let error as TesseraeClientError {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            lineupAuthoringPermission = .unknown
            lineupAuthoringSettingsURL = nil
            if showErrors {
                await presentOperationError(error)
            }
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            lineupAuthoringPermission = .unknown
            lineupAuthoringSettingsURL = nil
            if showErrors {
                lastError = error.localizedDescription
            }
        }
    }

    func refreshGallery(showErrors: Bool = true) async {
        let revision = connectionRevision
        let client = activeClient
        guard
            supportsGallery,
            let currentInstance = activeInstance,
            !isRefreshingGallery
        else {
            return
        }
        isRefreshingGallery = true
        defer {
            if connectionRevision == revision { isRefreshingGallery = false }
        }

        do {
            let folders = try await client.fetchGalleryFolders(
                instance: currentInstance
            )
            try checkConnectionRevision(revision)
            galleryFolders = folders
            let folderIDs = Set(folders.map(\.id))
            galleryFolderDetails = galleryFolderDetails.filter {
                folderIDs.contains($0.key)
            }
            offlineAlbumsByFolderID = offlineAlbumsByFolderID.filter {
                folderIDs.contains($0.key)
            }
            offlineAlbumETagsByFolderID = offlineAlbumETagsByFolderID.filter {
                folderIDs.contains($0.key)
            }
            let liveThumbnailPaths = Set(
                folders.compactMap(\.coverThumbnailURL)
                    + galleryFolderDetails.values.flatMap {
                        $0.images.map(\.thumbnailURL)
                    }
            )
            galleryThumbnailStates = galleryThumbnailStates.filter {
                liveThumbnailPaths.contains($0.key)
            }
            connectionHealth = .connected
            connectionNotice = nil
            await refreshGalleryWritePermission(showErrors: false)
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if showErrors || error == .unauthorized || error == .missingCredential {
                await presentOperationError(error)
            }
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if showErrors {
                lastError = error.localizedDescription
            }
        }
    }

    func refreshGalleryFolder(
        id: String,
        showErrors: Bool = true
    ) async {
        let revision = connectionRevision
        let client = activeClient
        guard
            supportsGallery,
            let currentInstance = activeInstance,
            !loadingGalleryFolderIDs.contains(id)
        else {
            return
        }
        loadingGalleryFolderIDs.insert(id)
        defer {
            if connectionRevision == revision { loadingGalleryFolderIDs.remove(id) }
        }

        do {
            let detail = try await client.fetchGalleryFolder(
                id: id,
                instance: currentInstance
            )
            try checkConnectionRevision(revision)
            galleryFolderDetails[id] = detail
            replaceGalleryFolder(detail.folder)
            connectionHealth = .connected
            connectionNotice = nil
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if showErrors || error == .unauthorized || error == .missingCredential {
                await presentOperationError(error)
            }
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if showErrors {
                lastError = error.localizedDescription
            }
        }
    }

    func refreshGalleryWritePermission(showErrors: Bool = false) async {
        let revision = connectionRevision
        let client = activeClient
        guard supportsGallery, let currentInstance = activeInstance else {
            galleryWritePermission = .unavailable
            galleryWriteSettingsURL = nil
            offlineAlbumAuthoringPermission = .unavailable
            offlineAlbumSettingsURL = nil
            return
        }
        guard supportsSessionRead else {
            galleryWritePermission = .unknown
            galleryWriteSettingsURL = nil
            offlineAlbumAuthoringPermission = supportsOfflineAlbums
                ? .unknown
                : .unavailable
            offlineAlbumSettingsURL = nil
            return
        }
        guard galleryWritePermission != .checking else { return }

        galleryWritePermission = .checking
        if supportsOfflineAlbums {
            offlineAlbumAuthoringPermission = .checking
        }
        do {
            let authorization = try await client.fetchSessionAuthorization(
                instance: currentInstance
            )
            try checkConnectionRevision(revision)
            if let authorization {
                galleryWritePermission = authorization.canWriteGallery
                    ? .granted
                    : .denied
                galleryWriteSettingsURL = authorization.settingsURL
                offlineAlbumAuthoringPermission = supportsOfflineAlbums
                    ? (authorization.canWriteOfflineAlbums ? .granted : .denied)
                    : .unavailable
                offlineAlbumSettingsURL = supportsOfflineAlbums
                    ? authorization.settingsURL
                    : nil
            } else {
                galleryWritePermission = .unknown
                galleryWriteSettingsURL = nil
                offlineAlbumAuthoringPermission = supportsOfflineAlbums
                    ? .unknown
                    : .unavailable
                offlineAlbumSettingsURL = nil
            }
        } catch is CancellationError {
            guard connectionRevision == revision else { return }
            galleryWritePermission = .unknown
            galleryWriteSettingsURL = nil
            offlineAlbumAuthoringPermission = supportsOfflineAlbums
                ? .unknown
                : .unavailable
            offlineAlbumSettingsURL = nil
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            galleryWritePermission = .unknown
            galleryWriteSettingsURL = nil
            offlineAlbumAuthoringPermission = supportsOfflineAlbums
                ? .unknown
                : .unavailable
            offlineAlbumSettingsURL = nil
            if showErrors {
                await presentOperationError(error)
            }
        }
    }

    func createGalleryFolder(name: String) async throws -> GalleryFolderDetail {
        let revision = connectionRevision
        let client = activeClient
        guard supportsGallery, let currentInstance = activeInstance else {
            throw TesseraeClientError.unavailable
        }
        let detail: GalleryFolderDetail
        do {
            detail = try await client.createGalleryFolder(
                name: name,
                instance: currentInstance
            )
        } catch let error as TesseraeClientError {
            try checkConnectionRevision(revision)
            if case .forbidden = error {
                galleryWritePermission = .denied
            }
            throw error
        }
        try checkConnectionRevision(revision)
        galleryFolderDetails[detail.folder.id] = detail
        replaceGalleryFolder(detail.folder)
        return detail
    }

    func uploadGalleryImage(
        folderID: String,
        data: Data,
        fileName: String,
        contentType: String,
        idempotencyKey: String
    ) async throws -> GalleryImage {
        let revision = connectionRevision
        let client = activeClient
        guard supportsGallery, let currentInstance = activeInstance else {
            throw TesseraeClientError.unavailable
        }
        let image: GalleryImage
        do {
            image = try await client.uploadGalleryImage(
                folderID: folderID,
                data: data,
                fileName: fileName,
                contentType: contentType,
                idempotencyKey: idempotencyKey,
                instance: currentInstance
            )
        } catch let error as TesseraeClientError {
            try checkConnectionRevision(revision)
            if case .forbidden = error {
                galleryWritePermission = .denied
            }
            throw error
        }
        try checkConnectionRevision(revision)
        if var detail = galleryFolderDetails[folderID],
           !detail.images.contains(where: { $0.id == image.id })
        {
            let images = detail.images + [image]
            let folder = GalleryFolder(
                id: detail.folder.id,
                name: detail.folder.name,
                kind: detail.folder.kind,
                writable: detail.folder.writable,
                imageCount: images.count,
                coverThumbnailURL: detail.folder.coverThumbnailURL
                    ?? image.thumbnailURL
            )
            detail = GalleryFolderDetail(folder: folder, images: images)
            galleryFolderDetails[folderID] = detail
            replaceGalleryFolder(folder)
        }
        return image
    }

    func fetchGalleryImageContent(
        _ image: GalleryImage
    ) async throws -> Data {
        let revision = connectionRevision
        guard supportsGallery, let currentInstance = activeInstance else {
            throw TesseraeClientError.unavailable
        }
        let result = try await activeClient.fetchGalleryResource(
            path: image.contentURL,
            ifNoneMatch: nil,
            instance: currentInstance
        )
        try checkConnectionRevision(revision)
        guard case let .image(data, _) = result else {
            throw TesseraeClientError.invalidResponse
        }
        return data
    }

    func loadGalleryThumbnail(path: String) async {
        let revision = connectionRevision
        let client = activeClient
        guard supportsGallery, let currentInstance = activeInstance else { return }
        let current = galleryThumbnailStates[path] ?? .idle
        guard current.phase != .loading, current.phase != .ready else { return }
        galleryThumbnailStates[path] = PreviewImageState(
            data: current.data,
            eTag: current.eTag,
            phase: .loading
        )
        do {
            let result = try await client.fetchGalleryResource(
                path: path,
                ifNoneMatch: current.eTag,
                instance: currentInstance
            )
            try checkConnectionRevision(revision)
            switch result {
            case let .image(data, eTag):
                galleryThumbnailStates[path] = PreviewImageState(
                    data: data,
                    eTag: eTag,
                    phase: .ready
                )
            case .notModified:
                galleryThumbnailStates[path] = PreviewImageState(
                    data: current.data,
                    eTag: current.eTag,
                    phase: current.data == nil ? .unavailable : .ready
                )
            case .notFound, .preparing:
                galleryThumbnailStates[path] = PreviewImageState(
                    data: nil,
                    eTag: nil,
                    phase: .unavailable
                )
            }
        } catch is CancellationError {
            guard connectionRevision == revision else { return }
            galleryThumbnailStates[path] = current
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            galleryThumbnailStates[path] = PreviewImageState(
                data: current.data,
                eTag: current.eTag,
                phase: current.data == nil ? .unavailable : .ready
            )
        }
    }

    func refreshOfflineAlbum(
        folderID: String,
        showErrors: Bool = false
    ) async {
        let revision = connectionRevision
        let client = activeClient
        guard
            supportsOfflineAlbums,
            let currentInstance = activeInstance,
            !loadingOfflineAlbumFolderIDs.contains(folderID)
        else {
            return
        }
        loadingOfflineAlbumFolderIDs.insert(folderID)
        defer {
            if connectionRevision == revision { loadingOfflineAlbumFolderIDs.remove(folderID) }
        }

        do {
            let versioned = try await client.fetchOfflineAlbum(
                folderID: folderID,
                instance: currentInstance
            )
            try checkConnectionRevision(revision)
            offlineAlbumsByFolderID[folderID] = versioned.response
            offlineAlbumETagsByFolderID[folderID] = versioned.eTag
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if case let .server(code, _, _) = error, code == "not_found" {
                offlineAlbumsByFolderID.removeValue(forKey: folderID)
                offlineAlbumETagsByFolderID.removeValue(forKey: folderID)
                return
            }
            if showErrors || error == .unauthorized || error == .missingCredential {
                await presentOperationError(error)
            }
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            if showErrors {
                lastError = error.localizedDescription
            }
        }
    }

    func preflightOfflineAlbum(
        folderID: String,
        draft: OfflineAlbumDraft
    ) async throws -> OfflineAlbumPreflightResponse {
        let revision = connectionRevision
        let client = activeClient
        guard supportsOfflineAlbums, let currentInstance = activeInstance else {
            throw TesseraeClientError.unavailable
        }
        do {
            let result = try await client.preflightOfflineAlbum(
                folderID: folderID,
                draft: draft,
                instance: currentInstance
            )
            try checkConnectionRevision(revision)
            return result
        } catch let error as TesseraeClientError {
            try checkConnectionRevision(revision)
            if case .forbidden = error {
                offlineAlbumAuthoringPermission = .denied
            }
            throw error
        }
    }

    @discardableResult
    func saveOfflineAlbum(
        folderID: String,
        draft: OfflineAlbumDraft,
        replaceConflicts: Bool
    ) async throws -> OfflineAlbumResponse {
        let revision = connectionRevision
        let client = activeClient
        guard supportsOfflineAlbums, let currentInstance = activeInstance else {
            throw TesseraeClientError.unavailable
        }
        do {
            let versioned = try await client.putOfflineAlbum(
                folderID: folderID,
                request: OfflineAlbumWriteRequest(
                    album: draft,
                    replaceConflicts: replaceConflicts
                ),
                eTag: offlineAlbumETagsByFolderID[folderID],
                instance: currentInstance
            )
            try checkConnectionRevision(revision)
            offlineAlbumsByFolderID[folderID] = versioned.response
            offlineAlbumETagsByFolderID[folderID] = versioned.eTag
            return versioned.response
        } catch let error as TesseraeClientError {
            try checkConnectionRevision(revision)
            if case .forbidden = error {
                offlineAlbumAuthoringPermission = .denied
            }
            if case let .server(code, _, _) = error,
               code == "precondition_failed"
            {
                await refreshOfflineAlbum(folderID: folderID)
            }
            throw error
        }
    }

    func deleteOfflineAlbum(folderID: String) async throws {
        let revision = connectionRevision
        let client = activeClient
        guard supportsOfflineAlbums, let currentInstance = activeInstance else {
            throw TesseraeClientError.unavailable
        }
        do {
            try await client.deleteOfflineAlbum(
                folderID: folderID,
                instance: currentInstance
            )
            try checkConnectionRevision(revision)
            offlineAlbumsByFolderID.removeValue(forKey: folderID)
            offlineAlbumETagsByFolderID.removeValue(forKey: folderID)
        } catch let error as TesseraeClientError {
            try checkConnectionRevision(revision)
            if case .forbidden = error {
                offlineAlbumAuthoringPermission = .denied
            }
            throw error
        }
    }

    private func replaceGalleryFolder(_ folder: GalleryFolder) {
        if let index = galleryFolders.firstIndex(where: { $0.id == folder.id }) {
            galleryFolders[index] = folder
        } else {
            galleryFolders.append(folder)
        }
    }

    func fetchLineupForEditing(_ lineupID: String) async throws -> VersionedLineup {
        let revision = connectionRevision
        guard supportsLineupAuthoring, let activeInstance else {
            throw TesseraeClientError.unavailable
        }
        let result = try await activeClient.fetchVersionedLineup(
            id: lineupID,
            instance: activeInstance
        )
        try checkConnectionRevision(revision)
        return result
    }

    func createLineup(
        _ request: LineupCreateRequest
    ) async -> LineupSaveOutcome {
        let revision = connectionRevision
        let client = activeClient
        guard supportsLineupAuthoring, let activeInstance else {
            return .failed(
                String(localized: "This Tesserae server does not support Lineup authoring.")
            )
        }
        let operationID = "lineup-create"
        activeOperationIDs.insert(operationID)
        defer {
            if connectionRevision == revision { activeOperationIDs.remove(operationID) }
        }

        do {
            let versioned = try await client.createLineup(
                request,
                instance: activeInstance
            )
            try checkConnectionRevision(revision)
            lineupAuthoringPermission = .granted
            replaceLineup(versioned.lineup)
            if connectionMode == .live {
                await persistSnapshot(showErrors: false)
            }
            try checkConnectionRevision(revision)
            return .saved(versioned.lineup)
        } catch let error as TesseraeClientError {
            guard connectionRevision == revision, !Task.isCancelled else {
                return .failed(CancellationError().localizedDescription)
            }
            if case .forbidden = error {
                lineupAuthoringPermission = .denied
                return .permissionRequired
            }
            await presentOperationError(error)
            return .failed(error.localizedDescription)
        } catch {
            guard connectionRevision == revision, !Task.isCancelled,
                  !(error is CancellationError) else {
                return .failed(CancellationError().localizedDescription)
            }
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    func updateLineup(
        id: String,
        eTag: String,
        patch: LineupPatchRequest
    ) async -> LineupSaveOutcome {
        let revision = connectionRevision
        let client = activeClient
        guard supportsLineupAuthoring, let activeInstance else {
            return .failed(
                String(localized: "This Tesserae server does not support Lineup authoring.")
            )
        }
        guard !patch.isEmpty else {
            if let lineup = lineups.first(where: { $0.id == id }) {
                return .saved(lineup)
            }
            return .failed(String(localized: "This Lineup is no longer available."))
        }
        let operationID = "lineup-edit:\(id)"
        activeOperationIDs.insert(operationID)
        defer {
            if connectionRevision == revision { activeOperationIDs.remove(operationID) }
        }

        do {
            let versioned = try await client.updateLineup(
                id: id,
                eTag: eTag,
                patch: patch,
                instance: activeInstance
            )
            try checkConnectionRevision(revision)
            lineupAuthoringPermission = .granted
            replaceLineup(versioned.lineup)
            if connectionMode == .live {
                await persistSnapshot(showErrors: false)
            }
            try checkConnectionRevision(revision)
            return .saved(versioned.lineup)
        } catch let error as TesseraeClientError {
            guard connectionRevision == revision, !Task.isCancelled else {
                return .failed(CancellationError().localizedDescription)
            }
            if case .forbidden = error {
                lineupAuthoringPermission = .denied
                return .permissionRequired
            }
            if case let .server(code, _, _) = error,
               code == "precondition_failed"
            {
                return .conflict
            }
            await presentOperationError(error)
            return .failed(error.localizedDescription)
        } catch {
            guard connectionRevision == revision, !Task.isCancelled,
                  !(error is CancellationError) else {
                return .failed(CancellationError().localizedDescription)
            }
            lastError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    func startActivityRefresh() {
        guard activityRefreshTask == nil else { return }

        activityRefreshTask = Task { [weak self] in
            guard let self else { return }
            await self.refreshActivity()
            self.activityRefreshTask = nil
        }
    }

    func moveDashboard(
        _ dashboardID: String,
        to destinationIndex: Int
    ) {
        var orderedIDs = sortedDashboards.map(\.id)
        guard let sourceIndex = orderedIDs.firstIndex(of: dashboardID) else {
            return
        }

        orderedIDs.remove(at: sourceIndex)
        let boundedIndex = min(max(0, destinationIndex), orderedIDs.count)
        orderedIDs.insert(dashboardID, at: boundedIndex)
        guard orderedIDs != dashboardOrderIDs else { return }

        dashboardOrderIDs = orderedIDs
        saveDashboardOrder()
    }

    func moveDisplay(
        _ displayID: String,
        to destinationIndex: Int
    ) {
        var orderedIDs = sortedDisplays.map(\.id)
        guard let sourceIndex = orderedIDs.firstIndex(of: displayID) else {
            return
        }

        orderedIDs.remove(at: sourceIndex)
        let boundedIndex = min(max(0, destinationIndex), orderedIDs.count)
        orderedIDs.insert(displayID, at: boundedIndex)
        guard orderedIDs != displayOrderIDs else { return }

        displayOrderIDs = orderedIDs
        saveDisplayOrder()
    }

    func setDashboardSectionCollapsed(
        _ sectionID: String,
        isCollapsed: Bool
    ) {
        var updatedIDs = collapsedDashboardSectionIDs
        if isCollapsed {
            updatedIDs.insert(sectionID)
        } else {
            updatedIDs.remove(sectionID)
        }
        guard updatedIDs != collapsedDashboardSectionIDs else { return }

        collapsedDashboardSectionIDs = updatedIDs
        saveCollapsedDashboardSections()
    }

    @discardableResult
    func push(
        _ dashboard: DashboardSummary,
        deviceIDs: [String]
    ) async -> Bool {
        let revision = connectionRevision
        let client = activeClient
        guard let activeInstance, !deviceIDs.isEmpty else { return false }
        activeOperationIDs.insert(dashboard.id)
        defer {
            if connectionRevision == revision { activeOperationIDs.remove(dashboard.id) }
        }

        do {
            let job = try await client.pushDashboard(
                id: dashboard.id,
                deviceIDs: deviceIDs,
                overrideQuietHours: ManualSendPolicy.overridesQuietHours,
                idempotencyKey: UUID().uuidString,
                instance: activeInstance
            )
            try checkConnectionRevision(revision)
            jobs.insert(job, at: 0)
            await persistSnapshot()
            try checkConnectionRevision(revision)
            await updateUntilTerminal(job, instance: activeInstance)
            try checkConnectionRevision(revision)
            await refreshDeviceUpcomingIfSupported(deviceIDs: deviceIDs)
            try checkConnectionRevision(revision)
            return true
        } catch {
            guard connectionRevision == revision, !Task.isCancelled, !(error is CancellationError) else { return false }
            await presentOperationError(error)
            return false
        }
    }

    func isOperatingOnLineup(_ lineupID: String) -> Bool {
        activeOperationIDs.contains(lineupStateOperationID(lineupID))
            || activeOperationIDs.contains(lineupControlOperationID(lineupID))
    }

    @discardableResult
    func setLineupEnabled(
        _ lineup: Lineup,
        enabled: Bool
    ) async -> Bool {
        let revision = connectionRevision
        let client = activeClient
        guard supportsLineupControl, let activeInstance else { return false }
        let operationID = lineupStateOperationID(lineup.id)
        activeOperationIDs.insert(operationID)
        defer {
            if connectionRevision == revision { activeOperationIDs.remove(operationID) }
        }

        do {
            let updated = try await client.setLineupEnabled(
                id: lineup.id,
                enabled: enabled,
                instance: activeInstance
            )
            try checkConnectionRevision(revision)
            replaceLineup(updated)
            await persistSnapshot()
            try checkConnectionRevision(revision)
            return true
        } catch {
            guard connectionRevision == revision, !Task.isCancelled, !(error is CancellationError) else { return false }
            if let error = error as? TesseraeClientError,
               case .forbidden = error
            {
                presentLineupsPermissionError()
                return false
            }
            await presentOperationError(error)
            return false
        }
    }

    @discardableResult
    func controlLineup(
        _ lineup: Lineup,
        action: LineupPaintAction,
        pageID: String? = nil,
        deviceIDs: [String]
    ) async -> Bool {
        let revision = connectionRevision
        let client = activeClient
        guard
            supportsLineupControl,
            let activeInstance,
            !deviceIDs.isEmpty
        else {
            return false
        }
        let operationID = lineupControlOperationID(lineup.id)
        activeOperationIDs.insert(operationID)
        defer {
            if connectionRevision == revision { activeOperationIDs.remove(operationID) }
        }

        do {
            let job = try await client.controlLineup(
                id: lineup.id,
                action: action,
                pageID: pageID,
                deviceIDs: deviceIDs,
                overrideQuietHours: ManualSendPolicy.overridesQuietHours,
                idempotencyKey: UUID().uuidString,
                instance: activeInstance
            )
            try checkConnectionRevision(revision)
            jobs.insert(job, at: 0)
            await persistSnapshot()
            try checkConnectionRevision(revision)
            await updateUntilTerminal(job, instance: activeInstance)
            try checkConnectionRevision(revision)
            await refreshLineups(showErrors: false)
            try checkConnectionRevision(revision)
            await refreshDeviceUpcomingIfSupported(deviceIDs: deviceIDs)
            try checkConnectionRevision(revision)
            return true
        } catch {
            guard connectionRevision == revision, !Task.isCancelled, !(error is CancellationError) else { return false }
            if let error = error as? TesseraeClientError,
               case .forbidden = error
            {
                presentLineupsPermissionError()
                return false
            }
            await presentOperationError(error)
            return false
        }
    }

    func savedSendPreferences() async -> CompanionSendPreferences? {
        guard let activeInstance else { return nil }
        do {
            return try await sendPreferences.preferences(
                for: activeInstance.id
            )
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    func saveSendPreferences(
        deviceIDs: [String],
        fit: ImageFitMode
    ) async {
        guard let activeInstance else { return }
        do {
            try await sendPreferences.save(
                CompanionSendPreferences(
                    instanceID: activeInstance.id,
                    deviceIDs: deviceIDs,
                    imageFitMode: fit
                )
            )
        } catch {
            lastError = error.localizedDescription
        }
    }

    func remindersPersonalDataStatus(session: CompanionConnectionSession) async throws -> PersonalDataSourceStatus? {
        try checkConnectionSession(session)
        guard let activeInstance else {
            throw RemindersBridgeError.unavailable
        }
        let result = try await activeClient.fetchPersonalDataStatus(
            instance: activeInstance
        ).sources.first { $0.sourceID == .reminders }
        try checkConnectionSession(session)
        return result
    }

    func putRemindersSnapshot(
        _ snapshot: RemindersSnapshot,
        session: CompanionConnectionSession
    ) async throws -> PersonalDataSourceStatus {
        try checkConnectionSession(session)
        guard let activeInstance else {
            throw RemindersBridgeError.unavailable
        }
        let result = try await activeClient.putRemindersSnapshot(
            snapshot,
            instance: activeInstance
        )
        try checkConnectionSession(session)
        return result
    }

    func deleteRemindersPersonalData(session: CompanionConnectionSession) async throws {
        try checkConnectionSession(session)
        guard let activeInstance else {
            throw RemindersBridgeError.unavailable
        }
        try await activeClient.deletePersonalData(
            sourceID: .reminders,
            instance: activeInstance
        )
        try checkConnectionSession(session)
    }

    func healthSummaryPersonalDataStatus(session: CompanionConnectionSession) async throws
        -> PersonalDataSourceStatus?
    {
        try checkConnectionSession(session)
        guard let activeInstance else {
            throw HealthBridgeError.unavailable
        }
        let result = try await activeClient.fetchPersonalDataStatus(
            instance: activeInstance
        ).sources.first { $0.sourceID == .healthSummary }
        try checkConnectionSession(session)
        return result
    }

    func putHealthSummarySnapshot(
        _ snapshot: HealthSummarySnapshot,
        session: CompanionConnectionSession
    ) async throws -> PersonalDataSourceStatus {
        try checkConnectionSession(session)
        guard let activeInstance else {
            throw HealthBridgeError.unavailable
        }
        let result = try await activeClient.putHealthSummarySnapshot(
            snapshot,
            instance: activeInstance
        )
        try checkConnectionSession(session)
        return result
    }

    func deleteHealthSummaryPersonalData(session: CompanionConnectionSession) async throws {
        try checkConnectionSession(session)
        guard let activeInstance else {
            throw HealthBridgeError.unavailable
        }
        try await activeClient.deletePersonalData(
            sourceID: .healthSummary,
            instance: activeInstance
        )
        try checkConnectionSession(session)
    }

    func sendImage(
        data: Data,
        fit: ImageFitMode,
        targetGroups: [ImageSendTargetGroup],
        idempotencyKeys: [String: String],
        contentType: String
    ) async -> Bool {
        let revision = connectionRevision
        let client = activeClient
        guard let activeInstance, !targetGroups.isEmpty else { return false }
        activeOperationIDs.insert("image")
        defer {
            if connectionRevision == revision { activeOperationIDs.remove("image") }
        }

        var acceptedJobs: [PushJob] = []
        var firstError: (any Error)?
        for group in targetGroups {
            guard connectionRevision == revision, !Task.isCancelled else { return false }
            do {
                let job = try await client.sendImage(
                    data: data,
                    fileName: imageFileName(for: contentType),
                    contentType: contentType,
                    fit: fit,
                    framing: group.framing,
                    deviceIDs: group.deviceIDs,
                    overrideQuietHours: ManualSendPolicy.overridesQuietHours,
                    idempotencyKey: idempotencyKeys[group.id]
                        ?? UUID().uuidString,
                    instance: activeInstance
                )
                try checkConnectionRevision(revision)
                await rememberActivityThumbnail(
                    imageData: data,
                    for: job,
                    instanceID: activeInstance.id
                )
                try checkConnectionRevision(revision)
                if !jobs.contains(where: { $0.id == job.id }) {
                    jobs.insert(job, at: 0)
                }
                acceptedJobs.append(job)
                await persistSnapshot(showErrors: false)
            } catch {
                guard connectionRevision == revision, !Task.isCancelled else { return false }
                if firstError == nil {
                    firstError = error
                }
            }
        }

        for job in acceptedJobs {
            guard connectionRevision == revision, !Task.isCancelled else { return false }
            await updateUntilTerminal(job, instance: activeInstance)
        }
        guard connectionRevision == revision, !Task.isCancelled else { return false }
        await refreshDeviceUpcomingIfSupported(
            deviceIDs: targetGroups.flatMap(\.deviceIDs)
        )
        guard connectionRevision == revision, !Task.isCancelled else { return false }
        if let firstError {
            await presentOperationError(firstError)
            return false
        }
        return true
    }

    func sendImage(
        data: Data,
        fit: ImageFitMode,
        framing: ImageFraming? = nil,
        deviceIDs: [String],
        contentType: String
    ) async -> Bool {
        let revision = connectionRevision
        let client = activeClient
        guard let activeInstance else { return false }
        activeOperationIDs.insert("image")
        defer {
            if connectionRevision == revision { activeOperationIDs.remove("image") }
        }

        do {
            let job = try await client.sendImage(
                data: data,
                fileName: imageFileName(for: contentType),
                contentType: contentType,
                fit: fit,
                framing: framing,
                deviceIDs: deviceIDs,
                overrideQuietHours: ManualSendPolicy.overridesQuietHours,
                idempotencyKey: UUID().uuidString,
                instance: activeInstance
            )
            try checkConnectionRevision(revision)
            await rememberActivityThumbnail(
                imageData: data,
                for: job,
                instanceID: activeInstance.id
            )
            try checkConnectionRevision(revision)
            jobs.insert(job, at: 0)
            await persistSnapshot()
            try checkConnectionRevision(revision)
            await updateUntilTerminal(job, instance: activeInstance)
            try checkConnectionRevision(revision)
            await refreshDeviceUpcomingIfSupported(deviceIDs: deviceIDs)
            try checkConnectionRevision(revision)
            return true
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return false }
            await presentOperationError(error)
            return false
        }
    }

    func sendLink(
        url: URL,
        kind: LinkPushKind,
        fit: ImageFitMode,
        deviceIDs: [String]
    ) async -> Bool {
        let revision = connectionRevision
        let client = activeClient
        guard let activeInstance else { return false }
        guard supportedLinkPushKinds.contains(kind) else {
            lastError = String(
                localized: "This Tesserae server does not support the selected link action."
            )
            return false
        }
        activeOperationIDs.insert("link")
        defer {
            if connectionRevision == revision { activeOperationIDs.remove("link") }
        }

        do {
            let idempotencyKey = UUID().uuidString
            let job: PushJob
            switch kind {
            case .imageURL:
                job = try await client.sendImageURL(
                    url: url,
                    fit: fit,
                    deviceIDs: deviceIDs,
                    overrideQuietHours: ManualSendPolicy.overridesQuietHours,
                    idempotencyKey: idempotencyKey,
                    instance: activeInstance
                )
            case .webpage:
                job = try await client.sendWebpage(
                    url: url,
                    fit: fit,
                    viewportW: nil,
                    deviceIDs: deviceIDs,
                    overrideQuietHours: ManualSendPolicy.overridesQuietHours,
                    idempotencyKey: idempotencyKey,
                    instance: activeInstance
                )
            }
            try checkConnectionRevision(revision)
            jobs.insert(job, at: 0)
            await persistSnapshot()
            try checkConnectionRevision(revision)
            await updateUntilTerminal(job, instance: activeInstance)
            try checkConnectionRevision(revision)
            await refreshDeviceUpcomingIfSupported(deviceIDs: deviceIDs)
            try checkConnectionRevision(revision)
            return true
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return false }
            await presentOperationError(error)
            return false
        }
    }

    func loadMoreHistory() async {
        let revision = connectionRevision
        let client = activeClient
        guard
            supportsHistory,
            !isLoadingMoreHistory,
            let beforeID = historyNextBeforeID,
            let activeInstance
        else {
            return
        }
        isLoadingMoreHistory = true
        defer {
            if connectionRevision == revision { isLoadingMoreHistory = false }
        }

        do {
            let page = try await client.fetchHistory(
                beforeID: beforeID,
                limit: 30,
                instance: activeInstance
            )
            try checkConnectionRevision(revision)
            let retainedPage = retainedHistoryPage(page)
            let existingIDs = Set(historyItems.map(\.id))
            historyItems.append(
                contentsOf: retainedPage.items.filter {
                    !existingIDs.contains($0.id)
                }
            )
            historyNextBeforeID = retainedPage.nextBeforeID
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            await presentOperationError(error)
        }
    }

    func resend(_ item: HistoryItem) async {
        let revision = connectionRevision
        let client = activeClient
        guard supportsHistory, item.resendable, let activeInstance else {
            return
        }
        let operationID = "history-\(item.id)"
        activeOperationIDs.insert(operationID)
        defer {
            if connectionRevision == revision { activeOperationIDs.remove(operationID) }
        }

        do {
            let job = try await client.resendHistory(
                id: item.id,
                overrideQuietHours: ManualSendPolicy.overridesQuietHours,
                idempotencyKey: UUID().uuidString,
                instance: activeInstance
            )
            try checkConnectionRevision(revision)
            jobs.insert(job, at: 0)
            await persistSnapshot()
            try checkConnectionRevision(revision)
            await updateUntilTerminal(job, instance: activeInstance)
            try checkConnectionRevision(revision)
            await refreshDeviceUpcomingIfSupported(deviceIDs: item.deviceIDs)
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            await presentOperationError(error)
        }
    }

    @discardableResult
    func clearLocalActivity() async -> Bool {
        guard let activeInstance, !isClearingLocalActivity else {
            return false
        }

        isClearingLocalActivity = true
        defer { isClearingLocalActivity = false }

        do {
            activityClearedBefore = max(
                activityClearedBefore ?? .distantPast,
                Date()
            )
            try await activityThumbnails.clear(
                instanceID: activeInstance.id
            )
            jobs = []
            historyItems = []
            historyNextBeforeID = nil
            activityThumbnailData = [:]
            historyPreviews = [:]
            ActivityPhotoCache.shared.removeAll()
            return await persistSnapshot()
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func retryPendingSharedImages() async {
        guard
            connectionMode == .live,
            connectionHealth == .connected,
            let activeInstance,
            !isRetryingSharedImages
        else {
            return
        }

        isRetryingSharedImages = true
        defer { isRetryingSharedImages = false }

        await reloadQueuedImages()
        for request in queuedImageRequests {
            _ = await submitQueuedImage(
                request,
                instance: activeInstance
            )
        }
    }

    func retryPendingSharedLinks() async {
        guard
            connectionMode == .live,
            connectionHealth == .connected,
            let activeInstance,
            !isRetryingSharedLinks
        else {
            return
        }

        isRetryingSharedLinks = true
        defer { isRetryingSharedLinks = false }

        await reloadQueuedLinks()
        for request in queuedLinkRequests {
            _ = await submitQueuedLink(
                request,
                instance: activeInstance
            )
        }
    }

    func reloadQueuedImages(showErrors: Bool = false) async {
        guard let activeInstance else {
            queuedImageRequests = []
            queuedImagePreviewData = [:]
            return
        }

        do {
            try await shareQueue.purge(
                expiredBefore: Date().addingTimeInterval(-24 * 60 * 60)
            )
            let requests = try await shareQueue.requests()
                .filter { $0.instanceID == activeInstance.id }
                .sorted {
                    if $0.createdAt != $1.createdAt {
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.id < $1.id
                }
            queuedImageRequests = requests
            let retainedIDs = Set(requests.map(\.id))
            queuedImagePreviewData = queuedImagePreviewData.filter {
                retainedIDs.contains($0.key)
            }
        } catch {
            if showErrors {
                connectionNotice = error.localizedDescription
            }
        }
    }

    func reloadQueuedLinks(showErrors: Bool = false) async {
        guard let activeInstance else {
            queuedLinkRequests = []
            return
        }

        do {
            try await linkShareQueue.purge(
                expiredBefore: Date().addingTimeInterval(-24 * 60 * 60)
            )
            queuedLinkRequests = try await linkShareQueue.requests()
                .filter { $0.instanceID == activeInstance.id }
                .sorted {
                    if $0.createdAt != $1.createdAt {
                        return $0.createdAt > $1.createdAt
                    }
                    return $0.id < $1.id
                }
        } catch {
            if showErrors {
                connectionNotice = error.localizedDescription
            }
        }
    }

    func loadQueuedImagePreview(_ request: SharedImageRequest) async {
        guard
            queuedImagePreviewData[request.id] == nil,
            queuedImageRequests.contains(where: { $0.id == request.id })
        else {
            return
        }

        do {
            let data = try await shareQueue.imageData(for: request)
            guard queuedImageRequests.contains(where: { $0.id == request.id }) else {
                return
            }
            queuedImagePreviewData[request.id] = data
        } catch {
            // The card remains actionable without artwork. Retry will surface
            // a missing/corrupt queue item as its latest failure reason.
        }
    }

    func retryQueuedImage(_ request: SharedImageRequest) async {
        guard
            connectionMode == .live,
            let activeInstance,
            request.instanceID == activeInstance.id
        else {
            return
        }

        _ = await submitQueuedImage(request, instance: activeInstance)
    }

    func discardQueuedImage(_ request: SharedImageRequest) async {
        guard
            !activeQueuedImageRequestIDs.contains(request.id),
            queuedImageRequests.contains(where: { $0.id == request.id })
        else {
            return
        }

        do {
            try await shareQueue.remove(request)
            removeQueuedImageFromView(request.id)
        } catch {
            connectionNotice = error.localizedDescription
        }
    }

    func retryQueuedLink(_ request: SharedLinkRequest) async {
        guard
            connectionMode == .live,
            let activeInstance,
            request.instanceID == activeInstance.id
        else {
            return
        }

        _ = await submitQueuedLink(request, instance: activeInstance)
    }

    func discardQueuedLink(_ request: SharedLinkRequest) async {
        guard
            !activeQueuedLinkRequestIDs.contains(request.id),
            queuedLinkRequests.contains(where: { $0.id == request.id })
        else {
            return
        }

        do {
            try await linkShareQueue.remove(request)
            queuedLinkRequests.removeAll { $0.id == request.id }
        } catch {
            connectionNotice = error.localizedDescription
        }
    }

    @discardableResult
    private func submitQueuedImage(
        _ request: SharedImageRequest,
        instance: TesseraeInstance
    ) async -> Bool {
        let revision = connectionRevision
        guard activeInstance?.id == instance.id else { return false }
        guard
            request.instanceID == instance.id,
            !activeQueuedImageRequestIDs.contains(request.id)
        else {
            return false
        }

        activeQueuedImageRequestIDs.insert(request.id)
        defer { activeQueuedImageRequestIDs.remove(request.id) }

        let submitting = request.updating(
            status: .submitting,
            error: nil
        )

        do {
            try await shareQueue.update(submitting)
            try checkConnectionRevision(revision)
            upsertQueuedImage(submitting)

            let data = try await shareQueue.imageData(for: submitting)
            try checkConnectionRevision(revision)
            let job = try await liveClient.sendImage(
                data: data,
                fileName: submitting.fileName,
                contentType: submitting.contentType,
                fit: submitting.fit,
                framing: submitting.framing,
                deviceIDs: submitting.deviceIDs,
                overrideQuietHours: submitting.overrideQuietHours,
                idempotencyKey: submitting.idempotencyKey,
                instance: instance
            )
            try await shareQueue.remove(submitting)
            if connectionRevision == revision, !Task.isCancelled {
                await rememberActivityThumbnail(
                    imageData: data,
                    for: job,
                    instanceID: instance.id
                )
                try checkConnectionRevision(revision)
                if !jobs.contains(where: { $0.id == job.id }) {
                    jobs.insert(job, at: 0)
                }
                removeQueuedImageFromView(submitting.id)
                connectionHealth = .connected
                connectionNotice = nil
                await persistSnapshot(showErrors: false)

                Task { [weak self] in
                    guard let self, self.connectionRevision == revision else { return }
                    await self.updateUntilTerminal(job, instance: instance)
                }
            }
            return true
        } catch {
            let failed = submitting.updating(
                status: .failed,
                error: error.localizedDescription
            )
            try? await shareQueue.update(failed)
            guard connectionRevision == revision, !Task.isCancelled else { return false }
            upsertQueuedImage(failed)

            if let clientError = error as? TesseraeClientError,
               clientError == .unauthorized
                    || clientError == .missingCredential
            {
                await handleConnectionError(clientError)
            }
            return false
        }
    }

    @discardableResult
    private func submitQueuedLink(
        _ request: SharedLinkRequest,
        instance: TesseraeInstance
    ) async -> Bool {
        let revision = connectionRevision
        guard activeInstance?.id == instance.id else { return false }
        guard
            request.instanceID == instance.id,
            !activeQueuedLinkRequestIDs.contains(request.id)
        else {
            return false
        }

        activeQueuedLinkRequestIDs.insert(request.id)
        defer { activeQueuedLinkRequestIDs.remove(request.id) }

        let submitting = request.updating(
            status: .submitting,
            error: nil
        )

        do {
            try await linkShareQueue.update(submitting)
            try checkConnectionRevision(revision)
            upsertQueuedLink(submitting)

            guard capabilities?.supports(submitting.kind) == true else {
                throw QueuedLinkSubmissionError.unsupported
            }

            let job: PushJob
            switch submitting.kind {
            case .imageURL:
                job = try await liveClient.sendImageURL(
                    url: submitting.url,
                    fit: submitting.fit,
                    deviceIDs: submitting.deviceIDs,
                    overrideQuietHours: submitting.overrideQuietHours,
                    idempotencyKey: submitting.idempotencyKey,
                    instance: instance
                )
            case .webpage:
                job = try await liveClient.sendWebpage(
                    url: submitting.url,
                    fit: submitting.fit,
                    viewportW: nil,
                    deviceIDs: submitting.deviceIDs,
                    overrideQuietHours: submitting.overrideQuietHours,
                    idempotencyKey: submitting.idempotencyKey,
                    instance: instance
                )
            }
            try await linkShareQueue.remove(submitting)
            if connectionRevision == revision, !Task.isCancelled {
                try checkConnectionRevision(revision)
                if !jobs.contains(where: { $0.id == job.id }) {
                    jobs.insert(job, at: 0)
                }
                queuedLinkRequests.removeAll { $0.id == submitting.id }
                connectionHealth = .connected
                connectionNotice = nil
                await persistSnapshot(showErrors: false)

                Task { [weak self] in
                    guard let self, self.connectionRevision == revision else { return }
                    await self.updateUntilTerminal(job, instance: instance)
                }
            }
            return true
        } catch {
            let failed = submitting.updating(
                status: .failed,
                error: error.localizedDescription
            )
            try? await linkShareQueue.update(failed)
            guard connectionRevision == revision, !Task.isCancelled else { return false }
            upsertQueuedLink(failed)

            if let clientError = error as? TesseraeClientError,
               clientError == .unauthorized
                    || clientError == .missingCredential
            {
                await handleConnectionError(clientError)
            }
            return false
        }
    }

    private func upsertQueuedImage(_ request: SharedImageRequest) {
        if let index = queuedImageRequests.firstIndex(
            where: { $0.id == request.id }
        ) {
            queuedImageRequests[index] = request
        } else {
            queuedImageRequests.append(request)
        }
        queuedImageRequests.sort {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.id < $1.id
        }
    }

    private func upsertQueuedLink(_ request: SharedLinkRequest) {
        if let index = queuedLinkRequests.firstIndex(
            where: { $0.id == request.id }
        ) {
            queuedLinkRequests[index] = request
        } else {
            queuedLinkRequests.append(request)
        }
        queuedLinkRequests.sort {
            if $0.createdAt != $1.createdAt {
                return $0.createdAt > $1.createdAt
            }
            return $0.id < $1.id
        }
    }

    private func removeQueuedImageFromView(_ requestID: String) {
        queuedImageRequests.removeAll { $0.id == requestID }
        queuedImagePreviewData.removeValue(forKey: requestID)
        ActivityPhotoCache.shared.remove(
            key: "queued-\(requestID)"
        )
    }

    func synchronizeSharedActivity() async {
        guard
            connectionMode == .live,
            connectionHealth == .connected,
            let activeInstance,
            !isSynchronizingSharedState
        else {
            return
        }

        isSynchronizingSharedState = true
        defer { isSynchronizingSharedState = false }

        do {
            guard
                let snapshot = try await stateStore.load(),
                snapshot.activeInstance.id == activeInstance.id
            else {
                return
            }

            let incomingNonterminalIDs = Set(
                snapshot.jobs
                    .filter { !$0.isTerminal }
                    .map(\.id)
            )
            jobs = CompanionSnapshot.mergingJobs(
                current: jobs,
                incoming: retainedActivityJobs(snapshot.jobs)
            )
            await reloadActivityThumbnails(instanceID: activeInstance.id)
            await persistSnapshot(showErrors: false)

            for job in jobs where incomingNonterminalIDs.contains(job.id) {
                await updateUntilTerminal(job, instance: activeInstance)
            }
            await retryPendingSharedImages()
            await retryPendingSharedLinks()
        } catch {
            connectionNotice = error.localizedDescription
        }
    }

    func openWebIfRequested() {
        let defaults = UserDefaults(
            suiteName: AppConfiguration.appGroupIdentifier
        )
        guard
            defaults?.bool(forKey: "TesseraeOpenWebRequested") == true,
            let activeInstance,
            let url = URL(string: activeInstance.webURL)
        else {
            return
        }
        defaults?.removeObject(forKey: "TesseraeOpenWebRequested")
        UIApplication.shared.open(
            url,
            options: [:],
            completionHandler: nil
        )
    }

    func displayNames(for ids: [String]) -> String {
        let names = ids.compactMap { id in displays.first(where: { $0.id == id })?.name }
        return names.isEmpty
            ? String(localized: "No displays")
            : names.joined(separator: ", ")
    }

    func displayNames(for item: HistoryItem) -> String {
        let names = ActivityReconciliation.displayNames(
            for: item,
            from: displays
        )
        return names.isEmpty
            ? String(localized: "No displays")
            : names.joined(separator: ", ")
    }

    func loadDisplayPreview(_ display: DisplaySummary) async {
        guard supportsPreviews, let instance = activeInstance else {
            return
        }
        let stored = displayPreviews[display.id] ?? .idle
        let previous = stored.phase == .loading
            ? PreviewImageState(
                data: stored.data,
                eTag: stored.eTag,
                phase: stored.data == nil ? .idle : .ready
            )
            : stored
        let requestID = UUID()
        displayPreviewRequestIDs[display.id] = requestID
        displayPreviews[display.id] = PreviewImageState(
            data: previous.data,
            eTag: previous.eTag,
            phase: .loading
        )

        do {
            let result = try await activeClient.fetchDevicePreview(
                id: display.id,
                revision: nil,
                ifNoneMatch: previous.data == nil ? nil : previous.eTag,
                instance: instance
            )
            guard displayPreviewRequestIDs[display.id] == requestID else {
                return
            }
            guard activeInstance?.id == instance.id, !Task.isCancelled else {
                displayPreviews[display.id] = previous
                displayPreviewRequestIDs[display.id] = nil
                return
            }
            apply(
                result,
                previous: previous,
                to: &displayPreviews,
                key: display.id
            )
            displayPreviewRequestIDs[display.id] = nil
        } catch is CancellationError {
            guard displayPreviewRequestIDs[display.id] == requestID else {
                return
            }
            finishCancelledPreview(
                previous: previous,
                in: &displayPreviews,
                key: display.id
            )
            displayPreviewRequestIDs[display.id] = nil
        } catch {
            guard displayPreviewRequestIDs[display.id] == requestID else {
                return
            }
            finishFailedPreview(
                previous: previous,
                in: &displayPreviews,
                key: display.id
            )
            displayPreviewRequestIDs[display.id] = nil
        }
    }

    func pendingDisplayPreview(
        for display: DisplaySummary
    ) -> PreviewImageState? {
        guard let key = pendingDisplayPreviewKey(display) else {
            return nil
        }
        return pendingDisplayPreviews[key]
    }

    func loadPendingDisplayPreview(_ display: DisplaySummary) async {
        guard
            supportsPreviews,
            let instance = activeInstance,
            let pendingRender = display.pendingRender,
            let key = pendingDisplayPreviewKey(display)
        else {
            return
        }

        let stored = pendingDisplayPreviews[key] ?? .idle
        let previous = stored.phase == .loading
            ? PreviewImageState(
                data: stored.data,
                eTag: stored.eTag,
                phase: stored.data == nil ? .idle : .ready
            )
            : stored
        let requestID = UUID()
        pendingDisplayPreviewRequestIDs[key] = requestID
        pendingDisplayPreviews[key] = PreviewImageState(
            data: previous.data,
            eTag: previous.eTag,
            phase: .loading
        )

        do {
            let result = try await activeClient.fetchDevicePreview(
                id: display.id,
                revision: pendingRender.revision,
                ifNoneMatch: previous.data == nil ? nil : previous.eTag,
                instance: instance
            )
            guard pendingDisplayPreviewRequestIDs[key] == requestID else {
                return
            }
            guard
                activeInstance?.id == instance.id,
                displays.first(where: { $0.id == display.id })?
                    .pendingRender?.revision == pendingRender.revision,
                !Task.isCancelled
            else {
                pendingDisplayPreviews[key] = previous
                pendingDisplayPreviewRequestIDs[key] = nil
                return
            }
            apply(
                result,
                previous: previous,
                to: &pendingDisplayPreviews,
                key: key
            )
            pendingDisplayPreviewRequestIDs[key] = nil
        } catch is CancellationError {
            guard pendingDisplayPreviewRequestIDs[key] == requestID else {
                return
            }
            finishCancelledPreview(
                previous: previous,
                in: &pendingDisplayPreviews,
                key: key
            )
            pendingDisplayPreviewRequestIDs[key] = nil
        } catch {
            guard pendingDisplayPreviewRequestIDs[key] == requestID else {
                return
            }
            finishFailedPreview(
                previous: previous,
                in: &pendingDisplayPreviews,
                key: key
            )
            pendingDisplayPreviewRequestIDs[key] = nil
        }
    }

    private func pendingDisplayPreviewKey(
        _ display: DisplaySummary
    ) -> String? {
        guard let revision = display.pendingRender?.revision else {
            return nil
        }
        return "\(display.id)|\(revision)"
    }

    func dashboardPreview(
        for dashboard: DashboardSummary,
        deviceID: String?
    ) -> PreviewImageState? {
        dashboardPreview(
            id: dashboard.id,
            deviceID: deviceID ?? dashboard.deviceIDs.first
        )
    }

    func dashboardPreview(
        id dashboardID: String,
        deviceID: String?
    ) -> PreviewImageState? {
        dashboardPreviews[
            DashboardPreviewKey(
                dashboardID: dashboardID,
                deviceID: deviceID
            )
        ]
    }

    func loadDashboardPreview(
        _ dashboard: DashboardSummary,
        deviceID: String? = nil
    ) async {
        await loadDashboardPreview(
            id: dashboard.id,
            deviceID: deviceID ?? dashboard.deviceIDs.first
        )
    }

    func loadDashboardPreview(
        id dashboardID: String,
        deviceID: String?
    ) async {
        guard supportsPreviews, let instance = activeInstance else {
            return
        }
        let key = DashboardPreviewKey(
            dashboardID: dashboardID,
            deviceID: deviceID
        )
        let stored = dashboardPreviews[key] ?? .idle
        let previous = stored.phase == .loading
            ? PreviewImageState(
                data: stored.data,
                eTag: stored.eTag,
                phase: stored.data == nil ? .idle : .ready
            )
            : stored
        let requestID = UUID()
        dashboardPreviewRequestIDs[key] = requestID
        dashboardPreviews[key] = PreviewImageState(
            data: previous.data,
            eTag: previous.eTag,
            phase: .loading
        )

        do {
            for attempt in 0..<8 {
                try Task.checkCancellation()
                let result = try await activeClient.fetchDashboardPreview(
                    id: dashboardID,
                    deviceID: key.deviceID,
                    ifNoneMatch: previous.data == nil ? nil : previous.eTag,
                    instance: instance
                )
                guard dashboardPreviewRequestIDs[key] == requestID else {
                    return
                }
                guard activeInstance?.id == instance.id, !Task.isCancelled else {
                    dashboardPreviews[key] = previous
                    dashboardPreviewRequestIDs[key] = nil
                    return
                }
                if case let .preparing(retryAfterSeconds) = result {
                    guard attempt < 7 else {
                        break
                    }
                    let boundedDelay = min(max(retryAfterSeconds, 0.25), 30)
                    try await Task.sleep(
                        for: .milliseconds(Int(boundedDelay * 1_000))
                    )
                    continue
                }
                apply(
                    result,
                    previous: previous,
                    to: &dashboardPreviews,
                    key: key
                )
                dashboardPreviewRequestIDs[key] = nil
                return
            }
            guard dashboardPreviewRequestIDs[key] == requestID else {
                return
            }
            finishFailedPreview(
                previous: previous,
                in: &dashboardPreviews,
                key: key
            )
            dashboardPreviewRequestIDs[key] = nil
        } catch is CancellationError {
            guard dashboardPreviewRequestIDs[key] == requestID else {
                return
            }
            finishCancelledPreview(
                previous: previous,
                in: &dashboardPreviews,
                key: key
            )
            dashboardPreviewRequestIDs[key] = nil
        } catch {
            guard dashboardPreviewRequestIDs[key] == requestID else {
                return
            }
            finishFailedPreview(
                previous: previous,
                in: &dashboardPreviews,
                key: key
            )
            dashboardPreviewRequestIDs[key] = nil
        }
    }

    func loadHistoryPreview(_ item: HistoryItem) async {
        guard supportsHistory, item.previewAvailable, let instance = activeInstance else {
            return
        }
        let previous = historyPreviews[item.id] ?? .idle
        guard previous.phase != .loading else {
            return
        }
        historyPreviews[item.id] = PreviewImageState(
            data: previous.data,
            eTag: previous.eTag,
            phase: .loading
        )

        do {
            let result = try await activeClient.fetchHistoryPreview(
                id: item.id,
                ifNoneMatch: previous.data == nil ? nil : previous.eTag,
                instance: instance
            )
            guard activeInstance?.id == instance.id, !Task.isCancelled else {
                return
            }
            apply(
                result,
                previous: previous,
                to: &historyPreviews,
                key: item.id
            )
        } catch is CancellationError {
            finishCancelledPreview(
                previous: previous,
                in: &historyPreviews,
                key: item.id
            )
        } catch {
            finishFailedPreview(
                previous: previous,
                in: &historyPreviews,
                key: item.id
            )
        }
    }

    private func updateUntilTerminal(_ acceptedJob: PushJob, instance: TesseraeInstance) async {
        let revision = connectionRevision
        let client = activeClient
        guard activeInstance?.id == instance.id else { return }
        var current = acceptedJob
        for _ in 0..<60 where !current.isTerminal {
            do {
                try checkConnectionRevision(revision)
                current = try await client.fetchJob(id: current.id, instance: instance)
                try checkConnectionRevision(revision)
                if let index = jobs.firstIndex(where: { $0.id == current.id }) {
                    jobs[index] = current
                }
                await persistSnapshot(showErrors: false)
                try checkConnectionRevision(revision)
                if !current.isTerminal {
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch is CancellationError {
                return
            } catch let error as TesseraeClientError {
                guard connectionRevision == revision, !Task.isCancelled else { return }
                if case .server("not_found", _, _) = error {
                    // The server swept this job after its advertised
                    // retention window (24 h), usually because the app never
                    // observed the terminal state. Drop the stale card instead
                    // of raising "No job with that id" on every launch; the
                    // published outcome remains in server History.
                    jobs.removeAll { $0.id == current.id }
                    await persistSnapshot(showErrors: false)
                    return
                }
                await presentOperationError(error)
                return
            } catch {
                guard connectionRevision == revision, !Task.isCancelled else { return }
                await presentOperationError(error)
                return
            }
        }
        guard connectionRevision == revision, !Task.isCancelled else { return }
        if current.isTerminal {
            await refreshDisplays(
                showErrors: false,
                saveSnapshot: false
            )
            guard connectionRevision == revision, !Task.isCancelled else { return }
            previewGeneration &+= 1
            if supportsHistory {
                await refreshHistoryAfterWrite(instance: instance)
            }
        }
    }

    private func refreshTrackedJobs(instance: TesseraeInstance) async {
        let revision = connectionRevision
        let client = activeClient
        guard activeInstance?.id == instance.id else { return }
        let nonterminalJobIDs = jobs
            .filter { !$0.isTerminal }
            .map(\.id)

        for jobID in nonterminalJobIDs {
            do {
                try checkConnectionRevision(revision)
                let refreshed = try await client.fetchJob(
                    id: jobID,
                    instance: instance
                )
                try checkConnectionRevision(revision)
                if let index = jobs.firstIndex(where: { $0.id == jobID }),
                   jobs[index].updatedAt <= refreshed.updatedAt
                {
                    jobs[index] = refreshed
                }
            } catch is CancellationError {
                return
            } catch {
                guard connectionRevision == revision, !Task.isCancelled else { return }
                // Keep the existing local progress card. A later refresh can
                // retry without turning an otherwise healthy list refresh
                // into a connection error.
            }
        }
    }

    func disconnect() async {
        isDisconnecting = true
        connectionRevision = UUID()
        let revision = connectionRevision
        var disconnectError: Error?
        let disconnectedInstanceID = activeInstance?.id
        if let activeInstance, connectionMode == .live {
            do {
                try await activeClient.revokeSession(instance: activeInstance)
            } catch {
                disconnectError = error
            }
            guard connectionRevision == revision else { return }
            do {
                try await credentials.removeToken(for: activeInstance.id)
            } catch {
                disconnectError = disconnectError ?? error
            }
            guard connectionRevision == revision else { return }
            do {
                try await stateStore.clear()
            } catch {
                disconnectError = disconnectError ?? error
            }
        }
        guard connectionRevision == revision else { return }
        if let disconnectedInstanceID {
            try? await activityThumbnails.clear(
                instanceID: disconnectedInstanceID
            )
        }
        guard connectionRevision == revision else { return }
        activeOperationIDs = []
        isRefreshingGallery = false
        loadingGalleryFolderIDs = []
        loadingOfflineAlbumFolderIDs = []
        activeInstance = nil
        connectionMode = nil
        connectionHealth = .idle
        connectionNotice = nil
        capabilities = nil
        lineupAuthoringPermission = .unknown
        lineupAuthoringSettingsURL = nil
        galleryWritePermission = .unknown
        galleryWriteSettingsURL = nil
        offlineAlbumAuthoringPermission = .unknown
        offlineAlbumSettingsURL = nil
        displays = []
        dashboards = []
        lineups = []
        galleryFolders = []
        galleryFolderDetails = [:]
        offlineAlbumsByFolderID = [:]
        offlineAlbumETagsByFolderID = [:]
        galleryThumbnailStates = [:]
        jobs = []
        historyItems = []
        historyNextBeforeID = nil
        activityClearedBefore = nil
        activityThumbnailData = [:]
        queuedImageRequests = []
        queuedLinkRequests = []
        queuedImagePreviewData = [:]
        historyPreviews = [:]
        displayPreviews = [:]
        displayPreviewRequestIDs = [:]
        pendingDisplayPreviews = [:]
        pendingDisplayPreviewRequestIDs = [:]
        deviceUpcomingResponses = [:]
        loadingDeviceTimelineIDs = []
        deviceTimelineErrors = [:]
        dashboardPreviews = [:]
        dashboardPreviewRequestIDs = [:]
        displayOrderIDs = []
        dashboardOrderIDs = []
        collapsedDashboardSectionIDs = []
        activeClient = liveClient
        if let disconnectError {
            lastError = disconnectError.localizedDescription
        }
    }

    private func handleConnectionError(
        _ error: TesseraeClientError
    ) async {
        if case .forbidden = error {
            connectionHealth = .connected
            connectionNotice = nil
            lastError = error.localizedDescription
            return
        }
        // Connection state is already presented persistently in RootView's
        // top banner. Clear any modal error so one failure never produces
        // both the banner and a blocking alert.
        lastError = nil
        if error == .unauthorized || error == .missingCredential {
            isDisconnecting = true
            connectionRevision = UUID()
            let revision = connectionRevision
            let disconnectedInstanceID = activeInstance?.id
            if let activeInstance {
                try? await credentials.removeToken(for: activeInstance.id)
            }
            guard connectionRevision == revision else { return }
            try? await stateStore.clear()
            guard connectionRevision == revision else { return }
            if let disconnectedInstanceID {
                try? await activityThumbnails.clear(
                    instanceID: disconnectedInstanceID
                )
            }
            guard connectionRevision == revision else { return }
            activeOperationIDs = []
            isRefreshingGallery = false
            isLoadingMoreHistory = false
            loadingGalleryFolderIDs = []
            loadingOfflineAlbumFolderIDs = []
            activeInstance = nil
            connectionMode = nil
            capabilities = nil
            lineupAuthoringPermission = .unknown
            lineupAuthoringSettingsURL = nil
            galleryWritePermission = .unknown
            galleryWriteSettingsURL = nil
            offlineAlbumAuthoringPermission = .unknown
            offlineAlbumSettingsURL = nil
            displays = []
            dashboards = []
            lineups = []
            galleryFolders = []
            galleryFolderDetails = [:]
            offlineAlbumsByFolderID = [:]
            offlineAlbumETagsByFolderID = [:]
            galleryThumbnailStates = [:]
            jobs = []
            historyItems = []
            historyNextBeforeID = nil
            activityClearedBefore = nil
            activityThumbnailData = [:]
            queuedImageRequests = []
            queuedLinkRequests = []
            queuedImagePreviewData = [:]
            historyPreviews = [:]
            displayPreviews = [:]
            displayPreviewRequestIDs = [:]
            pendingDisplayPreviews = [:]
            pendingDisplayPreviewRequestIDs = [:]
            deviceUpcomingResponses = [:]
            loadingDeviceTimelineIDs = []
            deviceTimelineErrors = [:]
            dashboardPreviews = [:]
            dashboardPreviewRequestIDs = [:]
            displayOrderIDs = []
            dashboardOrderIDs = []
            collapsedDashboardSectionIDs = []
            activeClient = liveClient
            connectionHealth = .requiresPairing
            connectionNotice = String(
                localized: "This Tesserae credential was revoked or expired. Pair again to reconnect."
            )
        } else {
            connectionHealth = .offline
            connectionNotice = error.localizedDescription
        }
    }

    private func presentLineupsPermissionError() {
        connectionHealth = .connected
        connectionNotice = nil
        lastError = String(
            localized: "This pairing does not include Lineups access. Pair again to use Lineups."
        )
    }

    private func presentOperationError(_ error: Error) async {
        if error is CancellationError {
            return
        }
        guard let clientError = error as? TesseraeClientError else {
            lastError = error.localizedDescription
            return
        }

        switch clientError {
        case .transport, .unavailable, .unauthorized, .missingCredential:
            await handleConnectionError(clientError)
        case let .httpStatus(status) where [502, 503, 504].contains(status):
            await handleConnectionError(clientError)
        default:
            lastError = clientError.localizedDescription
        }
    }

    private func loadDisplayOrder(for instanceID: String) {
        displayOrderIDs = UserDefaults.standard.stringArray(
            forKey: Self.displayOrderKeyPrefix + instanceID
        ) ?? []
    }

    private func reconcileDeviceTimelines() {
        guard supportsDeviceTimeline else {
            deviceUpcomingResponses = [:]
            loadingDeviceTimelineIDs = []
            deviceTimelineErrors = [:]
            return
        }
        let displayIDs = Set(displays.map(\.id))
        deviceUpcomingResponses = deviceUpcomingResponses.filter {
            displayIDs.contains($0.key)
        }
        loadingDeviceTimelineIDs = loadingDeviceTimelineIDs.intersection(
            displayIDs
        )
        deviceTimelineErrors = deviceTimelineErrors.filter {
            displayIDs.contains($0.key)
        }
    }

    private func loadDashboardOrder(for instanceID: String) {
        dashboardOrderIDs = UserDefaults.standard.stringArray(
            forKey: Self.dashboardOrderKeyPrefix + instanceID
        ) ?? []
    }

    private func loadCollapsedDashboardSections(for instanceID: String) {
        collapsedDashboardSectionIDs = Set(
            UserDefaults.standard.stringArray(
                forKey: Self.collapsedDashboardSectionsKeyPrefix + instanceID
            ) ?? []
        )
    }

    private func reconcileDisplayOrder() {
        let availableIDs = Set(displays.map(\.id))
        var seenIDs: Set<String> = []
        let retainedIDs = displayOrderIDs.filter { displayID in
            availableIDs.contains(displayID)
                && seenIDs.insert(displayID).inserted
        }
        let newIDs = displays
            .filter { !seenIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.id < rhs.id
            }
            .map(\.id)
        let normalizedOrder = retainedIDs + newIDs

        guard normalizedOrder != displayOrderIDs else { return }
        displayOrderIDs = normalizedOrder
        saveDisplayOrder()
    }

    private func reconcileDashboardOrder() {
        let availableIDs = Set(dashboards.map(\.id))
        var seenIDs: Set<String> = []
        let retainedIDs = dashboardOrderIDs.filter { dashboardID in
            availableIDs.contains(dashboardID)
                && seenIDs.insert(dashboardID).inserted
        }
        let newIDs = dashboards
            .filter { !seenIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.id < rhs.id
            }
            .map(\.id)
        let normalizedOrder = retainedIDs + newIDs

        guard normalizedOrder != dashboardOrderIDs else { return }
        dashboardOrderIDs = normalizedOrder
        saveDashboardOrder()
    }

    private func replaceLineup(_ updated: Lineup) {
        guard let index = lineups.firstIndex(where: { $0.id == updated.id }) else {
            lineups.append(updated)
            return
        }
        lineups[index] = updated
    }

    private func lineupStateOperationID(_ lineupID: String) -> String {
        "lineup-state:\(lineupID)"
    }

    private func lineupControlOperationID(_ lineupID: String) -> String {
        "lineup-control:\(lineupID)"
    }

    private func saveDashboardOrder() {
        guard let instanceID = activeInstance?.id else { return }
        UserDefaults.standard.set(
            dashboardOrderIDs,
            forKey: Self.dashboardOrderKeyPrefix + instanceID
        )
    }

    private func saveDisplayOrder() {
        guard let instanceID = activeInstance?.id else { return }
        UserDefaults.standard.set(
            displayOrderIDs,
            forKey: Self.displayOrderKeyPrefix + instanceID
        )
    }

    private func saveCollapsedDashboardSections() {
        guard let instanceID = activeInstance?.id else { return }
        UserDefaults.standard.set(
            collapsedDashboardSectionIDs.sorted(),
            forKey: Self.collapsedDashboardSectionsKeyPrefix + instanceID
        )
    }

    @discardableResult
    private func persistSnapshot(showErrors: Bool = true) async -> Bool {
        let revision = connectionRevision
        guard
            connectionMode == .live,
            let activeInstance
        else {
            return true
        }
        do {
            try await stateStore.save(
                CompanionSnapshot(
                    activeInstance: activeInstance,
                    capabilities: capabilities,
                    displays: displays,
                    dashboards: dashboards,
                    lineups: lineups,
                    jobs: jobs,
                    activityClearedBefore: activityClearedBefore
                )
            )
            return true
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return false }
            if showErrors {
                lastError = error.localizedDescription
            }
            return false
        }
    }

    private func refreshHistoryAfterWrite(instance: TesseraeInstance) async {
        let revision = connectionRevision
        let client = activeClient
        guard activeInstance?.id == instance.id else { return }
        do {
            let history = try await client.fetchHistory(
                beforeID: nil,
                limit: 30,
                instance: instance
            )
            try checkConnectionRevision(revision)
            let retainedHistory = retainedHistoryPage(history)
            historyItems = retainedHistory.items
            historyNextBeforeID = retainedHistory.nextBeforeID
            let historyIDs = Set(retainedHistory.items.map(\.id))
            historyPreviews = historyPreviews.filter {
                historyIDs.contains($0.key)
            }
        } catch {
            guard connectionRevision == revision, !Task.isCancelled else { return }
            // The Job remains visible as the immediate activity record. A
            // later pull-to-refresh can reconcile eventually consistent
            // server History without turning a successful send into an error.
        }
    }

    private func rememberActivityThumbnail(
        imageData: Data,
        for job: PushJob,
        instanceID: String
    ) async {
        let revision = connectionRevision
        guard job.kind == .imagePush else { return }
        if let thumbnail = try? await activityThumbnails.save(
            imageData: imageData,
            jobID: job.id,
            instanceID: instanceID,
            createdAt: job.createdAt
        ) {
            guard connectionRevision == revision, activeInstance?.id == instanceID else { return }
            activityThumbnailData[job.id] = thumbnail
        }
    }

    private func reloadActivityThumbnails(instanceID: String) async {
        try? await activityThumbnails.purge(referenceDate: Date())
        var loaded: [String: Data] = [:]
        for job in jobs where job.kind == .imagePush {
            if let data = try? await activityThumbnails.data(
                forJobID: job.id,
                instanceID: instanceID
            ) {
                loaded[job.id] = data
            }
        }
        activityThumbnailData = loaded
    }

    private func retainedActivityJobs(_ candidates: [PushJob]) -> [PushJob] {
        guard let activityClearedBefore else {
            return candidates
        }
        return candidates.filter {
            $0.createdAt > activityClearedBefore
        }
    }

    private func retainedHistoryPage(
        _ page: HistoryResponse
    ) -> HistoryResponse {
        guard let activityClearedBefore else {
            return page
        }
        let retained = page.items.filter {
            $0.createdAt > activityClearedBefore
        }
        return HistoryResponse(
            items: retained,
            nextBeforeID: retained.count == page.items.count
                ? page.nextBeforeID
                : nil
        )
    }

    private func imageFileName(for contentType: String) -> String {
        switch contentType {
        case "image/png": "shared-photo.png"
        case "image/heic": "shared-photo.heic"
        case "image/heif": "shared-photo.heif"
        case "image/webp": "shared-photo.webp"
        default: "shared-photo.jpg"
        }
    }

    private func apply<Key: Hashable>(
        _ result: PreviewFetchResult,
        previous: PreviewImageState,
        to previews: inout [Key: PreviewImageState],
        key: Key
    ) {
        switch result {
        case let .image(data, eTag):
            previews[key] = PreviewImageState(
                data: data,
                eTag: eTag,
                phase: .ready
            )
        case .notModified:
            previews[key] = PreviewImageState(
                data: previous.data,
                eTag: previous.eTag,
                phase: previous.data == nil ? .idle : .ready
            )
        case .notFound:
            previews[key] = PreviewImageState(
                data: nil,
                eTag: nil,
                phase: .unavailable
            )
        case .preparing:
            previews[key] = PreviewImageState(
                data: previous.data,
                eTag: previous.eTag,
                phase: .loading
            )
        }
    }

    private func finishCancelledPreview<Key: Hashable>(
        previous: PreviewImageState,
        in previews: inout [Key: PreviewImageState],
        key: Key
    ) {
        previews[key] = PreviewImageState(
            data: previous.data,
            eTag: previous.eTag,
            phase: previous.data == nil ? .idle : .ready
        )
    }

    private func finishFailedPreview<Key: Hashable>(
        previous: PreviewImageState,
        in previews: inout [Key: PreviewImageState],
        key: Key
    ) {
        previews[key] = PreviewImageState(
            data: previous.data,
            eTag: previous.eTag,
            phase: previous.data == nil ? .unavailable : .ready
        )
    }
}
