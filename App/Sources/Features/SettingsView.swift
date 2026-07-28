import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        NavigationStack {
            Form {
                if let instance = model.activeInstance {
                    Section("Instance") {
                        LabeledContent("Name", value: instance.name)
                        LabeledContent("Server", value: instance.baseURL.absoluteString)
                        LabeledContent("Version", value: instance.serverVersion)
                        LabeledContent(
                            "API mode",
                            value: model.connectionMode == .live ? "Live Companion API" : "Demo data"
                        )

                        Link(destination: instance.baseURL) {
                            Label("Open Web Management", systemImage: "safari")
                        }
                    }
                }

                Section("Connection") {
                    LabeledContent("Status", value: connectionStatus)
                    Text(
                        model.connectionMode == .live
                            ? "The client token is stored in shared Keychain access. Non-secret connection details are stored in the App Group for the app and Share Extension."
                            : "This session uses local demo data and does not contact a Tesserae server."
                    )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Disconnect", role: .destructive) {
                        Task {
                            await model.disconnect()
                            dismiss()
                        }
                    }
                }

                Section {
                    LabeledContent("Client", value: "Community-built")
                    LabeledContent("Framework", value: "0.1.0")
                } header: {
                    Text("About")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var connectionStatus: String {
        switch model.connectionHealth {
        case .idle:
            "Not connected"
        case .restoring:
            "Restoring"
        case .connected:
            "Connected"
        case .offline:
            "Saved for retry"
        case .requiresPairing:
            "Pair again"
        }
    }
}
