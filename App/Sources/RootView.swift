import SwiftUI
import TesseraeKit

private struct RootConnectionContext: Hashable {
    let revision: UUID
    let instanceID: String?
}

private struct BluetoothAssociationContext: Hashable {
    let connection: RootConnectionContext
    let displays: [DisplaySummary]
    let macs: [String]
    let isActive: Bool
}

private struct BluetoothModeSyncContext: Hashable {
    let connection: RootConnectionContext
    let reports: [BluetoothModeReport]
    let enabled: Bool
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
    @State private var nearbyPhotoConfirmation: TesseraeMessage?
    @State private var presentation = CompanionPresentation()

    private var connectionContext: RootConnectionContext {
        RootConnectionContext(revision: model.connectionRevision, instanceID: model.activeInstance?.id)
    }

    private var bluetoothAssociationContext: BluetoothAssociationContext {
        BluetoothAssociationContext(
            connection: connectionContext,
            displays: model.displays,
            macs: nearbyDevices.displayRecords.knownHardwareMACs,
            isActive: scenePhase == .active
        )
    }

    private var bluetoothModeSyncContext: BluetoothModeSyncContext {
        BluetoothModeSyncContext(connection: connectionContext,
            reports: nearbyDevices.displayRecords.pendingModeReports(
                displayIDs: model.displays.map(\.id), serverID: model.activeInstance?.id,
                includeStatus: model.capabilities?.features.contains("device_status_observations") == true),
            enabled: scenePhase == .active && model.connectionMode == .live
                && model.capabilities?.features.contains("device_mode_observations") == true)
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
                .tesseraeMessageCenter()
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
        .environment(presentation)
        .onChange(of: model.activeInstance?.id, initial: true) { _, id in
            nearbyDevices.displayRecords.activeServerID = id
            rememberServerDisplays()
        }
        .onChange(of: model.displays) { rememberServerDisplays() }
        .onChange(of: model.displayPreviews) { rememberServerDisplays() }
        .onChange(of: nearbyDevices.screenMode) { _, mode in
            guard mode == .wifi else { return }
            Task { await model.refreshDisplays(showErrors: false) }
        }
        .sheet(isPresented: $serversPresented) {
            OnboardingView(isChoosingServer: true)
        }
        .sheet(isPresented: $nearbyPresented) {
            NavigationStack {
                NearbyDisplaysView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done", systemImage: "checkmark") { nearbyPresented = false }
                                .labelStyle(.iconOnly)
                                .accessibilityIdentifier("nearby-displays-done")
                        }
                    }
            }
        }
        .task {
            await model.restoreConnectionIfNeeded()
            model.openWebIfRequested()
            synchronizeConnectionMessage()
        }
        .task(id: bluetoothAssociationContext) {
            let context = bluetoothAssociationContext
            guard context.isActive, !context.macs.isEmpty,
                  let serverID = context.connection.instanceID else { return }
            var retrySeconds = 30
            while !Task.isCancelled {
                let matches = await model.resolveBluetoothDisplayAssociations(macs: context.macs)
                guard !Task.isCancelled, context == bluetoothAssociationContext else { return }
                if let matches {
                    rememberServerDisplays()
                    nearbyDevices.displayRecords.observeMACMatches(matches, serverID: serverID)
                    return
                }
                do { try await Task.sleep(for: .seconds(retrySeconds)) }
                catch { return }
                retrySeconds = min(retrySeconds * 2, 300)
            }
        }
        .task(id: bluetoothModeSyncContext) {
            let context = bluetoothModeSyncContext
            guard context.enabled, !context.reports.isEmpty else { return }
            var retrySeconds = 30
            while !Task.isCancelled {
                await model.synchronizeBluetoothModes(context.reports, store: nearbyDevices.displayRecords)
                guard !Task.isCancelled, context == bluetoothModeSyncContext else { return }
                do { try await Task.sleep(for: .seconds(retrySeconds)) }
                catch { return }
                retrySeconds = min(retrySeconds * 2, 300)
            }
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
            presentation.sendSubmission.updateApplicationActivity(newPhase == .active)
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
            get: { presentation.isSendComposerPresented || presentation.sendSubmission.isSubmitting
                ? nil : nearbyDevices.suggestedDevice },
            set: { newDevice in
                if newDevice == nil, let suggestedDevice = nearbyDevices.suggestedDevice {
                    nearbyDevices.endSession(for: suggestedDevice)
                } else {
                    nearbyDevices.suggestedDevice = newDevice
                }
            }
        ), onDismiss: showNearbyPhotoConfirmation) { device in
            NearbyDeviceSheet(device: device) { nearbyPhotoConfirmation = $0 }
        }
        .onChange(of: connectionContext) { previous, _ in
            presentation.sheet = nil
            presentation.isSendComposerPresented = false
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
                get: { model.lastError != nil && !presentation.isSendComposerPresented
                    && !presentation.sendSubmission.isSubmitting },
                set: { isPresented in
                    if !isPresented && !presentation.isSendComposerPresented
                        && !presentation.sendSubmission.isSubmitting {
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

    private func rememberServerDisplays() {
        nearbyDevices.displayRecords.observeServer(displays: model.displays, previews: model.displayPreviews,
                                                   serverID: model.activeInstance?.id)
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

    private func showNearbyPhotoConfirmation() {
        guard let message = nearbyPhotoConfirmation else { return }
        nearbyPhotoConfirmation = nil
        messageCenter.post(message)
        AccessibilityNotification.Announcement(message.text).post()
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
