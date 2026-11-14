import SwiftUI
import TesseraeKit
import UIKit

struct OnboardingView: View {
    private enum ConnectionType {
        case cloud, selfHosted
    }

    var isChoosingServer = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    @Environment(ConnectionHost.self) private var connectionHost
    @ScaledMetric(relativeTo: .subheadline) private var nearbyServerRowHeight: CGFloat = 44
    @State private var connectionType = ConnectionType.cloud
    @State private var manualSetupPresented = false
    @State private var manualServerAddress: String?

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                ScrollView {
                    connectionContent(viewport)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
            .tesseraeMessageCenter()
            .tesseraeScreenBackground()
            .sheet(isPresented: $manualSetupPresented) {
                ManualConnectionView(
                    initialServerAddress: manualServerAddress,
                    onConnected: { if isChoosingServer { dismiss() } }
                )
            }
            .navigationTitle(String(localized: isChoosingServer ? "Tesserae Connections" : ""))
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(isChoosingServer ? .visible : .hidden, for: .navigationBar)
            .toolbar {
                if isChoosingServer {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark", action: closeChooser)
                            .labelStyle(.iconOnly)
                            .disabled(connectionHost.loginPhase == .committing)
                    }
                }
            }
            .task {
                connectionHost.reloadSavedConnections()
            }
            .onChange(of: shouldShowServerDiscovery) { _, visible in
                guard visible, model.discoveredInstances.isEmpty else { return }
                Task { await model.discoverNearby() }
            }
            .onChange(of: connectionHost.loginError) { _, error in
                if let error { AccessibilityNotification.Announcement(error).post() }
            }
            .onChange(of: model.connectionRevision) { _, _ in
                if isChoosingServer { dismiss() }
            }
        }
        .presentationDetents(isChoosingServer && !dynamicTypeSize.isAccessibilitySize ? [.medium, .large] : [.large])
        .presentationDragIndicator(isChoosingServer ? .visible : .automatic)
        .interactiveDismissDisabled(isChoosingServer && connectionHost.isSigningIn)
    }

    private var shouldShowServerDiscovery: Bool {
        connectionType == .selfHosted && !connectionHost.isSigningIn
    }

    private func connectionContent(_ viewport: GeometryProxy) -> some View {
        let isSigningIn = connectionHost.isSigningIn
        let insets = viewport.safeAreaInsets
        let screenHeight = viewport.size.height + insets.top + insets.bottom
        let spacious = !dynamicTypeSize.isAccessibilitySize && viewport.size.height >= 550
            && connectionHost.savedConnections.isEmpty
        let brandHeight = spacious ? max(132, screenHeight * 0.39 - insets.top) : 104
        let brandSize: CGFloat = spacious ? (viewport.size.width > 360 ? 104 : 88) : 72

        return VStack(spacing: 0) {
            if !isChoosingServer {
                TesseraeBrandMark(size: isSigningIn ? 52 : brandSize)
                    .frame(maxWidth: .infinity)
                    .frame(height: isSigningIn ? 84 : brandHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Tesserae Companion")
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier("onboarding-brand")
            }

            VStack(spacing: 16) {
                if !isSigningIn {
                    if !connectionHost.savedConnections.isEmpty {
                        savedConnections
                    }

                    if isChoosingServer {
                        Text("Add a Connection")
                            .font(.body.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                    }

                    Picker("Connection Type", selection: $connectionType) {
                        Text("Cloud").tag(ConnectionType.cloud)
                        Text("Self-Hosted").tag(ConnectionType.selfHosted)
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.large)
                    .frame(minHeight: 44)
                    .disabled(connectionHost.isSwitching)
                    .accessibilityIdentifier("connection-type")
                }

                if isSigningIn || connectionType == .cloud {
                    CloudSignInView()
                } else {
                    selfHostedConnection
                }

                if !isSigningIn, let error = connectionHost.loginError {
                    ConnectionLoginErrorMessage(message: error)
                }

                if shouldShowServerDiscovery {
                    nearbyServerDiscovery
                }

                if !isChoosingServer && !isSigningIn {
                    Spacer(minLength: 0)
                    onboardingAlternatives
                }
            }
            .padding(.horizontal, viewport.size.width > 370 ? 24 : 16)
            .padding(.vertical, isChoosingServer ? 20 : 0)
        }
        .padding(.bottom, 20)
        .frame(maxWidth: 680, minHeight: !isChoosingServer && !isSigningIn ? viewport.size.height : 0, alignment: .top)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: isSigningIn)
    }

    private var currentConnectionID: ConnectionID? {
        connectionHost.cloud?.fence.connectionID ?? model.activeConnectionFence?.connectionID
    }

    private var needsCloudConnection: Bool {
        connectionHost.cloud.map { $0.needsSignIn || $0.isRestricted } ?? false
    }

    private var savedConnections: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved Connections").font(.headline).accessibilityAddTraits(.isHeader)
            ForEach(connectionHost.savedConnections) { connection in
                let isCurrent = connection.id == currentConnectionID
                let isUnavailable = isCurrent && needsCloudConnection
                Button {
                    if isCurrent && isChoosingServer {
                        closeChooser()
                    } else {
                        Task { await connectionHost.select(connection.id) }
                    }
                } label: {
                    let layout = dynamicTypeSize.isAccessibilitySize
                        ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                        : AnyLayout(HStackLayout(spacing: 12))
                    layout {
                        if !dynamicTypeSize.isAccessibilitySize {
                            Image(systemName: connection.localInstance == nil ? "cloud" : "server.rack")
                                .foregroundStyle(TesseraeTheme.accent)
                                .accessibilityHidden(true)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.name)
                                .font(.body.weight(.semibold))
                            Text(connectionAddress(connection.identity))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            if isUnavailable {
                                Label("Cloud Connection Unavailable", systemImage: "exclamationmark.circle")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            } else if isCurrent && dynamicTypeSize.isAccessibilitySize {
                                Label("Current Connection", systemImage: "checkmark")
                                    .font(.footnote)
                                    .foregroundStyle(TesseraeTheme.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                        if !dynamicTypeSize.isAccessibilitySize {
                            Spacer(minLength: 8)
                            if isCurrent && !isUnavailable {
                                Image(systemName: "checkmark")
                                    .fontWeight(.semibold)
                                    .foregroundStyle(TesseraeTheme.accent)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isUnavailable || connectionHost.isSwitching || connectionHost.loginPhase == .committing)
                .accessibilityValue(isCurrent && !isUnavailable ? Text("Current Connection") : Text(""))
                .accessibilityAddTraits(isCurrent && !isUnavailable ? .isSelected : [])
                .accessibilityIdentifier("saved-connection-\(connection.id.rawValue)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
    }

    private var minimumNearbyServerRowHeight: CGFloat { max(44, nearbyServerRowHeight) }

    private var selfHostedConnection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Pair with the one-time code shown by your server.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            Button("Enter Server Address") {
                openManualSetup()
            }
            .buttonStyle(ConnectionOptionButtonStyle())
            .accessibilityIdentifier("self-hosted-manual-address")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nearbyServerDiscovery: some View {
        VStack(alignment: .leading, spacing: 4) {
            nearbyServersHeader
            if model.discoveredInstances.isEmpty {
                if model.isDiscovering {
                    nearbyServerPlaceholder
                } else if model.discoveryError != nil {
                    Text("Couldn’t search nearby. Check Local Network access in iOS Settings.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: minimumNearbyServerRowHeight, alignment: .leading)
                } else {
                    Text("No nearby servers found.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(minHeight: minimumNearbyServerRowHeight, alignment: .leading)
                        .accessibilityIdentifier("self-hosted-discovery-empty")
                }
            } else {
                ForEach(model.discoveredInstances) { instance in
                    Button {
                        openManualSetup(address: instance.baseURL.absoluteString)
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(instance.name).font(.subheadline.weight(.semibold))
                                Text(instance.baseURL.absoluteString)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Image(systemName: "chevron.right")
                                .font(.subheadline)
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: minimumNearbyServerRowHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var nearbyServersHeader: some View {
        HStack {
            Text("Nearby Tesserae")
                .font(.subheadline.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Spacer()
            Group {
                if model.isDiscovering {
                    ProgressView()
                        .accessibilityLabel("Searching for nearby servers…")
                        .accessibilityHidden(model.discoveredInstances.isEmpty)
                } else {
                    Button {
                        Task { await model.discoverNearby() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.body)
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityLabel("Refresh nearby Tesserae servers")
                }
            }
            .frame(width: 44, height: 44)
        }
    }

    private var nearbyServerPlaceholder: some View {
        VStack(alignment: .leading, spacing: 5) {
            Capsule().frame(width: 110, height: 9)
            Capsule().frame(width: 155, height: 7)
        }
        .foregroundStyle(.secondary.opacity(0.2))
        .frame(maxWidth: .infinity, minHeight: minimumNearbyServerRowHeight, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Searching for nearby servers…")
        .accessibilityIdentifier("self-hosted-discovery-loading")
    }

    private var onboardingAlternatives: some View {
        HStack(alignment: .top, spacing: 8) {
            NavigationLink {
                NearbyDisplaysView(fromOnboarding: true)
            } label: {
                Text("Nearby Devices")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("onboarding-nearby-devices")

            Button {
                Task { await connectionHost.connectDemo() }
            } label: {
                Group {
                    if model.activeOperationIDs.contains("pair") {
                        ProgressView().accessibilityLabel("Demo Mode")
                    } else {
                        Text("Demo Mode")
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 44)
                .contentShape(Rectangle())
            }
            .disabled(model.activeOperationIDs.contains("pair"))
            .accessibilityIdentifier("onboarding-demo")
        }
        .buttonStyle(.plain)
        .foregroundStyle(TesseraeTheme.accent)
        .font(.subheadline.weight(.medium))
        .multilineTextAlignment(.center)
    }

    private func connectionAddress(_ identity: ConnectionIdentity) -> String {
        switch identity {
        case let .cloud(issuer, _, _): issuer.host ?? issuer.absoluteString
        case let .selfHosted(service, _): service.absoluteString
        }
    }

    private func openManualSetup(address: String? = nil) {
        manualServerAddress = address
        manualSetupPresented = true
    }

    private func closeChooser() {
        if connectionHost.canCancelLogin, !connectionHost.cancelCloudSignIn() { return }
        dismiss()
    }
}

private struct ManualConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @Environment(ConnectionHost.self) private var connectionHost
    @State private var serverAddress: String
    @State private var pairingCode: String
    @State private var connectionTask: Task<Void, Never>?
    @State private var connectionError: String?
    private let onConnected: () -> Void

    init(
        initialServerAddress: String? = nil,
        onConnected: @escaping () -> Void = {}
    ) {
        self.onConnected = onConnected
        _serverAddress = State(
            initialValue: initialServerAddress
                ?? ProcessInfo.processInfo.environment["TESSERAE_SERVER_URL"]
                ?? "http://tesserae.local:8765"
        )
        _pairingCode = State(
            initialValue: ProcessInfo.processInfo.environment["TESSERAE_PAIRING_CODE"] ?? ""
        )
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("http://host:port", text: $serverAddress)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                    TextField("Pairing code", text: $pairingCode)
                        .keyboardType(.numberPad)
                }

                Section {
                    Text("Pair with the one-time code shown by your server.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .tesseraeScreenBackground()
            .navigationTitle("Connect Manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") {
                        connectionTask?.cancel()
                        dismiss()
                    }
                    .labelStyle(.iconOnly)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        guard let url = URL(string: serverAddress) else {
                            connectionError = String(
                                localized: "The server URL is invalid."
                            )
                            return
                        }
                        guard !pairingCode.isEmpty else {
                            connectionError = String(
                                localized: "Enter the one-time pairing code shown by Tesserae."
                            )
                            return
                        }
                        connectionTask = Task {
                            let connected = await connectionHost.connectLocal(
                                baseURL: url,
                                code: pairingCode,
                                clientName: UIDevice.current.name,
                                onFailure: { connectionError = $0 }
                            )
                            if connected {
                                dismiss()
                                onConnected()
                            }
                            connectionTask = nil
                        }
                    }
                    .disabled(connectionTask != nil)
                }
                if connectionTask != nil {
                    ToolbarItem(placement: .principal) { ProgressView() }
                }
            }
            .onDisappear { connectionTask?.cancel() }
            .alert("Unable to Connect", isPresented: Binding(
                get: { connectionError != nil },
                set: { if !$0 { connectionError = nil } }
            )) {
                Button("OK", role: .cancel) { connectionError = nil }
            } message: {
                Text(connectionError ?? "")
            }
        }
    }
}
