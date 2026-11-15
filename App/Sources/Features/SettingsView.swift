import SwiftUI
import TesseraeKit

struct SettingsView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(ConnectionHost.self) private var connectionHost
    @Environment(RemindersBridgeModel.self) private var remindersBridgeModel
    @Environment(HealthBridgeModel.self) private var healthBridgeModel
    @State private var clearActivityConfirmationPresented = false
    @State private var hapticFeedbackEnabled = TesseraeHapticSettings.isEnabled
    @State private var serversPresented = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    if let cloud = connectionHost.cloud {
                        NavigationLink {
                            CloudAccountSettings(model: cloud) { serversPresented = true }
                        } label: {
                            Label {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("Cloud Account")
                                    if let workspace = cloud.snapshot?.account.tenant.name {
                                        Text(workspace)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            } icon: {
                                Image(systemName: "person.crop.circle")
                            }
                        }
                        .accessibilityIdentifier("cloud-account-settings")
                    } else if let instance = model.activeInstance {
                        NavigationLink {
                            ServerDetailsView()
                        } label: {
                            let layout = dynamicTypeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                : AnyLayout(HStackLayout(spacing: 12))
                            layout {
                                Label(
                                    serverSummaryTitle(instanceName: instance.name),
                                    systemImage: model.connectionMode == .demo ? "shippingbox" : "server.rack"
                                )
                                .fixedSize(horizontal: false, vertical: true)
                                if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                                Text(serverSummaryValue)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    Button("Choose Connection", systemImage: "arrow.triangle.swap") {
                        serversPresented = true
                    }
                    .accessibilityIdentifier("choose-connection")
                }

                if connectionHost.cloud == nil && model.connectionMode != .demo {
                    Section("Displays") {
                        NavigationLink {
                            NearbyDisplaysView()
                        } label: {
                            Label(
                                "Nearby Setup & Maintenance",
                                systemImage: "dot.radiowaves.left.and.right"
                            )
                        }
                    }
                }

                Section("Interaction") {
                    Toggle(isOn: $hapticFeedbackEnabled) {
                        Label("Haptic Feedback", systemImage: "hand.tap")
                    }
                }

                if connectionHost.cloud == nil {
                    personalDataSection
                }

                Section("About") {
                    LabeledContent("App Version", value: appVersion)
                    Link(destination: URL(string: "https://github.com/charmmmz/tesserae-companion-ios")!) {
                        Label("Source Code", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 820)
            .frame(maxWidth: .infinity)
            .tesseraeScreenBackground()
            .tesseraeMessageCenter()
            .onChange(of: hapticFeedbackEnabled) { _, isEnabled in
                TesseraeHapticSettings.isEnabled = isEnabled
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $serversPresented) {
                OnboardingView(isChoosingServer: true)
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                        .labelStyle(.iconOnly)
                }
            }
            .alert(
                "Clear Local Activity?",
                isPresented: $clearActivityConfirmationPresented
            ) {
                Button("Clear Local Activity", role: .destructive) {
                    Task { await model.clearLocalActivity() }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(
                    "This clears the Activity list for this Tesserae instance and hides existing server History on this device. Server History remains available in Tesserae."
                )
            }
        }
    }

    private var personalDataSection: some View {
        Section("Data & Privacy") {
            NavigationLink {
                RemindersBridgeView()
            } label: {
                LabeledContent {
                    Text(remindersStatus)
                } label: {
                    Label("Reminders", systemImage: "checklist")
                }
            }

            NavigationLink {
                HealthBridgeView()
            } label: {
                LabeledContent {
                    Text(healthStatus)
                } label: {
                    Label("Health", systemImage: "heart.fill")
                }
            }

            Button("Clear Activity on This Device", systemImage: "trash", role: .destructive) {
                clearActivityConfirmationPresented = true
            }
            .accessibilityIdentifier("clear-local-activity")
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
        PersonalDataSyncState.reminders(
            isSupported: model.supportsRemindersPersonalData,
            model: remindersBridgeModel
        ).settingsLabel
    }

    private var healthStatus: String {
        PersonalDataSyncState.health(
            isSupported: model.supportsHealthSummaryPersonalData,
            model: healthBridgeModel
        ).settingsLabel
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
}

private struct ServerDetailsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(ConnectionHost.self) private var connectionHost

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

                if model.connectionMode == .live {
                    Section {
                        Link(destination: URL(string: instance.webURL) ?? instance.baseURL) {
                            Label("Open Tesserae Web", systemImage: "safari")
                        }
                    }
                }

                Section {
                    Button(role: .destructive) {
                        Task {
                            await connectionHost.signOut()
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
