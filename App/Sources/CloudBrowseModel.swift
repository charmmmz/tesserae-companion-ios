import Foundation
import Observation
import TesseraeKit

@MainActor @Observable
final class CloudBrowseModel {
    enum Preview: Equatable {
        case loading, image(Data), missing, unavailable(String)
    }
    let client: CloudReadClient
    var fence: ConnectionFence { client.fence }
    private(set) var snapshot: CloudBootstrap?
    private(set) var fetchedAt: Date?
    private(set) var isLoading = false
    private(set) var problem: String?
    private(set) var needsSignIn = false
    private(set) var isRestricted = false
    private(set) var previews: [String: Preview] = [:]
    private(set) var verifiedDetails: Set<String> = []
    private var previewDates: [String: Date] = [:]
    private var pageVersions: [String: Date] = [:]
    private var visibleDetails: Set<String> = []
    private var generation = UUID()
    private var isActive = true
    private var refreshTask: Task<Void, Never>?
    private var previewTasks: [String: Task<Void, Never>] = [:]
    private(set) var retryAfter: Date?
    private let now: @Sendable () -> Date

    init(client: CloudReadClient, now: @escaping @Sendable () -> Date = { Date() }) {
        self.client = client; self.now = now
    }
    var devices: [CloudDevice] {
        snapshot?.devices ?? []
    }
    var pages: [CloudPage] {
        snapshot?.pages ?? []
    }
    func previewVersion(id: String, isDevice: Bool) -> String? {
        if isDevice {
            guard let device = devices.first(where: { $0.id == id }) else { return nil }
            return device.frame.map { $0.digest + ":" + String($0.renderedAt.timeIntervalSince1970) } ?? "no-frame"
        }
        return pages.first(where: { $0.id == id }).map { String($0.updatedAt.timeIntervalSince1970) }
    }
    func invalidate() {
        isActive = false
        generation = UUID()
        refreshTask?.cancel(); refreshTask = nil
        previewTasks.values.forEach { $0.cancel() }; previewTasks = [:]
        snapshot = nil; previews = [:]; fetchedAt = nil; verifiedDetails = []
        visibleDetails = []
        previewDates = [:]; pageVersions = [:]
        isLoading = false; problem = nil
    }
    func refresh() async {
        guard isActive else { return }
        guard retryAfter.map({ $0 <= now() }) != false else { return }
        if let refreshTask { await refreshTask.value; return }
        let generation = generation
        isLoading = true
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let value = try await client.bootstrap()
                guard self.generation == generation, !Task.isCancelled else { return }
                snapshot = value; fetchedAt = now(); problem = nil
                previews = previews.filter { key, _ in
                    value.devices.contains { key == "device:\($0.id)" } || value.pages.contains {
                        key == "page:\($0.id)" && pageVersions[key] == $0.updatedAt
                    }
                }
                let cachedKeys = Set(previews.keys)
                previewDates = previewDates.filter { cachedKeys.contains($0.key) }
                pageVersions = pageVersions.filter { cachedKeys.contains($0.key) }
                needsSignIn = false; isRestricted = false; retryAfter = nil
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                handle(error)
            }
            guard self.generation == generation else { return }
            isLoading = false; refreshTask = nil
        }
        refreshTask = task
        await task.value
    }
    func openDetail(id: String, isDevice: Bool, reuseCached: Bool = true) async {
        guard isActive else { return }
        guard retryAfter.map({ $0 <= now() }) != false else { return }
        let key = Self.key(id, isDevice)
        visibleDetails.insert(key)
        trimPageCache()
        if let task = previewTasks[key] { await task.value; return }
        let generation = generation
        let cached = previews[key]
        verifiedDetails.remove(key)
        previews[key] = .loading
        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let exists: Bool
                var pageVersion: Date?
                if isDevice {
                    let values = try await client.devices()
                    guard self.generation == generation, !Task.isCancelled else { return }
                    if let current = snapshot {
                        snapshot = CloudBootstrap(account: current.account, devices: values, pages: current.pages)
                    }
                    exists = values.contains { $0.id == id }
                } else {
                    let values = try await client.pages()
                    guard self.generation == generation, !Task.isCancelled else { return }
                    if let current = snapshot {
                        snapshot = CloudBootstrap(account: current.account, devices: current.devices, pages: values)
                    }
                    exists = values.contains { $0.id == id }
                    pageVersion = values.first { $0.id == id }?.updatedAt
                }
                guard exists else { previews[key] = .unavailable(String(localized: "This item is no longer available.")); previewTasks[key] = nil; return }
                verifiedDetails.insert(key)
                let version = previewVersion(id: id, isDevice: isDevice)
                // Frames are no-store: never reuse a frame across detail openings.
                if !isDevice, reuseCached, case .image = cached,
                   previewDates[key].map({ now().timeIntervalSince($0) < 60 }) == true,
                   pageVersions[key] == pageVersion {
                    previews[key] = cached
                } else {
                    let data = try await (isDevice ? client.devicePreview(id: id) : client.pagePreview(id: id))
                    guard self.generation == generation, !Task.isCancelled else { return }
                    guard previewVersion(id: id, isDevice: isDevice) == version else {
                        previews[key] = .unavailable(String(localized: "This preview changed. Refresh to load the latest image."))
                        previewTasks[key] = nil
                        return
                    }
                    previews[key] = data.map(Preview.image) ?? .missing
                    previewDates[key] = now()
                    if let pageVersion { pageVersions[key] = pageVersion }
                    trimPageCache()
                }
            } catch {
                guard self.generation == generation, !Task.isCancelled else { return }
                handle(error)
                if !needsSignIn && !isRestricted {
                    previews[key] = .unavailable(Self.message(error))
                }
            }
            if self.generation == generation { previewTasks[key] = nil }
        }
        previewTasks[key] = task
        await task.value
    }
    func closeDetail(id: String, isDevice: Bool) {
        let key = Self.key(id, isDevice)
        previewTasks[key]?.cancel(); previewTasks[key] = nil
        visibleDetails.remove(key)
        verifiedDetails.remove(key)
        if isDevice { previews[key] = nil; previewDates[key] = nil }
        trimPageCache()
    }
    static func key(_ id: String, _ isDevice: Bool) -> String { "\(isDevice ? "device" : "page"):\(id)" }
    private func trimPageCache() {
        let inactive = previews.keys.filter { $0.hasPrefix("page:") && !visibleDetails.contains($0) }
            .sorted { (previewDates[$0] ?? .distantPast) < (previewDates[$1] ?? .distantPast) }
        let expired = inactive.filter { now().timeIntervalSince(previewDates[$0] ?? .distantPast) >= 60 }
        let surviving = inactive.filter { !expired.contains($0) }
        for key in expired + surviving.prefix(max(0, surviving.count - 12)) {
            previews[key] = nil; previewDates[key] = nil; pageVersions[key] = nil
        }
    }
    private func handle(_ error: Error) {
        problem = Self.message(error)
        switch error {
        case CloudReadError.unauthorized, ConnectionError.authorizationRequired,
             ConnectionError.rotationOutcomeUnknown, ConnectionError.signedOut, ConnectionError.sessionChanged:
            clearPrivateState(); needsSignIn = true
        case CloudReadError.forbidden, ConnectionError.accessRestricted:
            clearPrivateState(); isRestricted = true
        case CloudReadError.retryLater(let seconds):
            if let seconds { retryAfter = now().addingTimeInterval(seconds) }
        default: break
        }
    }
    private func clearPrivateState() {
        generation = UUID()
        refreshTask?.cancel(); refreshTask = nil
        previewTasks.values.forEach { $0.cancel() }; previewTasks = [:]
        snapshot = nil; previews = [:]; fetchedAt = nil; verifiedDetails = []
        visibleDetails = []
        previewDates = [:]; pageVersions = [:]
        isLoading = false
    }
    static func message(_ error: Error) -> String {
        switch error {
        case CloudReadError.unauthorized, ConnectionError.authorizationRequired, ConnectionError.signedOut:
            String(localized: "Sign in again to read this Cloud connection.")
        case CloudReadError.forbidden, ConnectionError.accessRestricted:
            String(localized: "Access to this Cloud tenant is unavailable. Choose another connection or sign in again.")
        case CloudReadError.limitReached: String(localized: "This Cloud plan limit has been reached.")
        case CloudReadError.retryLater: String(localized: "Cloud is busy. Wait before trying again.")
        case CloudReadError.unavailable: String(localized: "Cloud is temporarily unavailable. Try again later.")
        case CloudReadError.notFound: String(localized: "This item is no longer available.")
        case CloudReadError.invalidResponse: String(localized: "Cloud returned an unexpected response.")
        default: error.localizedDescription
        }
    }
}
