import Foundation

public protocol TesseraeServing: Sendable {
    func probe(baseURL: URL) async throws -> ServerCapabilities
    func pair(baseURL: URL, code: String, clientName: String) async throws -> PairedSession
    func fetchSessionAuthorization(
        instance: TesseraeInstance
    ) async throws -> CompanionSessionAuthorization?
    func revokeSession(instance: TesseraeInstance) async throws
    func fetchDisplays(instance: TesseraeInstance) async throws -> [DisplaySummary]
    func fetchDashboards(instance: TesseraeInstance) async throws -> [DashboardSummary]
    func fetchLineups(instance: TesseraeInstance) async throws -> [Lineup]
    func fetchLineup(id: String, instance: TesseraeInstance) async throws -> Lineup
    func fetchVersionedLineup(
        id: String,
        instance: TesseraeInstance
    ) async throws -> VersionedLineup
    func createLineup(
        _ request: LineupCreateRequest,
        instance: TesseraeInstance
    ) async throws -> VersionedLineup
    func updateLineup(
        id: String,
        eTag: String,
        patch: LineupPatchRequest,
        instance: TesseraeInstance
    ) async throws -> VersionedLineup
    func setLineupEnabled(
        id: String,
        enabled: Bool,
        instance: TesseraeInstance
    ) async throws -> Lineup
    func controlLineup(
        id: String,
        action: LineupPaintAction,
        pageID: String?,
        deviceIDs: [String]?,
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob
    func fetchDevicePreview(
        id: String,
        revision: String?,
        ifNoneMatch: String?,
        instance: TesseraeInstance
    ) async throws -> PreviewFetchResult
    func fetchDashboardPreview(
        id: String,
        deviceID: String?,
        ifNoneMatch: String?,
        instance: TesseraeInstance
    ) async throws -> PreviewFetchResult
    func fetchHistory(
        beforeID: String?,
        limit: Int?,
        instance: TesseraeInstance
    ) async throws -> HistoryResponse
    func fetchHistoryPreview(
        id: String,
        ifNoneMatch: String?,
        instance: TesseraeInstance
    ) async throws -> PreviewFetchResult
    func resendHistory(
        id: String,
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob
    func pushDashboard(
        id: String,
        deviceIDs: [String]?,
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob
    func sendImage(
        data: Data,
        fileName: String,
        contentType: String,
        fit: ImageFitMode,
        framing: ImageFraming?,
        deviceIDs: [String],
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob
    func sendImageURL(
        url: URL,
        fit: ImageFitMode,
        deviceIDs: [String],
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob
    func sendWebpage(
        url: URL,
        fit: ImageFitMode,
        viewportW: Int?,
        deviceIDs: [String],
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob
    func fetchPersonalDataStatus(
        instance: TesseraeInstance
    ) async throws -> PersonalDataStatusResponse
    func putRemindersSnapshot(
        _ snapshot: RemindersSnapshot,
        instance: TesseraeInstance
    ) async throws -> PersonalDataSourceStatus
    func putHealthSummarySnapshot(
        _ snapshot: HealthSummarySnapshot,
        instance: TesseraeInstance
    ) async throws -> PersonalDataSourceStatus
    func deletePersonalData(
        sourceID: PersonalDataSourceID,
        instance: TesseraeInstance
    ) async throws
    func fetchJob(id: String, instance: TesseraeInstance) async throws -> PushJob
}

public extension TesseraeServing {
    /// Backward-compatible unframed upload used by the existing app, Share
    /// Extension, and App Intents until their editing surfaces adopt 0.6.
    func sendImage(
        data: Data,
        fileName: String,
        contentType: String,
        fit: ImageFitMode,
        deviceIDs: [String],
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob {
        try await sendImage(
            data: data,
            fileName: fileName,
            contentType: contentType,
            fit: fit,
            framing: nil,
            deviceIDs: deviceIDs,
            overrideQuietHours: overrideQuietHours,
            idempotencyKey: idempotencyKey,
            instance: instance
        )
    }
}

public enum TesseraeClientError: Error, Equatable, LocalizedError, Sendable {
    case incompatibleServer
    case invalidPairingCode
    case invalidServerURL
    case missingFeatures([String])
    case missingCredential
    case noTargets
    case pairingUnavailable
    case unavailable
    case unauthorized
    case forbidden(message: String, requestID: String?)
    case invalidResponse
    case httpStatus(Int)
    case transport(String)
    case decoding(String)
    case server(code: String, message: String, requestID: String?)

    public var errorDescription: String? {
        switch self {
        case .incompatibleServer:
            "This Tesserae server does not advertise a compatible Companion API."
        case .invalidPairingCode:
            "The pairing code is invalid or expired."
        case .invalidServerURL:
            "Enter a valid HTTP or HTTPS Tesserae server URL."
        case let .missingFeatures(features):
            "This Tesserae server is missing required Companion features: \(features.joined(separator: ", "))."
        case .missingCredential:
            "This Tesserae instance is not paired on this device."
        case .noTargets:
            "Select at least one display."
        case .pairingUnavailable:
            "Companion pairing is disabled on this Tesserae server."
        case .unavailable:
            "The Tesserae instance is unavailable."
        case .unauthorized:
            "The Tesserae credential is invalid or has been revoked."
        case let .forbidden(message, requestID):
            if let requestID {
                "\(message) (request \(requestID))"
            } else {
                message
            }
        case .invalidResponse:
            "The server returned an invalid HTTP response."
        case let .httpStatus(status):
            "The Tesserae server returned HTTP \(status)."
        case let .transport(message):
            "Could not reach Tesserae: \(message)"
        case .decoding:
            "The Tesserae response does not match the Companion API contract."
        case let .server(_, message, requestID):
            if let requestID {
                "\(message) (request \(requestID))"
            } else {
                message
            }
        }
    }
}
