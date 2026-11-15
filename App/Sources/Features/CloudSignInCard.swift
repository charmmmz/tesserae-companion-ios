import SwiftUI

struct CloudSignInView: View {
    @Environment(ConnectionHost.self) private var host
    @State private var email = ""
    @State private var code = ""
    @State private var resendingCode: UUID?
    @State private var didRequestNewCode = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch host.loginPhase {
            case .idle:
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
                signInProgress
                loginError
            }

            if host.canCancelLogin {
                Button("Cancel", role: .cancel) { host.cancelCloudSignIn() }
                    .font(.subheadline.weight(.medium))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .buttonStyle(.plain)
                    .foregroundStyle(TesseraeTheme.accent)
                    .accessibilityLabel("Cancel Sign-In")
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
        VStack(spacing: 4) {
            if host.appleSignInAvailable {
                Button("Continue with Apple") {
                    Task { await host.beginAppleSignIn() }
                }
                .buttonStyle(ConnectionOptionButtonStyle(option: .apple))
                .disabled(host.isSwitching)
                .accessibilityIdentifier("cloud-signin-apple")
            }

            Button("Continue with email link") {
                Task { await host.beginCloudSignIn() }
            }
            .buttonStyle(ConnectionOptionButtonStyle(option: .email))
            .disabled(!host.cloudAvailable || host.isSwitching)
            .accessibilityIdentifier("cloud-signin")
        }
    }

    private var signInProgress: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ProgressView()
                    .accessibilityHidden(true)
                Text(progressTitle)
                    .font(.subheadline.weight(.medium))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("cloud-signin-progress")

            if host.loginPhase == .browser && host.canCancelLogin {
                Text("Open the link on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
    }

    private var emailVerification: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verify Your Existing Email")
                .font(.body.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            Text("Use your existing Cloud email address.")
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
        case .browser: "Check your email"
        case .appleAuthorizing: "Waiting for Apple…"
        case .appleCompleting: "Checking with Apple…"
        case .appleConsent: "Choose a workspace"
        default: "Connecting to Cloud…"
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
    enum Option {
        case serverAddress, apple, email
    }

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .callout) private var scaledSignInHeight: CGFloat = 37
    var option: Option = .serverAddress

    func makeBody(configuration: Configuration) -> some View {
        let isSignIn = option != .serverAddress
        let isApple = option == .apple
        let signInHeight = max(30, scaledSignInHeight)
        let shape = RoundedRectangle(cornerRadius: CloudSignInButtonShape.cornerRadius, style: .continuous)
        let foreground = isApple ? (colorScheme == .dark ? Color.black : .white) : TesseraeTheme.accent
        let background = isApple
            ? (colorScheme == .dark ? Color.white : .black)
            : (configuration.isPressed ? TesseraeTheme.accentSoft : TesseraeTheme.background)

        HStack(spacing: 8) {
            if isSignIn {
                signInIcon(height: signInHeight)
                    .accessibilityHidden(true)
            }
            configuration.label
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.vertical, 6)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: isSignIn ? signInHeight : 48)
        .foregroundStyle(foreground)
        .background(background, in: shape)
        .overlay {
            if !isApple { shape.strokeBorder(TesseraeTheme.accent.opacity(0.45), lineWidth: 1) }
        }
        .clipShape(shape)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .opacity(isEnabled ? (isApple && configuration.isPressed ? 0.8 : 1) : 0.5)
    }

    private func signInIcon(height: CGFloat) -> some View {
        let iconSize = height * 0.43
        return Color.clear
            .frame(width: iconSize, height: height)
            .overlay {
                if option == .apple {
                    Image("AppleSignInArtwork")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: height, height: height)
                } else {
                    Image(systemName: "envelope")
                        .resizable()
                        .scaledToFit()
                        .frame(width: iconSize, height: iconSize)
                }
            }
    }
}
