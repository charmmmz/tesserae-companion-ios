import SwiftUI
import TesseraeKit
import UIKit

struct OnboardingView: View {
    private enum ConnectionType {
        case cloud, selfHosted
    }

    private enum WelcomeStep {
        case nearby, demo
        case manual(address: String?)
    }

    var isChoosingServer = false
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(AppModel.self) private var model
    @Environment(ConnectionHost.self) private var connectionHost
    @ScaledMetric(relativeTo: .subheadline) private var nearbyServerRowHeight: CGFloat = 44
    @State private var connectionType = ConnectionType.cloud
    @State private var welcomeStep: WelcomeStep?
    @State private var connectionChooserPresented = false
    @State private var manualSetupPresented = false
    @State private var manualServerAddress: String?

    var body: some View {
        NavigationStack {
            GeometryReader { viewport in
                connectionContent(viewport)
            }
            .tesseraeMessageCenter()
            .tesseraeScreenBackground(grid: !isChoosingServer)
            .sheet(isPresented: $connectionChooserPresented) {
                OnboardingView(isChoosingServer: true)
            }
            .sheet(isPresented: $manualSetupPresented) {
                ManualConnectionView(
                    initialServerAddress: manualServerAddress,
                    onClose: { manualSetupPresented = false },
                    onConnected: { dismiss() }
                )
            }
            .navigationTitle(navigationTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarVisibility(.visible, for: .navigationBar)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                if isChoosingServer {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", systemImage: "xmark", action: closeChooser)
                            .labelStyle(.iconOnly)
                            .disabled(connectionHost.loginPhase == .committing)
                    }
                } else if case .nearby = welcomeStep {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Back", systemImage: "chevron.backward") { welcomeStep = nil }
                            .labelStyle(.iconOnly)
                    }
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: welcomeStep != nil)
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
        connectionType == .selfHosted && welcomeStep == nil && !connectionHost.isSigningIn
    }

    private var navigationTitle: Text {
        switch welcomeStep {
        case .nearby: Text("Nearby Devices")
        case .manual: Text("Connect Manually")
        case .demo: Text("Demo Mode")
        case nil: isChoosingServer ? Text("Tesserae Connections") : Text("")
        }
    }

    private func connectionContent(_ viewport: GeometryProxy) -> some View {
        let isSigningIn = connectionHost.isSigningIn
        let compactBrand = isSigningIn || welcomeStep != nil
        let insets = viewport.safeAreaInsets
        let screenHeight = viewport.size.height + insets.top + insets.bottom
        let spacious = !dynamicTypeSize.isAccessibilitySize && viewport.size.height >= 550
        let brandHeight = spacious ? max(132, screenHeight * 0.43 - insets.top) : 104
        let brandSize: CGFloat = spacious ? (viewport.size.width > 360 ? 104 : 88) : 72
        let headerHeight: CGFloat = isChoosingServer ? 0 : (compactBrand ? 84 : brandHeight)

        return VStack(spacing: 0) {
            if !isChoosingServer {
                TesseraeBrandMark(size: brandSize)
                    .scaleEffect(compactBrand ? 52 / brandSize : 1)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Tesserae Companion")
                    .accessibilityAddTraits(.isImage)
                    .accessibilityIdentifier("onboarding-brand")
                    .frame(maxWidth: .infinity)
                    .frame(height: headerHeight)
            }

            ZStack(alignment: .top) {
                switch welcomeStep {
                case .nearby:
                    NearbyDisplaysView(fromOnboarding: true)
                        .transition(.opacity)
                case .manual(let address):
                    ManualConnectionForm(initialServerAddress: address, onClose: { welcomeStep = nil })
                        .transition(.opacity)
                case .demo:
                    ProgressView()
                        .accessibilityLabel("Demo Mode")
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .transition(.opacity)
                case nil:
                    connectionOptions(horizontalPadding: viewport.size.width > 370 ? 24 : 16)
                        .transition(.opacity)
                }
            }
            .geometryGroup()
        }
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.26), value: isSigningIn)
    }

    private func connectionOptions(horizontalPadding: CGFloat) -> some View {
        ScrollView {
            VStack(spacing: 16) {
                let isSigningIn = connectionHost.isSigningIn
                if !isSigningIn {
                    if isChoosingServer && !connectionHost.savedConnections.isEmpty {
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

                VStack(spacing: 16) {
                    if isSigningIn || connectionType == .cloud {
                        CloudSignInView()
                            .transition(.opacity)
                    } else {
                        selfHostedConnection
                            .transition(.opacity)
                    }
                    if shouldShowServerDiscovery {
                        nearbyServerDiscovery
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: connectionType)

                if !isSigningIn, let error = connectionHost.loginError {
                    ConnectionLoginErrorMessage(message: error)
                }

            }
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, isChoosingServer ? 20 : 0)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if !isChoosingServer && !connectionHost.isSigningIn {
                welcomeActions
                    .padding(.horizontal, horizontalPadding)
                    .padding(.bottom, 20)
            }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }

    private var welcomeActions: some View {
        VStack(spacing: 4) {
            if !connectionHost.savedConnections.isEmpty {
                Button {
                    connectionChooserPresented = true
                } label: {
                    Text("Choose Connection")
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("onboarding-choose-connection")
            }
            onboardingAlternatives
        }
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
            Button {
                welcomeStep = .nearby
            } label: {
                Text("Nearby Devices")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .accessibilityIdentifier("onboarding-nearby-devices")

            Button {
                welcomeStep = .demo
                Task {
                    await connectionHost.connectDemo()
                    welcomeStep = nil
                }
            } label: {
                Text("Demo Mode")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .contentShape(Rectangle())
            }
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
        if isChoosingServer {
            manualServerAddress = address
            manualSetupPresented = true
        } else {
            welcomeStep = .manual(address: address)
        }
    }

    private func closeChooser() {
        if connectionHost.canCancelLogin, !connectionHost.cancelCloudSignIn() { return }
        dismiss()
    }
}

private struct ManualConnectionView: View {
    let initialServerAddress: String?
    let onClose: () -> Void
    let onConnected: () -> Void

    var body: some View {
        NavigationStack {
            ManualConnectionForm(initialServerAddress: initialServerAddress, onClose: onClose,
                                 onConnected: onConnected)
                .tesseraeScreenBackground()
                .navigationTitle("Connect Manually")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct ManualConnectionForm: View {
    @Environment(ConnectionHost.self) private var connectionHost
    @State private var serverAddress: String
    @State private var pairingCode: String
    @State private var connectionTask: Task<Void, Never>?
    @State private var connectionError: String?
    private let onClose: () -> Void
    private let onConnected: () -> Void

    init(
        initialServerAddress: String? = nil,
        onClose: @escaping () -> Void,
        onConnected: @escaping () -> Void = {}
    ) {
        self.onClose = onClose
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
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", systemImage: "xmark") {
                    connectionTask?.cancel()
                    onClose()
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
                            onClose()
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
