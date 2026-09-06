import SwiftUI
import TesseraeKit
import UIKit

struct OnboardingView: View {
    var isChoosingServer = false
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var manualSetupPresented = false
    @State private var manualServerAddress: String?
    @State private var manualPairingCode: String?
    @State private var selectionContentHeight: CGFloat = 260
    @State private var selectionChromeHeight: CGFloat = 64

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    if !isChoosingServer {
                        Spacer(minLength: 32)

                        Image("TesseraeLogo")
                            .resizable()
                            .scaledToFit()
                            .frame(width: 88, height: 88)
                            .accessibilityHidden(true)

                        VStack(spacing: 10) {
                            Text("Tesserae Companion")
                                .font(.largeTitle.bold())
                            Text(
                                "The official Tesserae app for quick, everyday display tasks on iPhone."
                            )
                            .font(.title3)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                        }

                        VStack(spacing: 12) {
                            onboardingRow(
                                icon: "wifi",
                                title: "Find your server",
                                detail: "Discover on your local network or enter an address."
                            )
                            onboardingRow(
                                icon: "rectangle.stack",
                                title: "Send what matters",
                                detail: "Push a dashboard or photo without opening the full editor."
                            )
                            onboardingRow(
                                icon: "lock.shield",
                                title: "Local and revocable",
                                detail: "Pair once with a credential you can remove from Tesserae."
                            )
                        }
                        .tesseraeCard()

                    }

                    Group {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                Text("Nearby Tesserae")
                                    .font(.headline)
                                Spacer()
                                if model.isDiscovering {
                                    ProgressView()
                                } else {
                                    Button {
                                        Task { await model.discoverNearby() }
                                    } label: {
                                        Image(systemName: "arrow.clockwise")
                                    }
                                    .accessibilityLabel("Refresh nearby Tesserae servers")
                                }
                            }

                            ForEach(model.discoveredInstances) { instance in
                                Button {
                                    manualServerAddress = instance.baseURL.absoluteString
                                    manualPairingCode = nil
                                    manualSetupPresented = true
                                } label: {
                                    HStack {
                                        Image(systemName: "server.rack")
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(instance.name)
                                                .font(.body.weight(.semibold))
                                            Text(instance.baseURL.absoluteString)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }

                            if let discoveryError = model.discoveryError {
                                VStack(alignment: .leading, spacing: 4) {
                                    Label(
                                        discoveryError,
                                        systemImage: "wifi.exclamationmark"
                                    )
                                    Text(
                                        "If Local Network access is off, enable it in iOS Settings. You can still enter the server address manually."
                                    )
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            } else if !model.isDiscovering
                                && model.discoveredInstances.isEmpty
                            {
                                Text(
                                    "No server found. Manual connection still works when discovery is unavailable."
                                )
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            }
                        }
                        .tesseraeCard()
                    }

                    VStack(spacing: 12) {
                        Button("Enter Server Address") {
                            manualServerAddress = nil
                            manualPairingCode = nil
                            manualSetupPresented = true
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)

                        if !isChoosingServer {
                            NavigationLink {
                                NearbyDisplaysView()
                            } label: {
                                Label(
                                    "Nearby Setup & Maintenance",
                                    systemImage: "dot.radiowaves.left.and.right")
                            }
                            .accessibilityIdentifier("onboarding-nearby-devices")

                            Button {
                                Task { await model.connectDemo() }
                            } label: {
                                if model.activeOperationIDs.contains("pair") {
                                    ProgressView()
                                        .frame(maxWidth: .infinity)
                                } else {
                                    Text("Explore with Demo Data")
                                        .frame(maxWidth: .infinity)
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(TesseraeTheme.accent)
                            .disabled(model.activeOperationIDs.contains("pair"))
                        }
                    }

                    Text(
                        "Bonjour finds servers but never authenticates. Every connection still requires a one-time code from Tesserae."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                }
                .padding(20)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    ceil(geometry.size.height)
                } action: { height in
                    if isChoosingServer { selectionContentHeight = height }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .onGeometryChange(for: CGFloat.self) { geometry in
                // Keep the chrome allowance independent of the sheet's position.
                max(64, ceil(geometry.safeAreaInsets.top))
            } action: { height in
                if isChoosingServer { selectionChromeHeight = height }
            }
            .tesseraeScreenBackground()
            .sheet(isPresented: $manualSetupPresented) {
                ManualConnectionView(
                    initialServerAddress: manualServerAddress,
                    initialPairingCode: manualPairingCode,
                    onConnected: { if isChoosingServer { dismiss() } }
                )
            }
            .navigationTitle(isChoosingServer ? "Tesserae Servers" : "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isChoosingServer {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .task {
                if model.discoveredInstances.isEmpty {
                    await model.discoverNearby()
                }
            }
        }
        .presentationDetents(isChoosingServer
            ? [.height(max(200, selectionContentHeight + selectionChromeHeight))]
            : [.large])
        .presentationDragIndicator(isChoosingServer ? .visible : .automatic)
    }

    private func onboardingRow(
        icon: String,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(TesseraeTheme.accent)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct ManualConnectionView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppModel.self) private var model
    @State private var serverAddress: String
    @State private var pairingCode: String
    @State private var connectionTask: Task<Void, Never>?
    @State private var connectionError: String?
    private let onConnected: () -> Void

    init(
        initialServerAddress: String? = nil,
        initialPairingCode: String? = nil,
        onConnected: @escaping () -> Void = {}
    ) {
        self.onConnected = onConnected
        _serverAddress = State(
            initialValue: initialServerAddress
                ?? ProcessInfo.processInfo.environment["TESSERAE_SERVER_URL"]
                ?? "http://tesserae.local:8765"
        )
        _pairingCode = State(
            initialValue: initialPairingCode
                ?? ProcessInfo.processInfo.environment["TESSERAE_PAIRING_CODE"]
                ?? ""
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
                    Text(
                        "The app probes `/api/app/v1`, exchanges the one-time code, and stores the returned Companion token in Keychain."
                    )
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
                    Button("Cancel") {
                        connectionTask?.cancel()
                        dismiss()
                    }
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
                            let connected = await model.connectLive(
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
