import AuthenticationServices
import SwiftUI

struct CloudSignInView: View {
    @Environment(ConnectionHost.self) private var host
    @ScaledMetric(relativeTo: .body) private var optionHeight: CGFloat = 48
    @State private var email = ""
    @State private var code = ""
    @State private var resendingCode: UUID?
    @State private var didRequestNewCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch host.loginPhase {
            case .idle:
                Text("Sign in to connect to a Tesserae Cloud workspace.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                signInOptions
            case .appleEmail:
                emailVerification
            case .appleSendingCode:
                if resendingCode != nil {
                    codeVerification
                } else {
                    emailVerification
                }
            case .appleCode, .appleVerifyingCode:
                codeVerification
            default:
                ProgressView(progressTitle)
                    .accessibilityIdentifier("cloud-signin-progress")
                loginError
            }

            if host.canCancelLogin {
                if host.loginPhase == .browser {
                    Text("Open the sign-in link on this device.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Button("Cancel Sign-In", role: .cancel) { host.cancelCloudSignIn() }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.plain)
                    .foregroundStyle(TesseraeTheme.accent)
                    .accessibilityIdentifier("cloud-signin-cancel")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task {
            if host.loginPhase == .idle { await host.checkAppleSignInAvailability() }
        }
        .onChange(of: host.loginPhase) { _, phase in
            if phase == .idle || phase == .appleConsent || phase == .exchanging {
                email = ""
                code = ""
                resendingCode = nil
                didRequestNewCode = false
            }
        }
    }

    private var signInOptions: some View {
        VStack(spacing: 8) {
            if host.appleSignInAvailable {
                CloudAppleSignInButton {
                    Task { await host.beginAppleSignIn() }
                }
                .frame(maxWidth: .infinity)
                .frame(height: optionHeight)
                .disabled(host.isSwitching)
            }

            Button("Sign In with Email Link") {
                Task { await host.beginCloudSignIn() }
            }
            .buttonStyle(ConnectionOptionButtonStyle(minimumHeight: optionHeight))
            .disabled(!host.cloudAvailable || host.isSwitching)
            .accessibilityIdentifier("cloud-signin")
        }
    }

    private var emailVerification: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verify Your Existing Email")
                .font(.body.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Use the email address you already sign in to Tesserae Cloud with.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Cloud Account Email")
                .font(.subheadline.weight(.medium))
                .accessibilityHidden(true)
            TextField("Cloud Account Email", text: $email, prompt: Text(verbatim: ""))
                .textContentType(.emailAddress)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 44)
                .submitLabel(.send)
                .onSubmit(sendCode)
                .disabled(host.loginPhase == .appleSendingCode)
                .accessibilityLabel("Cloud Account Email")
                .accessibilityIdentifier("cloud-apple-email")
            loginError
            if host.loginPhase == .appleSendingCode {
                ProgressView("Requesting Code…")
            } else {
                primaryAction("Send Code", action: sendCode)
                    .disabled(!canSendCode)
                    .accessibilityIdentifier("cloud-apple-send-code")
            }
        }
    }

    private var codeVerification: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Enter the Verification Code")
                .font(.body.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("If the address matches a Cloud account, a six-digit code will arrive by email.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            TextField("Six-Digit Code", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .textFieldStyle(.roundedBorder)
                .frame(minHeight: 44)
                .disabled(host.loginPhase != .appleCode || resendingCode != nil)
                .onChange(of: code) { _, value in
                    let digits = value.utf8.filter { (48...57).contains($0) }
                    let sanitized = String(decoding: digits.prefix(6), as: UTF8.self)
                    if sanitized != value { code = sanitized }
                }
                .accessibilityLabel("Six-Digit Code")
                .accessibilityIdentifier("cloud-apple-code")
            loginError
            if resendingCode != nil {
                ProgressView("Requesting Code…")
            } else if host.loginPhase == .appleVerifyingCode {
                ProgressView("Verifying Code…")
            } else {
                primaryAction("Verify and Continue", action: verifyCode)
                    .disabled(code.count != 6)
                    .accessibilityIdentifier("cloud-apple-verify-code")
                codeOptions
                if didRequestNewCode && host.loginError == nil {
                    Text("Code requested. Check your inbox.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var codeOptions: some View {
        HStack(alignment: .top, spacing: 8) {
            Button {
                code = ""
                didRequestNewCode = false
                host.changeAppleVerificationEmail()
            } label: {
                Text("Change Email")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityIdentifier("cloud-apple-change-email")
            Button(action: resendCode) {
                Text("Resend Code")
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityIdentifier("cloud-apple-resend-code")
        }
        .buttonStyle(.plain)
        .foregroundStyle(TesseraeTheme.accent)
        .font(.subheadline.weight(.medium))
        .multilineTextAlignment(.center)
    }

    @ViewBuilder private var loginError: some View {
        if let error = host.loginError {
            ConnectionLoginErrorMessage(message: error)
        }
    }

    private func primaryAction(_ title: LocalizedStringKey, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.body.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.roundedRectangle(radius: CloudSignInButtonShape.cornerRadius))
        .controlSize(.large)
        .tint(TesseraeTheme.accentFill)
    }

    private var progressTitle: LocalizedStringKey {
        switch host.loginPhase {
        case .applePreparing: "Connecting to Cloud…"
        case .appleAuthorizing: "Waiting for Apple…"
        case .appleCompleting: "Checking Apple Sign-In…"
        case .appleConsent: "Waiting for Workspace Approval…"
        case .exchanging, .committing: "Finishing Sign-In…"
        default: "Waiting for Sign-In…"
        }
    }

    private var canSendCode: Bool {
        host.loginPhase == .appleEmail && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func sendCode() {
        guard canSendCode else { return }
        let address = email
        Task { await host.sendAppleEmailCode(address) }
    }

    private func verifyCode() {
        guard host.loginPhase == .appleCode, resendingCode == nil else { return }
        let submitted = code
        code = ""
        didRequestNewCode = false
        Task { await host.verifyAppleEmailCode(submitted) }
    }

    private func resendCode() {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard host.loginPhase == .appleCode, resendingCode == nil, !address.isEmpty else { return }
        let id = UUID()
        resendingCode = id
        didRequestNewCode = false
        Task {
            await host.sendAppleEmailCode(address)
            guard resendingCode == id else { return }
            resendingCode = nil
            if host.loginPhase == .appleCode && host.loginError == nil {
                code = ""
                didRequestNewCode = true
                AccessibilityNotification.Announcement(String(localized: "Code requested. Check your inbox.")).post()
            }
        }
    }
}

struct ConnectionLoginErrorMessage: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(.subheadline)
            .foregroundStyle(TesseraeTheme.danger)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("cloud-signin-error")
    }
}

private enum CloudSignInButtonShape {
    static let cornerRadius: CGFloat = 10
}

struct ConnectionOptionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    var minimumHeight: CGFloat = 48

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: CloudSignInButtonShape.cornerRadius, style: .circular)
        configuration.label
            .font(.body.weight(.medium))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: minimumHeight)
            .foregroundStyle(TesseraeTheme.accent)
            .background(configuration.isPressed ? TesseraeTheme.accentSoft : TesseraeTheme.background, in: shape)
            .overlay { shape.strokeBorder(TesseraeTheme.accent.opacity(0.45), lineWidth: 1) }
            .contentShape(shape)
            .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct CloudAppleSignInButton: UIViewRepresentable {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> ASAuthorizationAppleIDButton {
        let button = ASAuthorizationAppleIDButton(type: .signIn, style: colorScheme == .dark ? .white : .black)
        button.cornerRadius = CloudSignInButtonShape.cornerRadius
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
