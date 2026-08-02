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

@MainActor
@Observable
final class AppModel {
    private static let dashboardOrderKeyPrefix = "dashboard-order."

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
    private var didAttemptRestore = false
    private var isSynchronizingSharedState = false
    private var activityRefreshTask: Task<Void, Never>?
    private var displayPreviewRequestIDs: [String: UUID] = [:]
    private var pendingDisplayPreviewRequestIDs: [String: UUID] = [:]

    var activeInstance: TesseraeInstance?
    var connectionMode: ConnectionMode?
    var connectionHealth: ConnectionHealth = .restoring
    var connectionNotice: String?
    var discoveredInstances: [DiscoveredInstance] = []
    var discoveryError: String?
    var capabilities: ServerCapabilities?
    var displays: [DisplaySummary] = []
    var dashboards: [DashboardSummary] = []
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
    var dashboardPreviews: [String: PreviewImageState] = [:]
    var previewGeneration = 0
    var displayPreviewGeneration = 0
    var dashboardOrderIDs: [String] = []
    var activeOperationIDs: Set<String> = []
    var isRefreshing = false
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

    var supportsRemindersPersonalData: Bool {
        connectionMode == .live
            && capabilities?.supports(personalDataSource: .remindersFridge) == true
    }

    var personalDataMaximumTTLSeconds: Int? {
        capabilities?.limits.personalDataMaxTTLSeconds
    }

    var supportedLinkPushKinds: [LinkPushKind] {
        guard let capabilities else { return [] }
        return LinkPushKind.allCases.filter(capabilities.supports)
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
        discovery: any TesseraeDiscovering
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

    func discoverNearby() async {
        guard activeInstance == nil, !isDiscovering else { return }
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

        await connect(
            using: demoClient,
            mode: .demo,
            baseURL: resolvedURL,
            code: "482193",
            clientName: "Demo iPhone"
        )
    }

    func connectLive(baseURL: URL, code: String, clientName: String) async {
        await connect(
            using: liveClient,
            mode: .live,
            baseURL: baseURL,
            code: code,
            clientName: clientName
        )
    }

    private func connect(
        using candidate: any TesseraeServing,
        mode: ConnectionMode,
        baseURL: URL,
        code: String,
        clientName: String
    ) async {
        connectionNotice = nil
        activeOperationIDs.insert("pair")
        defer { activeOperationIDs.remove("pair") }
        do {
            let capabilities = try await candidate.probe(baseURL: baseURL)
            let session = try await candidate.pair(
                baseURL: baseURL,
                code: code,
                clientName: clientName
            )
            if mode == .live {
                try await credentials.save(
                    token: session.token,
                    for: session.instance.id
                )
            }
            activeClient = candidate
            connectionMode = mode
            connectionHealth = .connected
            self.capabilities = capabilities
            activeInstance = session.instance.updatingServerVersion(
                to: capabilities.serverVersion
            )
            activityThumbnailData = [:]
            queuedImageRequests = []
            queuedLinkRequests = []
            queuedImagePreviewData = [:]
            historyItems = []
            historyNextBeforeID = nil
            activityClearedBefore = nil
            historyPreviews = [:]
            displayPreviews = [:]
            displayPreviewRequestIDs = [:]
            pendingDisplayPreviews = [:]
            pendingDisplayPreviewRequestIDs = [:]
            dashboardPreviews = [:]
            loadDashboardOrder(for: session.instance.id)
            if mode == .live {
                await persistSnapshot()
            }
            await refresh(probeCapabilities: false)
            await reloadQueuedImages()
            await reloadQueuedLinks()
            await retryPendingSharedImages()
            await retryPendingSharedLinks()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func restoreConnectionIfNeeded() async {
        guard !didAttemptRestore else { return }
        didAttemptRestore = true
        isRestoringConnection = true
        connectionHealth = .restoring
        defer { isRestoringConnection = false }

        do {
            guard let snapshot = try await stateStore.load() else {
                connectionHealth = .idle
                return
            }
            guard try await credentials.token(for: snapshot.activeInstance.id) != nil else {
                try await stateStore.clear()
                connectionHealth = .requiresPairing
                connectionNotice = String(
                    localized: "The saved Tesserae pairing is no longer available. Pair again to reconnect."
                )
                return
            }

            activeClient = liveClient
            connectionMode = .live
            activeInstance = snapshot.activeInstance
            loadDashboardOrder(for: snapshot.activeInstance.id)
            capabilities = snapshot.capabilities
            displays = snapshot.displays
            dashboards = snapshot.dashboards
            activityClearedBefore = snapshot.activityClearedBefore
            jobs = retainedActivityJobs(snapshot.jobs)
            await reloadActivityThumbnails(instanceID: snapshot.activeInstance.id)
            await reloadQueuedImages()
            await reloadQueuedLinks()

            let currentCapabilities = try await liveClient.probe(
                baseURL: snapshot.activeInstance.baseURL
            )
            capabilities = currentCapabilities
            activeInstance = snapshot.activeInstance.updatingServerVersion(
                to: currentCapabilities.serverVersion
            )
            await refresh(
                showErrors: false,
                probeCapabilities: false
            )
            await retryPendingSharedImages()
            await retryPendingSharedLinks()
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            await handleConnectionError(error)
        } catch {
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
            !isRefreshing
        else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            if probeCapabilities, connectionMode == .live {
                let currentCapabilities = try await activeClient.probe(
                    baseURL: currentInstance.baseURL
                )
                capabilities = currentCapabilities
                currentInstance = currentInstance.updatingServerVersion(
                    to: currentCapabilities.serverVersion
                )
                activeInstance = currentInstance
            }

            displays = try await activeClient.fetchDisplays(instance: currentInstance)
            dashboards = try await activeClient.fetchDashboards(instance: currentInstance)
            if supportsHistory {
                let history = try await activeClient.fetchHistory(
                    beforeID: nil,
                    limit: 30,
                    instance: currentInstance
                )
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
                    dashboardIDs.contains($0.key)
                }
            } else {
                displayPreviews = [:]
                pendingDisplayPreviews = [:]
                dashboardPreviews = [:]
            }
            displayPreviewGeneration &+= 1
            previewGeneration &+= 1
            if connectionMode == .live {
                await persistSnapshot(showErrors: showErrors)
            }
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            await handleConnectionError(error)
        } catch {
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
            !isRefreshing
        else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            let refreshedDisplays = try await activeClient.fetchDisplays(
                instance: currentInstance
            )
            guard activeInstance?.id == currentInstance.id else {
                return
            }

            displays = refreshedDisplays
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
            displayPreviewGeneration &+= 1

            if connectionMode == .live, saveSnapshot {
                await persistSnapshot(showErrors: showErrors)
            }
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            if showErrors
                || error == .unauthorized
                || error == .missingCredential
            {
                await handleConnectionError(error)
            }
        } catch {
            if showErrors {
                connectionHealth = .offline
                connectionNotice = error.localizedDescription
                lastError = nil
            }
        }
    }

    func refreshActivity(
        showErrors: Bool = true,
        saveSnapshot: Bool = true
    ) async {
        guard
            let currentInstance = activeInstance,
            !isRefreshing
        else {
            return
        }
        isRefreshing = true
        defer { isRefreshing = false }

        await reloadQueuedImages(showErrors: showErrors)
        await reloadQueuedLinks(showErrors: showErrors)

        do {
            if supportsHistory {
                let history = try await activeClient.fetchHistory(
                    beforeID: nil,
                    limit: 30,
                    instance: currentInstance
                )
                guard activeInstance?.id == currentInstance.id else {
                    return
                }
                let retainedHistory = retainedHistoryPage(history)
                historyItems = retainedHistory.items
                historyNextBeforeID = retainedHistory.nextBeforeID
                let historyIDs = Set(retainedHistory.items.map(\.id))
                historyPreviews = historyPreviews.filter {
                    historyIDs.contains($0.key)
                }
            }

            await refreshTrackedJobs(instance: currentInstance)
            guard activeInstance?.id == currentInstance.id else {
                return
            }
            connectionHealth = .connected
            connectionNotice = nil
            if connectionMode == .live, saveSnapshot {
                await persistSnapshot(showErrors: showErrors)
            }
        } catch is CancellationError {
            return
        } catch let error as TesseraeClientError {
            if showErrors
                || error == .unauthorized
                || error == .missingCredential
            {
                await handleConnectionError(error)
            }
        } catch {
            if showErrors {
                connectionHealth = .offline
                connectionNotice = error.localizedDescription
                lastError = nil
            }
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

    @discardableResult
    func push(
        _ dashboard: DashboardSummary,
        deviceIDs: [String]
    ) async -> Bool {
        guard let activeInstance, !deviceIDs.isEmpty else { return false }
        activeOperationIDs.insert(dashboard.id)
        defer { activeOperationIDs.remove(dashboard.id) }

        do {
            let job = try await activeClient.pushDashboard(
                id: dashboard.id,
                deviceIDs: deviceIDs,
                overrideQuietHours: false,
                idempotencyKey: UUID().uuidString,
                instance: activeInstance
            )
            jobs.insert(job, at: 0)
            await persistSnapshot()
            await updateUntilTerminal(job, instance: activeInstance)
            return true
        } catch {
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

    func remindersPersonalDataStatus() async throws -> PersonalDataSourceStatus? {
        guard let activeInstance else {
            throw RemindersBridgeError.unavailable
        }
        return try await activeClient.fetchPersonalDataStatus(
            instance: activeInstance
        ).sources.first { $0.sourceID == .remindersFridge }
    }

    func putRemindersSnapshot(
        _ snapshot: RemindersFridgeSnapshot
    ) async throws -> PersonalDataSourceStatus {
        guard let activeInstance else {
            throw RemindersBridgeError.unavailable
        }
        return try await activeClient.putRemindersFridgeSnapshot(
            snapshot,
            instance: activeInstance
        )
    }

    func deleteRemindersPersonalData() async throws {
        guard let activeInstance else {
            throw RemindersBridgeError.unavailable
        }
        try await activeClient.deletePersonalData(
            sourceID: .remindersFridge,
            instance: activeInstance
        )
    }

    func sendImage(
        data: Data,
        fit: ImageFitMode,
        deviceIDs: [String],
        contentType: String
    ) async -> Bool {
        guard let activeInstance else { return false }
        activeOperationIDs.insert("image")
        defer { activeOperationIDs.remove("image") }

        do {
            let job = try await activeClient.sendImage(
                data: data,
                fileName: imageFileName(for: contentType),
                contentType: contentType,
                fit: fit,
                deviceIDs: deviceIDs,
                overrideQuietHours: false,
                idempotencyKey: UUID().uuidString,
                instance: activeInstance
            )
            await rememberActivityThumbnail(
                imageData: data,
                for: job,
                instanceID: activeInstance.id
            )
            jobs.insert(job, at: 0)
            await persistSnapshot()
            await updateUntilTerminal(job, instance: activeInstance)
            return true
        } catch {
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
        guard let activeInstance else { return false }
        guard supportedLinkPushKinds.contains(kind) else {
            lastError = String(
                localized: "This Tesserae server does not support the selected link action."
            )
            return false
        }
        activeOperationIDs.insert("link")
        defer { activeOperationIDs.remove("link") }

        do {
            let idempotencyKey = UUID().uuidString
            let job: PushJob
            switch kind {
            case .imageURL:
                job = try await activeClient.sendImageURL(
                    url: url,
                    fit: fit,
                    deviceIDs: deviceIDs,
                    overrideQuietHours: false,
                    idempotencyKey: idempotencyKey,
                    instance: activeInstance
                )
            case .webpage:
                job = try await activeClient.sendWebpage(
                    url: url,
                    fit: fit,
                    viewportW: nil,
                    deviceIDs: deviceIDs,
                    overrideQuietHours: false,
                    idempotencyKey: idempotencyKey,
                    instance: activeInstance
        framing: ImageFraming? = nil,
                )
            }
            jobs.insert(job, at: 0)
            await persistSnapshot()
            await updateUntilTerminal(job, instance: activeInstance)
            return true
        } catch {
            await presentOperationError(error)
            return false
        }
    }

    func loadMoreHistory() async {
                framing: framing,
        guard
            supportsHistory,
            !isLoadingMoreHistory,
            let beforeID = historyNextBeforeID,
            let activeInstance
        else {
            return
        }
        isLoadingMoreHistory = true
        defer { isLoadingMoreHistory = false }

        do {
            let page = try await activeClient.fetchHistory(
                beforeID: beforeID,
                limit: 30,
                instance: activeInstance
            )
            let retainedPage = retainedHistoryPage(page)
            let existingIDs = Set(historyItems.map(\.id))
            historyItems.append(
                contentsOf: retainedPage.items.filter {
                    !existingIDs.contains($0.id)
                }
            )
            historyNextBeforeID = retainedPage.nextBeforeID
        } catch {
            await presentOperationError(error)
        }
    }

    func resend(_ item: HistoryItem) async {
        guard supportsHistory, item.resendable, let activeInstance else {
            return
        }
        let operationID = "history-\(item.id)"
        activeOperationIDs.insert(operationID)
        defer { activeOperationIDs.remove(operationID) }

        do {
            let job = try await activeClient.resendHistory(
                id: item.id,
                overrideQuietHours: false,
                idempotencyKey: UUID().uuidString,
                instance: activeInstance
            )
            jobs.insert(job, at: 0)
            await persistSnapshot()
            await updateUntilTerminal(job, instance: activeInstance)
        } catch {
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
            upsertQueuedImage(submitting)

            let data = try await shareQueue.imageData(for: submitting)
            let job = try await liveClient.sendImage(
                data: data,
                fileName: submitting.fileName,
                contentType: submitting.contentType,
                fit: submitting.fit,
                deviceIDs: submitting.deviceIDs,
                overrideQuietHours: submitting.overrideQuietHours,
                idempotencyKey: submitting.idempotencyKey,
                instance: instance
            )
            try await shareQueue.remove(submitting)
            if activeInstance?.id == instance.id {
                await rememberActivityThumbnail(
                    imageData: data,
                    for: job,
                    instanceID: instance.id
                )
                if !jobs.contains(where: { $0.id == job.id }) {
                    jobs.insert(job, at: 0)
                }
                removeQueuedImageFromView(submitting.id)
                connectionHealth = .connected
                connectionNotice = nil
                await persistSnapshot(showErrors: false)

                Task { [weak self] in
                    await self?.updateUntilTerminal(job, instance: instance)
                }
            }
            return true
        } catch {
            let failed = submitting.updating(
                status: .failed,
                error: error.localizedDescription
            )
            try? await shareQueue.update(failed)
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
            if activeInstance?.id == instance.id {
                if !jobs.contains(where: { $0.id == job.id }) {
                    jobs.insert(job, at: 0)
                }
                queuedLinkRequests.removeAll { $0.id == submitting.id }
                connectionHealth = .connected
                connectionNotice = nil
                await persistSnapshot(showErrors: false)

                Task { [weak self] in
                    await self?.updateUntilTerminal(job, instance: instance)
                }
            }
            return true
        } catch {
            let failed = submitting.updating(
                status: .failed,
                error: error.localizedDescription
            )
            try? await linkShareQueue.update(failed)
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

    func loadDashboardPreview(_ dashboard: DashboardSummary) async {
        guard supportsPreviews, let instance = activeInstance else {
            return
        }
        let previous = dashboardPreviews[dashboard.id] ?? .idle
        guard previous.phase != .loading else {
            return
        }
        dashboardPreviews[dashboard.id] = PreviewImageState(
            data: previous.data,
            eTag: previous.eTag,
            phase: .loading
        )

        do {
            for attempt in 0..<8 {
                try Task.checkCancellation()
                let result = try await activeClient.fetchDashboardPreview(
                    id: dashboard.id,
                    deviceID: dashboard.deviceIDs.first,
                    ifNoneMatch: previous.data == nil ? nil : previous.eTag,
                    instance: instance
                )
                guard activeInstance?.id == instance.id else {
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
                    key: dashboard.id
                )
                return
            }
            finishFailedPreview(
                previous: previous,
                in: &dashboardPreviews,
                key: dashboard.id
            )
        } catch is CancellationError {
            finishCancelledPreview(
                previous: previous,
                in: &dashboardPreviews,
                key: dashboard.id
            )
        } catch {
            finishFailedPreview(
                previous: previous,
                in: &dashboardPreviews,
                key: dashboard.id
            )
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
        var current = acceptedJob
        for _ in 0..<60 where !current.isTerminal {
            do {
                current = try await activeClient.fetchJob(id: current.id, instance: instance)
                guard activeInstance?.id == instance.id else {
                    return
                }
                if let index = jobs.firstIndex(where: { $0.id == current.id }) {
                    jobs[index] = current
                }
                await persistSnapshot(showErrors: false)
                if !current.isTerminal {
                    try await Task.sleep(for: .milliseconds(500))
                }
            } catch is CancellationError {
                return
            } catch {
                await presentOperationError(error)
                return
            }
        }
        if current.isTerminal {
            await refreshDisplays(
                showErrors: false,
                saveSnapshot: false
            )
            previewGeneration &+= 1
            if supportsHistory {
                await refreshHistoryAfterWrite(instance: instance)
            }
        }
    }

    private func refreshTrackedJobs(instance: TesseraeInstance) async {
        let nonterminalJobIDs = jobs
            .filter { !$0.isTerminal }
            .map(\.id)

        for jobID in nonterminalJobIDs {
            do {
                let refreshed = try await activeClient.fetchJob(
                    id: jobID,
                    instance: instance
                )
                guard activeInstance?.id == instance.id else {
                    return
                }
                if let index = jobs.firstIndex(where: { $0.id == jobID }),
                   jobs[index].updatedAt <= refreshed.updatedAt
                {
                    jobs[index] = refreshed
                }
            } catch is CancellationError {
                return
            } catch {
                // Keep the existing local progress card. A later refresh can
                // retry without turning an otherwise healthy list refresh
                // into a connection error.
            }
        }
    }

    func disconnect() async {
        var disconnectError: Error?
        let disconnectedInstanceID = activeInstance?.id
        if let activeInstance, connectionMode == .live {
            do {
                try await activeClient.revokeSession(instance: activeInstance)
            } catch {
                disconnectError = error
            }
            do {
                try await credentials.removeToken(for: activeInstance.id)
            } catch {
                disconnectError = disconnectError ?? error
            }
            do {
                try await stateStore.clear()
            } catch {
                disconnectError = disconnectError ?? error
            }
        }
        if let disconnectedInstanceID {
            try? await activityThumbnails.clear(
                instanceID: disconnectedInstanceID
            )
        }
        activeInstance = nil
        connectionMode = nil
        connectionHealth = .idle
        connectionNotice = nil
        capabilities = nil
        displays = []
        dashboards = []
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
        dashboardPreviews = [:]
        dashboardOrderIDs = []
        activeClient = liveClient
        if let disconnectError {
            lastError = disconnectError.localizedDescription
        }
    }

    private func handleConnectionError(
        _ error: TesseraeClientError
    ) async {
        // Connection state is already presented persistently in RootView's
        // top banner. Clear any modal error so one failure never produces
        // both the banner and a blocking alert.
        lastError = nil
        if error == .unauthorized || error == .missingCredential {
            let disconnectedInstanceID = activeInstance?.id
            if let activeInstance {
                try? await credentials.removeToken(for: activeInstance.id)
            }
            try? await stateStore.clear()
            if let disconnectedInstanceID {
                try? await activityThumbnails.clear(
                    instanceID: disconnectedInstanceID
                )
            }
            activeInstance = nil
            connectionMode = nil
            capabilities = nil
            displays = []
            dashboards = []
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
            dashboardPreviews = [:]
            dashboardOrderIDs = []
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

    private func loadDashboardOrder(for instanceID: String) {
        dashboardOrderIDs = UserDefaults.standard.stringArray(
            forKey: Self.dashboardOrderKeyPrefix + instanceID
        ) ?? []
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

    private func saveDashboardOrder() {
        guard let instanceID = activeInstance?.id else { return }
        UserDefaults.standard.set(
            dashboardOrderIDs,
            forKey: Self.dashboardOrderKeyPrefix + instanceID
        )
    }

    @discardableResult
    private func persistSnapshot(showErrors: Bool = true) async -> Bool {
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
                    jobs: jobs,
                    activityClearedBefore: activityClearedBefore
                )
            )
            return true
        } catch {
            if showErrors {
                lastError = error.localizedDescription
            }
            return false
        }
    }

    private func refreshHistoryAfterWrite(instance: TesseraeInstance) async {
        do {
            let history = try await activeClient.fetchHistory(
                beforeID: nil,
                limit: 30,
                instance: instance
            )
            guard activeInstance?.id == instance.id else {
                return
            }
            let retainedHistory = retainedHistoryPage(history)
            historyItems = retainedHistory.items
            historyNextBeforeID = retainedHistory.nextBeforeID
            let historyIDs = Set(retainedHistory.items.map(\.id))
            historyPreviews = historyPreviews.filter {
                historyIDs.contains($0.key)
            }
        } catch {
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
        guard job.kind == .imagePush else { return }
        if let thumbnail = try? await activityThumbnails.save(
            imageData: imageData,
            jobID: job.id,
            instanceID: instanceID,
            createdAt: job.createdAt
        ) {
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

    private func apply(
        _ result: PreviewFetchResult,
        previous: PreviewImageState,
        to previews: inout [String: PreviewImageState],
        key: String
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

    private func finishCancelledPreview(
        previous: PreviewImageState,
        in previews: inout [String: PreviewImageState],
        key: String
    ) {
        previews[key] = PreviewImageState(
            data: previous.data,
            eTag: previous.eTag,
            phase: previous.data == nil ? .idle : .ready
        )
    }

    private func finishFailedPreview(
        previous: PreviewImageState,
        in previews: inout [String: PreviewImageState],
        key: String
    ) {
        previews[key] = PreviewImageState(
            data: previous.data,
            eTag: previous.eTag,
            phase: previous.data == nil ? .unavailable : .ready
        )
    }
}
