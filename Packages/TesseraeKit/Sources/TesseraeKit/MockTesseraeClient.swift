import Foundation

public actor MockTesseraeClient: TesseraeServing {
    private static let dashboardPreviewData = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAADIAAAAeCAYAAABuUU38AAAAU0lEQVR42u3PMQ3AIBAAQJxUSxc84KgKagcZWGBiadKViiAkn+aGE3Dpffr8gyQisily3NdcMWoOQURERERERERERGR/pJUzBBERERERERGRgJEPNPv5WtxkAPMAAAAASUVORK5CYII="
    )!
    private let latency: Duration
    private var completedJobs: [String: PushJob] = [:]
    private var jobsByIdempotencyKey: [String: PushJob] = [:]

    public init(latency: Duration = .milliseconds(180)) {
        self.latency = latency
    }

    public func probe(baseURL: URL) async throws -> ServerCapabilities {
        try await pause()
        return ServerCapabilities(
            product: "tesserae",
            serverVersion: "0.205.0",
            api: CompanionAPI(version: 1),
            pairing: PairingCapabilities(supported: true, codeLength: 6, ttlSeconds: 600),
            features: [
                "devices",
                "dashboards",
                "dashboard_push",
                "image_push",
                "image_url_push",
                "jobs",
                "previews",
                "history",
                "webpage_push",
                "image_framing",
            ],
            limits: CompanionLimits(
                imageUploadBytes: 26_214_400,
                imageMaxEdge: 8_192,
                imageContentTypes: [
                    "image/jpeg",
                    "image/png",
                    "image/heic",
                    "image/heif",
                    "image/webp",
                ],
                imageFitModes: ImageFitMode.allCases,
                imageFramingMaxZoom: 4,
                jobRetentionSeconds: 86_400,
                idempotencyRetentionSeconds: 86_400
            ),
            webURL: "/"
        )
    }

    public func pair(baseURL: URL, code: String, clientName: String) async throws -> PairedSession {
        try await pause()
        guard code.count == 6, code.allSatisfy(\.isNumber) else {
            throw TesseraeClientError.invalidPairingCode
        }
        let instance = TesseraeInstance(
            id: "demo-home",
            name: "Home",
            baseURL: baseURL,
            serverVersion: "0.205.0",
            timezone: "Asia/Shanghai",
            webURL: "/"
        )
        return PairedSession(
            instance: instance,
            token: "fixture-token-for-\(clientName)",
            tokenID: "ct_fixture",
            scopes: [
                "devices:read",
                "dashboards:read",
                "push:write",
                "media:write",
            ],
            createdAt: .now
        )
    }

    public func revokeSession(instance: TesseraeInstance) async throws {
        try await pause()
    }

    public func fetchDisplays(instance: TesseraeInstance) async throws -> [DisplaySummary] {
        try await pause()
        return [
            DisplaySummary(
                id: "picpak-kitchen",
                name: "Kitchen",
                kind: "picpak",
                panel: PanelProfile(
                    width: 800,
                    height: 480,
                    gamut: "spectra_6",
                    orientation: "landscape"
                ),
                freshness: .fresh,
                lastSeenAt: .now.addingTimeInterval(-90),
                batteryPercent: 86,
                rssiDBM: -54,
                firmwareVersion: "1.8.0",
                hasPendingRender: true,
                pendingRender: PendingRender(
                    revision: "pending-demo-kitchen",
                    renderedAt: .now.addingTimeInterval(-30),
                    previewURL: "/api/app/v1/devices/picpak-kitchen/preview?revision=pending-demo-kitchen"
                )
            ),
            DisplaySummary(
                id: "e1004-desk",
                name: "Desk",
                kind: "reterminal_e1004",
                panel: PanelProfile(
                    width: 1200,
                    height: 1600,
                    gamut: "waveshare_e6",
                    orientation: "portrait"
                ),
                freshness: .stale,
                lastSeenAt: .now.addingTimeInterval(-7_200),
                batteryPercent: 61,
                rssiDBM: -67,
                firmwareVersion: "1.8.0",
                hasPendingRender: false
            ),
        ]
    }

    public func fetchDashboards(instance: TesseraeInstance) async throws -> [DashboardSummary] {
        try await pause()
        return [
            DashboardSummary(
                id: "morning",
                name: "Morning",
                kind: .grid,
                iconName: "sun-horizon",
                deviceIDs: ["e1004-desk"],
                updatedAt: .now.addingTimeInterval(-3_600),
                webURL: "/pages/morning"
            ),
            DashboardSummary(
                id: "pantry",
                name: "Pantry",
                kind: .canvas,
                iconName: "cooking-pot",
                deviceIDs: ["picpak-kitchen"],
                updatedAt: .now.addingTimeInterval(-900),
                webURL: "/pages/pantry"
            ),
            DashboardSummary(
                id: "photo-frame",
                name: "Photo Frame",
                kind: .grid,
                iconName: "image",
                deviceIDs: ["picpak-kitchen", "e1004-desk"],
                updatedAt: .now.addingTimeInterval(-86_400),
                webURL: "/pages/photo-frame"
            ),
        ]
    }

    public func fetchDevicePreview(
        id: String,
        revision: String?,
        ifNoneMatch: String?,
        instance: TesseraeInstance
    ) async throws -> PreviewFetchResult {
        try await pause()
        return .notFound
    }

    public func fetchDashboardPreview(
        id: String,
        deviceID: String?,
        ifNoneMatch: String?,
        instance: TesseraeInstance
    ) async throws -> PreviewFetchResult {
        try await pause()
        let eTag = "\"dashboard-preview-\(id)\""
        if ifNoneMatch == eTag {
            return .notModified
        }
        return .image(data: Self.dashboardPreviewData, eTag: eTag)
    }

    public func fetchHistory(
        beforeID: String?,
        limit: Int?,
        instance: TesseraeInstance
    ) async throws -> HistoryResponse {
        try await pause()
        let rows = [
            HistoryItem(
                id: "history-demo-photo",
                createdAt: .now.addingTimeInterval(-300),
                source: "companion",
                label: "Shared Photo",
                deviceIDs: ["e1004-desk"],
                status: "sent",
                durationSeconds: 8.2,
                previewAvailable: true,
                resendable: true,
                fit: .blur
            ),
            HistoryItem(
                id: "history-demo-dashboard",
                createdAt: .now.addingTimeInterval(-3_600),
                source: "button",
                label: "Pantry",
                deviceIDs: ["picpak-kitchen"],
                status: "dispatched",
                durationSeconds: 2.4,
                previewAvailable: true,
                resendable: true
            ),
        ]
        return HistoryResponse(
            items: Array(rows.prefix(limit ?? rows.count)),
            nextBeforeID: nil
        )
    }

    public func fetchHistoryPreview(
        id: String,
        ifNoneMatch: String?,
        instance: TesseraeInstance
    ) async throws -> PreviewFetchResult {
        try await pause()
        return .notFound
    }

    public func resendHistory(
        id: String,
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob {
        let history = try await fetchHistory(
            beforeID: nil,
            limit: nil,
            instance: instance
        )
        guard let item = history.items.first(where: { $0.id == id }),
              item.resendable
        else {
            throw TesseraeClientError.unavailable
        }
        return try await acceptJob(
            kind: .historyResend,
            label: item.label,
            deviceIDs: item.deviceIDs,
            overrideQuietHours: overrideQuietHours,
            idempotencyKey: idempotencyKey,
            historyEventIDs: ["history-demo-resent"]
        )
    }

    public func pushDashboard(
        id: String,
        deviceIDs: [String]?,
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob {
        let resolvedDeviceIDs = deviceIDs ?? ["e1004-desk"]
        guard !resolvedDeviceIDs.isEmpty else {
            throw TesseraeClientError.noTargets
        }
        return try await acceptJob(
            kind: .dashboardPush,
            label: id.replacingOccurrences(of: "-", with: " ").capitalized,
            deviceIDs: resolvedDeviceIDs,
            overrideQuietHours: overrideQuietHours,
            idempotencyKey: idempotencyKey
        )
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
        return try await acceptJob(
            kind: .imagePush,
            label: URL(fileURLWithPath: fileName)
                .deletingPathExtension()
                .lastPathComponent
                .replacingOccurrences(of: "-", with: " ")
                .capitalized,
            deviceIDs: deviceIDs,
            overrideQuietHours: overrideQuietHours,
            idempotencyKey: idempotencyKey,
            resultReason: [
                fit.rawValue,
                framing.map {
                    "focus \($0.focusX),\($0.focusY) · \($0.zoom)x"
                },
                "\(data.count) bytes",
            ]
            .compactMap(\.self)
            .joined(separator: " · ")
        )
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
        return try await acceptJob(
            kind: .imageURLPush,
            label: linkLabel(for: url),
            deviceIDs: deviceIDs,
            overrideQuietHours: overrideQuietHours,
            idempotencyKey: idempotencyKey,
            resultReason: fit.rawValue,
            historyEventIDs: ["history-demo-image-url"]
        )
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
        let renderSummary = [
            fit.rawValue,
            viewportW.map { "\($0)px viewport" },
        ]
        .compactMap(\.self)
        .joined(separator: " · ")
        return try await acceptJob(
            kind: .webpagePush,
            label: linkLabel(for: url),
            deviceIDs: deviceIDs,
            overrideQuietHours: overrideQuietHours,
            idempotencyKey: idempotencyKey,
            resultReason: renderSummary,
            historyEventIDs: ["history-demo-webpage"]
        )
    }

    public func fetchJob(id: String, instance: TesseraeInstance) async throws -> PushJob {
        try await pause()
        guard let job = completedJobs[id] else {
            throw TesseraeClientError.unavailable
        }
        return job
    }

    private func acceptJob(
        kind: PushJobKind,
        label: String,
        deviceIDs: [String],
        overrideQuietHours: Bool,
        idempotencyKey: String,
        resultReason: String? = nil,
        historyEventIDs: [String]? = nil
    ) async throws -> PushJob {
        try await pause()
        if let existing = jobsByIdempotencyKey[idempotencyKey] {
            return existing
        }

        let now = Date.now
        let id = "job_\(UUID().uuidString.lowercased())"
        let accepted = PushJob(
            id: id,
            kind: kind,
            status: .accepted,
            label: label,
            targetDeviceIDs: deviceIDs,
            createdAt: now,
            updatedAt: now
        )
        let completed = PushJob(
            id: id,
            kind: kind,
            status: .succeeded,
            label: label,
            targetDeviceIDs: deviceIDs,
            createdAt: now,
            updatedAt: now.addingTimeInterval(1),
            result: PushJobResult(
                status: .published,
                reason: resultReason ?? (overrideQuietHours ? "quiet_hours_overridden" : nil),
                deviceIDs: deviceIDs,
                historyEventIDs: historyEventIDs
            )
        )
        jobsByIdempotencyKey[idempotencyKey] = accepted
        completedJobs[id] = completed
        return accepted
    }

    private func linkLabel(for url: URL) -> String {
        let host = url.host() ?? url.absoluteString
        let path = url.path.isEmpty ? "/" : url.path
        return "\(host)\(path)"
    }

    private func pause() async throws {
        try await Task.sleep(for: latency)
    }
}
