import SwiftUI

@MainActor
@Observable
final class CompanionPresentation {
    enum Sheet: String, Identifiable {
        case settings, send, uploads
        var id: String { rawValue }
    }

    var sheet: Sheet?
}

struct TesseraeSettingsToolbarButton: View {
    @Environment(CompanionPresentation.self) private var presentation

    var body: some View {
        Button("Settings", systemImage: "gearshape") {
            presentation.sheet = .settings
        }
        .accessibilityIdentifier("root-settings")
    }
}

struct TesseraeSendToolbarButton: View {
    @Environment(CompanionPresentation.self) private var presentation

    var body: some View {
        Button("Send", systemImage: "paperplane.fill") {
            presentation.sheet = .send
        }
        .accessibilityHint("Opens the Send composer.")
        .accessibilityIdentifier("root-send-action")
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
    @State private var selection: AppTab = .displays
    @State private var presentation = CompanionPresentation()

    var body: some View {
        tabs
            .environment(presentation)
            .sheet(item: $presentation.sheet) { sheet in
                switch sheet {
                case .settings:
                    SettingsView()
                case .send:
                    SendComposerSheet { presentation.sheet = nil }
                case .uploads:
                    GalleryUploadDetailView()
                }
            }
            .onChange(of: galleryUploads.hasUploads) { _, hasUploads in
                if !hasUploads && presentation.sheet == .uploads {
                    presentation.sheet = nil
                }
            }
            .onChange(of: presentation.sheet) { _, sheet in
                galleryUploads.setDetailsPresented(sheet == .uploads)
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

    private var rootContentIsVisible: Bool {
        presentation.sheet == nil
    }

    private var tabs: some View {
        TabView(selection: $selection) {
            DisplaysView(isActive: selection == .displays && rootContentIsVisible)
            .tabItem { Label("Displays", systemImage: "display") }
            .tag(AppTab.displays)

            DashboardsView(isActive: selection == .dashboards && rootContentIsVisible)
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
                haptic: galleryUploads.isWorking
                    ? nil
                    : counts.failed > 0 ? .error : .success,
                tapAction: {
                    presentation.sheet = .uploads
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

struct SendComposerSheet: View {
    @State private var submission = SendSubmissionSession()
    var initialImage: SendImageDraft? = nil

    let close: () -> Void

    var body: some View {
        NavigationStack {
            SendView(initialImage: initialImage, prioritizesFramingGesture: true, submission: submission)
                .navigationTitle("Send")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") {
                            close()
                        }
                        .disabled(submission.isSubmitting)
                        .accessibilityIdentifier("root-send-close")
                    }
                }
        }
        .tesseraeMessageCenterInset()
        .frame(idealWidth: 960, idealHeight: 760)
        .presentationSizing(.fitted)
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
