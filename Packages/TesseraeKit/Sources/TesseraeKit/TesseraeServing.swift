import Foundation

public protocol TesseraeServing: Sendable {
    func probe(baseURL: URL) async throws -> ServerCapabilities
    func pair(baseURL: URL, code: String, clientName: String) async throws -> PairedSession
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
    case noTargets
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .incompatibleServer:
            "This Tesserae server does not advertise a compatible Companion API."
        case .invalidPairingCode:
            "The pairing code is invalid or expired."
        case .noTargets:
            "Select at least one display."
        case .unavailable:
            "The Tesserae instance is unavailable."
        }
    }
}
