import Foundation
import Observation
import TesseraeKit
import UIKit

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
    private let shareQueue: any ShareQueueStoring
    private let activityThumbnails: any ActivityThumbnailStoring
    private let discovery: any TesseraeDiscovering
    private var didAttemptRestore = false
    private var isSynchronizingSharedState = false

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
    var activityThumbnailData: [String: Data] = [:]
    var displayPreviews: [String: PreviewImageState] = [:]
    var dashboardPreviews: [String: PreviewImageState] = [:]
    var previewGeneration = 0
    var dashboardOrderIDs: [String] = []
    var activeOperationIDs: Set<String> = []
    var isRefreshing = false
    var isDiscovering = false
    var isRestoringConnection = true
    var isRetryingSharedImages = false
    var lastError: String?

    var supportsPreviews: Bool {
        capabilities?.features.contains("previews") == true
    }

    init(
        liveClient: any TesseraeServing,
        demoClient: any TesseraeServing,
        credentials: any CredentialStoring,
        stateStore: any CompanionStateStoring,
        shareQueue: any ShareQueueStoring,
        activityThumbnails: any ActivityThumbnailStoring,
        discovery: any TesseraeDiscovering
    ) {
        self.liveClient = liveClient
        self.demoClient = demoClient
        activeClient = liveClient
        self.credentials = credentials
        self.stateStore = stateStore
        self.shareQueue = shareQueue
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
            displayPreviews = [:]
            dashboardPreviews = [:]
            loadDashboardOrder(for: session.instance.id)
            if mode == .live {
                await persistSnapshot()
            }
            await refresh(probeCapabilities: false)
            await retryPendingSharedImages()
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
            jobs = snapshot.jobs
            await reloadActivityThumbnails(instanceID: snapshot.activeInstance.id)

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
        guard var currentInstance = activeInstance else { return }
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
            reconcileDashboardOrder()
            connectionHealth = .connected
            connectionNotice = nil
            if supportsPreviews {
                let displayIDs = Set(displays.map(\.id))
                let dashboardIDs = Set(dashboards.map(\.id))
                displayPreviews = displayPreviews.filter {
                    displayIDs.contains($0.key)
                }
                dashboardPreviews = dashboardPreviews.filter {
                    dashboardIDs.contains($0.key)
                }
            } else {
                displayPreviews = [:]
                dashboardPreviews = [:]
            }
            previewGeneration &+= 1
            if connectionMode == .live {
                await persistSnapshot(showErrors: showErrors)
            }
        } catch let error as TesseraeClientError {
            await handleConnectionError(error)
        } catch {
            connectionHealth = .offline
            connectionNotice = error.localizedDescription
            lastError = nil
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

    func push(_ dashboard: DashboardSummary) async {
        guard let activeInstance else { return }
        activeOperationIDs.insert(dashboard.id)
        defer { activeOperationIDs.remove(dashboard.id) }

        do {
            let job = try await activeClient.pushDashboard(
                id: dashboard.id,
                deviceIDs: dashboard.deviceIDs,
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

        do {
            try await shareQueue.purge(
                expiredBefore: Date().addingTimeInterval(-24 * 60 * 60)
            )
            let pending = try await shareQueue.requests()
                .filter { $0.instanceID == activeInstance.id }

            for request in pending {
                let submitting = request.updating(
                    status: .submitting,
                    error: nil
                )
                try await shareQueue.update(submitting)

                do {
                    let data = try await shareQueue.imageData(for: submitting)
                    let job = try await liveClient.sendImage(
                        data: data,
                        fileName: submitting.fileName,
                        contentType: submitting.contentType,
                        fit: submitting.fit,
                        deviceIDs: submitting.deviceIDs,
                        overrideQuietHours: submitting.overrideQuietHours,
                        idempotencyKey: submitting.idempotencyKey,
                        instance: activeInstance
                    )
                    await rememberActivityThumbnail(
                        imageData: data,
                        for: job,
                        instanceID: activeInstance.id
                    )
                    if !jobs.contains(where: { $0.id == job.id }) {
                        jobs.insert(job, at: 0)
                    }
                    try await shareQueue.remove(submitting)
                    await persistSnapshot(showErrors: false)
                } catch {
                    try? await shareQueue.update(
                        submitting.updating(
                            status: .failed,
                            error: error.localizedDescription
                        )
                    )
                    if let clientError = error as? TesseraeClientError,
                       clientError == .unauthorized
                            || clientError == .missingCredential
                    {
                        await handleConnectionError(clientError)
                        return
                    }
                }
            }
        } catch {
            connectionNotice = error.localizedDescription
        }
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
                incoming: snapshot.jobs
            )
            await reloadActivityThumbnails(instanceID: activeInstance.id)
            await persistSnapshot(showErrors: false)

            for job in jobs where incomingNonterminalIDs.contains(job.id) {
                await updateUntilTerminal(job, instance: activeInstance)
            }
            await retryPendingSharedImages()
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

    func loadDisplayPreview(_ display: DisplaySummary) async {
        guard supportsPreviews, let instance = activeInstance else {
            return
        }
        let previous = displayPreviews[display.id] ?? .idle
        guard previous.phase != .loading else {
            return
        }
        displayPreviews[display.id] = PreviewImageState(
            data: previous.data,
            eTag: previous.eTag,
            phase: .loading
        )

        do {
            let result = try await activeClient.fetchDevicePreview(
                id: display.id,
                ifNoneMatch: previous.data == nil ? nil : previous.eTag,
                instance: instance
            )
            guard activeInstance?.id == instance.id, !Task.isCancelled else {
                return
            }
            apply(
                result,
                previous: previous,
                to: &displayPreviews,
                key: display.id
            )
        } catch is CancellationError {
            finishCancelledPreview(
                previous: previous,
                in: &displayPreviews,
                key: display.id
            )
        } catch {
            finishFailedPreview(
                previous: previous,
                in: &displayPreviews,
                key: display.id
            )
        }
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

    private func updateUntilTerminal(_ acceptedJob: PushJob, instance: TesseraeInstance) async {
        var current = acceptedJob
        for _ in 0..<8 where !current.isTerminal {
            do {
                current = try await activeClient.fetchJob(id: current.id, instance: instance)
                if let index = jobs.firstIndex(where: { $0.id == current.id }) {
                    jobs[index] = current
                }
                await persistSnapshot(showErrors: false)
                if !current.isTerminal {
                    try await Task.sleep(for: .milliseconds(350))
                }
            } catch {
                await presentOperationError(error)
                return
            }
        }
        if current.isTerminal {
            previewGeneration &+= 1
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
        activityThumbnailData = [:]
        displayPreviews = [:]
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
            activityThumbnailData = [:]
            displayPreviews = [:]
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

    private func persistSnapshot(showErrors: Bool = true) async {
        guard
            connectionMode == .live,
            let activeInstance
        else {
            return
        }
        do {
            try await stateStore.save(
                CompanionSnapshot(
                    activeInstance: activeInstance,
                    capabilities: capabilities,
                    displays: displays,
                    dashboards: dashboards,
                    jobs: jobs
                )
            )
        } catch {
            if showErrors {
                lastError = error.localizedDescription
            }
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
