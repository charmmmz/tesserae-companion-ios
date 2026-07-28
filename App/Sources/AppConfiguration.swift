import Foundation

enum AppConfiguration {
    static let bundleIdentifier = Bundle.main.bundleIdentifier
        ?? "com.charmmmz.tesseraecompanion"

    static let keychainService = "com.charmmmz.tesseraecompanion.credentials"

    static let appGroupIdentifier = Bundle.main.object(
        forInfoDictionaryKey: "TesseraeAppGroupIdentifier"
    ) as? String

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
