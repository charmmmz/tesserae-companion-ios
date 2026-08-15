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

    public func fetchSessionAuthorization(
        instance: TesseraeInstance
    ) async throws -> CompanionSessionAuthorization? {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["session"],
            method: "GET"
        )
        let response = try await response(for: request)
        if response.statusCode == 404 || response.statusCode == 405 {
            return nil
        }
        guard response.statusCode == 200 else {
            throw try serverError(from: response)
        }
        do {
            return try TesseraeJSON.decoder().decode(
                CompanionSessionAuthorization.self,
                from: response.data
            )
        } catch {
            throw TesseraeClientError.decoding(String(describing: error))
        }
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
                iconName: dashboard.iconName,
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

    public func fetchGalleryFolders(
        instance: TesseraeInstance
    ) async throws -> [GalleryFolder] {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["gallery", "folders"],
            method: "GET"
        )
        let response: GalleryFoldersResponse = try await perform(
            request,
            expectedStatusCodes: [200]
        )
        return response.folders
    }

    public func fetchGalleryFolder(
        id: String,
        instance: TesseraeInstance
    ) async throws -> GalleryFolderDetail {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["gallery", "folders", id],
            method: "GET"
        )
        let response: GalleryFolderResponse = try await perform(
            request,
            expectedStatusCodes: [200]
        )
        return GalleryFolderDetail(
            folder: response.folder,
            images: response.images
        )
    }

    public func createGalleryFolder(
        name: String,
        instance: TesseraeInstance
    ) async throws -> GalleryFolderDetail {
        let body = GalleryFolderCreateRequest(name: name)
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["gallery", "folders"],
            method: "POST",
            body: TesseraeJSON.encoder().encode(body)
        )
        let response: GalleryFolderResponse = try await perform(
            request,
            expectedStatusCodes: [201]
        )
        return GalleryFolderDetail(
            folder: response.folder,
            images: response.images
        )
    }

    public func uploadGalleryImage(
        folderID: String,
        data: Data,
        fileName: String,
        contentType: String,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> GalleryImage {
        let boundary = "TesseraeGalleryBoundary-\(UUID().uuidString)"
        let body = galleryMultipartBody(
            boundary: boundary,
            image: data,
            fileName: fileName,
            contentType: contentType
        )
        var request = try await authenticatedRequest(
            instance: instance,
            path: ["gallery", "folders", folderID, "images"],
            method: "POST",
            body: body,
            contentType: "multipart/form-data; boundary=\(boundary)"
        )
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        let response: GalleryImageResponse = try await perform(
            request,
            expectedStatusCodes: [201]
        )
        return response.image
    }

    public func fetchGalleryResource(
        path: String,
        ifNoneMatch: String?,
        instance: TesseraeInstance
    ) async throws -> PreviewFetchResult {
        var request = try await authenticatedGalleryResourceRequest(
            instance: instance,
            path: path
        )
        configurePreviewRequest(&request, ifNoneMatch: ifNoneMatch)
        return try await previewResponse(
            for: request,
            allowsPreparing: false
        )
    }

    public func fetchOfflineAlbum(
        folderID: String,
        instance: TesseraeInstance
    ) async throws -> OfflineAlbumResponse {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["gallery", "folders", folderID, "offline-album"],
            method: "GET"
        )
        return try await perform(request, expectedStatusCodes: [200])
    }

    public func preflightOfflineAlbum(
        folderID: String,
        draft: OfflineAlbumDraft,
        instance: TesseraeInstance
    ) async throws -> OfflineAlbumPreflightResponse {
        let request = try await authenticatedRequest(
            instance: instance,
            path: [
                "gallery",
                "folders",
                folderID,
                "offline-album",
                "preflight",
            ],
            method: "POST",
            body: TesseraeJSON.encoder().encode(draft)
        )
        return try await perform(request, expectedStatusCodes: [200])
    }

    public func putOfflineAlbum(
        folderID: String,
        request requestBody: OfflineAlbumWriteRequest,
        instance: TesseraeInstance
    ) async throws -> OfflineAlbumResponse {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["gallery", "folders", folderID, "offline-album"],
            method: "PUT",
            body: TesseraeJSON.encoder().encode(requestBody)
        )
        return try await perform(request, expectedStatusCodes: [200, 201])
    }

    public func deleteOfflineAlbum(
        folderID: String,
        instance: TesseraeInstance
    ) async throws {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["gallery", "folders", folderID, "offline-album"],
            method: "DELETE"
        )
        _ = try await performWithoutBody(request, expectedStatusCodes: [204])
    }

    public func fetchLineups(instance: TesseraeInstance) async throws -> [Lineup] {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["lineups"],
            method: "GET"
        )
        let response: LineupsResponse = try await perform(
            request,
            expectedStatusCodes: [200]
        )
        return response.lineups
    }

    public func fetchLineup(
        id: String,
        instance: TesseraeInstance
    ) async throws -> Lineup {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["lineups", id],
            method: "GET"
        )
        let response: LineupResponse = try await perform(
            request,
            expectedStatusCodes: [200]
        )
        return response.lineup
    }

    public func fetchVersionedLineup(
        id: String,
        instance: TesseraeInstance
    ) async throws -> VersionedLineup {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["lineups", id],
            method: "GET"
        )
        return try await performVersionedLineup(
            request,
            expectedStatusCodes: [200]
        )
    }

    public func createLineup(
        _ requestBody: LineupCreateRequest,
        instance: TesseraeInstance
    ) async throws -> VersionedLineup {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["lineups"],
            method: "POST",
            body: TesseraeJSON.encoder().encode(requestBody)
        )
        return try await performVersionedLineup(
            request,
            expectedStatusCodes: [201]
        )
    }

    public func updateLineup(
        id: String,
        eTag: String,
        patch: LineupPatchRequest,
        instance: TesseraeInstance
    ) async throws -> VersionedLineup {
        var request = try await authenticatedRequest(
            instance: instance,
            path: ["lineups", id],
            method: "PATCH",
            body: TesseraeJSON.encoder().encode(patch)
        )
        request.setValue(eTag, forHTTPHeaderField: "If-Match")
        return try await performVersionedLineup(
            request,
            expectedStatusCodes: [200]
        )
    }

    public func setLineupEnabled(
        id: String,
        enabled: Bool,
        instance: TesseraeInstance
    ) async throws -> Lineup {
        let action: LineupStateAction = enabled ? .enable : .disable
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["lineups", id, "actions"],
            method: "POST",
            body: TesseraeJSON.encoder().encode(
                LineupStateActionRequest(action: action)
            )
        )
        let response: LineupResponse = try await perform(
            request,
            expectedStatusCodes: [200]
        )
        return response.lineup
    }

    public func controlLineup(
        id: String,
        action: LineupPaintAction,
        pageID: String?,
        deviceIDs: [String]?,
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob {
        let body = LineupPaintActionRequest(
            action: action,
            pageID: pageID,
            deviceIDs: deviceIDs,
            overrideQuietHours: overrideQuietHours
        )
        var request = try await authenticatedRequest(
            instance: instance,
            path: ["lineups", id, "actions"],
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

    public func fetchDevicePreview(
        id: String,
        revision: String?,
        ifNoneMatch: String?,
        instance: TesseraeInstance
    ) async throws -> PreviewFetchResult {
        let queryItems = revision.map {
            [URLQueryItem(name: "revision", value: $0)]
        } ?? []
        var request = try await authenticatedRequest(
            instance: instance,
            path: ["devices", id, "preview"],
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
        framing: ImageFraming?,
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
            framing: framing,
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

    public func fetchPersonalDataStatus(
        instance: TesseraeInstance
    ) async throws -> PersonalDataStatusResponse {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["personal-data", "status"],
            method: "GET"
        )
        return try await perform(
            request,
            expectedStatusCodes: [200]
        )
    }

    public func putRemindersSnapshot(
        _ snapshot: RemindersSnapshot,
        instance: TesseraeInstance
    ) async throws -> PersonalDataSourceStatus {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["personal-data", snapshot.sourceID.rawValue],
            method: "PUT",
            body: TesseraeJSON.encoder().encode(snapshot)
        )
        return try await perform(
            request,
            expectedStatusCodes: [200]
        )
    }

    public func putHealthSummarySnapshot(
        _ snapshot: HealthSummarySnapshot,
        instance: TesseraeInstance
    ) async throws -> PersonalDataSourceStatus {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["personal-data", snapshot.sourceID.rawValue],
            method: "PUT",
            body: TesseraeJSON.encoder().encode(snapshot)
        )
        return try await perform(
            request,
            expectedStatusCodes: [200]
        )
    }

    public func deletePersonalData(
        sourceID: PersonalDataSourceID,
        instance: TesseraeInstance
    ) async throws {
        let request = try await authenticatedRequest(
            instance: instance,
            path: ["personal-data", sourceID.rawValue],
            method: "DELETE"
        )
        _ = try await performWithoutBody(
            request,
            expectedStatusCodes: [204]
        )
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

    private func authenticatedGalleryResourceRequest(
        instance: TesseraeInstance,
        path: String
    ) async throws -> URLRequest {
        guard let token = try await credentials.token(for: instance.id) else {
            throw TesseraeClientError.missingCredential
        }
        let baseURL = try normalized(instance.baseURL)
        guard
            let endpoint = URL(string: path, relativeTo: baseURL)?.absoluteURL,
            endpoint.scheme == baseURL.scheme,
            endpoint.host == baseURL.host,
            endpoint.port == baseURL.port,
            endpoint.path.hasPrefix("/api/app/v1/gallery/")
        else {
            throw TesseraeClientError.invalidResponse
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 30
        request.setValue("image/*", forHTTPHeaderField: "Accept")
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

    private func performVersionedLineup(
        _ request: URLRequest,
        expectedStatusCodes: Set<Int>
    ) async throws -> VersionedLineup {
        let response = try await response(for: request)
        guard expectedStatusCodes.contains(response.statusCode) else {
            throw try serverError(from: response)
        }
        let eTag = response.headers.first {
            $0.key.caseInsensitiveCompare("etag") == .orderedSame
        }?.value
        guard let eTag, !eTag.isEmpty else {
            throw TesseraeClientError.invalidResponse
        }
        do {
            let decoded = try TesseraeJSON.decoder().decode(
                LineupResponse.self,
                from: response.data
            )
            return VersionedLineup(lineup: decoded.lineup, eTag: eTag)
        } catch let error as TesseraeClientError {
            throw error
        } catch {
            throw TesseraeClientError.decoding(String(describing: error))
        }
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
        let decoded = try? TesseraeJSON.decoder().decode(
            APIErrorResponse.self,
            from: response.data
        )
        if response.statusCode == 403 {
            return .forbidden(
                message: decoded?.error.message
                    ?? "This Tesserae pairing does not have permission for this request.",
                requestID: decoded?.error.requestID
            )
        }
        if let decoded {
            if decoded.error.code == "pairing_expired"
                || decoded.error.code == "pairing_code_used"
            {
                return .invalidPairingCode
            }
            if decoded.error.code == "offline_album_conflict" {
                return .offlineAlbumConflict(
                    claims: decoded.error.claims ?? [:],
                    message: decoded.error.message,
                    requestID: decoded.error.requestID
                )
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

    private func galleryMultipartBody(
        boundary: String,
        image: Data,
        fileName: String,
        contentType: String
    ) -> Data {
        let safeName = fileName
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        var body = Data()
        body.appendUTF8("--\(boundary)\r\n")
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
