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
                    Text(
                        model.connectionMode == .live
                            ? "The client token is stored in Keychain and sent only to this Tesserae instance."
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
}
