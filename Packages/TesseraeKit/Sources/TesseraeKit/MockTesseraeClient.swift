import Foundation

public actor MockTesseraeClient: TesseraeServing {
    private static let dashboardPreviewData = Data(
        base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAADIAAAAeCAYAAABuUU38AAAAU0lEQVR42u3PMQ3AIBAAQJxUSxc84KgKagcZWGBiadKViiAkn+aGE3Dpffr8gyQisily3NdcMWoOQURERERERERERGR/pJUzBBERERERERGRgJEPNPv5WtxkAPMAAAAASUVORK5CYII="
    )!
    private let latency: Duration
    private var completedJobs: [String: PushJob] = [:]
    private var jobsByIdempotencyKey: [String: PushJob] = [:]
    private var lineupEnabled = true
    private var lineupCurrentPageID = "pantry"
    private let lineupIntent: LineupIntent

    public init(
        latency: Duration = .milliseconds(180),
        lineupIntent: LineupIntent = .manual
    ) {
        self.latency = latency
        self.lineupIntent = lineupIntent
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
                "lineups",
                "lineup_control",
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
                "lineups:read",
                "lineups:control",
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
                iconName: "device-tablet",
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
                iconName: "monitor",
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

    public func fetchLineups(instance: TesseraeInstance) async throws -> [Lineup] {
        try await pause()
        return [demoLineup(enabled: lineupEnabled)]
    }

    public func fetchLineup(
        id: String,
        instance: TesseraeInstance
    ) async throws -> Lineup {
        try await pause()
        guard id == "kitchen-deck" else {
            throw TesseraeClientError.unavailable
        }
        return demoLineup(enabled: lineupEnabled)
    }

    public func setLineupEnabled(
        id: String,
        enabled: Bool,
        instance: TesseraeInstance
    ) async throws -> Lineup {
        _ = try await fetchLineup(id: id, instance: instance)
        lineupEnabled = enabled
        return demoLineup(enabled: enabled)
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
        let lineup = try await fetchLineup(id: id, instance: instance)
        if action == .play,
           !lineup.dashboards.contains(where: { $0.pageID == pageID }) {
            throw TesseraeClientError.unavailable
        }
        if action != .play, pageID != nil {
            throw TesseraeClientError.unavailable
        }
        let targets = deviceIDs ?? lineup.deviceIDs
        guard !targets.isEmpty else {
            throw TesseraeClientError.noTargets
        }
        guard Set(targets).isSubset(of: Set(lineup.deviceIDs)) else {
            throw TesseraeClientError.unavailable
        }
        let job = try await acceptJob(
            kind: .lineupAction,
            label: lineup.name,
            deviceIDs: targets,
            overrideQuietHours: overrideQuietHours,
            idempotencyKey: idempotencyKey,
            resultReason: action.rawValue,
            historyEventIDs: ["history-demo-lineup"]
        )
        let pageIDs = lineup.dashboards.map(\.pageID)
        switch action {
        case .play:
            lineupCurrentPageID = pageID ?? lineupCurrentPageID
        case .next:
            if let currentIndex = pageIDs.firstIndex(of: lineupCurrentPageID) {
                lineupCurrentPageID = pageIDs[(currentIndex + 1) % pageIDs.count]
            }
        case .previous:
            if let currentIndex = pageIDs.firstIndex(of: lineupCurrentPageID) {
                lineupCurrentPageID = pageIDs[
                    (currentIndex - 1 + pageIDs.count) % pageIDs.count
                ]
            }
        }
        return job
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
        let previewTarget = deviceID ?? "default"
        let eTag = "\"dashboard-preview-\(id)-\(previewTarget)\""
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

    private func demoLineup(enabled: Bool = true) -> Lineup {
        let isManual = lineupIntent == .manual
        let name: String
        let trigger: LineupTrigger?
        let intervalMinutes: Int?
        switch lineupIntent {
        case .daily:
            name = "Daily weather"
            trigger = .daily
            intervalMinutes = nil
        case .interval:
            name = "News interval"
            trigger = .interval
            intervalMinutes = 45
        case .cycle:
            name = "Morning cycle"
            trigger = .cycle
            intervalMinutes = 30
        case .manual:
            name = "Kitchen deck"
            trigger = nil
            intervalMinutes = nil
        }
        let dashboards = [
            LineupDashboard(
                pageID: "pantry",
                name: "Pantry",
                dwellMinutes: lineupIntent == .cycle ? 20 : 30,
                missing: false,
                refreshIntervalMinutes: nil,
                links: isManual
                    ? [LineupLink(targetPageID: "morning", button: "right")]
                    : [],
                conditions: []
            ),
            LineupDashboard(
                pageID: "morning",
                name: "Morning",
                dwellMinutes: lineupIntent == .cycle ? 40 : 30,
                missing: false,
                refreshIntervalMinutes: nil,
                links: isManual
                    ? [LineupLink(targetPageID: "pantry", button: "left")]
                    : [],
                conditions: []
            ),
        ]

        return Lineup(
            id: "kitchen-deck",
            name: name,
            enabled: enabled,
            intent: lineupIntent,
            deviceIDs: ["picpak-kitchen"],
            dashboards: lineupIntent == .daily ? [dashboards[0]] : dashboards,
            current: [
                LineupCurrent(
                    deviceID: "picpak-kitchen",
                    pageID: lineupCurrentPageID
                )
            ],
            nextAdvanceEpoch: nil,
            advance: isManual ? .manual : .timer,
            trigger: trigger,
            intervalMinutes: intervalMinutes,
            firesAt: lineupIntent == .daily ? "07:30" : nil,
            anchor: lineupIntent == .cycle ? "06:00" : nil,
            entryPageID: "pantry",
            homePageID: nil,
            homeTimeoutMinutes: 0,
            refreshIntervalMinutes: 15,
            endAt: nil,
            daysOfWeek: lineupIntent == .daily
                ? [0, 1, 2, 3, 4]
                : [0, 1, 2, 3, 4, 5, 6],
            priority: 0,
            smartSync: false,
            smartSyncLeadSeconds: 10,
            mode: .scheduled,
            minHoldMinutes: 5,
            windowStart: nil,
            windowEnd: nil,
            fallbackPageID: nil,
            nativeEditable: true,
            requiresWebReason: nil,
            webURL: "/decks/kitchen-deck/edit"
        )
    }

    private func pause() async throws {
        try await Task.sleep(for: latency)
    }
}
