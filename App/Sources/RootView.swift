import SwiftUI

private struct RootConnectionContext: Hashable {
    let revision: UUID
    let instanceID: String?
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(RemindersBridgeModel.self) private var remindersBridgeModel
    @Environment(HealthBridgeModel.self) private var healthBridgeModel
    @Environment(GalleryUploadCoordinator.self) private var galleryUploads
    @Environment(TesseraeMessageCenter.self) private var messageCenter
    @Environment(NearbyDeviceManager.self) private var nearbyDevices
    @Environment(\.scenePhase) private var scenePhase
    @State private var serversPresented = false
    @State private var nearbyPresented = false

    private var connectionContext: RootConnectionContext {
        RootConnectionContext(revision: model.connectionRevision, instanceID: model.activeInstance?.id)
    }

    var body: some View {
        Group {
            if model.isRestoringConnection && model.activeInstance == nil {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Restoring Tesserae connection…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    connectionActions
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .tesseraeScreenBackground()
            } else if model.activeInstance == nil {
                OnboardingView()
            } else {
                VStack(spacing: 0) {
                    if model.connectionHealth == .restoring || model.connectionHealth == .offline {
                        connectionRecovery
                    }
                    MainTabView()
                        .id(model.connectionRevision)
                }
            }
        }
        .animation(.snappy, value: model.activeInstance?.id)
        .tesseraeMessageCenterOverlay()
        .sheet(isPresented: $serversPresented) {
            OnboardingView(isChoosingServer: true)
        }
        .sheet(isPresented: $nearbyPresented) {
            NavigationStack {
                NearbyDisplaysView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") { nearbyPresented = false }
                        }
                    }
            }
        }
        .task {
            await model.restoreConnectionIfNeeded()
            model.openWebIfRequested()
            synchronizeConnectionMessage()
        }
        .task(id: connectionContext) {
            await remindersBridgeModel.load(using: model)
            guard !Task.isCancelled else { return }
            remindersBridgeModel.startChangeMonitoring(
                using: model,
                applicationIsActive: scenePhase == .active
            )
            await healthBridgeModel.load(using: model)
            guard !Task.isCancelled else { return }
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
            set: { newDevice in
                if newDevice == nil, let suggestedDevice = nearbyDevices.suggestedDevice {
                    nearbyDevices.endSession(for: suggestedDevice)
                } else {
                    nearbyDevices.suggestedDevice = newDevice
                }
            }
        )) { device in
            NearbyDeviceSheet(device: device)
        }
        .onChange(of: connectionContext) { previous, _ in
            guard previous.instanceID != nil else { return }
            galleryUploads.cancelAndClear()
            messageCenter.dismiss(id: "gallery.uploads")
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
        if model.activeInstance != nil,
            model.connectionHealth == .offline || model.connectionHealth == .restoring {
            messageCenter.dismiss(id: "connection.status")
            return
        }
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

    private var connectionRecovery: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if model.connectionHealth == .restoring {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "wifi.exclamationmark")
                }
                Text(model.connectionHealth == .restoring
                     ? "Reconnecting…" : "Server unavailable")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
                if model.connectionHealth == .offline {
                    Button("Retry") { Task { await model.refresh(showErrors: false) } }
                        .disabled(model.isRefreshing)
                }
            }
            connectionActions
        }
        .font(.subheadline)
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.regularMaterial)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("connection-recovery")
    }

    private var connectionActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) { connectionButtons }
            VStack(alignment: .leading, spacing: 12) { connectionButtons }
        }
    }

    @ViewBuilder
    private var connectionButtons: some View {
        Button("Other Servers", systemImage: "server.rack") { serversPresented = true }
            .accessibilityIdentifier("choose-server")
        Button("Bluetooth Maintenance", systemImage: "dot.radiowaves.left.and.right") { nearbyPresented = true }
            .accessibilityIdentifier("offline-nearby-devices")
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
