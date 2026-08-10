import SwiftUI

private enum AppTab: Hashable {
    case displays
    case dashboards
    case lineups
    case send
    case activity
}

struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @State private var selection: AppTab = .displays
    @State private var settingsPresented = false

    var body: some View {
        TabView(selection: $selection) {
            tabNavigation(title: "Displays") {
                DisplaysView(
                    isActive: selection == .displays && !settingsPresented
                )
            }
            .tabItem { Label("Displays", systemImage: "display") }
            .tag(AppTab.displays)

            tabNavigation(title: "Dashboards") {
                DashboardsView(
                    isActive: selection == .dashboards && !settingsPresented
                )
            }
            .tabItem { Label("Dashboards", systemImage: "rectangle.grid.2x2") }
            .tag(AppTab.dashboards)

            if model.supportsLineups {
                tabNavigation(title: "Lineups") {
                    LineupsView(
                        isActive: selection == .lineups && !settingsPresented
                    )
                }
                .tabItem { Label("Lineups", systemImage: "rectangle.3.group") }
                .tag(AppTab.lineups)
            }

            tabNavigation(title: "Send") {
                SendView()
            }
            .tabItem { Label("Send", systemImage: "paperplane") }
            .tag(AppTab.send)

            tabNavigation(title: "Activity") {
                ActivityView(
                    isActive: selection == .activity && !settingsPresented
                )
            }
            .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
            .tag(AppTab.activity)
        }
        .sheet(isPresented: $settingsPresented) {
            SettingsView()
        }
        .onChange(of: model.supportsLineups) { _, supportsLineups in
            if !supportsLineups, selection == .lineups {
                selection = .dashboards
            }
        }
    }

    private func tabNavigation<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        NavigationStack {
            content()
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Settings", systemImage: "gearshape") {
                            settingsPresented = true
                        }
                    }
                }
        }
    }
}
