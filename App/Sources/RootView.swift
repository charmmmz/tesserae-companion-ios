import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(RemindersBridgeModel.self) private var remindersBridgeModel
    @Environment(HealthBridgeModel.self) private var healthBridgeModel
    @Environment(GalleryUploadCoordinator.self) private var galleryUploads
    @Environment(TesseraeMessageCenter.self) private var messageCenter
    @Environment(NearbyDeviceManager.self) private var nearbyDevices
    @Environment(\.scenePhase) private var scenePhase

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
        .tesseraeMessageCenterOverlay()
        .task {
            await model.restoreConnectionIfNeeded()
            model.openWebIfRequested()
            synchronizeConnectionMessage()
        }
        .task(id: model.activeInstance?.id) {
            await remindersBridgeModel.load(using: model)
            remindersBridgeModel.startChangeMonitoring(
                using: model,
                applicationIsActive: scenePhase == .active
            )
            await healthBridgeModel.load(using: model)
            if scenePhase == .active {
                await healthBridgeModel.foregroundCatchUp(using: model)
            }
        }
        .onChange(of: scenePhase) { _, newPhase in
            nearbyDevices.updateApplicationActivity(newPhase == .active)
            remindersBridgeModel.updateApplicationActivity(
                newPhase == .active,
                using: model
            )
            if newPhase == .active {
                model.openWebIfRequested()
                Task {
                    await model.synchronizeSharedActivity()
                    await healthBridgeModel.foregroundCatchUp(using: model)
                }
            }
        }
        .onAppear {
            nearbyDevices.updateApplicationActivity(scenePhase == .active)
        }
        .sheet(item: Binding(
            get: { nearbyDevices.suggestedDevice },
            set: { nearbyDevices.suggestedDevice = $0 }
        )) { device in
            NearbyDeviceSetupView(device: device)
        }
        .onChange(of: model.activeInstance?.id) { previousID, currentID in
            if previousID != nil, previousID != currentID {
                galleryUploads.cancelAndClear()
                messageCenter.dismiss(id: "gallery.uploads")
            }
        }
        .onChange(of: connectionMessageRevision) { _, _ in
            synchronizeConnectionMessage()
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

    private var connectionMessageRevision: String {
        let health: String = switch model.connectionHealth {
        case .idle: "idle"
        case .restoring: "restoring"
        case .connected: "connected"
        case .offline: "offline"
        case .requiresPairing: "requires-pairing"
        }
        return [model.connectionNotice ?? "", health, model.activeInstance?.id ?? ""]
            .joined(separator: "|")
    }

    private func synchronizeConnectionMessage() {
        guard let notice = model.connectionNotice else {
            messageCenter.dismiss(id: "connection.status")
            return
        }

        let retryAction: TesseraeMessageAction? = if model.activeInstance != nil {
            TesseraeMessageAction(title: String(localized: "Retry")) {
                Task { await model.refresh() }
            }
        } else {
            nil
        }

        messageCenter.post(
            TesseraeMessage(
                id: "connection.status",
                text: connectionMessageText,
                kind: model.connectionHealth == .requiresPairing
                    ? .warning
                    : .error,
                lifetime: .persistent,
                priority: .high,
                systemImage: model.connectionHealth == .requiresPairing
                    ? "key.slash"
                    : "wifi.exclamationmark",
                accessibilityIdentifier: "connection-message-capsule",
                accessibilityText: notice,
                action: retryAction
            )
        )
    }

    private var connectionMessageText: String {
        switch model.connectionHealth {
        case .requiresPairing:
            String(localized: "Pair again to reconnect")
        case .offline:
            String(localized: "Unable to connect to Tesserae")
        case .connected:
            String(localized: "Couldn’t update Tesserae data")
        case .restoring:
            String(localized: "Restoring connection…")
        case .idle:
            String(localized: "Connection unavailable")
        }
    }
}
