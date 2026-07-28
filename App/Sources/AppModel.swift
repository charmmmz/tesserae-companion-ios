import Foundation
import Observation
import TesseraeKit

@MainActor
@Observable
final class AppModel {
    enum ConnectionMode {
        case live
        case demo
    }

    private let liveClient: any TesseraeServing
    private let demoClient: any TesseraeServing
    private var activeClient: any TesseraeServing
    private let credentials: any CredentialStoring

    var activeInstance: TesseraeInstance?
    var connectionMode: ConnectionMode?
    var capabilities: ServerCapabilities?
    var displays: [DisplaySummary] = []
    var dashboards: [DashboardSummary] = []
    var jobs: [PushJob] = []
    var favoriteDashboardIDs: Set<String> = []
    var activeOperationIDs: Set<String> = []
    var isRefreshing = false
    var lastError: String?

    init(
        liveClient: any TesseraeServing,
        demoClient: any TesseraeServing,
        credentials: any CredentialStoring
    ) {
        self.liveClient = liveClient
        self.demoClient = demoClient
        activeClient = liveClient
        self.credentials = credentials
    }

    var sortedDashboards: [DashboardSummary] {
        dashboards.sorted { lhs, rhs in
            let lhsFavorite = favoriteDashboardIDs.contains(lhs.id)
            let rhsFavorite = favoriteDashboardIDs.contains(rhs.id)
            if lhsFavorite != rhsFavorite {
                return lhsFavorite
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func connectDemo(baseURL: URL? = nil) async {
        let fallbackURL = URL(string: "http://tesserae.local:8765")
        guard let resolvedURL = baseURL ?? fallbackURL else {
            lastError = "The server URL is invalid."
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
            self.capabilities = capabilities
            activeInstance = session.instance
            favoriteDashboardIDs = mode == .demo ? ["pantry"] : []
            await refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func refresh() async {
        guard let activeInstance else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            displays = try await activeClient.fetchDisplays(instance: activeInstance)
            dashboards = try await activeClient.fetchDashboards(instance: activeInstance)
        } catch {
            lastError = error.localizedDescription
        }
    }

    func toggleFavorite(_ dashboardID: String) {
        if favoriteDashboardIDs.contains(dashboardID) {
            favoriteDashboardIDs.remove(dashboardID)
        } else {
            favoriteDashboardIDs.insert(dashboardID)
        }
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
            await updateUntilTerminal(job, instance: activeInstance)
        } catch {
            lastError = error.localizedDescription
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
            jobs.insert(job, at: 0)
            await updateUntilTerminal(job, instance: activeInstance)
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func displayNames(for ids: [String]) -> String {
        let names = ids.compactMap { id in displays.first(where: { $0.id == id })?.name }
        return names.isEmpty ? "No displays" : names.joined(separator: ", ")
    }

    private func updateUntilTerminal(_ acceptedJob: PushJob, instance: TesseraeInstance) async {
        var current = acceptedJob
        for _ in 0..<8 where !current.isTerminal {
            do {
                current = try await activeClient.fetchJob(id: current.id, instance: instance)
                if let index = jobs.firstIndex(where: { $0.id == current.id }) {
                    jobs[index] = current
                }
                if !current.isTerminal {
                    try await Task.sleep(for: .milliseconds(350))
                }
            } catch {
                lastError = error.localizedDescription
                return
            }
        }
    }

    func disconnect() async {
        var disconnectError: Error?
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
        }
        activeInstance = nil
        connectionMode = nil
        capabilities = nil
        displays = []
        dashboards = []
        jobs = []
        favoriteDashboardIDs = []
        activeClient = liveClient
        if let disconnectError {
            lastError = disconnectError.localizedDescription
        }
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
}
