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
                            value: apiMode
                        )
                        if let capabilities = model.capabilities {
                            LabeledContent(
                                "Companion API",
                                value: "v\(capabilities.api.version)"
                            )
                        }

                        Link(destination: instance.baseURL) {
                            Label("Open Web Management", systemImage: "safari")
                        }
                    }
                }

                Section("Connection") {
                    LabeledContent("Status", value: connectionStatus)
                    Text(connectionDescription)
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
            String(localized: "Not connected")
        case .restoring:
            String(localized: "Restoring")
        case .connected:
            String(localized: "Connected")
        case .offline:
            String(localized: "Saved for retry")
        case .requiresPairing:
            String(localized: "Pair again")
        }
    }

    private var apiMode: String {
        model.connectionMode == .live
            ? String(localized: "Live Companion API")
            : String(localized: "Demo data")
    }

    private var connectionDescription: String {
        model.connectionMode == .live
            ? String(localized: "The client token is stored in shared Keychain access. Non-secret connection details are stored in the App Group for the app and Share Extension.")
            : String(localized: "This session uses local demo data and does not contact a Tesserae server.")
    }
}
