import Foundation

public protocol TesseraeServing: Sendable {
    func probe(baseURL: URL) async throws -> ServerCapabilities
    func pair(baseURL: URL, code: String, clientName: String) async throws -> PairedSession
    func revokeSession(instance: TesseraeInstance) async throws
    func fetchDisplays(instance: TesseraeInstance) async throws -> [DisplaySummary]
    func fetchDashboards(instance: TesseraeInstance) async throws -> [DashboardSummary]
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
        deviceIDs: [String],
        overrideQuietHours: Bool,
        idempotencyKey: String,
        instance: TesseraeInstance
    ) async throws -> PushJob
    func fetchJob(id: String, instance: TesseraeInstance) async throws -> PushJob
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
