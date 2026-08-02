import Foundation

public extension MockTesseraeClient {
    func fetchPersonalDataStatus(
        instance: TesseraeInstance
    ) async throws -> PersonalDataStatusResponse {
        PersonalDataStatusResponse(sources: [])
    }

    func putRemindersFridgeSnapshot(
        _ snapshot: RemindersFridgeSnapshot,
        instance: TesseraeInstance
    ) async throws -> PersonalDataSourceStatus {
        PersonalDataSourceStatus(
            sourceID: snapshot.sourceID,
            state: snapshot.expiresAt > Date() ? .fresh : .expired,
            generatedAt: snapshot.generatedAt,
            staleAt: snapshot.generatedAt.addingTimeInterval(86_400),
            expiresAt: snapshot.expiresAt
        )
    }

    func deletePersonalData(
        sourceID: PersonalDataSourceID,
        instance: TesseraeInstance
    ) async throws {}
}
