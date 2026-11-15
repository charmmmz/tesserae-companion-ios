import AuthenticationServices
import CryptoKit
import Darwin
import Foundation
import Security
import TesseraeKit
import UIKit

enum CloudLoginError: Error, LocalizedError {
    case unavailable, invalidCallback, expired, denied, exchangeFailed
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "Cloud sign-in is unavailable. Try again.")
        case .invalidCallback: String(localized: "This sign-in link does not match the current request.")
        case .expired: String(localized: "This sign-in expired or was already used. Start sign-in again.")
        case .denied: String(localized: "Cloud access was not authorized. Your current connection was kept.")
        case .exchangeFailed: String(localized: "Sign-in could not be confirmed. Start sign-in again.")
        }
    }
}

struct PendingCloudLogin: Codable, Sendable {
    enum AppleStage: Codable, Sendable, Equatable {
        case provingIdentity
        case consent(userID: String)
    }

    let id: UUID
    let issuer: URL
    let state: String
    let verifier: String
    let createdAt: Date
    var consumed = false
    var appleStage: AppleStage?
    static let callback = "com.charmmmz.tesseraecompanion:/oauth/callback"
    static let clientID = "tesserae-companion"
    static let scopes = "app:read app:send app:refresh"

    init(issuer: URL, now: Date = Date(), appleStage: AppleStage? = nil) throws {
        id = UUID(); self.issuer = issuer; createdAt = now
        state = try Self.random(); verifier = try Self.random()
        self.appleStage = appleStage
    }

    var acceptsCallback: Bool { appleStage != .provingIdentity }
    var expectedUserID: String? {
        if case let .consent(userID) = appleStage { return userID }
        return nil
    }
    var authorizationURL: URL {
        var components = URLComponents(url: issuer.appending(path: "oauth/authorize"), resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: Self.clientID),
            URLQueryItem(name: "redirect_uri", value: Self.callback),
            URLQueryItem(name: "resource", value: issuer.appending(path: "api/t").absoluteString),
            URLQueryItem(name: "scope", value: Self.scopes),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: Data(SHA256.hash(data: Data(verifier.utf8))).base64URL)
        ]
        return components.url!
    }
    private static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw CloudLoginError.unavailable
        }
        return Data(bytes).base64URL
    }
}

private extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}

struct CloudLoginVault: Sendable {
    struct Revocation: Codable, Sendable, Identifiable {
        let id: UUID
        let issuer: URL
        let token: String
    }
    private struct Envelope: Codable {
        var pending: PendingCloudLogin?
        var revocations: [Revocation] = []
    }
    let directory: URL
    let service: String
    var accessGroup: String? = nil

    func pending() throws -> PendingCloudLogin? { try transaction { $0.pending } }
    func replace(_ pending: PendingCloudLogin?) throws { try transaction { $0.pending = pending } }
    func invalidate() throws { try replace(nil) }

    func armAppleConsent(attemptID: UUID, userID: String) throws {
        try transaction { envelope in
            guard var attempt = envelope.pending, attempt.id == attemptID, !attempt.consumed,
                  attempt.appleStage == .provingIdentity else { throw CloudLoginError.expired }
            attempt.appleStage = .consent(userID: userID)
            envelope.pending = attempt
        }
    }
    func claim(_ url: URL, issuer: URL, now: Date = Date()) throws -> (PendingCloudLogin, String)? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == "com.charmmmz.tesseraecompanion", parts.host == nil,
              parts.path == "/oauth/callback", parts.fragment == nil, parts.user == nil, parts.port == nil else {
            throw CloudLoginError.invalidCallback
        }
        let items = parts.queryItems ?? []
        guard Set(items.map(\.name)).count == items.count else { throw CloudLoginError.invalidCallback }
        let fields = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        let result: (PendingCloudLogin, String)? = try transaction { envelope in
            guard var attempt = envelope.pending else { throw CloudLoginError.expired }
            guard attempt.acceptsCallback else { return nil }
            guard attempt.issuer == issuer, fields["state"] == attempt.state else { throw CloudLoginError.invalidCallback }
            guard now.timeIntervalSince(attempt.createdAt) >= 0,
                  now.timeIntervalSince(attempt.createdAt) < 900 else { throw CloudLoginError.expired }
            guard !attempt.consumed else { return nil }
            guard fields["error"] != nil || fields["code"]?.isEmpty == false else { throw CloudLoginError.invalidCallback }
            guard fields["error"] == nil || fields["code"] == nil else { throw CloudLoginError.invalidCallback }
            attempt.consumed = true
            envelope.pending = attempt
            return (attempt, fields["code"] ?? "")
        }
        if result != nil, fields["error"] != nil { throw CloudLoginError.denied }
        return result
    }
    func retainRevocation(issuer: URL, token: String) throws -> Revocation {
        let record = Revocation(id: UUID(), issuer: issuer, token: token)
        try transaction { $0.revocations.append(record) }
        return record
    }
    func revocations() throws -> [Revocation] { try transaction { $0.revocations } }
    func removeRevocation(_ id: UUID) throws { try transaction { $0.revocations.removeAll { $0.id == id } } }

    private func transaction<T>(_ action: (inout Envelope) throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.appending(path: "oauth.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw CloudLoginError.unavailable }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw ConnectionError.coordinationTimeout }
        defer { flock(fd, LOCK_UN) }
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: "pending-and-revocations",
            kSecAttrSynchronizable as String: false]
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        var read = query
        read[kSecReturnData as String] = true; read[kSecMatchLimit as String] = kSecMatchLimitOne
        var data: CFTypeRef?
        let status = SecItemCopyMatching(read as CFDictionary, &data)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw CredentialStoreError.keychain(status) }
        var envelope = try (data as? Data).map { try JSONDecoder().decode(Envelope.self, from: $0) } ?? Envelope()
        let result = try action(&envelope)
        let encoded = try JSONEncoder().encode(envelope)
        var attributes: [String: Any] = [kSecValueData as String: encoded]
        let written: OSStatus
        if status == errSecItemNotFound {
            attributes.merge(query) { first, _ in first }
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            written = SecItemAdd(attributes as CFDictionary, nil)
        } else {
            written = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        }
        guard written == errSecSuccess else { throw CredentialStoreError.keychain(written) }
        return result
    }
}

struct CloudOAuthClient: Sendable {
    static let requestTimeout: TimeInterval = 15
    let transport: any TesseraeHTTPTransporting
    init(transport: (any TesseraeHTTPTransporting)? = nil) {
        self.transport = transport ?? URLSessionTesseraeTransport.cloud(resourceTimeout: Self.requestTimeout)
    }
    func exchange(_ attempt: PendingCloudLogin, code: String) async throws -> CloudTokenResponse {
        let response = try await post(issuer: attempt.issuer, path: "oauth/token", fields: [
            "grant_type": "authorization_code", "client_id": PendingCloudLogin.clientID,
            "redirect_uri": PendingCloudLogin.callback, "resource": attempt.issuer.appending(path: "api/t").absoluteString,
            "code": code, "code_verifier": attempt.verifier])
        guard response.statusCode == 200 else { throw CloudLoginError.exchangeFailed }
        return try JSONDecoder().decode(CloudTokenResponse.self, from: response.data)
    }
    func revoke(_ record: CloudLoginVault.Revocation) async throws {
        let response = try await post(issuer: record.issuer, path: "oauth/revoke",
            fields: ["client_id": PendingCloudLogin.clientID, "token": record.token])
        guard response.statusCode == 200 else { throw CloudLoginError.unavailable }
    }
    private func post(issuer: URL, path: String, fields: [String: String]) async throws -> TesseraeHTTPResponse {
        var request = URLRequest(url: issuer.appending(path: path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: Self.requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var form = URLComponents()
        form.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        request.httpBody = form.percentEncodedQuery?.replacingOccurrences(of: "+", with: "%2B").data(using: .utf8)
        return try await transport.send(request)
    }
}

@MainActor
protocol CloudSignInBrowsing {
    func open(_ url: URL, completion: @escaping @MainActor (URL?, Error?) -> Void) throws
    func cancel()
}

@MainActor
final class CloudSignInBrowser: NSObject, ASWebAuthenticationPresentationContextProviding, CloudSignInBrowsing {
    private var session: ASWebAuthenticationSession?
    func open(_ url: URL, completion: @escaping @MainActor (URL?, Error?) -> Void) throws {
        let session = ASWebAuthenticationSession(url: url,
            callbackURLScheme: "com.charmmmz.tesseraecompanion") { url, error in
                Task { @MainActor in completion(url, error) }
            }
        self.session = session
        session.presentationContextProvider = self
        guard session.start() else { self.session = nil; throw CloudLoginError.unavailable }
    }
    func cancel() { session?.cancel(); session = nil }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        cloudSignInPresentationAnchor()
    }
}

@MainActor
func cloudSignInPresentationAnchor() -> ASPresentationAnchor {
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
}
