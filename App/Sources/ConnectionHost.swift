import AuthenticationServices
import Foundation
import Observation
import TesseraeKit

@MainActor @Observable
final class ConnectionHost {
    enum LoginPhase { case idle, browser, exchanging, committing }
    private(set) var cloud: CloudBrowseModel?
    private(set) var savedConnections: [SavedConnection] = []
    private(set) var loginPhase: LoginPhase = .idle
    private(set) var isSwitching = false
    private(set) var isRestoring = true
    var loginError: String?
    private let runtime: ConnectionRuntime?
    private let local: AppModel
    private let vault: CloudLoginVault
    private let oauth: CloudOAuthClient
    private let issuer: URL
    private let browser = CloudSignInBrowser()
    private var attemptID: UUID?
    private var selectionIntent = UUID()
    private var tail: Task<Void, Never>?
    private var didRestore = false

    init(local: AppModel, runtime: ConnectionRuntime?, vault: CloudLoginVault,
         oauth: CloudOAuthClient = CloudOAuthClient(), issuer: URL = AppConfiguration.cloudIssuer) {
        self.local = local; self.runtime = runtime; self.vault = vault; self.oauth = oauth
        self.issuer = issuer
    }
    var cloudAvailable: Bool { runtime != nil }
    var isSigningIn: Bool { loginPhase != .idle }
    var canCancelLogin: Bool { loginPhase == .browser || loginPhase == .exchanging }

    func reloadSavedConnections() {
        do { savedConnections = try runtime?.registry.savedConnections() ?? [] }
        catch { loginError = error.localizedDescription }
    }
    func restore() async {
        guard !didRestore else { return }
        didRestore = true
        defer { isRestoring = false }
        await serialized {
            await self.local.restoreConnectionIfNeeded()
            if let runtime = self.runtime, let id = try runtime.registry.selectedID(),
               let descriptor = try runtime.registry.connection(id), case .cloud = descriptor.identity {
                let client = try await CloudReadClient(transport: runtime.cloudTransport(for: id))
                self.local.suspendForConnectionSwitch()
                self.cloud = CloudBrowseModel(client: client)
            }
            self.reloadSavedConnections()
            if self.runtime != nil, self.attemptID == nil, let pending = try self.vault.pending() {
                if !pending.consumed, Date().timeIntervalSince(pending.createdAt) < 900 {
                    self.attemptID = pending.id; self.loginPhase = .browser
                } else {
                    try self.vault.invalidate()
                    self.loginError = CloudLoginError.expired.localizedDescription
                }
            }
        }
        await cloud?.refresh()
        if runtime != nil { await drainRevocations() }
    }

    func beginCloudSignIn() async {
        guard runtime != nil else { loginError = CloudLoginError.unavailable.localizedDescription; return }
        if loginPhase == .committing {
            await serialized { }; await beginCloudSignIn(); return
        }
        guard cancelCloudSignIn() else { return }
        selectionIntent = UUID()
        do {
            let attempt = try PendingCloudLogin(issuer: issuer)
            try vault.replace(attempt)
            attemptID = attempt.id; loginPhase = .browser; loginError = nil
            try browser.open(AppConfiguration.cloudBrowserURL(attempt.authorizationURL)) { [weak self] url, error in
                guard let self else { return }
                if let url {
                    Task { await self.receiveCloudCallback(url) }
                } else if self.attemptID == attempt.id && self.loginPhase == .browser {
                    self.cancelCloudSignIn()
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                        self.loginError = error?.localizedDescription ?? CloudLoginError.unavailable.localizedDescription
                    }
                }
            }
        } catch { loginPhase = .idle; loginError = error.localizedDescription }
    }
    @discardableResult func cancelCloudSignIn() -> Bool {
        guard runtime != nil else { return true }
        guard loginPhase != .committing else { return false }
        do { try vault.invalidate() } catch { loginError = error.localizedDescription; return false }
        attemptID = nil; loginPhase = .idle
        browser.cancel()
        return true
    }
    func receiveCloudCallback(_ url: URL) async {
        let claimed: (PendingCloudLogin, String)?
        do { claimed = try vault.claim(url, issuer: issuer) }
        catch {
            loginError = error.localizedDescription
            if case CloudLoginError.denied = error { cancelCloudSignIn() }
            return
        }
        guard let (attempt, code) = claimed else { return }
        do {
            guard attemptID == nil || attemptID == attempt.id else { throw CloudLoginError.expired }
            attemptID = attempt.id; loginPhase = .exchanging; loginError = nil
            browser.cancel()
            let response = try await oauth.exchange(attempt, code: code)
            var acceptedModel: CloudBrowseModel?
            await serialized {
                guard self.attemptID == attempt.id, self.loginPhase == .exchanging else {
                    _ = try self.vault.retainRevocation(issuer: attempt.issuer, token: response.refreshToken)
                    return
                }
                guard let runtime = self.runtime else { throw CloudLoginError.unavailable }
                self.loginPhase = .committing
                let id = ConnectionIdentity.cloud(issuer: attempt.issuer, userID: response.user.id, tenantID: response.tenant.id).id
                var priorFence: ConnectionFence?
                var installedFence: ConnectionFence?
                var installationStarted = false
                do {
                    priorFence = try await runtime.sessions.fence(for: id)
                    if self.cloud?.fence.connectionID == id {
                        self.cloud?.invalidate(); self.cloud = nil
                        self.local.suspendForConnectionSwitch()
                    }
                    installationStarted = true
                    installedFence = try await runtime.installCloud(issuer: attempt.issuer, response: response)
                    try await runtime.activate(id)
                    let client = try await CloudReadClient(transport: runtime.cloudTransport(for: id))
                    self.cloud?.invalidate()
                    self.local.suspendForConnectionSwitch()
                    self.cloud = CloudBrowseModel(client: client)
                    acceptedModel = self.cloud
                    try self.vault.invalidate()
                    self.attemptID = nil; self.loginPhase = .idle
                    self.reloadSavedConnections()
                } catch {
                    let installationError = error
                    if installationStarted, installedFence == nil, let current = try? await runtime.sessions.fence(for: id), current != priorFence {
                        installedFence = current
                    }
                    if let installedFence {
                        self.cloud?.invalidate(); self.cloud = nil
                        try? await runtime.sessions.close(installedFence)
                        Task { try? await runtime.signOut(installedFence) }
                    } else {
                        _ = try self.vault.retainRevocation(issuer: attempt.issuer, token: response.refreshToken)
                    }
                    throw installationError
                }
            }
            if attemptID == attempt.id { attemptID = nil; loginPhase = .idle }
            if let acceptedModel, cloud === acceptedModel { await acceptedModel.refresh() }
            await drainRevocations()
        } catch {
            if attemptID == attempt.id {
                loginError = error.localizedDescription
                attemptID = nil; loginPhase = .idle
                try? vault.invalidate()
            }
        }
    }
    func select(_ id: ConnectionID) async {
        if loginPhase != .committing, !cancelCloudSignIn() { return }
        loginError = nil
        let intent = UUID(); selectionIntent = intent
        await serialized {
            guard self.selectionIntent == intent, let runtime = self.runtime,
                  let descriptor = try runtime.registry.connection(id) else { return }
            self.isSwitching = true
            defer { self.isSwitching = false }
            try await runtime.activate(id)
            self.cloud?.invalidate(); self.cloud = nil
            self.local.suspendForConnectionSwitch()
            switch descriptor.identity {
            case .cloud:
                self.cloud = try await CloudBrowseModel(client: CloudReadClient(transport: runtime.cloudTransport(for: id)))
            case .selfHosted:
                await self.local.restoreSelectedLocalConnection()
            }
        }
        await cloud?.refresh()
    }
    func connectDemo() async {
        if loginPhase != .committing, !cancelCloudSignIn() { return }
        loginError = nil
        let intent = UUID(); selectionIntent = intent
        await serialized {
            guard self.selectionIntent == intent else { return }
            try self.runtime?.registry.select(nil)
            self.cloud?.invalidate(); self.cloud = nil
            self.local.suspendForConnectionSwitch()
            await self.local.connectDemo()
        }
    }
    func connectLocal(baseURL: URL, code: String, clientName: String,
                      onFailure: (String) -> Void) async -> Bool {
        if loginPhase != .committing, !cancelCloudSignIn() { return false }
        loginError = nil
        let intent = UUID(); selectionIntent = intent
        var connected = false
        var failure: String?
        await serialized {
            guard self.selectionIntent == intent else { return }
            connected = await self.local.connectLive(baseURL: baseURL, code: code, clientName: clientName,
                onFailure: { failure = $0 })
            if connected { self.cloud?.invalidate(); self.cloud = nil; self.reloadSavedConnections() }
        }
        if !connected, !Task.isCancelled, let failure { onFailure(failure) }
        return connected
    }
    func signOut() async {
        if loginPhase != .committing, !cancelCloudSignIn() { return }
        selectionIntent = UUID()
        await serialized {
            if let cloud = self.cloud, let runtime = self.runtime {
                let fence = cloud.fence
                cloud.invalidate(); self.cloud = nil
                self.local.suspendForConnectionSwitch()
                try await runtime.signOut(fence)
            } else { await self.local.disconnect() }
            self.reloadSavedConnections()
        }
    }
    private func drainRevocations() async {
        guard let records = try? vault.revocations() else { return }
        for record in records {
            do { try await oauth.revoke(record); try vault.removeRevocation(record.id) }
            catch { }
        }
    }
    private func serialized(_ operation: @escaping @MainActor () async throws -> Void) async {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            do { try await operation() }
            catch { self.loginError = error.localizedDescription }
        }
        tail = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }
}
