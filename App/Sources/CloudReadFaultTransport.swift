#if DEBUG
import Foundation
import TesseraeKit

struct CloudReadFaultTransport: TesseraeHTTPTransporting {
    let issuer: URL
    let proxy: URL
    private let direct = URLSessionTesseraeTransport.cloud()

    func send(_ original: URLRequest) async throws -> TesseraeHTTPResponse {
        guard let url = original.url, original.httpMethod == "GET",
              url.scheme == issuer.scheme, url.host == issuer.host, url.port == issuer.port,
              url.path.hasPrefix(issuer.appending(path: "api/t").path + "/") else {
            return try await direct.send(original)
        }
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.scheme = proxy.scheme; parts.host = proxy.host; parts.port = proxy.port
        var request = original
        request.url = parts.url
        return try await direct.send(request)
    }
}
#endif
