import Foundation

public struct TesseraeClientIdentity: Hashable, Sendable {
    public let appVersion: String
    public let installationID: String

    public init(appVersion: String, installationID: String) {
        self.appVersion = appVersion
        self.installationID = installationID
    }
}

public actor LiveTesseraeClient: TesseraeServing {
    private let transport: any TesseraeHTTPTransporting
    private let credentials: any CredentialStoring
    private let identity: TesseraeClientIdentity

    public init(
        credentials: any CredentialStoring,
        identity: TesseraeClientIdentity,
        transport: any TesseraeHTTPTransporting = URLSessionTesseraeTransport()
    ) {
        self.credentials = credentials
        self.identity = identity
        self.transport = transport
    }

    public func probe(baseURL: URL) async throws -> ServerCapabilities {
        let request = try makeRequest(
            baseURL: baseURL,
            path: [],
            method: "GET"
        )
        let capabilities: ServerCapabilities = try await perform(
            request,
            expectedStatusCodes: [200]
        )
        try CompanionCompatibility.validate(capabilities)
        return capabilities
    }

    public func pair(
        baseURL: URL,
        code: String,
        clientName: String
    ) async throws -> PairedSession {
        guard
            (6...12).contains(code.count),
            code.allSatisfy(\.isNumber)
        else {
            throw TesseraeClientError.invalidPairingCode
        }

        let body = PairingRequest(
            code: code,
            client: PairingClient(
                name: clientName,
                appVersion: identity.appVersion,
                installationID: identity.installationID
            )
        )
        let request = try makeRequest(
            baseURL: baseURL,
            path: ["pair"],
            method: "POST",
            body: TesseraeJSON.encoder().encode(body)
        )
        let response: PairingResponse = try await perform(
            request,
            expectedStatusCodes: [201]
        )
        let instance = TesseraeInstance(
            id: response.instance.id,
            name: response.instance.name,
            baseURL: try normalized(baseURL),
            serverVersion: response.instance.serverVersion,
            timezone: response.instance.timezone,
            webURL: try resolvedWebURL(
                response.instance.webURL,
                against: baseURL
            )
        )
        return PairedSession(
            instance: instance,
            token: response.token,
            tokenID: response.tokenID,
            scopes: response.scopes,
            createdAt: response.createdAt
        )
    }

    public func revokeSession(instance: TesseraeInstance) async throws {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["session"],
            method: "DELETE"
        )
        _ = try await performWithoutBody(
            request,
            expectedStatusCodes: [204]
        )
    }

    public func fetchDisplays(instance: TesseraeInstance) async throws -> [DisplaySummary] {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["devices"],
            method: "GET"
        )
        let response: DevicesResponse = try await perform(
            request,
            expectedStatusCodes: [200]
        )
        return response.devices
    }

    public func fetchDashboards(instance: TesseraeInstance) async throws -> [DashboardSummary] {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["dashboards"],
            method: "GET"
        )
        let response: DashboardsResponse = try await perform(
            request,
            expectedStatusCodes: [200]
        )
        return try response.dashboards.map { dashboard in
            DashboardSummary(
                id: dashboard.id,
                name: dashboard.name,
                kind: dashboard.kind,
                deviceIDs: dashboard.deviceIDs,
                updatedAt: dashboard.updatedAt,
                webURL: try dashboard.webURL.map {
                    try resolvedWebURL(
                        $0,
                        against: instance.baseURL
                    )
                }
            )
        }
    }

    public func pushDashboard(
        id: String,
        deviceIDs: [String]?,
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob {
        if let deviceIDs, deviceIDs.isEmpty {
            throw TesseraeClientError.noTargets
        }
        let body = DashboardPushRequest(
            deviceIDs: deviceIDs,
            overrideQuietHours: overrideQuietHours
        )
        var request = try await authenticatedRequest(
            instance: instance,
            path: ["dashboards", id, "push"],
            method: "POST",
            body: TesseraeJSON.encoder().encode(body)
        )
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        let response: JobResponse = try await perform(
            request,
            expectedStatusCodes: [202]
        )
        return response.job
    }

    public func sendImage(
        data: Data,
        fileName: String,
        contentType: String,
        fit: ImageFitMode,
        deviceIDs: [String],
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob {
        guard !deviceIDs.isEmpty else {
            throw TesseraeClientError.noTargets
        }

        let boundary = "TesseraeBoundary-\(UUID().uuidString)"
        let metadata = ImagePushRequest(
            deviceIDs: deviceIDs,
            fit: fit,
            overrideQuietHours: overrideQuietHours
        )
        let body = try multipartBody(
            boundary: boundary,
            image: data,
            fileName: fileName,
            contentType: contentType,
            request: TesseraeJSON.encoder().encode(metadata)
        )
        var request = try await authenticatedRequest(
            instance: instance,
            path: ["images"],
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        let response: JobResponse = try await perform(
            request,
            expectedStatusCodes: [202]
        )
        return response.job
    }

    public func fetchJob(id: String, instance: TesseraeInstance) async throws -> PushJob {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["jobs", id],
            method: "GET"
        )
        let response: JobResponse = try await perform(
            request,
            expectedStatusCodes: [200]
        )
        return response.job
    }

    private func authenticatedRequest(
        instance: TesseraeInstance,
        path: [String],
        method: String,
        body: Data? = nil,
        contentType: String = "application/json"
    ) async throws -> URLRequest {
        guard let token = try await credentials.token(for: instance.id) else {
            throw TesseraeClientError.missingCredential
        }
        var request = try makeRequest(
            baseURL: instance.baseURL,
            path: path,
            method: method,
            body: body,
            contentType: contentType
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeRequest(
        baseURL: URL,
        path: [String],
        method: String,
        body: Data? = nil,
        contentType: String = "application/json"
    ) throws -> URLRequest {
        var endpoint = try normalized(baseURL)
            .appending(path: "api")
            .appending(path: "app")
            .appending(path: "v1")
        for component in path {
            endpoint.append(path: component)
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = body
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func normalized(_ baseURL: URL) throws -> URL {
        guard
            var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
            components.scheme == "http" || components.scheme == "https",
            components.host != nil
        else {
            throw TesseraeClientError.invalidServerURL
        }
        components.query = nil
        components.fragment = nil
        guard let normalizedURL = components.url else {
            throw TesseraeClientError.invalidServerURL
        }
        return normalizedURL
    }

    private func resolvedWebURL(
        _ rawValue: String,
        against baseURL: URL
    ) throws -> String {
        guard
            let url = URL(
                string: rawValue,
                relativeTo: try normalized(baseURL)
            )?.absoluteURL,
            url.scheme == "http" || url.scheme == "https",
            url.host != nil
        else {
            throw TesseraeClientError.invalidServerURL
        }
        return url.absoluteString
    }

    private func perform<Response: Decodable>(
        _ request: URLRequest,
        expectedStatusCodes: Set<Int>
    ) async throws -> Response {
        let response = try await response(for: request)
        guard expectedStatusCodes.contains(response.statusCode) else {
            throw try serverError(from: response)
        }
        do {
            return try TesseraeJSON.decoder().decode(Response.self, from: response.data)
        } catch {
            throw TesseraeClientError.decoding(String(describing: error))
        }
    }

    private func performWithoutBody(
        _ request: URLRequest,
        expectedStatusCodes: Set<Int>
    ) async throws -> TesseraeHTTPResponse {
        let response = try await response(for: request)
        guard expectedStatusCodes.contains(response.statusCode) else {
            throw try serverError(from: response)
        }
        return response
    }

    private func response(for request: URLRequest) async throws -> TesseraeHTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as TesseraeClientError {
            throw error
        } catch {
            throw TesseraeClientError.transport(error.localizedDescription)
        }
    }

    private func serverError(from response: TesseraeHTTPResponse) throws -> TesseraeClientError {
        if response.statusCode == 401 {
            return .unauthorized
        }
        if let decoded = try? TesseraeJSON.decoder().decode(
            APIErrorResponse.self,
            from: response.data
        ) {
            if decoded.error.code == "pairing_expired"
                || decoded.error.code == "pairing_code_used"
            {
                return .invalidPairingCode
            }
            return .server(
                code: decoded.error.code,
                message: decoded.error.message,
                requestID: decoded.error.requestID
            )
        }
        return .httpStatus(response.statusCode)
    }

    private func multipartBody(
        boundary: String,
        image: Data,
        fileName: String,
        contentType: String,
        request: Data
    ) throws -> Data {
        let safeName = fileName
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
        body.appendUTF8("Content-Disposition: form-data; name=\"request\"\r\n")
        body.appendUTF8("Content-Type: application/json\r\n\r\n")
        body.append(request)
        body.appendUTF8("\r\n--\(boundary)\r\n")
        body.appendUTF8(
            "Content-Disposition: form-data; name=\"image\"; filename=\"\(safeName)\"\r\n"
        )
        body.appendUTF8("Content-Type: \(contentType)\r\n\r\n")
        body.append(image)
        body.appendUTF8("\r\n--\(boundary)--\r\n")
        return body
    }
}

private extension Data {
    mutating func appendUTF8(_ string: String) {
        append(contentsOf: string.utf8)
    }
}
