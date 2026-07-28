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
                        LabeledContent("API mode", value: "Fixture-backed")

                        Link(destination: instance.baseURL) {
                            Label("Open Web Management", systemImage: "safari")
                        }
                    }
                }

                Section("Prototype") {
                    Text("The UI is running against contract fixtures. Bonjour, QR scanning, Keychain persistence, and live HTTP transport remain behind protocol boundaries until the upstream API is agreed.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section {
                    Button("Disconnect Demo Instance", role: .destructive) {
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
}

