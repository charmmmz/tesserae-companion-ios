import AuthenticationServices
import Observation
import Foundation
import TesseraeKit

struct CloudAppleCredential: Sendable {
    let identityToken: String
    let authorizationCode: String
}

@MainActor
protocol CloudAppleAuthorizing {
    func authorize(nonce: String, state: String) async throws -> CloudAppleCredential
    func cancel()
}

@MainActor
final class CloudAppleAuthorization: NSObject, CloudAppleAuthorizing,
    ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    private struct Request {
        let controller: ASAuthorizationController
        let state: String
        let result: CheckedContinuation<CloudAppleCredential, Error>
    }

    private var request: Request?

    func authorize(nonce: String, state: String) async throws -> CloudAppleCredential {
        try Task.checkCancellation()
        guard request == nil else { throw CloudLoginError.unavailable }
        let authorization = ASAuthorizationAppleIDProvider().createRequest()
        authorization.requestedScopes = [.email]
        authorization.nonce = nonce
        authorization.state = state
        let controller = ASAuthorizationController(authorizationRequests: [authorization])
        controller.delegate = self
        controller.presentationContextProvider = self
        return try await withCheckedThrowingContinuation { continuation in
            request = Request(controller: controller, state: state, result: continuation)
            controller.performRequests()
        }
    }

    func cancel() {
        guard let current = request else { return }
        request = nil
        current.controller.cancel()
        current.result.resume(throwing: CancellationError())
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let current = request, controller === current.controller else { return }
        request = nil
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              credential.state == current.state,
              let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8), !token.isEmpty,
              let codeData = credential.authorizationCode, let code = String(data: codeData, encoding: .utf8), !code.isEmpty else {
            current.result.resume(throwing: CloudLoginError.exchangeFailed)
            return
        }
        current.result.resume(returning: CloudAppleCredential(identityToken: token, authorizationCode: code))
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        guard let current = request, controller === current.controller else { return }
        request = nil
        if (error as? ASAuthorizationError)?.code == .canceled {
            current.result.resume(throwing: CancellationError())
        } else {
            current.result.resume(throwing: CloudLoginError.exchangeFailed)
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        cloudSignInPresentationAnchor()
    }
}

enum CloudAppleSignInError: Error, LocalizedError {
    case startUnavailable, codeRequest, codeVerification, tryLater

    var errorDescription: String? {
        switch self {
        case .startUnavailable: String(localized: "Apple sign-in is unavailable. Try again or sign in with email.")
        case .codeRequest: String(localized: "Could not request a code. Check the email address or start sign-in again.")
        case .codeVerification: String(localized: "Could not verify the code. Check it or start sign-in again.")
        case .tryLater: String(localized: "Please wait a moment before trying again.")
        }
    }
}

struct CloudAppleSignInStart: Decodable, Sendable {
    let attemptID: String
    let nonce: String

    private enum CodingKeys: String, CodingKey { case attemptID = "attempt_id", nonce }
}

struct CloudAppleConsent: Sendable {
    let userID: String
    let url: URL
}

enum CloudAppleSignInOutcome: Sendable {
    case ready(CloudAppleConsent)
    case verifyEmail
}

enum CloudAppleSignInMethod: Sendable {
    case web, native
}

extension CloudOAuthClient {
    static func supportsAppleSignIn(issuer: URL) -> Bool { appleIssuer(issuer) != nil }

    func appleSignInMethod(issuer: URL) async throws -> CloudAppleSignInMethod? {
        guard Self.supportsAppleSignIn(issuer: issuer) else { return nil }
        struct Providers: Decodable {
            let apple_web: Bool?
            let apple_native: Bool?
        }
        let response = try await appleRequest(issuer: issuer, path: "auth/providers")
        guard response.statusCode == 200,
              let providers = try? JSONDecoder().decode(Providers.self, from: response.data) else { return nil }
        if providers.apple_web == true { return .web }
        if providers.apple_native == true, issuer.host?.lowercased() != AppConfiguration.defaultCloudIssuer.host {
            return .native
        }
        return nil
    }

    static func appleWebStartURL(_ attempt: PendingCloudLogin) throws -> URL {
        guard var start = appleIssuer(attempt.issuer),
              let authorization = URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false),
              let query = authorization.percentEncodedQuery else { throw CloudLoginError.unavailable }
        start.path = "/auth/apple/web/start"
        start.queryItems = [URLQueryItem(name: "next", value: "\(authorization.percentEncodedPath)?\(query)")]
        guard let url = start.url else { throw CloudLoginError.unavailable }
        return url
    }

    func startAppleSignIn(_ attempt: PendingCloudLogin) async throws -> CloudAppleSignInStart {
        let response = try await appleRequest(issuer: attempt.issuer, path: "auth/apple/start",
                                              body: ["authorization_url": attempt.authorizationURL.absoluteString])
        guard response.statusCode == 200,
              let result = try? JSONDecoder().decode(CloudAppleSignInStart.self, from: response.data),
              !result.attemptID.isEmpty, !result.nonce.isEmpty else { throw CloudLoginError.exchangeFailed }
        return result
    }

    func completeAppleSignIn(issuer: URL, attemptID: String, credential: CloudAppleCredential) async throws -> CloudAppleSignInOutcome {
        let response = try await appleRequest(issuer: issuer, path: "auth/apple/complete", body: [
            "attempt_id": attemptID, "identity_token": credential.identityToken, "authorization_code": credential.authorizationCode
        ])
        return try appleOutcome(response, issuer: issuer)
    }

    func sendAppleEmailCode(issuer: URL, attemptID: String, email: String) async throws {
        let response = try await appleRequest(issuer: issuer, path: "auth/apple/email",
                                              body: ["attempt_id": attemptID, "email": email])
        if response.statusCode == 429 { throw CloudAppleSignInError.tryLater }
        guard response.statusCode == 204 else { throw CloudAppleSignInError.codeRequest }
    }

    func verifyAppleEmailCode(issuer: URL, attemptID: String, code: String) async throws -> CloudAppleConsent {
        let response = try await appleRequest(issuer: issuer, path: "auth/apple/verify",
                                              body: ["attempt_id": attemptID, "code": code])
        if response.statusCode == 429 { throw CloudAppleSignInError.tryLater }
        guard response.statusCode == 200 else { throw CloudAppleSignInError.codeVerification }
        guard case let .ready(consent) = try appleOutcome(response, issuer: issuer) else {
            throw CloudLoginError.exchangeFailed
        }
        return consent
    }

    private func appleRequest(issuer: URL, path: String, body: [String: String]? = nil) async throws -> TesseraeHTTPResponse {
        guard Self.supportsAppleSignIn(issuer: issuer) else { throw CloudLoginError.unavailable }
        try Task.checkCancellation()
        var request = URLRequest(url: issuer.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: Self.requestTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(body)
        }
        return try await transport.send(request)
    }

    private func appleOutcome(_ response: TesseraeHTTPResponse, issuer: URL) throws -> CloudAppleSignInOutcome {
        struct Reply: Decodable {
            enum Status: String, Decodable { case ready, verifyEmail = "verify_email" }
            let status: Status
            let user_id: String?
            let consent_url: String?
        }
        guard response.statusCode == 200, let reply = try? JSONDecoder().decode(Reply.self, from: response.data) else {
            throw CloudLoginError.exchangeFailed
        }
        switch reply.status {
        case .verifyEmail:
            return .verifyEmail
        case .ready:
            guard let userID = reply.user_id, !userID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let rawURL = reply.consent_url, let url = Self.appleConsentURL(rawURL, issuer: issuer) else {
                throw CloudLoginError.exchangeFailed
            }
            return .ready(CloudAppleConsent(userID: userID, url: url))
        }
    }

    private static func appleIssuer(_ issuer: URL) -> URLComponents? {
        guard let parts = URLComponents(url: issuer, resolvingAgainstBaseURL: false), parts.scheme == "https",
              let host = parts.host, !host.isEmpty, ["", "/"].contains(parts.percentEncodedPath),
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.query == nil else { return nil }
        return parts
    }

    static func appleConsentURL(_ raw: String, issuer: URL) -> URL? {
        guard let expected = appleIssuer(issuer), let parts = URLComponents(string: raw),
              parts.scheme == "https", parts.host?.lowercased() == expected.host?.lowercased(),
              (parts.port ?? 443) == (expected.port ?? 443), parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.percentEncodedPath == "/auth/apple/consent",
              let query = parts.queryItems, query.count == 1, query[0].name == "ticket",
              let ticket = query[0].value, !ticket.isEmpty, ticket.utf8.count <= 512,
              ticket.utf8.allSatisfy({
                  (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95
              }),
              parts.percentEncodedQuery == "ticket=\(ticket)" else { return nil }
        return parts.url
    }
}

@MainActor @Observable
final class CloudAppleAccountLinkModel {
    private enum Phase: Equatable {
        case idle, checking(UUID), starting(UUID), authorizing(UUID)
    }

    private enum Outcome: String {
        case linked, cancelled, failed
    }

    private static let callbackPath = "/apple/link/callback"
    private let browser: any CloudSignInBrowsing
    private var phase: Phase = .idle
    private(set) var isLinked: Bool?
    private(set) var problem: String?

    init(browser: any CloudSignInBrowsing = CloudSignInBrowser()) {
        self.browser = browser
    }

    var isBusy: Bool { phase != .idle }

    static func isLinkCallback(_ url: URL) -> Bool {
        url.scheme == PendingCloudLogin.callbackScheme && url.path == callbackPath
    }

    func reset() {
        phase = .idle
        isLinked = nil
        problem = nil
        browser.cancel()
    }

    func check(_ client: CloudReadClient, isCurrent: () -> Bool) async {
        guard !isBusy, isCurrent() else { return }
        let phase = Phase.checking(UUID())
        self.phase = phase
        problem = nil
        await readStatus(client, phase: phase, isCurrent: isCurrent)
    }

    func link(_ client: CloudReadClient, isCurrent: @escaping @MainActor () -> Bool) async {
        guard !isBusy, isLinked == false, isCurrent() else { return }
        let id = UUID()
        phase = .starting(id)
        problem = nil
        do {
            let state = try PendingCloudLogin.random()
            let started = ProcessInfo.processInfo.systemUptime
            let start = try await client.startAppleAccountLink(state: state)
            guard phase == .starting(id) else { return }
            guard !Task.isCancelled, isCurrent() else { reset(); return }
            switch start {
            case .alreadyLinked:
                await readStatus(client, phase: .starting(id), requireLinked: true, isCurrent: isCurrent)
            case let .authorization(url, expiresIn):
                let deadline = started + expiresIn
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw CloudLoginError.expired }
                phase = .authorizing(id)
                try browser.open(url) { [weak self] callback, error in
                    guard let self, self.phase == .authorizing(id) else { return }
                    guard isCurrent() else { self.reset(); return }
                    self.phase = .idle
                    if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
                    guard let callback, let outcome = Self.outcome(callback, state: state, deadline: deadline) else {
                        self.reportLinkFailure()
                        return
                    }
                    switch outcome {
                    case .cancelled: return
                    case .failed: self.reportLinkFailure()
                    case .linked:
                        self.phase = .checking(id)
                        Task { await self.readStatus(client, phase: .checking(id), requireLinked: true, isCurrent: isCurrent) }
                    }
                }
            }
        } catch {
            guard phase == .starting(id) || phase == .authorizing(id) else { return }
            phase = .idle
            if isCurrent(), !Task.isCancelled { reportLinkFailure() }
        }
    }

    private func readStatus(_ client: CloudReadClient, phase: Phase, requireLinked: Bool = false,
                            isCurrent: () -> Bool) async {
        defer { if self.phase == phase { self.phase = .idle } }
        do {
            let linked = try await client.appleAccountLinked()
            guard self.phase == phase, !Task.isCancelled, isCurrent() else { return }
            isLinked = linked
            if requireLinked, linked != true { reportLinkFailure() }
        } catch {
            guard self.phase == phase, !Task.isCancelled, isCurrent() else { return }
            problem = String(localized: "Couldn’t check whether Apple is linked. Try again.")
        }
    }

    private func reportLinkFailure() {
        problem = String(localized: "Couldn’t confirm the Apple account link. Try again.")
    }

    private static func outcome(_ url: URL, state: String, deadline: TimeInterval) -> Outcome? {
        guard ProcessInfo.processInfo.systemUptime < deadline, isLinkCallback(url),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host == nil, parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              parts.percentEncodedPath == callbackPath, let fields = parts.queryItems, fields.count == 2,
              fields.contains(URLQueryItem(name: "state", value: state)),
              let result = fields.first(where: { $0.name == "result" })?.value else { return nil }
        return Outcome(rawValue: result)
    }
}
