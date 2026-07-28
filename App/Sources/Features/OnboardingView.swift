import SwiftUI

struct OnboardingView: View {
    @Environment(AppModel.self) private var model
    @State private var manualSetupPresented = false
    @State private var qrNoticePresented = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Spacer(minLength: 32)

                    Image(systemName: "square.grid.3x3.square")
                        .font(.system(size: 62, weight: .medium))
                        .foregroundStyle(TesseraeTheme.accent)
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

                    VStack(spacing: 12) {
                        Button {
                            qrNoticePresented = true
                        } label: {
                            Label("Scan Pairing QR", systemImage: "qrcode.viewfinder")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button("Enter Server Address") {
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

                    Text("The live pairing and discovery transports will be connected after the server contract is accepted.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding(20)
            }
            .tesseraeScreenBackground()
            .sheet(isPresented: $manualSetupPresented) {
                ManualConnectionView()
            }
            .alert("QR Pairing Placeholder", isPresented: $qrNoticePresented) {
                Button("Use Demo", action: {
                    Task { await model.connectDemo() }
                })
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Camera pairing is scaffolded but intentionally waits for the accepted Companion contract.")
            }
        }
    }

    private func onboardingRow(icon: String, title: String, detail: String) -> some View {
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
    @State private var serverAddress = "http://tesserae.local:8765"

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("http://host:port", text: $serverAddress)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                        .autocorrectionDisabled()
                }

                Section {
                    Text("This prototype uses fixture data after validating the URL shape. It does not send a password or call an internal Tesserae route.")
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
                            model.lastError = "The server URL is invalid."
                            return
                        }
                        Task {
                            await model.connectDemo(baseURL: url)
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

