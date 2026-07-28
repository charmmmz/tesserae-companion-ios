import SwiftUI
import TesseraeKit

@main
@MainActor
struct TesseraeCompanionApp: App {
    @State private var model = AppModel(
        client: MockTesseraeClient(),
        credentials: InMemoryCredentialStore()
    )

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(TesseraeTheme.accent)
        }
    }
}

