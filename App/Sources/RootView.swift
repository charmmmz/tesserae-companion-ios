import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.activeInstance == nil {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .animation(.snappy, value: model.activeInstance?.id)
        .alert(
            "Something Went Wrong",
            isPresented: Binding(
                get: { model.lastError != nil },
                set: { isPresented in
                    if !isPresented {
                        model.lastError = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                model.lastError = nil
            }
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

