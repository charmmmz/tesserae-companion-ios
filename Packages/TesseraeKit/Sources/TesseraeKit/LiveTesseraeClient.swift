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

    public func fetchDevicePreview(
        id: String,
        ifNoneMatch: String?,
        instance: TesseraeInstance
    ) async throws -> PreviewFetchResult {
        var request = try await authenticatedRequest(
            instance: instance,
            path: ["devices", id, "preview"],
            method: "GET",
            accept: "image/png"
        )
        configurePreviewRequest(
            &request,
            ifNoneMatch: ifNoneMatch
        )
        return try await previewResponse(
            for: request,
            allowsPreparing: false
        )
    }

    public func fetchDashboardPreview(
        id: String,
        deviceID: String?,
        ifNoneMatch: String?,
        instance: TesseraeInstance
    ) async throws -> PreviewFetchResult {
        let queryItems = deviceID.map {
            [URLQueryItem(name: "device_id", value: $0)]
        } ?? []
        var request = try await authenticatedRequest(
            instance: instance,
            path: ["dashboards", id, "preview"],
            method: "GET",
            queryItems: queryItems,
            accept: "image/png"
        )
        configurePreviewRequest(
            &request,
            ifNoneMatch: ifNoneMatch
        )
        return try await previewResponse(
            for: request,
            allowsPreparing: true
        )
    }

    public func fetchHistory(
        beforeID: String?,
        limit: Int?,
        instance: TesseraeInstance
    ) async throws -> HistoryResponse {
        var queryItems: [URLQueryItem] = []
        if let beforeID {
            queryItems.append(URLQueryItem(name: "before_id", value: beforeID))
        }
        if let limit {
            queryItems.append(URLQueryItem(name: "limit", value: String(limit)))
        }
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["history"],
            method: "GET",
            queryItems: queryItems
        )
        return try await perform(
            request,
            expectedStatusCodes: [200]
        )
    }

    public func fetchHistoryPreview(
        id: String,
        ifNoneMatch: String?,
        instance: TesseraeInstance
    ) async throws -> PreviewFetchResult {
        var request = try await authenticatedRequest(
            instance: instance,
            path: ["history", id, "preview"],
            method: "GET",
            accept: "image/png"
        )
        configurePreviewRequest(
            &request,
            ifNoneMatch: ifNoneMatch
        )
        return try await previewResponse(
            for: request,
            allowsPreparing: false
        )
    }

    public func resendHistory(
        id: String,
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob {
        let body = HistoryResendRequest(
            overrideQuietHours: overrideQuietHours
        )
        var request = try await authenticatedRequest(
            instance: instance,
            path: ["history", id, "resend"],
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

    public func sendImageURL(
        url: URL,
        fit: ImageFitMode,
        deviceIDs: [String],
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob {
        guard !deviceIDs.isEmpty else {
            throw TesseraeClientError.noTargets
        }
        let body = ImageURLPushRequest(
            url: url,
            deviceIDs: deviceIDs,
            fit: fit,
            overrideQuietHours: overrideQuietHours
        )
        var request = try await authenticatedRequest(
            instance: instance,
            path: ["image-urls"],
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

    public func sendWebpage(
        url: URL,
        fit: ImageFitMode,
        viewportW: Int?,
        deviceIDs: [String],
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob {
        guard !deviceIDs.isEmpty else {
            throw TesseraeClientError.noTargets
        }
        let body = WebpagePushRequest(
            url: url,
            deviceIDs: deviceIDs,
            fit: fit,
            viewportW: viewportW,
            overrideQuietHours: overrideQuietHours
        )
        var request = try await authenticatedRequest(
            instance: instance,
            path: ["webpages"],
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
        contentType: String = "application/json",
        queryItems: [URLQueryItem] = [],
        accept: String = "application/json"
    ) async throws -> URLRequest {
        guard let token = try await credentials.token(for: instance.id) else {
            throw TesseraeClientError.missingCredential
        }
        var request = try makeRequest(
            baseURL: instance.baseURL,
            path: path,
            method: method,
            body: body,
            contentType: contentType,
            queryItems: queryItems,
            accept: accept
        )
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func makeRequest(
        baseURL: URL,
        path: [String],
        method: String,
        body: Data? = nil,
        contentType: String = "application/json",
        queryItems: [URLQueryItem] = [],
        accept: String = "application/json"
    ) throws -> URLRequest {
        var endpoint = try normalized(baseURL)
            .appending(path: "api")
            .appending(path: "app")
            .appending(path: "v1")
        for component in path {
            endpoint.append(path: component)
        }
        if !queryItems.isEmpty {
            guard
                var components = URLComponents(
                    url: endpoint,
                    resolvingAgainstBaseURL: false
                )
            else {
                throw TesseraeClientError.invalidServerURL
            }
            components.queryItems = queryItems
            guard let queriedEndpoint = components.url else {
                throw TesseraeClientError.invalidServerURL
            }
            endpoint = queriedEndpoint
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = method
        request.timeoutInterval = 30
        request.setValue(accept, forHTTPHeaderField: "Accept")
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

    private func previewResponse(
        for request: URLRequest,
        allowsPreparing: Bool
    ) async throws -> PreviewFetchResult {
        let response = try await response(for: request)
        switch response.statusCode {
        case 200:
            guard !response.data.isEmpty else {
                throw TesseraeClientError.invalidResponse
            }
            return .image(
                data: response.data,
                eTag: response.headers["etag"]
            )
        case 202 where allowsPreparing:
            let retryAfter = response.headers["retry-after"]
                .flatMap(TimeInterval.init) ?? 2
            return .preparing(retryAfterSeconds: retryAfter)
        case 304:
            return .notModified
        case 404:
            return .notFound
        default:
            throw try serverError(from: response)
        }
    }

    private func configurePreviewRequest(
        _ request: inout URLRequest,
        ifNoneMatch: String?
    ) {
        // PreviewImageState owns the response bytes and ETag. Letting
        // URLSession.shared cache the same authenticated URL creates a second
        // cache with an independent validator; a synthesized cached 200 after
        // a 304 can then replace newer preview bytes with an older body.
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        if let ifNoneMatch {
            request.setValue(ifNoneMatch, forHTTPHeaderField: "If-None-Match")
        }
    }

    private func response(for request: URLRequest) async throws -> TesseraeHTTPResponse {
        do {
            return try await transport.send(request)
        } catch let error as TesseraeClientError {
            throw error
        } catch {
            let nsError = error as NSError
            let isCancelledURLRequest =
                nsError.domain == NSURLErrorDomain
                    && nsError.code == NSURLErrorCancelled
            if error is CancellationError || isCancelledURLRequest {
                throw CancellationError()
            }
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
