import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var clearActivityConfirmationPresented = false
    @State private var activityClearConfirmation: String?

    var body: some View {
        NavigationStack {
            Form {
                if let instance = model.activeInstance {
                    Section("Instance") {
                        LabeledContent("Name", value: instance.name)
                        LabeledContent("Server", value: instance.baseURL.absoluteString)
                        LabeledContent(
                            "Version",
                            value: model.capabilities?.serverVersion
                                ?? instance.serverVersion
                        )
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

                    Button("Disconnect", role: .destructive) {
                        Task {
                            await model.disconnect()
                            dismiss()
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        clearActivityConfirmationPresented = true
                    } label: {
                        if model.isClearingLocalActivity {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Clearing Local Activity…")
                            }
                        } else {
                            Label(
                                "Clear Local Activity",
                                systemImage: "trash"
                            )
                        }
                    }
                    .disabled(model.isClearingLocalActivity)
                    .accessibilityIdentifier("clear-local-activity")

                    if let activityClearConfirmation {
                        Label(
                            activityClearConfirmation,
                            systemImage: "checkmark.circle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Local Storage")
                } footer: {
                    Text(
                        "Clears Activity on this iPhone, including locally displayed server History. Tesserae server History is not deleted."
                    )
                }

                Section {
                    Link(
                        destination: URL(
                            string: "https://github.com/charmmmz/tesserae-companion-ios"
                        )!
                    ) {
                        LabeledContent(
                            "GitHub Repository",
                            value: "charmmmz/tesserae-companion-ios"
                        )
                    }
                    LabeledContent("Framework", value: "0.1.0")
                } header: {
                    Text("About")
                }
            }
            .scrollContentBackground(.hidden)
            .tesseraeScreenBackground()
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog(
                "Clear Local Activity?",
                isPresented: $clearActivityConfirmationPresented,
                titleVisibility: .visible
            ) {
                Button("Clear Local Activity", role: .destructive) {
                    Task {
                        if await model.clearLocalActivity() {
                            activityClearConfirmation = String(
                                localized: "Local Activity was cleared."
                            )
                        }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This clears the Activity list for this Tesserae instance and hides existing server History on this iPhone. Server History remains available in Tesserae."
                )
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
