import SwiftUI
import TesseraeKit

@main
@MainActor
struct TesseraeCompanionApp: App {
    @State private var model: AppModel

    init() {
        let credentials: any CredentialStoring
#if DEBUG
        if ProcessInfo.processInfo.environment[
            "TESSERAE_USE_IN_MEMORY_CREDENTIALS"
        ] == "1" {
            credentials = InMemoryCredentialStore()
        } else {
            credentials = KeychainCredentialStore(
                service: AppConfiguration.bundleIdentifier,
                accessGroup: AppConfiguration.keychainAccessGroup
            )
        }
#else
        credentials = KeychainCredentialStore(
            service: AppConfiguration.bundleIdentifier,
            accessGroup: AppConfiguration.keychainAccessGroup
        )
#endif
        let liveClient = LiveTesseraeClient(
            credentials: credentials,
            identity: TesseraeClientIdentity(
                appVersion: AppConfiguration.appVersion,
                installationID: AppConfiguration.installationID
            )
        )
        _model = State(
            initialValue: AppModel(
                liveClient: liveClient,
                demoClient: MockTesseraeClient(),
                credentials: credentials
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(TesseraeTheme.accent)
        }
    }
}
