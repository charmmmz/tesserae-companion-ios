import Foundation
import Security

public protocol CredentialStoring: Sendable {
    func token(for instanceID: String) async throws -> String?
    func save(token: String, for instanceID: String) async throws
    func removeToken(for instanceID: String) async throws
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

public enum CredentialStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidTokenEncoding
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidTokenEncoding:
            "The stored Tesserae credential is not valid UTF-8."
        case let .keychain(status):
            SecCopyErrorMessageString(status, nil) as String?
                ?? "Keychain returned status \(status)."
        }
    }
}

public actor KeychainCredentialStore: CredentialStoring {
    private let service: String
    private let accessGroup: String?

    public init(service: String, accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
    }

    public func token(for instanceID: String) throws -> String? {
        var query = baseQuery(for: instanceID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw CredentialStoreError.keychain(status)
        }
        guard
            let data = result as? Data,
            let token = String(data: data, encoding: .utf8)
        else {
            throw CredentialStoreError.invalidTokenEncoding
        }
        return token
    }

    public func save(token: String, for instanceID: String) throws {
        let tokenData = Data(token.utf8)
        var query = baseQuery(for: instanceID)
        let attributes = [kSecValueData as String: tokenData]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            attributes as CFDictionary
        )

        if updateStatus == errSecItemNotFound {
            query[kSecValueData as String] = tokenData
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialStoreError.keychain(addStatus)
            }
            return
        }

        guard updateStatus == errSecSuccess else {
            throw CredentialStoreError.keychain(updateStatus)
        }
    }

    public func removeToken(for instanceID: String) throws {
        let status = SecItemDelete(baseQuery(for: instanceID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CredentialStoreError.keychain(status)
        }
    }

    private func baseQuery(for instanceID: String) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: instanceID,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
        if let accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }
        return query
    }
}
