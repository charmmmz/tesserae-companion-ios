import SwiftUI
import TesseraeKit

@main
@MainActor
struct TesseraeCompanionApp: App {
    @State private var model: AppModel
    @State private var connectionHost: ConnectionHost
    @State private var remindersBridgeModel: RemindersBridgeModel
    @State private var healthBridgeModel: HealthBridgeModel
    @State private var galleryUploads: GalleryUploadCoordinator
    @State private var messageCenter: TesseraeMessageCenter
    @State private var nearbyDevices: NearbyDeviceManager
    @State private var setupNetworks: SetupNetworkStore

    init() {
        let credentials: any CredentialStoring
        var stateStore: any CompanionStateStoring
        let sendPreferences: any CompanionSendPreferencesStoring
        let shareQueue: any ShareQueueStoring
        let linkShareQueue: any LinkShareQueueStoring
        let activityThumbnails: any ActivityThumbnailStoring
        let discovery: any TesseraeDiscovering
        let demoLatency: Duration
        let demoLineupIntent: LineupIntent
        let demoDisplayNames: [String: String]
        let demoImageSendErrors: [TesseraeClientError]
#if DEBUG
        demoImageSendErrors = ProcessInfo.processInfo.environment[
            "TESSERAE_UI_TEST_IMAGE_SEND_FAILURE_ONCE"
        ] == "1" ? [.server(code: "send_failed", message: "Test send failed. Try again.", requestID: nil)] : []
        demoDisplayNames = ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_LONG_DISPLAY_NAMES"] == "1"
            ? ["picpak-kitchen": "厨房里的家庭共享信息显示屏 Kitchen Family Display — 东侧窗边",
               "e1004-desk": "工作书桌旁的日程与待办事项显示屏 Desk Planning Display — 第二工作区"]
            : [:]
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
                suiteName: AppConfiguration.stateSuiteName
            )
            sendPreferences = UserDefaultsCompanionSendPreferencesStore(
                suiteName: AppConfiguration.stateSuiteName, directoryURL: AppConfiguration.sharedContainerURL
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
            suiteName: AppConfiguration.stateSuiteName
        )
        sendPreferences = UserDefaultsCompanionSendPreferencesStore(
            suiteName: AppConfiguration.stateSuiteName, directoryURL: AppConfiguration.sharedContainerURL
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
        demoDisplayNames = [:]
        demoImageSendErrors = []
#endif
        let runtime = (credentials is InMemoryCredentialStore) ? nil : AppConfiguration.sharedContainerURL.map {
            ConnectionRuntime(directory: $0, suiteName: AppConfiguration.stateSuiteName,
                keychainService: AppConfiguration.keychainService, accessGroup: AppConfiguration.keychainAccessGroup,
                identity: TesseraeClientIdentity(appVersion: AppConfiguration.appVersion,
                                                 installationID: AppConfiguration.installationID), isPrimary: true,
                transport: AppConfiguration.cloudReadTestTransport)
        }
        if let runtime { stateStore = runtime.stateStore }
        let liveClient = runtime?.bootstrapClient() ?? ConnectionRuntime.localClient(credentials: credentials,
            identity: TesseraeClientIdentity(appVersion: AppConfiguration.appVersion,
                                             installationID: AppConfiguration.installationID))
        let appModel = AppModel(
                liveClient: liveClient,
                connectionRuntime: runtime,
                demoClient: MockTesseraeClient(
                    latency: demoLatency,
                    lineupIntent: demoLineupIntent,
                    displayNames: demoDisplayNames,
                    imageSendErrors: demoImageSendErrors
                ),
                credentials: credentials,
                stateStore: stateStore,
                sendPreferences: sendPreferences,
                shareQueue: shareQueue,
                linkShareQueue: linkShareQueue,
                activityThumbnails: activityThumbnails,
                discovery: discovery,
                displayOrderPreferences: DisplayOrderPreferences(
                    defaults: AppConfiguration.stateSuiteName
                        .flatMap(UserDefaults.init(suiteName:)) ?? .standard
                )
        )
        _model = State(initialValue: appModel)
        _connectionHost = State(initialValue: ConnectionHost(local: appModel, runtime: runtime,
            vault: CloudLoginVault(directory: AppConfiguration.sharedContainerURL
                ?? URL.applicationSupportDirectory.appending(path: "CloudLogin"),
                service: AppConfiguration.keychainService + ".oauth", accessGroup: AppConfiguration.keychainAccessGroup),
            sendPreferences: sendPreferences))
        _remindersBridgeModel = State(initialValue: RemindersBridgeModel())
        _healthBridgeModel = State(initialValue: HealthBridgeModel())
        _galleryUploads = State(initialValue: GalleryUploadCoordinator())
        _messageCenter = State(initialValue: TesseraeMessageCenter())
        _nearbyDevices = State(initialValue: NearbyDeviceManager(displayRecords: BluetoothDisplayStore(
            fileURL: ProcessInfo.processInfo.environment["TESSERAE_USE_IN_MEMORY_CREDENTIALS"] == "1"
                ? nil : BluetoothDisplayStore.defaultFileURL
        )))
        _setupNetworks = State(
            initialValue: SetupNetworkStore(
                credentials: KeychainCredentialStore(
                    service: AppConfiguration.keychainService + ".wifi",
                    accessGroup: AppConfiguration.keychainAccessGroup
                )
            )
        )
    }

    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                if ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_BLUETOOTH_SHARE"] == "1" {
                    BluetoothShareTestHost()
                } else { RootView() }
#else
                RootView()
#endif
            }
                .environment(model)
                .environment(connectionHost)
                .onOpenURL { url in Task { await connectionHost.receiveCloudCallback(url) } }
                .environment(remindersBridgeModel)
                .environment(healthBridgeModel)
                .environment(galleryUploads)
                .environment(messageCenter)
                .environment(nearbyDevices)
                .environment(setupNetworks)
                .tint(TesseraeTheme.accent)
                .preferredColorScheme(uiTestColorScheme)
                .tesseraeWindowMessageOverlay(center: messageCenter)
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
    @State private var nearbyDevices = NearbyDeviceManager(displayRecords: BluetoothDisplayStore(fileURL: nil))
    @State private var model: AppModel
    @State private var connectionHost: ConnectionHost
    @State private var remindersBridgeModel = RemindersBridgeModel()
    @State private var presentation = CompanionPresentation()
    @State private var galleryUploads = GalleryUploadCoordinator()
    @State private var messageCenter = TesseraeMessageCenter()
    @State private var healthBridgeModel = HealthBridgeModel()
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        let client = MockTesseraeClient(latency: .milliseconds(0))
        let previewModel = AppModel(
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
        _model = State(initialValue: previewModel)
        _connectionHost = State(initialValue: ConnectionHost(local: previewModel, runtime: nil,
            vault: CloudLoginVault(directory: .temporaryDirectory, service: "preview.cloud.oauth")))
        self.content = content()
    }

    var body: some View {
        content
            .environment(nearbyDevices)
            .environment(model)
            .environment(connectionHost)
            .environment(remindersBridgeModel)
            .environment(presentation)
            .environment(healthBridgeModel)
            .environment(galleryUploads)
            .environment(messageCenter)
            .tint(TesseraeTheme.accent)
            .task {
                guard model.connectionMode != .demo else { return }
                await connectionHost.connectDemo()
            }
    }
}
#endif
