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
    private var authoredLineups: [String: Lineup] = [:]
    private var lineupVersions: [String: Int] = [:]
    private var galleryFoldersByID: [String: GalleryFolder]
    private var galleryImagesByFolderID: [String: [GalleryImage]]
    private var galleryImagesByIdempotencyKey: [String: GalleryImage] = [:]
    private var offlineAlbumsByFolderID: [String: OfflineAlbum] = [:]
    private let lineupIntent: LineupIntent
    private let lineupFetchError: TesseraeClientError?
    private let lineupAuthoringGranted: Bool
    private let offlineAlbumAuthoringGranted: Bool

    public init(
        latency: Duration = .milliseconds(180),
        lineupIntent: LineupIntent = .manual,
        lineupFetchError: TesseraeClientError? = nil,
        lineupAuthoringGranted: Bool = true,
        offlineAlbumAuthoringGranted: Bool = true
    ) {
        self.latency = latency
        self.lineupIntent = lineupIntent
        self.lineupFetchError = lineupFetchError
        self.lineupAuthoringGranted = lineupAuthoringGranted
        self.offlineAlbumAuthoringGranted = offlineAlbumAuthoringGranted
        let family = GalleryFolder(
            id: "folder_family",
            name: "family",
            kind: .internal,
            writable: true,
            imageCount: 5,
            coverThumbnailURL: "/api/app/v1/gallery/images/image_family_01/thumbnail"
        )
        let archive = GalleryFolder(
            id: "folder_archive",
            name: "nas-archive",
            kind: .external,
            writable: false,
            imageCount: 1,
            coverThumbnailURL: "/api/app/v1/gallery/images/image_archive_01/thumbnail"
        )
        galleryFoldersByID = [family.id: family, archive.id: archive]
        galleryImagesByFolderID = [
            family.id: [
                GalleryImage(
                    id: "image_family_01",
                    folderID: family.id,
                    name: "family-portrait.png",
                    contentType: "image/png",
                    bytes: Self.dashboardPreviewData.count,
                    width: 1200,
                    height: 1600,
                    eTag: "\"gallery-image-family-01\"",
                    thumbnailURL: "/api/app/v1/gallery/images/image_family_01/thumbnail",
                    contentURL: "/api/app/v1/gallery/images/image_family_01/content",
                    createdAt: .now.addingTimeInterval(-3_600)
                ),
                GalleryImage(
                    id: "image_family_02",
                    folderID: family.id,
                    name: "picnic.jpg",
                    contentType: "image/jpeg",
                    bytes: Self.dashboardPreviewData.count,
                    width: 1600,
                    height: 1200,
                    eTag: "\"gallery-image-family-02\"",
                    thumbnailURL: "/api/app/v1/gallery/images/image_family_02/thumbnail",
                    contentURL: "/api/app/v1/gallery/images/image_family_02/content",
                    createdAt: .now.addingTimeInterval(-1_800)
                ),
                GalleryImage(
                    id: "image_family_03",
                    folderID: family.id,
                    name: "birthday-square.png",
                    contentType: "image/png",
                    bytes: Self.dashboardPreviewData.count,
                    width: 1_000,
                    height: 1_000,
                    eTag: "\"gallery-image-family-03\"",
                    thumbnailURL: "/api/app/v1/gallery/images/image_family_03/thumbnail",
                    contentURL: "/api/app/v1/gallery/images/image_family_03/content",
                    createdAt: .now.addingTimeInterval(-1_200)
                ),
                GalleryImage(
                    id: "image_family_04",
                    folderID: family.id,
                    name: "panorama.png",
                    contentType: "image/png",
                    bytes: Self.dashboardPreviewData.count,
                    width: 2_000,
                    height: 800,
                    eTag: "\"gallery-image-family-04\"",
                    thumbnailURL: "/api/app/v1/gallery/images/image_family_04/thumbnail",
                    contentURL: "/api/app/v1/gallery/images/image_family_04/content",
                    createdAt: .now.addingTimeInterval(-600)
                ),
                GalleryImage(
                    id: "image_family_05",
                    folderID: family.id,
                    name: "portrait.png",
                    contentType: "image/png",
                    bytes: Self.dashboardPreviewData.count,
                    width: 800,
                    height: 1_600,
                    eTag: "\"gallery-image-family-05\"",
                    thumbnailURL: "/api/app/v1/gallery/images/image_family_05/thumbnail",
                    contentURL: "/api/app/v1/gallery/images/image_family_05/content",
                    createdAt: .now.addingTimeInterval(-300)
                ),
            ],
            archive.id: [
                GalleryImage(
                    id: "image_archive_01",
                    folderID: archive.id,
                    name: "archive.jpg",
                    contentType: "image/jpeg",
                    bytes: Self.dashboardPreviewData.count,
                    width: 800,
                    height: 480,
                    eTag: "\"gallery-image-archive-01\"",
                    thumbnailURL: "/api/app/v1/gallery/images/image_archive_01/thumbnail",
                    contentURL: "/api/app/v1/gallery/images/image_archive_01/content"
                ),
            ],
        ]
    }

    public func probe(baseURL: URL) async throws -> ServerCapabilities {
        try await pause()
        return ServerCapabilities(
            product: "tesserae",
            serverVersion: "0.303.0",
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
                "lineup_authoring",
                "session_read",
                "gallery",
                "offline_albums",
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
                galleryUploadBytes: 20_971_520,
                galleryImageContentTypes: [
                    "image/jpeg",
                    "image/png",
                    "image/heic",
                    "image/heif",
                    "image/webp",
                ],
                galleryUploadBatchSize: 20,
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
            serverVersion: "0.303.0",
            timezone: "Asia/Shanghai",
            webURL: "/"
        )
        var scopes = [
            "devices:read",
            "dashboards:read",
            "push:write",
            "media:write",
            "lineups:read",
            "lineups:control",
            "gallery:read",
            "gallery:write",
        ]
        if lineupAuthoringGranted {
            scopes.append("lineups:write")
        }
        return PairedSession(
            instance: instance,
            token: "fixture-token-for-\(clientName)",
            tokenID: "ct_fixture",
            scopes: scopes,
            createdAt: .now
        )
    }

    public func fetchSessionAuthorization(
        instance: TesseraeInstance
    ) async throws -> CompanionSessionAuthorization? {
        try await pause()
        var scopes: Set<String> = [
            "devices:read",
            "dashboards:read",
            "lineups:read",
            "lineups:control",
            "gallery:read",
            "gallery:write",
        ]
        if lineupAuthoringGranted {
            scopes.insert("lineups:write")
        }
        if offlineAlbumAuthoringGranted {
            scopes.insert("offline_albums:write")
        }
        return CompanionSessionAuthorization(
            tokenID: "ct_fixture",
            scopes: scopes,
            settingsURL: "/settings/companion"
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
                capabilitySupport: [
                    "frame_cache": DeviceCapabilitySupport(
                        state: .unsupported,
                        reasonCode: "not_advertised",
                        observedAt: .now.addingTimeInterval(-90)
                    ),
                ],
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
                capabilitySupport: [
                    "frame_cache": DeviceCapabilitySupport(
                        state: .supported,
                        observedAt: .now.addingTimeInterval(-7_200),
                        detail: [
                            "capacity_bytes": 67_108_864,
                            "max_frames": 32,
                        ]
                    ),
                ],
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

    public func fetchGalleryFolders(
        instance: TesseraeInstance
    ) async throws -> [GalleryFolder] {
        try await pause()
        return galleryFoldersByID.values.sorted {
            $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    public func fetchGalleryFolder(
        id: String,
        instance: TesseraeInstance
    ) async throws -> GalleryFolderDetail {
        try await pause()
        guard let folder = galleryFoldersByID[id] else {
            throw TesseraeClientError.unavailable
        }
        return GalleryFolderDetail(
            folder: folder,
            images: galleryImagesByFolderID[id] ?? []
        )
    }

    public func createGalleryFolder(
        name: String,
        instance: TesseraeInstance
    ) async throws -> GalleryFolderDetail {
        try await pause()
        let normalized = name
            .lowercased()
            .replacingOccurrences(
                of: "[^a-z0-9_-]+",
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !normalized.isEmpty else {
            throw TesseraeClientError.server(
                code: "invalid_gallery_folder",
                message: "Enter a folder name containing letters or numbers.",
                requestID: nil
            )
        }
        guard !galleryFoldersByID.values.contains(where: { $0.name == normalized }) else {
            throw TesseraeClientError.server(
                code: "gallery_folder_exists",
                message: "A Gallery folder with this name already exists.",
                requestID: nil
            )
        }
        let folder = GalleryFolder(
            id: "folder_\(UUID().uuidString.lowercased())",
            name: normalized,
            kind: .internal,
            writable: true,
            imageCount: 0
        )
        galleryFoldersByID[folder.id] = folder
        galleryImagesByFolderID[folder.id] = []
        return GalleryFolderDetail(folder: folder, images: [])
    }

    public func uploadGalleryImage(
        folderID: String,
        data: Data,
        fileName: String,
        contentType: String,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> GalleryImage {
        try await pause()
        if let existing = galleryImagesByIdempotencyKey[idempotencyKey] {
            return existing
        }
        guard let folder = galleryFoldersByID[folderID] else {
            throw TesseraeClientError.unavailable
        }
        guard folder.writable else {
            throw TesseraeClientError.server(
                code: "gallery_folder_read_only",
                message: "This Gallery folder is read-only.",
                requestID: nil
            )
        }
        let storedContentType = ["image/heic", "image/heif"].contains(contentType)
            ? "image/jpeg"
            : contentType
        let imageID = "image_\(UUID().uuidString.lowercased())"
        let image = GalleryImage(
            id: imageID,
            folderID: folderID,
            name: fileName,
            contentType: storedContentType,
            bytes: data.count,
            width: 1200,
            height: 1600,
            eTag: "\"\(imageID)\"",
            thumbnailURL: "/api/app/v1/gallery/images/\(imageID)/thumbnail",
            contentURL: "/api/app/v1/gallery/images/\(imageID)/content",
            createdAt: .now
        )
        galleryImagesByIdempotencyKey[idempotencyKey] = image
        galleryImagesByFolderID[folderID, default: []].append(image)
        galleryFoldersByID[folderID] = GalleryFolder(
            id: folder.id,
            name: folder.name,
            kind: folder.kind,
            writable: folder.writable,
            imageCount: galleryImagesByFolderID[folderID]?.count ?? 0,
            coverThumbnailURL: folder.coverThumbnailURL ?? image.thumbnailURL
        )
        return image
    }

    public func fetchGalleryResource(
        path: String,
        ifNoneMatch: String?,
        instance: TesseraeInstance
    ) async throws -> PreviewFetchResult {
        try await pause()
        guard path.hasPrefix("/api/app/v1/gallery/images/") else {
            throw TesseraeClientError.invalidResponse
        }
        let eTag = "\"mock-gallery-resource\""
        if ifNoneMatch == eTag {
            return .notModified
        }
        return .image(data: Self.dashboardPreviewData, eTag: eTag)
    }

    public func fetchOfflineAlbum(
        folderID: String,
        instance: TesseraeInstance
    ) async throws -> OfflineAlbumResponse {
        try await pause()
        guard let album = offlineAlbumsByFolderID[folderID] else {
            throw TesseraeClientError.server(
                code: "not_found",
                message: "This Gallery folder has no Offline Album.",
                requestID: nil
            )
        }
        let targetPlans = offlineAlbumTargets(
            deviceIDs: album.deviceIDs,
            folderID: folderID
        )
        return OfflineAlbumResponse(album: album, targets: targetPlans)
    }

    public func preflightOfflineAlbum(
        folderID: String,
        draft: OfflineAlbumDraft,
        instance: TesseraeInstance
    ) async throws -> OfflineAlbumPreflightResponse {
        try await pause()
        try requireOfflineAlbumWritePermission()
        guard galleryFoldersByID[folderID] != nil else {
            throw TesseraeClientError.server(
                code: "not_found",
                message: "Gallery folder not found.",
                requestID: nil
            )
        }
        return OfflineAlbumPreflightResponse(
            folderID: folderID,
            targets: offlineAlbumTargets(
                deviceIDs: draft.deviceIDs,
                folderID: folderID
            )
        )
    }

    public func putOfflineAlbum(
        folderID: String,
        request: OfflineAlbumWriteRequest,
        instance: TesseraeInstance
    ) async throws -> OfflineAlbumResponse {
        try await pause()
        try requireOfflineAlbumWritePermission()
        guard galleryFoldersByID[folderID] != nil else {
            throw TesseraeClientError.server(
                code: "not_found",
                message: "Gallery folder not found.",
                requestID: nil
            )
        }

        let displays = try await fetchDisplays(instance: instance)
        let displayByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        let unsupported = request.album.deviceIDs.filter {
            displayByID[$0]?.frameCacheSupport?.state == .unsupported
        }
        if !unsupported.isEmpty {
            throw TesseraeClientError.server(
                code: "invalid_target",
                message: "One or more displays do not support Offline Albums.",
                requestID: nil
            )
        }

        let claims = offlineAlbumClaims(
            deviceIDs: request.album.deviceIDs,
            excludingFolderID: folderID
        )
        if !claims.isEmpty, !request.replaceConflicts {
            throw TesseraeClientError.offlineAlbumConflict(
                claims: claims,
                message: "One or more displays are used by another Offline Album.",
                requestID: nil
            )
        }
        if request.replaceConflicts {
            for claimedFolderID in Set(claims.values) {
                guard let displaced = offlineAlbumsByFolderID[claimedFolderID] else {
                    continue
                }
                let remainingDeviceIDs = displaced.deviceIDs.filter {
                    claims[$0] != claimedFolderID
                }
                offlineAlbumsByFolderID[claimedFolderID] = OfflineAlbum(
                    id: displaced.id,
                    folderID: displaced.folderID,
                    name: displaced.name,
                    enabled: displaced.enabled,
                    deviceIDs: remainingDeviceIDs,
                    order: displaced.order,
                    fit: displaced.fit,
                    playback: displaced.playback
                )
            }
        }

        let album = OfflineAlbum(
            id: offlineAlbumsByFolderID[folderID]?.id ?? folderID,
            folderID: folderID,
            draft: request.album
        )
        offlineAlbumsByFolderID[folderID] = album
        return OfflineAlbumResponse(
            album: album,
            targets: offlineAlbumTargets(
                deviceIDs: album.deviceIDs,
                folderID: folderID
            )
        )
    }

    public func deleteOfflineAlbum(
        folderID: String,
        instance: TesseraeInstance
    ) async throws {
        try await pause()
        try requireOfflineAlbumWritePermission()
        offlineAlbumsByFolderID.removeValue(forKey: folderID)
    }

    public func fetchLineups(instance: TesseraeInstance) async throws -> [Lineup] {
        try await pause()
        if let lineupFetchError {
            throw lineupFetchError
        }
        let primary = authoredLineups["kitchen-deck"]
            ?? demoLineup(enabled: lineupEnabled)
        let created = authoredLineups.values
            .filter { $0.id != "kitchen-deck" }
            .sorted { $0.name < $1.name }
        return [primary] + created
    }

    public func fetchLineup(
        id: String,
        instance: TesseraeInstance
    ) async throws -> Lineup {
        try await pause()
        if let authored = authoredLineups[id] {
            return authored
        }
        guard id == "kitchen-deck" else {
            throw TesseraeClientError.unavailable
        }
        return demoLineup(enabled: lineupEnabled)
    }

    public func fetchVersionedLineup(
        id: String,
        instance: TesseraeInstance
    ) async throws -> VersionedLineup {
        let lineup = try await fetchLineup(id: id, instance: instance)
        return VersionedLineup(lineup: lineup, eTag: mockETag(for: id))
    }

    public func createLineup(
        _ request: LineupCreateRequest,
        instance: TesseraeInstance
    ) async throws -> VersionedLineup {
        try await pause()
        guard lineupAuthoringGranted else {
            throw TesseraeClientError.forbidden(
                message: "Grant Create and edit Lineups in Tesserae Settings.",
                requestID: nil
            )
        }
        let dashboardCatalog = try await fetchDashboards(instance: instance)
        let names = Dictionary(uniqueKeysWithValues: dashboardCatalog.map { ($0.id, $0.name) })
        let resolvedDeviceIDs = resolveLineupDeviceIDs(
            explicitDeviceIDs: request.deviceIDs,
            pageIDs: request.pageIDs,
            dashboardCatalog: dashboardCatalog
        )
        let id = uniqueLineupID(for: request.name)
        let trigger: LineupTrigger?
        let advance: LineupAdvance
        switch request.intent {
        case .manual:
            advance = .manual
            trigger = nil
        case .daily:
            advance = .timer
            trigger = .daily
        case .interval:
            advance = .timer
            trigger = .interval
        case .cycle:
            advance = .timer
            trigger = .cycle
        }
        let dashboards = request.pageIDs.map { pageID in
            LineupDashboard(
                pageID: pageID,
                name: names[pageID] ?? pageID,
                dwellMinutes: request.dwellMinutes?[pageID]
                    ?? request.intervalMinutes
                    ?? 30,
                missing: names[pageID] == nil,
                refreshIntervalMinutes: nil,
                links: [],
                conditions: []
            )
        }
        let lineup = Lineup(
            id: id,
            name: request.name,
            enabled: true,
            intent: request.intent,
            deviceIDs: request.deviceIDs,
            resolvedDeviceIDs: resolvedDeviceIDs,
            dashboards: dashboards,
            current: [],
            nextAdvanceEpoch: nil,
            advance: advance,
            trigger: trigger,
            intervalMinutes: request.intent == .manual ? nil : request.intervalMinutes,
            firesAt: request.firesAt,
            anchor: request.intent == .manual ? nil : request.anchor,
            entryPageID: request.pageIDs.first,
            homePageID: nil,
            homeTimeoutMinutes: nil,
            refreshIntervalMinutes: nil,
            endAt: nil,
            daysOfWeek: [0, 1, 2, 3, 4, 5, 6],
            priority: 0,
            smartSync: false,
            smartSyncLeadSeconds: nil,
            mode: .scheduled,
            minHoldMinutes: nil,
            windowStart: nil,
            windowEnd: nil,
            fallbackPageID: nil,
            nativeEditable: true,
            requiresWebReason: nil,
            webURL: "/decks/\(id)/edit"
        )
        authoredLineups[id] = lineup
        lineupVersions[id] = 1
        return VersionedLineup(lineup: lineup, eTag: mockETag(for: id))
    }

    public func updateLineup(
        id: String,
        eTag: String,
        patch: LineupPatchRequest,
        instance: TesseraeInstance
    ) async throws -> VersionedLineup {
        try await pause()
        guard lineupAuthoringGranted else {
            throw TesseraeClientError.forbidden(
                message: "Grant Create and edit Lineups in Tesserae Settings.",
                requestID: nil
            )
        }
        guard eTag == mockETag(for: id) else {
            throw TesseraeClientError.server(
                code: "precondition_failed",
                message: "The lineup changed since you loaded it; re-read it and try again.",
                requestID: nil
            )
        }
        let existing = try await fetchLineup(id: id, instance: instance)
        let dashboardCatalog = try await fetchDashboards(instance: instance)
        let names = Dictionary(uniqueKeysWithValues: dashboardCatalog.map { ($0.id, $0.name) })
        let pageIDs = patch.pageIDs ?? existing.dashboards.map(\.pageID)
        let deviceIDs = patch.deviceIDs ?? existing.deviceIDs
        let resolvedDeviceIDs = resolveLineupDeviceIDs(
            explicitDeviceIDs: deviceIDs,
            pageIDs: pageIDs,
            dashboardCatalog: dashboardCatalog
        )
        let previous = Dictionary(uniqueKeysWithValues: existing.dashboards.map { ($0.pageID, $0) })
        let dashboards = pageIDs.map { pageID in
            let old = previous[pageID]
            return LineupDashboard(
                pageID: pageID,
                name: names[pageID] ?? old?.name ?? pageID,
                dwellMinutes: patch.dwellMinutes?[pageID]
                    ?? old?.dwellMinutes
                    ?? patch.intervalMinutes
                    ?? existing.intervalMinutes
                    ?? 30,
                missing: names[pageID] == nil,
                refreshIntervalMinutes: old?.refreshIntervalMinutes,
                links: old?.links,
                conditions: old?.conditions
            )
        }
        let updated = copying(
            existing,
            name: patch.name ?? existing.name,
            enabled: patch.enabled ?? existing.enabled,
            deviceIDs: deviceIDs,
            resolvedDeviceIDs: resolvedDeviceIDs,
            dashboards: dashboards,
            intervalMinutes: patch.intervalMinutes ?? existing.intervalMinutes,
            firesAt: patch.firesAt ?? existing.firesAt,
            anchor: patch.anchor ?? existing.anchor
        )
        authoredLineups[id] = updated
        if id == "kitchen-deck" {
            lineupEnabled = updated.enabled
        }
        lineupVersions[id, default: 1] += 1
        return VersionedLineup(lineup: updated, eTag: mockETag(for: id))
    }

    public func setLineupEnabled(
        id: String,
        enabled: Bool,
        instance: TesseraeInstance
    ) async throws -> Lineup {
        let existing = try await fetchLineup(id: id, instance: instance)
        let updated = copying(existing, enabled: enabled)
        authoredLineups[id] = updated
        lineupVersions[id, default: 1] += 1
        if id == "kitchen-deck" {
            lineupEnabled = enabled
        }
        return updated
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
        let resolvedDeviceIDs = lineup.resolvedDeviceIDs ?? lineup.deviceIDs
        let targets = deviceIDs ?? resolvedDeviceIDs
        guard !targets.isEmpty else {
            throw TesseraeClientError.noTargets
        }
        guard Set(targets).isSubset(of: Set(resolvedDeviceIDs)) else {
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
        var currentByDevice = Dictionary(
            uniqueKeysWithValues: lineup.current.map { ($0.deviceID, $0.pageID) }
        )
        for target in targets {
            currentByDevice[target] = lineupCurrentPageID
        }
        authoredLineups[id] = copying(
            lineup,
            current: currentByDevice.keys.sorted().map {
                LineupCurrent(
                    deviceID: $0,
                    pageID: currentByDevice[$0] ?? lineupCurrentPageID
                )
            }
        )
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

    private func requireOfflineAlbumWritePermission() throws {
        guard offlineAlbumAuthoringGranted else {
            throw TesseraeClientError.forbidden(
                message: "Grant Offline Album management in Tesserae Settings.",
                requestID: nil
            )
        }
    }

    private func offlineAlbumClaims(
        deviceIDs: [String],
        excludingFolderID: String
    ) -> [String: String] {
        var claims: [String: String] = [:]
        for album in offlineAlbumsByFolderID.values
            where album.enabled && album.folderID != excludingFolderID
        {
            for deviceID in deviceIDs where album.deviceIDs.contains(deviceID) {
                claims[deviceID] = album.id
            }
        }
        return claims
    }

    private func offlineAlbumTargets(
        deviceIDs: [String],
        folderID: String
    ) -> [OfflineAlbumTarget] {
        let sourceCount = galleryImagesByFolderID[folderID]?.count ?? 0
        let claims = offlineAlbumClaims(
            deviceIDs: deviceIDs,
            excludingFolderID: folderID
        )
        return deviceIDs.map { deviceID in
            let support: DeviceCapabilitySupport
            switch deviceID {
            case "e1004-desk":
                support = DeviceCapabilitySupport(
                    state: .supported,
                    observedAt: .now.addingTimeInterval(-7_200),
                    detail: [
                        "capacity_bytes": 67_108_864,
                        "max_frames": 32,
                    ]
                )
            case "picpak-kitchen":
                support = DeviceCapabilitySupport(
                    state: .unsupported,
                    reasonCode: "not_advertised",
                    observedAt: .now.addingTimeInterval(-90)
                )
            default:
                support = DeviceCapabilitySupport(
                    state: .unknown,
                    reasonCode: "no_usable_heartbeat"
                )
            }
            let cacheable = min(
                sourceCount,
                support.frameCacheMaxFrames ?? sourceCount
            )
            let plan = support.state == .supported
                ? OfflineAlbumPlan(
                    totalFrames: sourceCount,
                    cacheableFrames: cacheable,
                    fullyOffline: cacheable == sourceCount,
                    storage: OfflineAlbumStorageProjection(
                        bytes: cacheable * 768_000,
                        accuracy: .exact
                    )
                )
                : nil
            return OfflineAlbumTarget(
                deviceID: deviceID,
                support: support,
                conflict: claims[deviceID].map {
                    OfflineAlbumTargetConflict(albumID: $0)
                },
                plan: plan
            )
        }
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

    private func uniqueLineupID(for name: String) -> String {
        let base = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "_" }
            .joined()
            .split(separator: "_")
            .joined(separator: "_")
        let candidate = base.isEmpty ? "lineup" : base
        let taken = Set(["kitchen-deck"] + authoredLineups.keys)
        guard taken.contains(candidate) else { return candidate }
        var suffix = 2
        while taken.contains("\(candidate)_\(suffix)") {
            suffix += 1
        }
        return "\(candidate)_\(suffix)"
    }

    private func mockETag(for id: String) -> String {
        "\"mock-\(id)-\(lineupVersions[id, default: 1])\""
    }

    private func copying(
        _ lineup: Lineup,
        name: String? = nil,
        enabled: Bool? = nil,
        deviceIDs: [String]? = nil,
        resolvedDeviceIDs: [String]? = nil,
        dashboards: [LineupDashboard]? = nil,
        current: [LineupCurrent]? = nil,
        intervalMinutes: Int? = nil,
        firesAt: String? = nil,
        anchor: String? = nil
    ) -> Lineup {
        Lineup(
            id: lineup.id,
            name: name ?? lineup.name,
            enabled: enabled ?? lineup.enabled,
            intent: lineup.intent,
            deviceIDs: deviceIDs ?? lineup.deviceIDs,
            resolvedDeviceIDs: resolvedDeviceIDs ?? lineup.resolvedDeviceIDs,
            dashboards: dashboards ?? lineup.dashboards,
            current: current ?? lineup.current,
            nextAdvanceEpoch: lineup.nextAdvanceEpoch,
            advance: lineup.advance,
            trigger: lineup.trigger,
            intervalMinutes: intervalMinutes ?? lineup.intervalMinutes,
            firesAt: firesAt ?? lineup.firesAt,
            anchor: anchor ?? lineup.anchor,
            entryPageID: lineup.entryPageID,
            homePageID: lineup.homePageID,
            homeTimeoutMinutes: lineup.homeTimeoutMinutes,
            refreshIntervalMinutes: lineup.refreshIntervalMinutes,
            endAt: lineup.endAt,
            daysOfWeek: lineup.daysOfWeek,
            priority: lineup.priority,
            smartSync: lineup.smartSync,
            smartSyncLeadSeconds: lineup.smartSyncLeadSeconds,
            mode: lineup.mode,
            minHoldMinutes: lineup.minHoldMinutes,
            windowStart: lineup.windowStart,
            windowEnd: lineup.windowEnd,
            fallbackPageID: lineup.fallbackPageID,
            nativeEditable: lineup.nativeEditable,
            requiresWebReason: lineup.requiresWebReason,
            webURL: lineup.webURL
        )
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
            resolvedDeviceIDs: ["picpak-kitchen"],
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

    private func resolveLineupDeviceIDs(
        explicitDeviceIDs: [String],
        pageIDs: [String],
        dashboardCatalog: [DashboardSummary]
    ) -> [String] {
        let candidates = explicitDeviceIDs.isEmpty
            ? dashboardCatalog
                .filter { pageIDs.contains($0.id) }
                .flatMap(\.deviceIDs)
            : explicitDeviceIDs
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0).inserted }
    }
}
