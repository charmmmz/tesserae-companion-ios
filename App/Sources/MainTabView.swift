import SwiftUI

private enum AppTab: Hashable {
    case displays
    case dashboards
    case send
    case activity
}

struct MainTabView: View {
    @State private var selection: AppTab = .displays
    @State private var settingsPresented = false

    var body: some View {
        TabView(selection: $selection) {
            tabNavigation(title: "Displays") {
                DisplaysView()
            }
            .tabItem { Label("Displays", systemImage: "rectangle.connected.to.line.below") }
            .tag(AppTab.displays)

            tabNavigation(title: "Dashboards") {
                DashboardsView()
            }
            .tabItem { Label("Dashboards", systemImage: "rectangle.grid.2x2") }
            .tag(AppTab.dashboards)

            tabNavigation(title: "Send") {
                SendView()
            }
            .tabItem { Label("Send", systemImage: "paperplane") }
            .tag(AppTab.send)

            tabNavigation(title: "Activity") {
                ActivityView()
            }
            .tabItem { Label("Activity", systemImage: "clock.arrow.circlepath") }
            .tag(AppTab.activity)
        }
        .sheet(isPresented: $settingsPresented) {
            SettingsView()
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
