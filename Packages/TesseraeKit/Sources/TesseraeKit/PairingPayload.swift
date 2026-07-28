import Foundation

public struct PairingPayload: Codable, Hashable, Sendable {
    public let baseURL: URL
    public let code: String

    public init(baseURL: URL, code: String) throws {
        guard
            let scheme = baseURL.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            baseURL.host != nil
        else {
            throw PairingPayloadError.invalidServerURL
        }
        guard
            (6...12).contains(code.count),
            code.allSatisfy(\.isNumber)
        else {
            throw PairingPayloadError.invalidCode
        }
        self.baseURL = baseURL
        self.code = code
    }

    private enum CodingKeys: String, CodingKey {
        case baseURL = "baseUrl"
        case code
    }
}

public enum PairingPayloadError: Error, Equatable, LocalizedError, Sendable {
    case invalidFormat
    case invalidServerURL
    case invalidCode

    public var errorDescription: String? {
        switch self {
        case .invalidFormat:
            "This QR code is not a Tesserae Companion pairing code."
        case .invalidServerURL:
            "The Tesserae QR code contains an invalid server address."
        case .invalidCode:
            "The Tesserae QR code contains an invalid or expired pairing code."
        }
    }
}

public enum PairingPayloadCodec {
    public static func decode(_ value: String) throws -> PairingPayload {
        if let data = value.data(using: .utf8),
            let decoded = try? TesseraeJSON.decoder().decode(
                PairingPayload.self,
                from: data
            )
        {
            return try PairingPayload(
                baseURL: decoded.baseURL,
                code: decoded.code
            )
        }

        guard
            let components = URLComponents(string: value),
            components.scheme?.lowercased() == "tesserae",
            components.host?.lowercased() == "pair"
        else {
            throw PairingPayloadError.invalidFormat
        }
        let items = components.queryItems ?? []
        guard
            let baseURLValue = items.first(where: {
                $0.name == "base_url" || $0.name == "url"
            })?.value,
            let baseURL = URL(string: baseURLValue),
            let code = items.first(where: { $0.name == "code" })?.value
        else {
            throw PairingPayloadError.invalidFormat
        }
        return try PairingPayload(baseURL: baseURL, code: code)
    }

    public static func encode(_ payload: PairingPayload) throws -> String {
        var components = URLComponents()
        components.scheme = "tesserae"
        components.host = "pair"
        components.queryItems = [
            URLQueryItem(name: "base_url", value: payload.baseURL.absoluteString),
            URLQueryItem(name: "code", value: payload.code),
        ]
        guard let value = components.string else {
            throw PairingPayloadError.invalidFormat
        }
        return value
    }
}
