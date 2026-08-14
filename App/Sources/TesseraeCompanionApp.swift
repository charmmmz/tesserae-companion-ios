import SwiftUI
import TesseraeKit

@main
@MainActor
struct TesseraeCompanionApp: App {
    @State private var model: AppModel
    @State private var remindersBridgeModel: RemindersBridgeModel
    @State private var galleryUploads: GalleryUploadCoordinator
    @State private var messageCenter: TesseraeMessageCenter

    init() {
        let credentials: any CredentialStoring
        let stateStore: any CompanionStateStoring
        let sendPreferences: any CompanionSendPreferencesStoring
        let shareQueue: any ShareQueueStoring
        let linkShareQueue: any LinkShareQueueStoring
        let activityThumbnails: any ActivityThumbnailStoring
        let discovery: any TesseraeDiscovering
        let demoLatency: Duration
        let demoLineupIntent: LineupIntent
#if DEBUG
        if let galleryGridMode = ProcessInfo.processInfo.environment[
            "TESSERAE_UI_TEST_GALLERY_GRID_MODE"
        ] {
            UserDefaults.standard.set(
                galleryGridMode,
                forKey: "gallery.grid.mode"
            )
        }
        if let rawGalleryColumns = ProcessInfo.processInfo.environment[
            "TESSERAE_UI_TEST_GALLERY_GRID_COLUMNS"
        ], let galleryColumns = Int(rawGalleryColumns) {
            UserDefaults.standard.set(
                galleryColumns,
                forKey: "gallery.grid.columns"
            )
        }
        if let rawLatency = ProcessInfo.processInfo.environment[
            "TESSERAE_UI_TEST_DEMO_LATENCY_MS"
        ], let milliseconds = Int64(rawLatency), milliseconds >= 0 {
            demoLatency = .milliseconds(milliseconds)
        } else {
            demoLatency = .milliseconds(180)
        }
        demoLineupIntent = ProcessInfo.processInfo.environment[
            "TESSERAE_UI_TEST_LINEUP_INTENT"
        ].flatMap(LineupIntent.init(rawValue:)) ?? .manual
        if ProcessInfo.processInfo.environment[
            "TESSERAE_USE_IN_MEMORY_CREDENTIALS"
        ] == "1" {
            credentials = InMemoryCredentialStore()
            stateStore = InMemoryCompanionStateStore()
            sendPreferences = InMemoryCompanionSendPreferencesStore()
            shareQueue = InMemoryShareQueueStore()
            linkShareQueue = InMemoryLinkShareQueueStore()
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
            sendPreferences = UserDefaultsCompanionSendPreferencesStore(
                suiteName: AppConfiguration.appGroupIdentifier
            )
            shareQueue = FileShareQueueStore(
                directoryURL: AppConfiguration.sharedContainerURL
            )
            linkShareQueue = FileLinkShareQueueStore(
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
        sendPreferences = UserDefaultsCompanionSendPreferencesStore(
            suiteName: AppConfiguration.appGroupIdentifier
        )
        shareQueue = FileShareQueueStore(
            directoryURL: AppConfiguration.sharedContainerURL
        )
        linkShareQueue = FileLinkShareQueueStore(
            directoryURL: AppConfiguration.sharedContainerURL
        )
        activityThumbnails = FileActivityThumbnailStore(
            directoryURL: AppConfiguration.sharedContainerURL
        )
        discovery = BonjourDiscoveryService()
        demoLatency = .milliseconds(180)
        demoLineupIntent = .manual
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
                demoClient: MockTesseraeClient(
                    latency: demoLatency,
                    lineupIntent: demoLineupIntent
                ),
                credentials: credentials,
                stateStore: stateStore,
                sendPreferences: sendPreferences,
                shareQueue: shareQueue,
                linkShareQueue: linkShareQueue,
                activityThumbnails: activityThumbnails,
                discovery: discovery
            )
        )
        _remindersBridgeModel = State(initialValue: RemindersBridgeModel())
        _galleryUploads = State(initialValue: GalleryUploadCoordinator())
        _messageCenter = State(initialValue: TesseraeMessageCenter())
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(remindersBridgeModel)
                .environment(galleryUploads)
                .environment(messageCenter)
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

#if DEBUG
@MainActor
struct TesseraePreviewHost<Content: View>: View {
    @State private var model: AppModel
    @State private var galleryUploads = GalleryUploadCoordinator()
    @State private var messageCenter = TesseraeMessageCenter()
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        let client = MockTesseraeClient(latency: .milliseconds(0))
        _model = State(
            initialValue: AppModel(
                liveClient: client,
                demoClient: client,
                credentials: InMemoryCredentialStore(),
                stateStore: InMemoryCompanionStateStore(),
                sendPreferences: InMemoryCompanionSendPreferencesStore(),
                shareQueue: InMemoryShareQueueStore(),
                linkShareQueue: InMemoryLinkShareQueueStore(),
                activityThumbnails: InMemoryActivityThumbnailStore(),
                discovery: StaticDiscoveryService(results: [])
            )
        )
        self.content = content()
    }

    var body: some View {
        content
            .environment(model)
            .environment(galleryUploads)
            .environment(messageCenter)
            .tint(TesseraeTheme.accent)
            .task {
                guard model.connectionMode != .demo else { return }
                await model.connectDemo()
            }
    }
}
#endif
