import Foundation
import TesseraeKit

enum AppConfiguration {
    static var cloudIssuer: URL {
#if DEBUG
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
        if cloudIssuer.scheme == "http", cloudIssuer.host == "127.0.0.1", cloudIssuer.port == 8877,
           cloudIssuer.path.isEmpty,
           let raw = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_READ_PROXY"],
           let proxy = URL(string: raw), proxy.scheme == "http", proxy.host == "127.0.0.1",
           proxy.port == 8882, proxy.query == nil, proxy.fragment == nil,
           proxy.user == nil, proxy.password == nil, ["", "/"].contains(proxy.path) {
            return CloudReadFaultTransport(issuer: cloudIssuer, proxy: proxy)
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
    private static var cloudTestNamespace: String? {
        guard let value = ProcessInfo.processInfo.environment["TESSERAE_CLOUD_TEST_NAMESPACE"],
              !value.isEmpty, value.count <= 80,
              value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        return value
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
