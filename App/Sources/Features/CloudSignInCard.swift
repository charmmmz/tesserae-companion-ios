import AuthenticationServices
import SwiftUI

struct CloudSignInCard: View {
    @Environment(ConnectionHost.self) private var host

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tesserae Cloud", systemImage: "cloud").font(.headline)
            Group {
                if host.appleSignInAvailable {
                    Text("Sign in to your existing Cloud account and choose a workspace in the secure browser.")
                } else {
                    Text("Sign in with your email and choose a tenant in the secure browser.")
                }
            }
            .font(.subheadline).foregroundStyle(.secondary)
            CloudSignInControls()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
    }
}

struct CloudSignInControls: View {
    @Environment(ConnectionHost.self) private var host
    @State private var email = ""
    @State private var code = ""
    var inSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch host.loginPhase {
            case .idle:
                if host.appleSignInAvailable {
                    CloudAppleSignInButton {
                        Task { await host.beginAppleSignIn() }
                    }
                    .frame(height: 48)
                    .disabled(host.isSwitching)
                }
                emailSignInButton
            case .appleEmail, .appleSendingCode:
                Text("Verify Your Existing Email").font(.headline)
                Text("Enter the email you already use for Tesserae Cloud. We’ll send a six-digit code.")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextField("Cloud Account Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .disabled(host.loginPhase == .appleSendingCode)
                    .accessibilityIdentifier("cloud-apple-email")
                if host.loginPhase == .appleSendingCode {
                    ProgressView("Requesting Code…")
                } else {
                    Button("Send Code") { Task { await host.sendAppleEmailCode(email) } }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        .accessibilityIdentifier("cloud-apple-send-code")
                }
            case .appleCode, .appleVerifyingCode:
                Text("Enter the Verification Code").font(.headline)
                Text("If the address matches a Cloud account, a six-digit code will arrive by email.")
                    .font(.subheadline).foregroundStyle(.secondary)
                TextField("Six-Digit Code", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(minHeight: 44)
                    .disabled(host.loginPhase == .appleVerifyingCode)
                    .onChange(of: code) { _, value in
                        code = String(value.filter { $0.isASCII && $0.isNumber }.prefix(6))
                    }
                    .accessibilityIdentifier("cloud-apple-code")
                if host.loginPhase == .appleVerifyingCode {
                    ProgressView("Verifying Code…")
                } else {
                    Button("Verify and Continue") {
                        let submitted = code
                        code = ""
                        Task { await host.verifyAppleEmailCode(submitted) }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(code.count != 6)
                    .accessibilityIdentifier("cloud-apple-verify-code")
                    Button("Change Email or Request Another Code") {
                        code = ""
                        host.changeAppleVerificationEmail()
                    }
                    .frame(minHeight: 44)
                }
            default:
                ProgressView(String(localized: host.loginPhase == .committing ? "Finishing Sign-In…" : "Waiting for Sign-In…"))
                    .accessibilityIdentifier("cloud-signin-progress")
            }

            if host.canCancelLogin {
                Button("Cancel Sign-In", role: .cancel) { host.cancelCloudSignIn() }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("cloud-signin-cancel")
                if host.loginPhase == .browser {
                    Text("If the email link opened on another device, return to this device or start sign-in again here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }

            if let error = host.loginError {
                Text(error).foregroundStyle(TesseraeTheme.danger)
                    .font(.footnote).accessibilityIdentifier("cloud-signin-error")
            }
        }
        .task { await host.checkAppleSignInAvailability() }
        .onChange(of: host.loginPhase) { _, phase in
            if phase == .idle || phase == .appleConsent || phase == .exchanging {
                email = ""
                code = ""
            }
        }
    }

    @ViewBuilder private var emailSignInButton: some View {
        if inSettings {
            Button(String(localized: host.appleSignInAvailable ? "Sign In with Email" : "Sign In Again"),
                   systemImage: "person.crop.circle.badge.checkmark", action: beginEmailSignIn)
                .frame(minHeight: 44)
                .disabled(host.isSwitching)
        } else {
            Button(String(localized: host.appleSignInAvailable ? "Sign In with Email" : "Sign In to Cloud"),
                   systemImage: "person.crop.circle", action: beginEmailSignIn)
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!host.cloudAvailable || host.isSwitching)
                .accessibilityIdentifier("cloud-signin")
        }
    }

    private func beginEmailSignIn() {
        Task { await host.beginCloudSignIn() }
    }
}

private struct CloudAppleSignInButton: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: colorScheme == .dark ? .white : .black)
        button.accessibilityIdentifier = "cloud-signin-apple"
        button.addTarget(context.coordinator, action: #selector(Coordinator.signIn), for: .touchUpInside)
        return button
    }

    func updateUIView(_ button: ASAuthorizationAppleIDButton, context: Context) {
        context.coordinator.action = action
        button.isEnabled = isEnabled
    }

    final class Coordinator: NSObject {
        var action: () -> Void

        init(action: @escaping () -> Void) { self.action = action }

        @objc func signIn() { action() }
    }
}
