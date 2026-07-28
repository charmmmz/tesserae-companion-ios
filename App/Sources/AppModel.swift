import Foundation
import Observation
import TesseraeKit

@MainActor
@Observable
final class AppModel {
    private let client: any TesseraeServing
    private let credentials: any CredentialStoring

    var activeInstance: TesseraeInstance?
    var displays: [DisplaySummary] = []
    var dashboards: [DashboardSummary] = []
    var jobs: [PushJob] = []
    var favoriteDashboardIDs: Set<String> = []
    var activeOperationIDs: Set<String> = []
    var isRefreshing = false
    var lastError: String?

    init(client: any TesseraeServing, credentials: any CredentialStoring) {
        self.client = client
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

        activeOperationIDs.insert("pair")
        defer { activeOperationIDs.remove("pair") }

        do {
            _ = try await client.probe(baseURL: resolvedURL)
            let session = try await client.pair(
                baseURL: resolvedURL,
                code: "482193",
                clientName: "Demo iPhone"
            )
            await credentials.save(token: session.token, for: session.instance.id)
            activeInstance = session.instance
            favoriteDashboardIDs = ["pantry"]
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
            displays = try await client.fetchDisplays(instance: activeInstance)
            dashboards = try await client.fetchDashboards(instance: activeInstance)
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
            let job = try await client.pushDashboard(
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
        deviceIDs: [String]
    ) async -> Bool {
        guard let activeInstance else { return false }
        activeOperationIDs.insert("image")
        defer { activeOperationIDs.remove("image") }

        do {
            let job = try await client.sendImage(
                data: data,
                fileName: "Shared Photo",
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
                current = try await client.fetchJob(id: current.id, instance: instance)
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
        if let activeInstance {
            await credentials.removeToken(for: activeInstance.id)
        }
        activeInstance = nil
        displays = []
        dashboards = []
        jobs = []
        favoriteDashboardIDs = []
    }
}
