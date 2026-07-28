import SwiftUI
import TesseraeKit

@main
@MainActor
struct TesseraeCompanionApp: App {
    @State private var model: AppModel

    init() {
        let credentials: any CredentialStoring
        let stateStore: any CompanionStateStoring
        let shareQueue: any ShareQueueStoring
        let activityThumbnails: any ActivityThumbnailStoring
        let discovery: any TesseraeDiscovering
#if DEBUG
        if ProcessInfo.processInfo.environment[
            "TESSERAE_USE_IN_MEMORY_CREDENTIALS"
        ] == "1" {
            credentials = InMemoryCredentialStore()
            stateStore = InMemoryCompanionStateStore()
            shareQueue = InMemoryShareQueueStore()
            activityThumbnails = InMemoryActivityThumbnailStore()
            discovery = StaticDiscoveryService(results: [])
        } else {
            credentials = KeychainCredentialStore(
                service: AppConfiguration.keychainService,
                accessGroup: AppConfiguration.keychainAccessGroup
            )
            stateStore = UserDefaultsCompanionStateStore(
                suiteName: AppConfiguration.appGroupIdentifier
            )
            shareQueue = FileShareQueueStore(
                directoryURL: AppConfiguration.sharedContainerURL
            )
            activityThumbnails = FileActivityThumbnailStore(
                directoryURL: AppConfiguration.sharedContainerURL
            )
            discovery = BonjourDiscoveryService()
        }
#else
        credentials = KeychainCredentialStore(
            service: AppConfiguration.keychainService,
            accessGroup: AppConfiguration.keychainAccessGroup
        )
        stateStore = UserDefaultsCompanionStateStore(
            suiteName: AppConfiguration.appGroupIdentifier
        )
        shareQueue = FileShareQueueStore(
            directoryURL: AppConfiguration.sharedContainerURL
        )
        activityThumbnails = FileActivityThumbnailStore(
            directoryURL: AppConfiguration.sharedContainerURL
        )
        discovery = BonjourDiscoveryService()
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
                credentials: credentials,
                stateStore: stateStore,
                shareQueue: shareQueue,
                activityThumbnails: activityThumbnails,
                discovery: discovery
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(TesseraeTheme.accent)
                .preferredColorScheme(uiTestColorScheme)
        }
    }

    private var uiTestColorScheme: ColorScheme? {
#if DEBUG
        switch ProcessInfo.processInfo.environment[
            "TESSERAE_UI_TEST_COLOR_SCHEME"
        ] {
        case "light":
            .light
        case "dark":
            .dark
        default:
            nil
        }
#else
        nil
#endif
    }
}
