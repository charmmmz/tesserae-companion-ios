import Foundation

public struct TesseraeHTTPResponse: Sendable {
    public let data: Data
    public let statusCode: Int
    public let headers: [String: String]

    public init(data: Data, statusCode: Int, headers: [String: String] = [:]) {
        self.data = data
        self.statusCode = statusCode
        self.headers = headers
    }
}

public protocol TesseraeHTTPTransporting: Sendable {
    func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse
}

public final class URLSessionTesseraeTransport: TesseraeHTTPTransporting, @unchecked Sendable {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func send(_ request: URLRequest) async throws -> TesseraeHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw TesseraeClientError.invalidResponse
        }

        let headers = response.allHeaderFields.reduce(into: [String: String]()) {
            partialResult,
            field in
            guard
                let key = field.key as? String,
                let value = field.value as? String
            else {
                return
            }
            partialResult[key.lowercased()] = value
        }
        return TesseraeHTTPResponse(
            data: data,
            statusCode: response.statusCode,
            headers: headers
        )
    }
}
