import Foundation
import Darwin
import CryptoKit
import TesseraeKit

enum AppConfiguration {
    static var cloudIssuer: URL {
#if DEBUG
        if let fixture = systemFixture { return URL(string: fixture.issuer)! }
        if hasSystemFixture { return URL(string: "http://127.0.0.1:1")! }
        if let raw = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_ISSUER"],
           let url = URL(string: raw), let service = try? TesseraeKit.ConnectionIdentity.canonicalService(url) { return service }
#endif
        return URL(string: Bundle.main.object(forInfoDictionaryKey: "TesseraeCloudIssuer") as? String
            ?? "https://cloud.tesserae.ink")!
    }

    static func cloudBrowserURL(_ url: URL) -> URL {
#if DEBUG
        if let raw = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_BROWSER_ENTRY"],
           var entry = URLComponents(string: raw), let original = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            entry.queryItems = original.queryItems
            if let result = entry.url { return result }
        }
#endif
        return url
    }

    static func cloudSetupURL(issuer: URL) -> URL {
        var parts = URLComponents(url: issuer.appending(path: "app/"), resolvingAgainstBaseURL: false)!
        parts.fragment = "/setup"
        return parts.url!
    }

    static var cloudReadTestTransport: (any TesseraeHTTPTransporting)? {
#if DEBUG
        let sharedProxy = systemFixture?.proxy == true
        if cloudIssuer.scheme == "http", cloudIssuer.host == "127.0.0.1", cloudIssuer.port == 8877,
           cloudIssuer.path.isEmpty,
           let raw = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_READ_PROXY"]
                ?? ProcessInfo.processInfo.environment["TESSERAE_CLOUD_SUBMISSION_PROXY"]
                ?? (sharedProxy ? "http://127.0.0.1:8882" : nil),
           let proxy = URL(string: raw), proxy.scheme == "http", proxy.host == "127.0.0.1",
           proxy.port == 8882, proxy.query == nil, proxy.fragment == nil,
           proxy.user == nil, proxy.password == nil, ["", "/"].contains(proxy.path) {
            return CloudReadFaultTransport(issuer: cloudIssuer, proxy: proxy,
                interceptsReads: sharedProxy || ProcessInfo.processInfo.environment["TESSERAE_CLOUD_READ_PROXY"] != nil,
                interceptsSubmissions: sharedProxy || ProcessInfo.processInfo.environment["TESSERAE_CLOUD_SUBMISSION_PROXY"] != nil,
                interceptsOAuth: sharedProxy)
        }
#endif
        return nil
    }
    static let bundleIdentifier = Bundle.main.bundleIdentifier
        ?? "com.charmmmz.tesseraecompanion"

    static var keychainService: String {
        let base = "com.charmmmz.tesseraecompanion.credentials"
#if DEBUG
        if let namespace = cloudTestNamespace { return base + ".tests." + namespace }
#endif
        return base
    }

#if DEBUG
    static func recordSystemInput(decision: UUID, data: Data, contentType: String, recipe: CloudPhotoRecipe,
                                  deviceIDs: [String], sourceKind: String, requestedSeconds: Double?, outputRevision: UUID?) {
        guard let fixture = systemFixture, let root = sharedContainerURL,
              root.lastPathComponent == fixture.namespace else { return }
        let directory = root.appending(path: "Diagnostics/\(decision.uuidString)")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appending(path: "committed-still")
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let recipeJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(recipe))
            var row: [String: Any] = ["decision": decision.uuidString, "pid": ProcessInfo.processInfo.processIdentifier,
                "contentType": contentType, "sourceKind": sourceKind, "deviceIDs": deviceIDs,
                "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(), "recipe": recipeJSON]
            if let requestedSeconds { row["requestedSeconds"] = requestedSeconds }
            if let outputRevision { row["outputRevision"] = outputRevision.uuidString }
            try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]).write(to: directory.appending(path: "committed.json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { }
    }

    static func recordSystemDiagnostic(_ stage: String) {
        guard let fixture = systemFixture, let root = sharedContainerURL,
              root.lastPathComponent == fixture.namespace else { return }
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return }
        let row: [String: Any] = ["stage": stage, "pid": ProcessInfo.processInfo.processIdentifier,
            "uptime": ProcessInfo.processInfo.systemUptime, "physicalFootprintBytes": info.phys_footprint,
            "residentBytes": info.resident_size]
        let directory = root.appending(path: "Diagnostics")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
            try data.write(to: directory.appending(path: UUID().uuidString + ".json"),
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { }
    }

    private struct SystemFixture: Codable {
        let namespace: String
        let issuer: String
        let proxy: Bool
    }
    private static var fixtureURL: URL? {
        guard let group = appGroupIdentifier,
              let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group) else { return nil }
        return container.appending(path: "CloudSystemEntryTest.json")
    }
    private static func validNamespace(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 80 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
    private static var hasSystemFixture: Bool {
        ProcessInfo.processInfo.environment["TESSERAE_SYSTEM_ENTRY_FIXTURE"] == "1"
            || (fixtureURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false)
    }
    private static var systemFixture: SystemFixture? {
        guard let url = fixtureURL else { return nil }
        let environment = ProcessInfo.processInfo.environment
        if environment["TESSERAE_SYSTEM_ENTRY_FIXTURE_CLEAR"] == "1" {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        if environment["TESSERAE_SYSTEM_ENTRY_FIXTURE"] == "1",
           let namespace = environment["TESSERAE_CLOUD_TEST_NAMESPACE"], validNamespace(namespace), namespace.hasPrefix("a4-"),
           environment["TESSERAE_CLOUD_ISSUER"] == "http://127.0.0.1:8877" {
            let fixture = SystemFixture(namespace: namespace, issuer: "http://127.0.0.1:8877",
                                        proxy: environment["TESSERAE_SYSTEM_ENTRY_PROXY"] == "1")
            guard let data = try? JSONEncoder().encode(fixture),
                  (try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])) != nil else { return nil }
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return fixture
        }
        guard let data = try? Data(contentsOf: url), data.count <= 4_096,
              let fixture = try? JSONDecoder().decode(SystemFixture.self, from: data),
              fixture.namespace.hasPrefix("a4-"), validNamespace(fixture.namespace),
              fixture.issuer == "http://127.0.0.1:8877" else { return nil }
        return fixture
    }
    private static var cloudTestNamespace: String? {
        if let value = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_TEST_NAMESPACE"], validNamespace(value) { return value }
        if let fixture = systemFixture { return fixture.namespace }
        return hasSystemFixture ? "invalid-system-fixture" : nil
    }
#endif

    static let appGroupIdentifier = Bundle.main.object(
        forInfoDictionaryKey: "TesseraeAppGroupIdentifier"
    ) as? String

    static var stateSuiteName: String? {
#if DEBUG
        if let namespace = cloudTestNamespace { return appGroupIdentifier.map { $0 + ".tests." + namespace } }
#endif
        return appGroupIdentifier
    }

    static var sharedContainerURL: URL? {
        guard let appGroupIdentifier else { return nil }
        let container = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        )
#if DEBUG
        if let namespace = cloudTestNamespace { return container?.appending(path: "CloudTests/\(namespace)") }
#endif
        return container
    }

    static let appVersion = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "0.1.0"

    static let keychainAccessGroup: String? = {
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

    static var installationID: String {
        let key = "TesseraeCompanionInstallationID"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let created = UUID().uuidString
        UserDefaults.standard.set(created, forKey: key)
        return created
    }
}
