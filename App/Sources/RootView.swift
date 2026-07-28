import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.isRestoringConnection {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Restoring Tesserae connection…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tesseraeScreenBackground()
            } else if model.activeInstance == nil {
                OnboardingView()
            } else {
                MainTabView()
            }
        }
        .animation(.snappy, value: model.activeInstance?.id)
        .safeAreaInset(edge: .top) {
            if let notice = model.connectionNotice {
                HStack(alignment: .top, spacing: 10) {
                    Image(
                        systemName: model.connectionHealth == .requiresPairing
                            ? "key.slash"
                            : "wifi.exclamationmark"
                    )
                    Text(notice)
                        .font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if model.activeInstance != nil {
                        Button("Retry") {
                            Task { await model.refresh() }
                        }
                        .font(.footnote.weight(.semibold))
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.thinMaterial)
            }
        }
        .task {
            await model.restoreConnectionIfNeeded()
        }
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
