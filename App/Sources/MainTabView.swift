import SwiftUI

private struct TesseraeSettingsActionKey: EnvironmentKey {
    static let defaultValue: @MainActor @Sendable () -> Void = {}
}

extension EnvironmentValues {
    var presentTesseraeSettings: @MainActor @Sendable () -> Void {
        get { self[TesseraeSettingsActionKey.self] }
        set { self[TesseraeSettingsActionKey.self] = newValue }
    }
}

struct TesseraeSettingsToolbarButton: View {
    let openSettings: @MainActor @Sendable () -> Void

    var body: some View {
        Button("Settings", systemImage: "gearshape") {
            openSettings()
        }
        .accessibilityIdentifier("root-settings")
    }
}

private enum AppTab: Hashable {
    case displays
    case dashboards
    case gallery
    case activity
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(GalleryUploadCoordinator.self) private var galleryUploads
    @Environment(TesseraeMessageCenter.self) private var messageCenter
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var selection: AppTab = .displays
    @State private var settingsPresented = false
    @State private var sendPresented = false
    @State private var uploadDetailsPresented = false

    var body: some View {
        tabsWithSendAction
            .environment(\.presentTesseraeSettings) {
                settingsPresented = true
            }
            .sheet(isPresented: $settingsPresented) {
                SettingsView()
            }
            .sheet(isPresented: $sendPresented) {
                RootSendSheet {
                    sendPresented = false
                }
            }
            .sheet(isPresented: $uploadDetailsPresented) {
                GalleryUploadDetailView()
            }
            .onChange(of: galleryUploads.hasUploads) { _, hasUploads in
                if !hasUploads {
                    uploadDetailsPresented = false
                }
            }
            .onChange(of: uploadDetailsPresented) { _, isPresented in
                galleryUploads.setDetailsPresented(isPresented)
            }
            .task {
#if DEBUG
                if ProcessInfo.processInfo.environment[
                    "TESSERAE_UI_TEST_GALLERY_UPLOAD_CAPSULE"
                ] == "1" {
                    galleryUploads.seedForUITesting()
                }
#endif
                synchronizeGalleryUploadMessage()
            }
            .onChange(of: galleryUploadMessageRevision) { _, _ in
                synchronizeGalleryUploadMessage()
            }
    }

    private var tabsWithSendAction: some View {
        tabs
            .overlay(alignment: .bottomTrailing) {
                sendActionButton
                    .padding(.trailing, sendActionTrailingPadding)
                    .padding(.bottom, sendActionBottomPadding)
            }
    }

    private var sendActionBottomPadding: CGFloat {
        horizontalSizeClass == .compact ? 62 : 20
    }

    private var sendActionTrailingPadding: CGFloat {
        horizontalSizeClass == .compact ? 18 : 24
    }

    private var rootContentIsVisible: Bool {
        !settingsPresented && !sendPresented && !uploadDetailsPresented
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            tabNavigation(title: "Displays") {
                DisplaysView(
                    isActive: selection == .displays && rootContentIsVisible
                )
            }
            .tabItem { Label("Displays", systemImage: "display") }
            .tag(AppTab.displays)

            tabNavigation(title: "Dashboards") {
                DashboardsView(
                    isActive: selection == .dashboards && rootContentIsVisible
                )
            }
            .tabItem { Label("Dashboards", systemImage: "rectangle.grid.2x2") }
            .tag(AppTab.dashboards)

            if model.supportsGallery {
                tabNavigation(title: "Library") {
                    GalleryView(
                        isActive: selection == .gallery && rootContentIsVisible
                    )
                }
                .tabItem {
                    Label("Library", systemImage: "photo.on.rectangle.angled")
                }
                .tag(AppTab.gallery)
            }

            tabNavigation(title: "Activity") {
                ActivityView(
                    isActive: selection == .activity && rootContentIsVisible
                )
            }
            .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
            .tag(AppTab.activity)
        }
    }

    private var sendActionButton: some View {
        Button {
            sendPresented = true
        } label: {
            Image(systemName: "paperplane.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 54, height: 54)
                .background(TesseraeTheme.accent, in: Circle())
                .overlay {
                    Circle()
                        .stroke(.white.opacity(0.22), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.24), radius: 12, y: 6)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send")
        .accessibilityHint("Opens the Send composer.")
        .accessibilityIdentifier("root-send-action")
    }

    private var galleryUploadMessageRevision: String {
        let counts = galleryUploads.counts
        return [
            galleryUploads.hasUploads ? "visible" : "hidden",
            galleryUploads.isWorking ? "working" : "idle",
            String(counts.total),
            String(counts.finished),
            String(counts.uploaded),
            String(counts.failed),
        ].joined(separator: "|")
    }

    private func synchronizeGalleryUploadMessage() {
        guard galleryUploads.hasUploads else {
            messageCenter.dismiss(id: "gallery.uploads")
            return
        }

        let counts = galleryUploads.counts
        let kind: TesseraeMessageKind
        let priority: TesseraeMessagePriority
        if galleryUploads.isWorking {
            let fraction = counts.finished == 0
                ? nil
                : Double(counts.finished) / Double(max(counts.total, 1))
            kind = .progress(fraction: fraction)
            priority = .normal
        } else if counts.failed > 0 {
            kind = .error
            priority = .critical
        } else {
            kind = .success
            priority = .normal
        }

        messageCenter.post(
            TesseraeMessage(
                id: "gallery.uploads",
                text: galleryUploads.capsuleTitle,
                kind: kind,
                lifetime: .persistent,
                priority: priority,
                accessibilityIdentifier: "gallery-upload-capsule",
                accessibilityHint: String(localized: "Show Upload Details"),
                tapAction: {
                    uploadDetailsPresented = true
                }
            )
        )
    }

    private func tabNavigation<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .navigationTitle(title)
        }
    }
}

private struct RootSendSheet: View {
    @State private var settingsPresented = false

    let close: () -> Void

    var body: some View {
        NavigationStack {
            SendView(prioritizesFramingGesture: true)
                .navigationTitle("Send")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") {
                            close()
                        }
                        .accessibilityIdentifier("root-send-close")
                    }
                }
        }
        .environment(\.presentTesseraeSettings) {
            settingsPresented = true
        }
        .sheet(isPresented: $settingsPresented) {
            SettingsView()
        }
        .tesseraeMessageCenterOverlay()
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
