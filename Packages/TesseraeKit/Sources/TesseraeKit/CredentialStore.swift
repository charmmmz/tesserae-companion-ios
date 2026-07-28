public protocol CredentialStoring: Sendable {
    func token(for instanceID: String) async -> String?
    func save(token: String, for instanceID: String) async
    func removeToken(for instanceID: String) async
}

public actor InMemoryCredentialStore: CredentialStoring {
    private var tokens: [String: String] = [:]

    public init() {}

    public func token(for instanceID: String) -> String? {
        tokens[instanceID]
    }

    public func save(token: String, for instanceID: String) {
        tokens[instanceID] = token
    }

    public func removeToken(for instanceID: String) {
        tokens.removeValue(forKey: instanceID)
    }
}

