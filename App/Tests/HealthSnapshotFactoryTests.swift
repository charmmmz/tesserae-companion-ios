import Foundation
import HealthKit
import TesseraeKit
import XCTest
@testable import Tesserae_Companion

@MainActor
final class HealthSnapshotFactoryTests: XCTestCase {
    func testPersonalDataSyncStateMakesEmptyStatesExplicit() {
        XCTAssertEqual(
            PersonalDataSyncState.resolve(
                isSupported: true,
                isAvailable: true,
                isBusy: false,
                hasError: false,
                needsAccess: false,
                isEnabled: false,
                hasPendingChanges: false,
                freshness: nil
            ),
            .off
        )
        XCTAssertEqual(
            PersonalDataSyncState.resolve(
                isSupported: true,
                isAvailable: true,
                isBusy: false,
                hasError: false,
                needsAccess: false,
                isEnabled: true,
                hasPendingChanges: false,
                freshness: nil
            ),
            .waitingForFirstSync
        )
    }

    func testPersonalDataSyncStatePrioritizesActionableConditions() {
        XCTAssertEqual(
            PersonalDataSyncState.resolve(
                isSupported: true,
                isAvailable: true,
                isBusy: true,
                hasError: true,
                needsAccess: true,
                isEnabled: true,
                hasPendingChanges: true,
                freshness: .expired
            ),
            .syncing
        )
        XCTAssertEqual(
            PersonalDataSyncState.resolve(
                isSupported: true,
                isAvailable: true,
                isBusy: false,
                hasError: true,
                needsAccess: true,
                isEnabled: true,
                hasPendingChanges: true,
                freshness: .fresh
            ),
            .needsAccess
        )
        XCTAssertEqual(
            PersonalDataSyncState.resolve(
                isSupported: true,
                isAvailable: true,
                isBusy: false,
                hasError: false,
                needsAccess: false,
                isEnabled: true,
                hasPendingChanges: true,
                freshness: .fresh
            ),
            .changesPending
        )
    }

    func testPersonalDataSyncStateUsesServerFreshness() {
        for (freshness, expected) in [
            (PersonalDataFreshness.fresh, PersonalDataSyncState.fresh),
            (.stale, .stale),
            (.expired, .expired),
        ] {
            XCTAssertEqual(
                PersonalDataSyncState.resolve(
                    isSupported: true,
                    isAvailable: true,
                    isBusy: false,
                    hasError: false,
                    needsAccess: false,
                    isEnabled: true,
                    hasPendingChanges: false,
                    freshness: freshness
                ),
                expected
            )
        }

        XCTAssertEqual(
            PersonalDataSyncState.resolve(
                isSupported: true,
                isAvailable: true,
                isBusy: false,
                hasError: true,
                needsAccess: false,
                isEnabled: true,
                hasPendingChanges: false,
                freshness: .fresh
            ),
            .fresh,
            "A failed refresh must not replace the state of a usable server snapshot."
        )

        XCTAssertEqual(
            PersonalDataSyncState.resolve(
                isSupported: true,
                isAvailable: true,
                isBusy: false,
                hasError: true,
                needsAccess: false,
                isEnabled: true,
                hasPendingChanges: false,
                freshness: nil
            ),
            .failed
        )
    }

    func testHealthKitNoDataErrorIsRecognizedAsAnEmptyResult() {
        let noData = NSError(
            domain: HKError.errorDomain,
            code: HKError.Code.errorNoData.rawValue
        )
        let other = NSError(
            domain: HKError.errorDomain,
            code: HKError.Code.errorAuthorizationDenied.rawValue
        )

        XCTAssertTrue(HealthKitStore.isNoDataError(noData))
        XCTAssertFalse(HealthKitStore.isNoDataError(other))
    }

    func testSevenDayWindowUsesInstanceTimeZone() throws {
        let window = try HealthDateWindow.sevenDays(
            endingAt: date("2026-08-16T00:30:00Z"),
            timeZoneIdentifier: "America/Los_Angeles"
        )

        XCTAssertEqual(window.dateStrings.first, "2026-08-09")
        XCTAssertEqual(window.dateStrings.last, "2026-08-15")
        XCTAssertEqual(window.dateStrings.count, 7)
    }

    func testActivitySummaryPredicateComponentsIncludeGregorianCalendar() throws {
        let components = try XCTUnwrap(
            HealthKitStore.activitySummaryDateComponents(in: window())
        )

        XCTAssertEqual(components.start.calendar?.identifier, .gregorian)
        XCTAssertEqual(components.end.calendar?.identifier, .gregorian)
        XCTAssertEqual(components.start.calendar?.timeZone.identifier, "Asia/Shanghai")
        XCTAssertEqual(components.end.calendar?.timeZone.identifier, "Asia/Shanghai")

        // This API raises NSInvalidArgumentException instead of returning a
        // Swift error when the DateComponents calendar property is absent.
        _ = HKQuery.predicate(
            forActivitySummariesBetweenStart: components.start,
            end: components.end
        )
    }

    func testActivityProducesSevenDaysAndPreservesNullInsteadOfFalseZero() throws {
        let window = try window()
        let snapshot = try HealthSnapshotFactory.makeSnapshot(
            window: window,
            selectedSections: [.activity],
            activityDays: [
                HealthActivityDaySource(
                    date: "2026-08-16",
                    steps: 0,
                    walkingRunningDistanceMeters: nil,
                    rings: nil
                )
            ],
            sleepSamples: [],
            workouts: [],
            publicationSalt: Data("salt".utf8),
            generatedAt: date("2026-08-16T04:00:00Z"),
            serverMaximumTTLSeconds: 3_600
        )

        XCTAssertEqual(snapshot.data.activity?.days.count, 7)
        XCTAssertNil(snapshot.data.activity?.days.first?.steps)
        XCTAssertEqual(snapshot.data.activity?.days.last?.steps, 0)
        XCTAssertNil(snapshot.data.activity?.days.last?.walkingRunningDistanceMeters)
        XCTAssertNil(snapshot.data.sleep)
        XCTAssertNil(snapshot.data.workouts)
        XCTAssertEqual(
            snapshot.expiresAt!.timeIntervalSince(snapshot.generatedAt),
            3_600
        )
    }

    func testSleepChoosesStageRichSourceAndDeduplicatesOverlaps() throws {
        let window = try window()
        let start = date("2026-08-15T14:00:00Z")
        let end = date("2026-08-15T22:00:00Z")
        let samples = [
            HealthSleepSampleSource(
                start: start,
                end: end,
                kind: .asleepUnspecified,
                sourceKey: "source-a"
            ),
            HealthSleepSampleSource(
                start: start,
                end: date("2026-08-15T18:00:00Z"),
                kind: .core,
                sourceKey: "source-b"
            ),
            HealthSleepSampleSource(
                start: date("2026-08-15T18:00:00Z"),
                end: date("2026-08-15T19:00:00Z"),
                kind: .deep,
                sourceKey: "source-b"
            ),
            HealthSleepSampleSource(
                start: date("2026-08-15T19:00:00Z"),
                end: date("2026-08-15T21:00:00Z"),
                kind: .rem,
                sourceKey: "source-b"
            ),
            HealthSleepSampleSource(
                start: start,
                end: end,
                kind: .asleepUnspecified,
                sourceKey: "source-b"
            ),
            HealthSleepSampleSource(
                start: date("2026-08-15T21:00:00Z"),
                end: end,
                kind: .awake,
                sourceKey: "source-b"
            )
        ]

        let snapshot = try HealthSnapshotFactory.makeSnapshot(
            window: window,
            selectedSections: [.sleep],
            activityDays: [],
            sleepSamples: samples,
            workouts: [],
            publicationSalt: Data("salt".utf8),
            generatedAt: date("2026-08-16T04:00:00Z"),
            serverMaximumTTLSeconds: nil
        )

        let night = try XCTUnwrap(snapshot.data.sleep?.nights.first)
        XCTAssertEqual(night.wakeDate, "2026-08-16")
        XCTAssertEqual(night.asleepMinutes, 480)
        XCTAssertEqual(night.coreMinutes, 240)
        XCTAssertEqual(night.deepMinutes, 60)
        XCTAssertEqual(night.remMinutes, 120)
        XCTAssertEqual(night.unspecifiedMinutes, 60)
        XCTAssertEqual(night.awakeMinutes, 60)
    }

    func testWorkoutPublicationIDIsStableOnlyForSameInstanceSalt() throws {
        let source = workoutSource()
        let first = try workoutSnapshot(
            source: source,
            salt: Data("instance-one".utf8)
        )
        let second = try workoutSnapshot(
            source: source,
            salt: Data("instance-one".utf8)
        )
        let otherInstance = try workoutSnapshot(
            source: source,
            salt: Data("instance-two".utf8)
        )

        let firstID = try XCTUnwrap(first.data.workouts?.items.first?.id)
        XCTAssertEqual(firstID.count, 24)
        XCTAssertEqual(firstID, second.data.workouts?.items.first?.id)
        XCTAssertNotEqual(firstID, otherInstance.data.workouts?.items.first?.id)
    }

    func testWorkoutOmitsAllSegmentsWhenPerWorkoutLimitIsExceeded() throws {
        let activities = (0..<65).map { offset in
            HealthWorkoutActivitySource(
                activityType: .running,
                start: date("2026-08-16T01:00:00Z")
                    .addingTimeInterval(Double(offset) * 30),
                end: date("2026-08-16T01:00:00Z")
                    .addingTimeInterval(Double(offset + 1) * 30),
                duration: 30,
                metrics: .empty
            )
        }
        let source = HealthWorkoutSource(
            localIdentifier: "local-workout-id",
            activityType: .running,
            start: date("2026-08-16T01:00:00Z"),
            end: date("2026-08-16T02:00:00Z"),
            duration: 1_950,
            metrics: .empty,
            activities: activities
        )

        let snapshot = try workoutSnapshot(
            source: source,
            salt: Data("salt".utf8)
        )
        let workout = try XCTUnwrap(snapshot.data.workouts?.items.first)
        XCTAssertTrue(workout.segments.isEmpty)
        XCTAssertTrue(workout.segmentsTruncated)
    }

    func testWorkoutDurationDoesNotRoundPastSerializedInterval() throws {
        let start = date("2026-08-16T01:00:00Z").addingTimeInterval(0.1)
        let end = date("2026-08-16T01:00:30Z").addingTimeInterval(0.9)
        let source = HealthWorkoutSource(
            localIdentifier: "fractional-workout-id",
            activityType: .running,
            start: start,
            end: end,
            duration: 30.8,
            metrics: .empty,
            activities: []
        )

        let snapshot = try workoutSnapshot(
            source: source,
            salt: Data("salt".utf8)
        )
        let workout = try XCTUnwrap(snapshot.data.workouts?.items.first)

        XCTAssertEqual(workout.durationSeconds, 30)
        XCTAssertLessThanOrEqual(
            Double(workout.durationSeconds),
            workout.endAt.timeIntervalSince(workout.startAt)
        )
    }

    func testModelReviewsAuthorizationAndUploadsSelectedSnapshot() async throws {
        let suiteName = "HealthSnapshotFactoryTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let health = TestHealthDataStore()
        let preferences = HealthBridgePreferencesStore(
            defaults: defaults,
            keyPrefix: "Health",
            authorizationKey: "Authorization"
        )
        let server = TestHealthServer()
        let model = HealthBridgeModel(
            health: health,
            preferencesStore: preferences
        )

        await model.load(using: server)
        model.toggleSection(.activity)
        await model.requestAccess()
        await model.enableAndSync(using: server)

        XCTAssertEqual(health.requestedSections, [.activity])
        XCTAssertTrue(model.isEnabled)
        XCTAssertEqual(server.snapshots.count, 1)
        XCTAssertEqual(server.snapshots[0].data.activity?.days.count, 7)
        XCTAssertNil(server.snapshots[0].data.sleep)
        XCTAssertNil(server.snapshots[0].data.workouts)

        let restoredModel = HealthBridgeModel(
            health: health,
            preferencesStore: preferences
        )
        await restoredModel.load(using: server)

        XCTAssertEqual(restoredModel.activityDayCount, 7)
        XCTAssertNil(restoredModel.sleepNightCount)
        XCTAssertFalse(restoredModel.hasPendingSelectionChanges)

        restoredModel.toggleSection(.sleep)

        XCTAssertTrue(restoredModel.hasPendingSelectionChanges)
        XCTAssertEqual(restoredModel.activityDayCount, 7)
        XCTAssertNil(restoredModel.sleepNightCount)
    }

    func testRetentionChangeUploadsUnchangedDataAndSurvivesReload() async throws {
        let suite = "HealthRetention.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HealthBridgePreferencesStore(defaults: defaults, keyPrefix: "Health", authorizationKey: "Authorization")
        let health = TestHealthDataStore()
        let server = TestHealthServer()
        server.personalDataMaximumTTLSeconds = 31_536_000
        server.supportsPersonalDataRetention = true
        let model = HealthBridgeModel(health: health, preferencesStore: preferences)
        await model.load(using: server)
        model.toggleSection(.activity)
        await model.requestAccess()
        await model.enableAndSync(using: server)
        model.setRetention(.never)
        XCTAssertTrue(model.hasPendingSelectionChanges)
        await model.foregroundCatchUp(using: server)
        XCTAssertEqual(server.snapshots.count, 2)
        XCTAssertNil(server.snapshots.last?.expiresAt)
        XCTAssertFalse(model.hasPendingSelectionChanges)
        let restored = HealthBridgeModel(health: health, preferencesStore: preferences)
        await restored.load(using: server)
        XCTAssertEqual(restored.retention, .never)
        XCTAssertFalse(restored.hasPendingSelectionChanges)
        restored.setRetention(.sevenDays)
        await restored.foregroundCatchUp(using: server)
        let latest = try XCTUnwrap(server.snapshots.last)
        XCTAssertEqual(latest.expiresAt, latest.generatedAt.addingTimeInterval(7 * 86400))
        server.supportsPersonalDataRetention = false
        restored.setRetention(.never)
        await restored.syncNow(using: server)
        XCTAssertNotNil(restored.errorMessage)
        XCTAssertEqual(server.snapshots.count, 3)
        XCTAssertTrue(restored.hasPendingSelectionChanges)
        server.activeHealthInstanceID = "other-server"
        await restored.load(using: server)
        XCTAssertEqual(restored.retention, .twoDays)
    }

    func testServerSwitchDuringHealthReadDoesNotUploadOrSaveNewServerPreferences() async throws {
        let suite = "HealthSession.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HealthBridgePreferencesStore(defaults: defaults, keyPrefix: "Health", authorizationKey: "Authorization")
        preferences.save(HealthBridgePreferences(instanceID: "other", selectedSections: [.activity], isEnabled: false))
        let before = preferences.preferences(for: "other")
        let health = TestHealthDataStore()
        let server = TestHealthServer()
        let model = HealthBridgeModel(health: health, preferencesStore: preferences)
        await model.load(using: server)
        model.toggleSection(.activity)
        await model.requestAccess()
        let gate = SessionTestGate()
        health.activityGate = gate
        let sync = Task { await model.enableAndSync(using: server) }
        await gate.waitUntilStarted()
        server.activeHealthInstanceID = "other"
        server.revision = UUID()
        await model.load(using: server)
        await gate.release()
        await sync.value
        XCTAssertTrue(server.snapshots.isEmpty)
        XCTAssertFalse(model.isEnabled)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.confirmationMessage)
        XCTAssertEqual(preferences.preferences(for: "other"), before)
    }

    func testReloadingSameServerPreservesHealthSyncInProgress() async throws {
        let suite = "HealthReload.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = HealthBridgePreferencesStore(defaults: defaults, keyPrefix: "Health", authorizationKey: "Authorization")
        let health = TestHealthDataStore()
        let server = TestHealthServer()
        let model = HealthBridgeModel(health: health, preferencesStore: preferences)
        await model.load(using: server)
        model.toggleSection(.activity)
        await model.requestAccess()
        let gate = SessionTestGate()
        health.activityGate = gate
        let sync = Task { await model.enableAndSync(using: server) }
        await gate.waitUntilStarted()
        await model.load(using: server)
        XCTAssertTrue(model.isBusy)
        await gate.release()
        await sync.value
        XCTAssertEqual(server.snapshots.count, 1)
        XCTAssertTrue(model.isEnabled)
        XCTAssertFalse(model.isBusy)
        XCTAssertNil(model.errorMessage)
    }

    private func window() throws -> HealthDateWindow {
        try HealthDateWindow.sevenDays(
            endingAt: date("2026-08-16T04:00:00Z"),
            timeZoneIdentifier: "Asia/Shanghai"
        )
    }

    private func workoutSource() -> HealthWorkoutSource {
        HealthWorkoutSource(
            localIdentifier: "550E8400-E29B-41D4-A716-446655440000",
            activityType: .running,
            start: date("2026-08-16T01:00:00Z"),
            end: date("2026-08-16T02:00:00Z"),
            duration: 3_500,
            metrics: HealthMetricSource(
                activeEnergyKcal: 400.04,
                walkingRunningDistanceMeters: 6_123.45,
                cyclingDistanceMeters: nil,
                swimmingDistanceMeters: nil,
                wheelchairDistanceMeters: nil,
                flightsClimbed: 2,
                swimmingStrokeCount: nil
            ),
            activities: []
        )
    }

    private func workoutSnapshot(
        source: HealthWorkoutSource,
        salt: Data
    ) throws -> HealthSummarySnapshot {
        try HealthSnapshotFactory.makeSnapshot(
            window: window(),
            selectedSections: [.workouts],
            activityDays: [],
            sleepSamples: [],
            workouts: [source],
            publicationSalt: salt,
            generatedAt: date("2026-08-16T04:00:00Z"),
            serverMaximumTTLSeconds: nil
        )
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }
}

@MainActor
private final class TestHealthDataStore: HealthDataAccessing {
    var isAvailable = true
    var requestedSections: Set<HealthSummarySection> = []
    var activityGate: SessionTestGate?

    func requestAuthorization(
        for sections: Set<HealthSummarySection>
    ) async throws {
        requestedSections.formUnion(sections)
    }

    func activityDays(
        in window: HealthDateWindow
    ) async throws -> [HealthActivityDaySource] {
        if let activityGate { await activityGate.pause() }
        return window.dateStrings.map {
            HealthActivityDaySource(
                date: $0,
                steps: 1_000,
                walkingRunningDistanceMeters: 800,
                rings: nil
            )
        }
    }

    func sleepSamples(
        in window: HealthDateWindow
    ) async throws -> [HealthSleepSampleSource] {
        []
    }

    func workouts(
        in window: HealthDateWindow
    ) async throws -> [HealthWorkoutSource] {
        []
    }
}

@MainActor
private final class TestHealthServer: HealthBridgeServing {
    var revision = UUID()
    var connectionSession: CompanionConnectionSession? {
        activeHealthInstanceID.map { CompanionConnectionSession(instanceID: $0, revision: revision) }
    }
    var supportsHealthSummaryPersonalData = true
    var supportsPersonalDataRetention = false
    var personalDataMaximumTTLSeconds: Int? = 48 * 60 * 60
    var activeHealthInstanceID: String? = "instance-1"
    var activeHealthTimeZone: String? = "Asia/Shanghai"
    var snapshots: [HealthSummarySnapshot] = []

    func healthSummaryPersonalDataStatus(session: CompanionConnectionSession) async throws
        -> PersonalDataSourceStatus?
    {
        snapshots.last.map(status)
    }

    func putHealthSummarySnapshot(
        _ snapshot: HealthSummarySnapshot, session: CompanionConnectionSession
    ) async throws -> PersonalDataSourceStatus {
        snapshots.append(snapshot)
        return status(snapshot)
    }

    func deleteHealthSummaryPersonalData(session: CompanionConnectionSession) async throws {
        snapshots = []
    }

    private func status(
        _ snapshot: HealthSummarySnapshot
    ) -> PersonalDataSourceStatus {
        PersonalDataSourceStatus(
            sourceID: .healthSummary,
            state: .fresh,
            generatedAt: snapshot.generatedAt,
            staleAt: snapshot.generatedAt.addingTimeInterval(24 * 60 * 60),
            expiresAt: snapshot.expiresAt
        )
    }
}
