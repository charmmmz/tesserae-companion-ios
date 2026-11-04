import SwiftUI

struct CloudSignInCard: View {
    @Environment(ConnectionHost.self) private var host
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tesserae Cloud", systemImage: "cloud").font(.headline)
            Text("Sign in with your email and choose a tenant in the secure browser.")
                .font(.subheadline).foregroundStyle(.secondary)
            if host.isSigningIn {
                ProgressView(String(localized: host.loginPhase == .committing ? "Finishing Sign-In…" : "Waiting for Sign-In…"))
                    .accessibilityIdentifier("cloud-signin-progress")
                if host.canCancelLogin {
                    Button("Cancel Sign-In", role: .cancel) { host.cancelCloudSignIn() }
                        .accessibilityIdentifier("cloud-signin-cancel")
                    Text("If the email link opened on another device, return to this device or start sign-in again here.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Button("Sign In to Cloud", systemImage: "person.crop.circle") {
                    Task { await host.beginCloudSignIn() }
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .disabled(!host.cloudAvailable)
                .accessibilityIdentifier("cloud-signin")
            }
            if let error = host.loginError {
                Text(error).foregroundStyle(TesseraeTheme.danger)
                    .font(.footnote).accessibilityIdentifier("cloud-signin-error")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tesseraeCard()
    }
}
