import SwiftUI
import TesseraeKit
import UIKit

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var manualSetupPresented = false
    @State private var manualServerAddress: String?
    @State private var manualPairingCode: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 32)

                    Image("TesseraeLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 88, height: 88)
                        .accessibilityHidden(true)

                    VStack(spacing: 10) {
                        Text("Tesserae Companion")
                            .font(.largeTitle.bold())
                        Text("A community-built client for the small, everyday actions around your displays.")
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

                    if model.isDiscovering || !model.discoveredInstances.isEmpty
                        || model.discoveryError != nil
                    {
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
                                    Text("If Local Network access is off, enable it in iOS Settings. You can still enter the server address manually.")
                                }
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                            } else if !model.isDiscovering
                                && model.discoveredInstances.isEmpty
                            {
                                Text("No server found. Manual connection still works when discovery is unavailable.")
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

                    Text("Bonjour finds servers but never authenticates. Every connection still requires a one-time code from Tesserae.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .tesseraeScreenBackground()
            .sheet(isPresented: $manualSetupPresented) {
                ManualConnectionView(
                    initialServerAddress: manualServerAddress,
                    initialPairingCode: manualPairingCode
                )
            }
            .task {
                if model.discoveredInstances.isEmpty {
                    await model.discoverNearby()
                }
            }
        }
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

    init(
        initialServerAddress: String? = nil,
        initialPairingCode: String? = nil
    ) {
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
                    Text("The app probes `/api/app/v1`, exchanges the one-time code, and stores the returned Companion token in Keychain.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connect Manually")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect") {
                        guard let url = URL(string: serverAddress) else {
                            model.lastError = String(
                                localized: "The server URL is invalid."
                            )
                            return
                        }
                        guard !pairingCode.isEmpty else {
                            model.lastError = String(
                                localized: "Enter the one-time pairing code shown by Tesserae."
                            )
                            return
                        }
                        Task {
                            await model.connectLive(
                                baseURL: url,
                                code: pairingCode,
                                clientName: UIDevice.current.name
                            )
                            if model.activeInstance != nil {
                                dismiss()
                            }
                        }
                    }
                }
            }
        }
    }
}
