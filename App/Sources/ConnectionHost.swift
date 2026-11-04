import AuthenticationServices
import Foundation
import Observation
import TesseraeKit

struct CloudPresentationContext: Hashable, Sendable {
    let revision: UUID
    let fence: ConnectionFence
    fileprivate let selectionIntent: UUID
    fileprivate init(revision: UUID, fence: ConnectionFence, selectionIntent: UUID) {
        self.revision = revision; self.fence = fence; self.selectionIntent = selectionIntent
    }
}

@MainActor @Observable
final class ConnectionHost {
    enum LoginPhase { case idle, browser, exchanging, committing }
    private(set) var cloud: CloudBrowseModel?
    private(set) var cloudContextRevision = UUID()
    private var submissions: CloudSubmissionService?
    private var acceptedCloudDecisions: Set<UUID> = []
    private var permissionCheckedResults: Set<UUID> = []
    private let submissionDirectory: URL
    private let sendPreferences: any CompanionSendPreferencesStoring
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
         oauth: CloudOAuthClient = CloudOAuthClient(), issuer: URL = AppConfiguration.cloudIssuer,
         submissionDirectory: URL? = AppConfiguration.sharedContainerURL,
         sendPreferences: any CompanionSendPreferencesStoring = InMemoryCompanionSendPreferencesStore()) {
        self.local = local; self.runtime = runtime; self.vault = vault; self.oauth = oauth
        self.issuer = issuer
        self.sendPreferences = sendPreferences
        self.submissionDirectory = submissionDirectory ?? URL.applicationSupportDirectory.appending(path: "CloudSubmissions")
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
        let intent = selectionIntent
        await local.restoreConnectionIfNeeded()
        await serialized {
            guard self.selectionIntent == intent else { return }
            if let runtime = self.runtime, let id = try runtime.registry.selectedID(),
               let descriptor = try runtime.registry.connection(id), case .cloud = descriptor.identity {
                let client = try await CloudReadClient(transport: runtime.cloudTransport(for: id))
                self.local.suspendForConnectionSwitch()
                try self.installCloudPresentation(client: client)
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
                    try await self.stopCloudExecution()
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
                    try self.installCloudPresentation(client: client)
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
        var localRevision: UUID?
        await serialized {
            guard self.selectionIntent == intent, let runtime = self.runtime,
                  let descriptor = try runtime.registry.connection(id) else { return }
            self.isSwitching = true
            defer { self.isSwitching = false }
            try await self.stopCloudExecution()
            try await runtime.activate(id)
            self.cloud?.invalidate(); self.cloud = nil
            self.local.suspendForConnectionSwitch()
            switch descriptor.identity {
            case .cloud:
                let client = try await CloudReadClient(transport: runtime.cloudTransport(for: id))
                try self.installCloudPresentation(client: client)
            case .selfHosted:
                localRevision = self.local.connectionRevision
            }
        }
        if let localRevision {
            await local.restoreSelectedLocalConnection(ifRevision: localRevision)
        }
        await cloud?.refresh()
    }
    func connectDemo() async {
        if loginPhase != .committing, !cancelCloudSignIn() { return }
        loginError = nil
        let intent = UUID(); selectionIntent = intent
        do {
            let prepared = try await local.prepareDemoConnection()
            await commitPreparedLocal(prepared, intent: intent)
        } catch { if !Task.isCancelled, selectionIntent == intent { loginError = error.localizedDescription } }
    }
    func connectLocal(baseURL: URL, code: String, clientName: String,
                      onFailure: (String) -> Void) async -> Bool {
        if loginPhase != .committing, !cancelCloudSignIn() { return false }
        loginError = nil
        let intent = UUID(); selectionIntent = intent
        do {
            let prepared = try await local.prepareLocalConnection(baseURL: baseURL, code: code, clientName: clientName)
            let connected = await commitPreparedLocal(prepared, intent: intent)
            if !connected, selectionIntent == intent, let loginError { onFailure(loginError) }
            return connected
        } catch {
            if !Task.isCancelled, selectionIntent == intent { onFailure(error.localizedDescription) }
            return false
        }
    }
    @discardableResult
    private func commitPreparedLocal(_ prepared: AppModel.PreparedConnection, intent: UUID) async -> Bool {
        var revision: UUID?
        await serialized {
            guard self.selectionIntent == intent else { return }
            try Task.checkCancellation()
            try await self.stopCloudExecution()
            if prepared.mode == .demo { try self.runtime?.registry.select(nil) }
            revision = try await self.local.commitConnection(prepared)
            self.cloud?.invalidate(); self.cloud = nil
            self.reloadSavedConnections()
        }
        guard let revision else { return false }
        let finish = Task { await self.local.finishConnection(revision: revision, attemptID: prepared.attemptID) }
        await finish.value
        return true
    }
    func signOut() async {
        if loginPhase != .committing, !cancelCloudSignIn() { return }
        let intent = UUID(); selectionIntent = intent
        var remoteFence: ConnectionFence?
        var legacySession: CompanionConnectionSession?
        await serialized {
            try await self.stopCloudExecution()
            if let runtime = self.runtime, let fence = self.cloud?.fence ?? self.local.activeFenceForSignOut {
                try await runtime.closeConnection(fence)
                remoteFence = fence
                self.cloud?.invalidate(); self.cloud = nil
                self.local.suspendForConnectionSwitch()
            } else { legacySession = self.local.connectionSession }
            self.reloadSavedConnections()
        }
        if let remoteFence, let runtime {
            do { try await runtime.sessions.retryRevocations(for: remoteFence.connectionID) }
            catch { if selectionIntent == intent { loginError = ConnectionError.remoteRevocationUnconfirmed.localizedDescription } }
        } else if let legacySession, local.connectionSession == legacySession {
            await local.disconnect()
        }
    }

    private func installCloudPresentation(client: CloudReadClient) throws {
        guard let runtime else { throw CloudLoginError.unavailable }
        cloudContextRevision = UUID()
        cloud = CloudBrowseModel(client: client)
        submissions = try CloudSubmissionService(runtime: runtime, directory: submissionDirectory, fence: client.fence)
    }
    private func stopCloudExecution() async throws {
        try await submissions?.stopExecution()
        submissions = nil
        acceptedCloudDecisions = []
        permissionCheckedResults = []
        cloudContextRevision = UUID()
    }

    var cloudPresentationContext: CloudPresentationContext? {
        guard let cloud else { return nil }
        return .init(revision: cloudContextRevision, fence: cloud.fence, selectionIntent: selectionIntent)
    }
    var canUseCloudSubmissions: Bool {
        cloud != nil && submissions != nil && cloud?.needsSignIn == false && cloud?.isRestricted == false
    }
    @discardableResult
    func withCurrentCloudPresentation(_ context: CloudPresentationContext, _ update: () -> Void) -> Bool {
        guard cloudPresentationContext == context, canUseCloudSubmissions else { return false }
        update()
        return true
    }
    func cloudSendPreferences(context: CloudPresentationContext) async throws -> CompanionSendPreferences? {
        _ = try cloudAccess(context)
        let value = try await sendPreferences.preferences(for: context.fence.connectionID.rawValue)
        _ = try cloudAccess(context)
        return value
    }
    func saveCloudSendPreferences(targetIDs: Set<String>, fit: ImageFitMode, context: CloudPresentationContext) async throws {
        _ = try cloudAccess(context)
        try await sendPreferences.save(.init(instanceID: context.fence.connectionID.rawValue,
            deviceIDs: targetIDs.sorted(), imageFitMode: fit))
    }
    func submitCloudPhoto(media: PreparedUploadImage, selectedIDs: Set<String>, fit: ImageFitMode,
                          framings: [PanelAspectRatio: ImageFraming], decision: UUID,
                          context: CloudPresentationContext) async throws -> UUID {
        let (model, service) = try cloudAccess(context)
        do {
            let photo = try await CloudPhotoPreparer.prepare(data: media.data, devices: model.devices,
                selectedIDs: selectedIDs, fit: fit, framings: framings)
            let prepared = try await service.preparePhoto(decision: decision, targets: photo.targets, outputs: photo.outputs)
            return try await acceptCloud(prepared, context: context, model: model, service: service)
        } catch { await handleCloudReadError(error, model: model); throw error }
    }
    func refreshCloudCurrentPage(_ deviceID: String, decision: UUID,
                                 context: CloudPresentationContext) async throws -> UUID {
        let (model, service) = try cloudAccess(context)
        do {
            let prepared = try await service.prepareCurrentPage(decision: decision, deviceID: deviceID)
            return try await acceptCloud(prepared, context: context, model: model, service: service)
        } catch { await handleCloudReadError(error, model: model); throw error }
    }
    func resendCloud(_ sourceID: UUID, expectedRevision: Int, selection: CloudResendSelection,
                     decision: UUID, context: CloudPresentationContext) async throws -> UUID {
        let (model, service) = try cloudAccess(context)
        do {
            let prepared = try await service.prepareResend(decision: decision, sourceID: sourceID,
                expectedRevision: expectedRevision, selection: selection)
            return try await acceptCloud(prepared, context: context, model: model, service: service)
        } catch { await handleCloudReadError(error, model: model); throw error }
    }
    func cloudSubmissionHistory(context: CloudPresentationContext) async throws -> [CloudSubmissionBatch] {
        let (_, service) = try cloudAccess(context)
        let result = try await service.history()
        _ = try cloudAccess(context)
        return result
    }
    func cloudSubmissionResult(_ id: UUID, context: CloudPresentationContext) async throws -> CloudSubmissionBatch {
        let (model, service) = try cloudAccess(context)
        let batch = try await service.result(id)
        _ = try cloudAccess(context)
        for result in batch.results where batch.fence == context.fence
            && acceptedCloudDecisions.contains(id) && !permissionCheckedResults.contains(id) {
            guard case .refused(let problem, _, _) = result.outcome else { continue }
            let error: CloudReadError?
            switch problem {
            case .authorization: error = .unauthorized
            case .membershipRemoved: error = .forbidden(reason: "membership_removed")
            case .tenantUnavailable: error = .forbidden(reason: "tenant_unavailable")
            case .resourceMismatch: error = .forbidden(reason: "resource_mismatch")
            default: error = nil
            }
            if error != nil {
                permissionCheckedResults.insert(id)
                do { _ = try await model.client.account() }
                catch { await handleCloudReadError(error, model: model) }
                _ = try cloudAccess(context)
            }
        }
        if !batch.isActive {
            let newlyAccepted = acceptedCloudDecisions.remove(id) != nil
            permissionCheckedResults.remove(id)
            let generated = batch.results.contains { if case .generated = $0.outcome { true } else { false } }
            if newlyAccepted && generated {
                Task { [weak self] in
                    await model.refresh()
                    guard let self, self.cloud === model, self.cloudPresentationContext == context else { return }
                    if model.needsSignIn || model.isRestricted { await self.cloudReadAccessChanged() }
                }
            }
        }
        return batch
    }
    func cloudSubmissionPreview(_ id: UUID, taskID: UUID, context: CloudPresentationContext) async throws -> Data? {
        _ = try await cloudSubmissionResult(id, context: context)
        let (_, service) = try cloudAccess(context)
        let data = try await service.preview(id, taskID: taskID)
        _ = try cloudAccess(context)
        return data
    }
    func deleteCloudMedia(_ id: UUID, context: CloudPresentationContext) async throws {
        let (_, service) = try cloudAccess(context)
        try await service.deleteMedia(id)
    }
    func deleteCloudResult(_ id: UUID, context: CloudPresentationContext) async throws {
        let (_, service) = try cloudAccess(context)
        try await service.deleteResult(id)
    }
    func cloudReadAccessChanged() async {
        guard let model = cloud else { return }
        let service = submissions, revision = cloudContextRevision
        await serialized {
            guard self.cloud === model, self.submissions === service,
                  self.cloudContextRevision == revision else { return }
            if model.needsSignIn || model.isRestricted {
                try await self.stopCloudExecution()
            } else if self.submissions == nil, model.snapshot != nil, let runtime = self.runtime {
                try await runtime.sessions.validate(model.fence)
                self.submissions = try CloudSubmissionService(runtime: runtime, directory: self.submissionDirectory, fence: model.fence)
                self.cloudContextRevision = UUID()
            }
        }
    }
    private func cloudAccess(_ context: CloudPresentationContext) throws -> (CloudBrowseModel, CloudSubmissionService) {
        guard cloudPresentationContext == context, let cloud, let submissions,
              !cloud.needsSignIn, !cloud.isRestricted else { throw ConnectionError.sessionChanged }
        return (cloud, submissions)
    }
    private func acceptCloud(_ prepared: PreparedCloudSubmission, context: CloudPresentationContext,
                             model: CloudBrowseModel, service: CloudSubmissionService) async throws -> UUID {
        var result: Result<UUID, Error> = .failure(CancellationError())
        await serialized {
            do {
                let (current, active) = try self.cloudAccess(context)
                guard current === model, active === service else { throw ConnectionError.sessionChanged }
                let id = try await service.start(prepared)
                self.acceptedCloudDecisions.insert(id)
                result = .success(id)
            } catch { result = .failure(error) }
        }
        _ = try cloudAccess(context)
        return try result.get()
    }
    private func handleCloudReadError(_ error: Error, model: CloudBrowseModel) async {
        switch error {
        case CloudReadError.unauthorized, CloudReadError.forbidden,
             ConnectionError.authorizationRequired, ConnectionError.signedOut, ConnectionError.rotationOutcomeUnknown:
            guard cloud === model else { return }
            model.reportReadAuthorizationError(error)
            await cloudReadAccessChanged()
        default: break
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
