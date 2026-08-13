import SwiftUI
import TesseraeKit

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(RemindersBridgeModel.self) private var remindersBridgeModel
    @State private var clearActivityConfirmationPresented = false

    var body: some View {
        NavigationStack {
            Form {
                if let instance = model.activeInstance {
                    Section("Tesserae Server") {
                        NavigationLink {
                            ServerDetailsView()
                        } label: {
                            LabeledContent {
                                Text(serverSummaryValue)
                            } label: {
                                Label(
                                    serverSummaryTitle(instanceName: instance.name),
                                    systemImage: model.connectionMode == .demo
                                        ? "shippingbox"
                                        : "server.rack"
                                )
                            }
                        }

                        if model.connectionMode == .live {
                            Link(destination: webURL(for: instance)) {
                                Label("Open Tesserae Web", systemImage: "safari")
                            }
                        }
                    }
                }

                Section {
                    NavigationLink {
                        RemindersBridgeView()
                    } label: {
                        LabeledContent {
                            Text(remindersStatus)
                        } label: {
                            Label("Apple Reminders", systemImage: "checklist")
                        }
                    }

                    Button(role: .destructive) {
                        clearActivityConfirmationPresented = true
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "trash")
                                .foregroundStyle(.red)
                            Text("Clear Activity on This iPhone")
                                .foregroundStyle(.red)
                        }
                    }
                    .accessibilityIdentifier("clear-local-activity")
                } header: {
                    Text("Data & Privacy")
                } footer: {
                    Text(
                        "Clearing Activity affects only this Tesserae instance on this iPhone. Server History remains available in Tesserae."
                    )
                }

                Section("About") {
                    LabeledContent("App Version", value: appVersion)

                    Link(
                        destination: URL(
                            string: "https://github.com/charmmmz/tesserae-companion-ios"
                        )!
                    ) {
                        Label(
                            "Source Code",
                            systemImage: "chevron.left.forwardslash.chevron.right"
                        )
                    }
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
            .alert(
                "Clear Local Activity?",
                isPresented: $clearActivityConfirmationPresented
            ) {
                Button("Clear Local Activity", role: .destructive) {
                    Task {
                        await model.clearLocalActivity()
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

    private var serverSummaryValue: String {
        model.connectionMode == .demo
            ? String(localized: "Local data")
            : model.connectionHealth.displayName
    }

    private func serverSummaryTitle(instanceName: String) -> String {
        model.connectionMode == .demo
            ? String(localized: "Demo Mode")
            : instanceName
    }

    private var remindersStatus: String {
        guard model.supportsRemindersPersonalData else {
            return String(localized: "Server update required")
        }
        if remindersBridgeModel.isBusy {
            return String(localized: "Syncing…")
        }
        if remindersBridgeModel.authorizationState == .denied
            || remindersBridgeModel.isEnabled
                && remindersBridgeModel.authorizationState != .fullAccess
        {
            return String(localized: "Needs Access")
        }
        guard remindersBridgeModel.isEnabled else {
            return String(localized: "Off")
        }
        guard let sourceStatus = remindersBridgeModel.sourceStatus else {
            return String(localized: "On")
        }
        switch sourceStatus.state {
        case .fresh:
            return String(localized: "Synced")
        case .stale:
            return String(localized: "Stale")
        case .expired:
            return String(localized: "Expired")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "—"
        let build = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleVersion"
        ) as? String ?? ""

        return build.isEmpty ? version : "\(version) (\(build))"
    }

    private func webURL(for instance: TesseraeInstance) -> URL {
        URL(string: instance.webURL) ?? instance.baseURL
    }
}

private struct ServerDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if let instance = model.activeInstance {
                Section("Connection") {
                    LabeledContent("Name", value: instance.name)
                    LabeledContent("Status", value: statusValue)
                    LabeledContent("Server", value: instance.baseURL.absoluteString)
                    LabeledContent(
                        "Tesserae Version",
                        value: model.capabilities?.serverVersion
                            ?? instance.serverVersion
                    )
                    if let capabilities = model.capabilities {
                        LabeledContent(
                            "Companion API",
                            value: "v\(capabilities.api.version)"
                        )
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            await model.disconnect()
                            dismiss()
                        }
                    } label: {
                        Label(
                            model.connectionMode == .demo
                                ? "Exit Demo"
                                : "Disconnect",
                            systemImage: "link.badge.minus"
                        )
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .tesseraeScreenBackground()
        .navigationTitle("Server Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusValue: String {
        model.connectionMode == .demo
            ? String(localized: "Demo Mode")
            : model.connectionHealth.displayName
    }
}

private extension AppModel.ConnectionHealth {
    var displayName: String {
        switch self {
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
}
