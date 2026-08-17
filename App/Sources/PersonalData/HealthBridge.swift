@preconcurrency import HealthKit
import CryptoKit
import Foundation
import Observation
import TesseraeKit

enum HealthSummarySection: String, Codable, CaseIterable, Hashable, Sendable {
    case activity
    case sleep
    case workouts
}

enum HealthAuthorizationState: Equatable {
    case unavailable
    case reviewRequired
    case reviewed
}

struct HealthDateWindow: Equatable, Sendable {
    let timeZoneIdentifier: String
    let dateStrings: [String]
    let start: Date
    let end: Date

    static func sevenDays(
        endingAt date: Date,
        timeZoneIdentifier: String
    ) throws -> HealthDateWindow {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            throw HealthBridgeError.invalidTimeZone
        }
        let calendar: Calendar = {
            var value = Calendar(identifier: .gregorian)
            value.timeZone = timeZone
            return value
        }()
        let endDay = calendar.startOfDay(for: date)
        guard
            let startDay = calendar.date(byAdding: .day, value: -6, to: endDay),
            let upperBound = calendar.date(byAdding: .day, value: 1, to: endDay)
        else {
            throw HealthBridgeError.invalidTimeZone
        }

        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"

        let dates = (0..<7).compactMap { offset -> String? in
            calendar.date(byAdding: .day, value: offset, to: startDay)
                .map(formatter.string(from:))
        }
        guard dates.count == 7 else {
            throw HealthBridgeError.invalidTimeZone
        }
        return HealthDateWindow(
            timeZoneIdentifier: timeZoneIdentifier,
            dateStrings: dates,
            start: startDay,
            end: upperBound
        )
    }

    func interval(for dateString: String) -> DateInterval? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            return nil
        }
        let calendar: Calendar = {
            var value = Calendar(identifier: .gregorian)
            value.timeZone = timeZone
            return value
        }()
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        guard
            let start = formatter.date(from: dateString),
            let end = calendar.date(byAdding: .day, value: 1, to: start)
        else {
            return nil
        }
        return DateInterval(start: start, end: end)
    }
}

struct HealthActivityRingSource: Equatable, Sendable {
    let moveMode: HealthMoveMode
    let activeEnergyKcal: Double?
    let activeEnergyGoalKcal: Double?
    let moveMinutes: Double?
    let moveGoalMinutes: Double?
    let exerciseMinutes: Double?
    let exerciseGoalMinutes: Double?
    let standHours: Double?
    let standGoalHours: Double?
}

struct HealthActivityDaySource: Equatable, Sendable {
    let date: String
    let steps: Double?
    let walkingRunningDistanceMeters: Double?
    let rings: HealthActivityRingSource?
}

enum HealthSleepSampleKind: Equatable, Sendable {
    case inBed
    case awake
    case core
    case deep
    case rem
    case asleepUnspecified
}

struct HealthSleepSampleSource: Equatable, Sendable {
    let start: Date
    let end: Date
    let kind: HealthSleepSampleKind
    let sourceKey: String
}

struct HealthMetricSource: Equatable, Sendable {
    let activeEnergyKcal: Double?
    let walkingRunningDistanceMeters: Double?
    let cyclingDistanceMeters: Double?
    let swimmingDistanceMeters: Double?
    let wheelchairDistanceMeters: Double?
    let flightsClimbed: Double?
    let swimmingStrokeCount: Double?

    static let empty = HealthMetricSource(
        activeEnergyKcal: nil,
        walkingRunningDistanceMeters: nil,
        cyclingDistanceMeters: nil,
        swimmingDistanceMeters: nil,
        wheelchairDistanceMeters: nil,
        flightsClimbed: nil,
        swimmingStrokeCount: nil
    )
}

struct HealthWorkoutActivitySource: Equatable, Sendable {
    let activityType: HealthWorkoutActivityType
    let start: Date
    let end: Date
    let duration: TimeInterval
    let metrics: HealthMetricSource
}

struct HealthWorkoutSource: Equatable, Sendable {
    let localIdentifier: String
    let activityType: HealthWorkoutActivityType
    let start: Date
    let end: Date
    let duration: TimeInterval
    let metrics: HealthMetricSource
    let activities: [HealthWorkoutActivitySource]
}

@MainActor
protocol HealthDataAccessing: AnyObject {
    var isAvailable: Bool { get }

    func requestAuthorization(for sections: Set<HealthSummarySection>) async throws
    func activityDays(in window: HealthDateWindow) async throws
        -> [HealthActivityDaySource]
    func sleepSamples(in window: HealthDateWindow) async throws
        -> [HealthSleepSampleSource]
    func workouts(in window: HealthDateWindow) async throws
        -> [HealthWorkoutSource]
}

@MainActor
final class HealthKitStore: HealthDataAccessing {
    private let healthStore = HKHealthStore()

    var isAvailable: Bool {
        HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization(
        for sections: Set<HealthSummarySection>
    ) async throws {
        guard isAvailable else { throw HealthBridgeError.healthUnavailable }
        try await healthStore.requestAuthorization(
            toShare: [],
            read: Self.readTypes(for: sections)
        )
    }

    func activityDays(
        in window: HealthDateWindow
    ) async throws -> [HealthActivityDaySource] {
        let summaries = try await activitySummaries(in: window)
        var days: [HealthActivityDaySource] = []
        for dateString in window.dateStrings {
            guard let interval = window.interval(for: dateString) else { continue }
            async let steps = cumulativeSum(
                type: HKQuantityType(.stepCount),
                unit: .count(),
                interval: interval
            )
            async let distance = cumulativeSum(
                type: HKQuantityType(.distanceWalkingRunning),
                unit: .meter(),
                interval: interval
            )
            days.append(
                HealthActivityDaySource(
                    date: dateString,
                    steps: try await steps,
                    walkingRunningDistanceMeters: try await distance,
                    rings: summaries[dateString]
                )
            )
        }
        return days
    }

    func sleepSamples(
        in window: HealthDateWindow
    ) async throws -> [HealthSleepSampleSource] {
        guard let queryStart = Calendar(identifier: .gregorian).date(
            byAdding: .day,
            value: -1,
            to: window.start
        ) else {
            return []
        }
        let type = HKCategoryType(.sleepAnalysis)
        let predicate = HKQuery.predicateForSamples(
            withStart: queryStart,
            end: window.end,
            options: []
        )
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: type,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [
                    NSSortDescriptor(
                        key: HKSampleSortIdentifierStartDate,
                        ascending: true
                    )
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                let values = (samples as? [HKCategorySample] ?? []).compactMap {
                    sample -> HealthSleepSampleSource? in
                    guard
                        sample.endDate > sample.startDate,
                        let kind = Self.sleepKind(for: sample.value)
                    else {
                        return nil
                    }
                    return HealthSleepSampleSource(
                        start: sample.startDate,
                        end: sample.endDate,
                        kind: kind,
                        sourceKey: sample.sourceRevision.source.bundleIdentifier
                    )
                }
                continuation.resume(returning: values)
            }
            healthStore.execute(query)
        }
    }

    func workouts(
        in window: HealthDateWindow
    ) async throws -> [HealthWorkoutSource] {
        let predicate = HKQuery.predicateForSamples(
            withStart: window.start,
            end: window.end,
            options: .strictStartDate
        )
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: HKObjectType.workoutType(),
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [
                    NSSortDescriptor(
                        key: HKSampleSortIdentifierStartDate,
                        ascending: true
                    )
                ]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(
                    returning: (samples as? [HKWorkout] ?? []).compactMap(
                        Self.workoutSource
                    )
                )
            }
            healthStore.execute(query)
        }
    }

    private func activitySummaries(
        in window: HealthDateWindow
    ) async throws -> [String: HealthActivityRingSource] {
        guard
            let timeZone = TimeZone(identifier: window.timeZoneIdentifier),
            let components = Self.activitySummaryDateComponents(in: window)
        else {
            return [:]
        }
        let calendar: Calendar = {
            var value = Calendar(identifier: .gregorian)
            value.timeZone = timeZone
            return value
        }()
        let predicate = HKQuery.predicate(
            forActivitySummariesBetweenStart: components.start,
            end: components.end
        )
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKActivitySummaryQuery(predicate: predicate) {
                _, summaries, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                var values: [String: HealthActivityRingSource] = [:]
                for summary in summaries ?? [] {
                    guard
                        let year = summary.dateComponents(for: calendar).year,
                        let month = summary.dateComponents(for: calendar).month,
                        let day = summary.dateComponents(for: calendar).day
                    else {
                        continue
                    }
                    let key = String(format: "%04d-%02d-%02d", year, month, day)
                    let moveMode: HealthMoveMode = summary.activityMoveMode == .appleMoveTime
                        ? .moveTime
                        : .activeEnergy
                    values[key] = HealthActivityRingSource(
                        moveMode: moveMode,
                        activeEnergyKcal: moveMode == .activeEnergy
                            ? summary.activeEnergyBurned.doubleValue(for: .kilocalorie())
                            : nil,
                        activeEnergyGoalKcal: moveMode == .activeEnergy
                            ? summary.activeEnergyBurnedGoal.doubleValue(
                                for: .kilocalorie()
                            )
                            : nil,
                        moveMinutes: moveMode == .moveTime
                            ? summary.appleMoveTime.doubleValue(for: .minute())
                            : nil,
                        moveGoalMinutes: moveMode == .moveTime
                            ? summary.appleMoveTimeGoal.doubleValue(for: .minute())
                            : nil,
                        exerciseMinutes: summary.appleExerciseTime.doubleValue(
                            for: .minute()
                        ),
                        exerciseGoalMinutes: summary.exerciseTimeGoal?.doubleValue(
                            for: .minute()
                        ),
                        standHours: summary.appleStandHours.doubleValue(for: .count()),
                        standGoalHours: summary.standHoursGoal?.doubleValue(for: .count())
                    )
                }
                continuation.resume(returning: values)
            }
            healthStore.execute(query)
        }
    }

    static func activitySummaryDateComponents(
        in window: HealthDateWindow
    ) -> (start: DateComponents, end: DateComponents)? {
        guard let timeZone = TimeZone(identifier: window.timeZoneIdentifier) else {
            return nil
        }
        let calendar: Calendar = {
            var value = Calendar(identifier: .gregorian)
            value.timeZone = timeZone
            return value
        }()
        let componentSet: Set<Calendar.Component> = [.era, .year, .month, .day]
        var start = calendar.dateComponents(componentSet, from: window.start)
        let endDate = calendar.date(byAdding: .second, value: -1, to: window.end)
            ?? window.end
        var end = calendar.dateComponents(componentSet, from: endDate)

        // HealthKit raises an Objective-C exception (not a catchable Swift
        // error) when either component omits its calendar. Calendar's
        // dateComponents(_:from:) does not populate this property for us.
        start.calendar = calendar
        end.calendar = calendar
        return (start, end)
    }

    private func cumulativeSum(
        type: HKQuantityType,
        unit: HKUnit,
        interval: DateInterval
    ) async throws -> Double? {
        let predicate = HKQuery.predicateForSamples(
            withStart: interval.start,
            end: interval.end,
            options: .strictStartDate
        )
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKStatisticsQuery(
                quantityType: type,
                quantitySamplePredicate: predicate,
                options: .cumulativeSum
            ) { _, statistics, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(
                        returning: statistics?.sumQuantity()?.doubleValue(for: unit)
                    )
                }
            }
            healthStore.execute(query)
        }
    }

    private static func readTypes(
        for sections: Set<HealthSummarySection>
    ) -> Set<HKObjectType> {
        var types: Set<HKObjectType> = []
        if sections.contains(.activity) {
            types.formUnion([
                HKObjectType.activitySummaryType(),
                HKQuantityType(.stepCount),
                HKQuantityType(.distanceWalkingRunning)
            ])
        }
        if sections.contains(.sleep) {
            types.insert(HKCategoryType(.sleepAnalysis))
        }
        if sections.contains(.workouts) {
            types.formUnion([
                HKObjectType.workoutType(),
                HKQuantityType(.activeEnergyBurned),
                HKQuantityType(.distanceWalkingRunning),
                HKQuantityType(.distanceCycling),
                HKQuantityType(.distanceSwimming),
                HKQuantityType(.distanceWheelchair),
                HKQuantityType(.flightsClimbed),
                HKQuantityType(.swimmingStrokeCount)
            ])
        }
        return types
    }

    nonisolated private static func sleepKind(
        for value: Int
    ) -> HealthSleepSampleKind? {
        switch HKCategoryValueSleepAnalysis(rawValue: value) {
        case .inBed: .inBed
        case .awake: .awake
        case .asleepCore: .core
        case .asleepDeep: .deep
        case .asleepREM: .rem
        case .asleepUnspecified: .asleepUnspecified
        case nil: nil
        @unknown default: nil
        }
    }

    nonisolated private static func workoutSource(
        _ workout: HKWorkout
    ) -> HealthWorkoutSource? {
        guard workout.endDate > workout.startDate else { return nil }
        let activities = workout.workoutActivities.compactMap {
            activity -> HealthWorkoutActivitySource? in
            guard let end = activity.endDate, end > activity.startDate else {
                return nil
            }
            return HealthWorkoutActivitySource(
                activityType: normalizedActivityType(
                    activity.workoutConfiguration.activityType
                ),
                start: activity.startDate,
                end: end,
                duration: activity.duration,
                metrics: metrics { activity.statistics(for: $0) }
            )
        }
        return HealthWorkoutSource(
            localIdentifier: workout.uuid.uuidString,
            activityType: normalizedActivityType(workout.workoutActivityType),
            start: workout.startDate,
            end: workout.endDate,
            duration: workout.duration,
            metrics: metrics { workout.statistics(for: $0) },
            activities: activities
        )
    }

    nonisolated private static func metrics(
        statistics: (HKQuantityType) -> HKStatistics?
    ) -> HealthMetricSource {
        func sum(_ identifier: HKQuantityTypeIdentifier, unit: HKUnit) -> Double? {
            statistics(HKQuantityType(identifier))?
                .sumQuantity()?
                .doubleValue(for: unit)
        }
        return HealthMetricSource(
            activeEnergyKcal: sum(.activeEnergyBurned, unit: .kilocalorie()),
            walkingRunningDistanceMeters: sum(.distanceWalkingRunning, unit: .meter()),
            cyclingDistanceMeters: sum(.distanceCycling, unit: .meter()),
            swimmingDistanceMeters: sum(.distanceSwimming, unit: .meter()),
            wheelchairDistanceMeters: sum(.distanceWheelchair, unit: .meter()),
            flightsClimbed: sum(.flightsClimbed, unit: .count()),
            swimmingStrokeCount: sum(.swimmingStrokeCount, unit: .count())
        )
    }

    nonisolated private static func normalizedActivityType(
        _ type: HKWorkoutActivityType
    ) -> HealthWorkoutActivityType {
        switch type {
        case .americanFootball: .americanFootball
        case .archery: .archery
        case .australianFootball: .australianFootball
        case .badminton: .badminton
        case .barre: .barre
        case .baseball: .baseball
        case .basketball: .basketball
        case .bowling: .bowling
        case .boxing: .boxing
        case .cardioDance: .cardioDance
        case .climbing: .climbing
        case .cooldown: .cooldown
        case .coreTraining: .coreTraining
        case .cricket: .cricket
        case .crossCountrySkiing: .crossCountrySkiing
        case .crossTraining: .crossTraining
        case .curling: .curling
        case .cycling: .cycling
        case .dance: .dance
        case .danceInspiredTraining: .danceInspiredTraining
        case .discSports: .discSports
        case .downhillSkiing: .downhillSkiing
        case .elliptical: .elliptical
        case .equestrianSports: .equestrianSports
        case .fencing: .fencing
        case .fishing: .fishing
        case .fitnessGaming: .fitnessGaming
        case .flexibility: .flexibility
        case .functionalStrengthTraining: .functionalStrengthTraining
        case .golf: .golf
        case .gymnastics: .gymnastics
        case .handCycling: .handCycling
        case .handball: .handball
        case .highIntensityIntervalTraining: .highIntensityIntervalTraining
        case .hiking: .hiking
        case .hockey: .hockey
        case .hunting: .hunting
        case .jumpRope: .jumpRope
        case .kickboxing: .kickboxing
        case .lacrosse: .lacrosse
        case .martialArts: .martialArts
        case .mindAndBody: .mindAndBody
        case .mixedCardio: .mixedCardio
        case .mixedMetabolicCardioTraining: .mixedMetabolicCardioTraining
        case .paddleSports: .paddleSports
        case .pickleball: .pickleball
        case .pilates: .pilates
        case .play: .play
        case .preparationAndRecovery: .preparationAndRecovery
        case .racquetball: .racquetball
        case .rowing: .rowing
        case .rugby: .rugby
        case .running: .running
        case .sailing: .sailing
        case .skatingSports: .skatingSports
        case .snowSports: .snowSports
        case .snowboarding: .snowboarding
        case .soccer: .soccer
        case .socialDance: .socialDance
        case .softball: .softball
        case .squash: .squash
        case .stairClimbing: .stairClimbing
        case .stairs: .stairs
        case .stepTraining: .stepTraining
        case .surfingSports: .surfingSports
        case .swimBikeRun: .swimBikeRun
        case .swimming: .swimming
        case .tableTennis: .tableTennis
        case .taiChi: .taiChi
        case .tennis: .tennis
        case .trackAndField: .trackAndField
        case .traditionalStrengthTraining: .traditionalStrengthTraining
        case .transition: .transition
        case .underwaterDiving: .underwaterDiving
        case .volleyball: .volleyball
        case .walking: .walking
        case .waterFitness: .waterFitness
        case .waterPolo: .waterPolo
        case .waterSports: .waterSports
        case .wheelchairRunPace: .wheelchairRunPace
        case .wheelchairWalkPace: .wheelchairWalkPace
        case .wrestling: .wrestling
        case .yoga: .yoga
        case .other: .other
        @unknown default: .other
        }
    }
}

enum HealthSnapshotFactory {
    static let privacyTTLSeconds = 48 * 60 * 60
    static let maximumWorkoutCount = 100
    static let maximumSegmentsPerWorkout = 64
    static let maximumSegmentsPerSnapshot = 256
    private static let sleepEpisodeGap: TimeInterval = 3 * 60 * 60
    private static let minimumPrimarySleep: TimeInterval = 60 * 60
    private static let maximumInterval: TimeInterval = 7 * 24 * 60 * 60

    static func makeSnapshot(
        window: HealthDateWindow,
        selectedSections: Set<HealthSummarySection>,
        activityDays: [HealthActivityDaySource],
        sleepSamples: [HealthSleepSampleSource],
        workouts: [HealthWorkoutSource],
        publicationSalt: Data,
        generatedAt: Date = .now,
        serverMaximumTTLSeconds: Int?
    ) throws -> HealthSummarySnapshot {
        guard !selectedSections.isEmpty else {
            throw HealthBridgeError.sectionRequired
        }
        let ttl = max(
            1,
            min(serverMaximumTTLSeconds ?? privacyTTLSeconds, privacyTTLSeconds)
        )
        let activity = selectedSections.contains(.activity)
            ? HealthActivityData(
                days: normalizedActivityDays(activityDays, window: window)
            )
            : nil
        let sleep = selectedSections.contains(.sleep)
            ? HealthSleepData(
                nights: normalizedSleepNights(sleepSamples, window: window)
            )
            : nil
        let workoutData = selectedSections.contains(.workouts)
            ? normalizedWorkouts(workouts, publicationSalt: publicationSalt)
            : nil

        return HealthSummarySnapshot(
            generatedAt: generatedAt,
            expiresAt: generatedAt.addingTimeInterval(TimeInterval(ttl)),
            data: HealthSummaryData(
                timeZone: window.timeZoneIdentifier,
                windowStartDate: window.dateStrings[0],
                windowEndDate: window.dateStrings[6],
                activity: activity,
                sleep: sleep,
                workouts: workoutData
            )
        )
    }

    private static func normalizedActivityDays(
        _ sourceDays: [HealthActivityDaySource],
        window: HealthDateWindow
    ) -> [HealthActivityDay] {
        let byDate = Dictionary(sourceDays.map { ($0.date, $0) }) { first, _ in
            first
        }
        return window.dateStrings.map { date in
            let source = byDate[date]
            let rings = source?.rings
            return HealthActivityDay(
                date: date,
                steps: boundedInteger(source?.steps, maximum: 1_000_000),
                walkingRunningDistanceMeters: boundedDecimal(
                    source?.walkingRunningDistanceMeters,
                    maximum: 1_000_000
                ),
                moveMode: rings?.moveMode,
                activeEnergyKcal: rings?.moveMode == .activeEnergy
                    ? boundedDecimal(rings?.activeEnergyKcal, maximum: 100_000)
                    : nil,
                activeEnergyGoalKcal: rings?.moveMode == .activeEnergy
                    ? boundedDecimal(rings?.activeEnergyGoalKcal, maximum: 100_000)
                    : nil,
                moveMinutes: rings?.moveMode == .moveTime
                    ? boundedInteger(rings?.moveMinutes, maximum: 1_440)
                    : nil,
                moveGoalMinutes: rings?.moveMode == .moveTime
                    ? boundedInteger(rings?.moveGoalMinutes, maximum: 1_440)
                    : nil,
                exerciseMinutes: boundedInteger(
                    rings?.exerciseMinutes,
                    maximum: 1_440
                ),
                exerciseGoalMinutes: boundedInteger(
                    rings?.exerciseGoalMinutes,
                    maximum: 1_440
                ),
                standHours: boundedInteger(rings?.standHours, maximum: 24),
                standGoalHours: boundedInteger(rings?.standGoalHours, maximum: 24)
            )
        }
    }

    private struct SleepCandidate {
        let sourceKey: String
        let start: Date
        let end: Date
        let inBedMinutes: Int?
        let asleepMinutes: Int
        let awakeMinutes: Int?
        let coreMinutes: Int?
        let deepMinutes: Int?
        let remMinutes: Int?
        let unspecifiedMinutes: Int?
        let specificStageSeconds: TimeInterval
    }

    private static func normalizedSleepNights(
        _ sourceSamples: [HealthSleepSampleSource],
        window: HealthDateWindow
    ) -> [HealthSleepNight] {
        let valid = sourceSamples
            .filter {
                $0.end > $0.start
                    && $0.end.timeIntervalSince($0.start) <= 24 * 60 * 60
            }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                if $0.end != $1.end { return $0.end < $1.end }
                return $0.sourceKey < $1.sourceKey
            }
        let clusters = sleepClusters(valid)
        var primaryByWakeDate: [String: SleepCandidate] = [:]

        for cluster in clusters {
            let candidates = Dictionary(grouping: cluster, by: \.sourceKey)
                .compactMap { sourceKey, samples in
                    sleepCandidate(sourceKey: sourceKey, samples: samples)
                }
            guard let candidate = candidates.sorted(by: preferredSleepCandidate).first,
                  let wakeDate = dateString(
                    candidate.end,
                    timeZoneIdentifier: window.timeZoneIdentifier
                  ),
                  window.dateStrings.contains(wakeDate)
            else {
                continue
            }
            if let existing = primaryByWakeDate[wakeDate] {
                if preferredPrimarySleep(candidate, over: existing) {
                    primaryByWakeDate[wakeDate] = candidate
                }
            } else {
                primaryByWakeDate[wakeDate] = candidate
            }
        }

        return window.dateStrings.compactMap { wakeDate in
            guard let candidate = primaryByWakeDate[wakeDate] else { return nil }
            return HealthSleepNight(
                wakeDate: wakeDate,
                startAt: candidate.start,
                endAt: candidate.end,
                inBedMinutes: candidate.inBedMinutes,
                asleepMinutes: candidate.asleepMinutes,
                awakeMinutes: candidate.awakeMinutes,
                coreMinutes: candidate.coreMinutes,
                deepMinutes: candidate.deepMinutes,
                remMinutes: candidate.remMinutes,
                unspecifiedMinutes: candidate.unspecifiedMinutes
            )
        }
    }

    private static func sleepClusters(
        _ samples: [HealthSleepSampleSource]
    ) -> [[HealthSleepSampleSource]] {
        var clusters: [[HealthSleepSampleSource]] = []
        var current: [HealthSleepSampleSource] = []
        var currentEnd: Date?
        for sample in samples {
            if let lastEnd = currentEnd,
               sample.start.timeIntervalSince(lastEnd) > sleepEpisodeGap
            {
                if !current.isEmpty { clusters.append(current) }
                current = []
                currentEnd = nil
            }
            current.append(sample)
            if currentEnd == nil || sample.end > currentEnd! {
                currentEnd = sample.end
            }
        }
        if !current.isEmpty { clusters.append(current) }
        return clusters
    }

    private static func sleepCandidate(
        sourceKey: String,
        samples: [HealthSleepSampleSource]
    ) -> SleepCandidate? {
        guard
            let start = samples.map(\.start).min(),
            let end = samples.map(\.end).max(),
            end.timeIntervalSince(start) <= 24 * 60 * 60
        else {
            return nil
        }
        let staged = partitionedStageDurations(samples)
        let asleepSeconds = staged.core + staged.deep + staged.rem + staged.unspecified
        guard asleepSeconds >= minimumPrimarySleep else { return nil }
        return SleepCandidate(
            sourceKey: sourceKey,
            start: start,
            end: end,
            inBedMinutes: optionalMinutes(
                unionDuration(samples.filter { $0.kind == .inBed })
            ),
            asleepMinutes: Int((asleepSeconds / 60).rounded()),
            awakeMinutes: optionalMinutes(
                unionDuration(samples.filter { $0.kind == .awake })
            ),
            coreMinutes: optionalMinutes(staged.core),
            deepMinutes: optionalMinutes(staged.deep),
            remMinutes: optionalMinutes(staged.rem),
            unspecifiedMinutes: optionalMinutes(staged.unspecified),
            specificStageSeconds: staged.core + staged.deep + staged.rem
        )
    }

    private static func preferredSleepCandidate(
        _ lhs: SleepCandidate,
        _ rhs: SleepCandidate
    ) -> Bool {
        if lhs.specificStageSeconds != rhs.specificStageSeconds {
            return lhs.specificStageSeconds > rhs.specificStageSeconds
        }
        if lhs.asleepMinutes != rhs.asleepMinutes {
            return lhs.asleepMinutes > rhs.asleepMinutes
        }
        if lhs.end != rhs.end { return lhs.end > rhs.end }
        return lhs.sourceKey < rhs.sourceKey
    }

    private static func preferredPrimarySleep(
        _ lhs: SleepCandidate,
        over rhs: SleepCandidate
    ) -> Bool {
        if lhs.asleepMinutes != rhs.asleepMinutes {
            return lhs.asleepMinutes > rhs.asleepMinutes
        }
        if lhs.end != rhs.end { return lhs.end > rhs.end }
        return lhs.sourceKey < rhs.sourceKey
    }

    private static func partitionedStageDurations(
        _ samples: [HealthSleepSampleSource]
    ) -> (core: TimeInterval, deep: TimeInterval, rem: TimeInterval, unspecified: TimeInterval) {
        let stages = samples.filter {
            switch $0.kind {
            case .core, .deep, .rem, .asleepUnspecified: true
            case .inBed, .awake: false
            }
        }
        let boundaries = Array(Set(stages.flatMap { [$0.start, $0.end] })).sorted()
        var result: (TimeInterval, TimeInterval, TimeInterval, TimeInterval) = (0, 0, 0, 0)
        guard boundaries.count >= 2 else { return result }

        for index in 0..<(boundaries.count - 1) {
            let start = boundaries[index]
            let end = boundaries[index + 1]
            guard end > start else { continue }
            let activeKinds = stages.compactMap { sample -> HealthSleepSampleKind? in
                sample.start < end && sample.end > start ? sample.kind : nil
            }
            let chosen: HealthSleepSampleKind?
            if activeKinds.contains(.core) {
                chosen = .core
            } else if activeKinds.contains(.deep) {
                chosen = .deep
            } else if activeKinds.contains(.rem) {
                chosen = .rem
            } else if activeKinds.contains(.asleepUnspecified) {
                chosen = .asleepUnspecified
            } else {
                chosen = nil
            }
            let duration = end.timeIntervalSince(start)
            switch chosen {
            case .core: result.0 += duration
            case .deep: result.1 += duration
            case .rem: result.2 += duration
            case .asleepUnspecified: result.3 += duration
            case .inBed, .awake, nil: break
            }
        }
        return result
    }

    private static func unionDuration(
        _ samples: [HealthSleepSampleSource]
    ) -> TimeInterval? {
        let intervals = samples
            .map { DateInterval(start: $0.start, end: $0.end) }
            .sorted { $0.start < $1.start }
        guard var current = intervals.first else { return nil }
        var total: TimeInterval = 0
        for interval in intervals.dropFirst() {
            if interval.start <= current.end {
                current = DateInterval(
                    start: current.start,
                    end: max(current.end, interval.end)
                )
            } else {
                total += current.duration
                current = interval
            }
        }
        return total + current.duration
    }

    private static func optionalMinutes(_ duration: TimeInterval?) -> Int? {
        guard let duration else { return nil }
        return min(1_440, max(0, Int((duration / 60).rounded())))
    }

    private static func normalizedWorkouts(
        _ sourceWorkouts: [HealthWorkoutSource],
        publicationSalt: Data
    ) -> HealthWorkoutsData {
        let sorted = sourceWorkouts
            .filter {
                $0.end > $0.start
                    && $0.end.timeIntervalSince($0.start) <= maximumInterval
            }
            .sorted {
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.localIdentifier < $1.localIdentifier
            }
        let retained = Array(sorted.suffix(maximumWorkoutCount))
        var segmentBudget = maximumSegmentsPerSnapshot
        let items = retained.map { source -> HealthWorkout in
            let wallDuration = source.end.timeIntervalSince(source.start)
            let duration = min(
                Int(wallDuration.rounded(.down)),
                max(0, Int(source.duration.rounded()))
            )
            let candidateActivities = source.activities.count > 1
                ? source.activities
                : []
            var segments: [HealthWorkoutSegment] = []
            var segmentsTruncated = false
            if candidateActivities.count > maximumSegmentsPerWorkout
                || candidateActivities.count > segmentBudget
            {
                segmentsTruncated = true
            } else {
                let mapped = candidateActivities.enumerated().compactMap {
                    ordinal, activity -> HealthWorkoutSegment? in
                    guard
                        activity.end > activity.start,
                        activity.end.timeIntervalSince(activity.start) <= maximumInterval
                    else {
                        return nil
                    }
                    let wall = activity.end.timeIntervalSince(activity.start)
                    return HealthWorkoutSegment(
                        ordinal: ordinal,
                        activityType: activity.activityType,
                        startAt: activity.start,
                        endAt: activity.end,
                        durationSeconds: min(
                            Int(wall.rounded(.down)),
                            max(0, Int(activity.duration.rounded()))
                        ),
                        activeEnergyKcal: metricDecimal(
                            activity.metrics.activeEnergyKcal,
                            maximum: 100_000
                        ),
                        walkingRunningDistanceMeters: metricDecimal(
                            activity.metrics.walkingRunningDistanceMeters,
                            maximum: 10_000_000
                        ),
                        cyclingDistanceMeters: metricDecimal(
                            activity.metrics.cyclingDistanceMeters,
                            maximum: 10_000_000
                        ),
                        swimmingDistanceMeters: metricDecimal(
                            activity.metrics.swimmingDistanceMeters,
                            maximum: 10_000_000
                        ),
                        wheelchairDistanceMeters: metricDecimal(
                            activity.metrics.wheelchairDistanceMeters,
                            maximum: 10_000_000
                        ),
                        flightsClimbed: boundedInteger(
                            activity.metrics.flightsClimbed,
                            maximum: 10_000_000
                        ),
                        swimmingStrokeCount: boundedInteger(
                            activity.metrics.swimmingStrokeCount,
                            maximum: 10_000_000
                        )
                    )
                }
                if mapped.count == candidateActivities.count {
                    segments = mapped
                    segmentBudget -= mapped.count
                } else {
                    segmentsTruncated = !candidateActivities.isEmpty
                }
            }
            return HealthWorkout(
                id: publicationID(
                    localIdentifier: source.localIdentifier,
                    salt: publicationSalt
                ),
                activityType: source.activityType,
                startAt: source.start,
                endAt: source.end,
                durationSeconds: duration,
                activeEnergyKcal: metricDecimal(
                    source.metrics.activeEnergyKcal,
                    maximum: 100_000
                ),
                walkingRunningDistanceMeters: metricDecimal(
                    source.metrics.walkingRunningDistanceMeters,
                    maximum: 10_000_000
                ),
                cyclingDistanceMeters: metricDecimal(
                    source.metrics.cyclingDistanceMeters,
                    maximum: 10_000_000
                ),
                swimmingDistanceMeters: metricDecimal(
                    source.metrics.swimmingDistanceMeters,
                    maximum: 10_000_000
                ),
                wheelchairDistanceMeters: metricDecimal(
                    source.metrics.wheelchairDistanceMeters,
                    maximum: 10_000_000
                ),
                flightsClimbed: boundedInteger(
                    source.metrics.flightsClimbed,
                    maximum: 10_000_000
                ),
                swimmingStrokeCount: boundedInteger(
                    source.metrics.swimmingStrokeCount,
                    maximum: 10_000_000
                ),
                segments: segments,
                segmentsTruncated: segmentsTruncated
            )
        }
        return HealthWorkoutsData(
            items: items,
            itemsTruncated: sorted.count > maximumWorkoutCount
        )
    }

    static func publicationID(
        localIdentifier: String,
        salt: Data
    ) -> String {
        let key = SymmetricKey(data: salt)
        let code = HMAC<SHA256>.authenticationCode(
            for: Data(localIdentifier.utf8),
            using: key
        )
        return code.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func boundedInteger(
        _ value: Double?,
        maximum: Int
    ) -> Int? {
        guard let value, value.isFinite, value >= 0, value <= Double(maximum) else {
            return nil
        }
        return Int(value.rounded())
    }

    private static func boundedDecimal(
        _ value: Double?,
        maximum: Double
    ) -> Double? {
        guard let value, value.isFinite, value >= 0, value <= maximum else {
            return nil
        }
        return (value * 10).rounded() / 10
    }

    private static func metricDecimal(
        _ value: Double?,
        maximum: Double
    ) -> Double? {
        boundedDecimal(value, maximum: maximum)
    }

    private static func dateString(
        _ date: Date,
        timeZoneIdentifier: String
    ) -> String? {
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct HealthBridgePreferences: Codable, Equatable {
    let instanceID: String
    var selectedSections: [HealthSummarySection]
    var publicationSaltBase64: String
    var lastSuccessfulContentDigest: String?
    var lastSuccessfulSections: [HealthSummarySection]
    var isEnabled: Bool

    init(
        instanceID: String,
        selectedSections: [HealthSummarySection] = [],
        publicationSaltBase64: String = HealthBridgePreferences.makeSalt()
            .base64EncodedString(),
        lastSuccessfulContentDigest: String? = nil,
        lastSuccessfulSections: [HealthSummarySection] = [],
        isEnabled: Bool = false
    ) {
        self.instanceID = instanceID
        self.selectedSections = selectedSections
        self.publicationSaltBase64 = publicationSaltBase64
        self.lastSuccessfulContentDigest = lastSuccessfulContentDigest
        self.lastSuccessfulSections = lastSuccessfulSections
        self.isEnabled = isEnabled
    }

    var publicationSalt: Data {
        Data(base64Encoded: publicationSaltBase64)
            ?? Self.makeSalt()
    }

    private static func makeSalt() -> Data {
        Data((UUID().uuidString + UUID().uuidString).utf8)
    }
}

@MainActor
final class HealthBridgePreferencesStore {
    private let defaults: UserDefaults
    private let keyPrefix: String
    private let authorizationKey: String

    init(
        defaults: UserDefaults = .standard,
        keyPrefix: String = "TesseraeHealthBridge",
        authorizationKey: String = "TesseraeHealthAuthorizationSections"
    ) {
        self.defaults = defaults
        self.keyPrefix = keyPrefix
        self.authorizationKey = authorizationKey
    }

    func preferences(for instanceID: String) -> HealthBridgePreferences {
        guard
            let data = defaults.data(forKey: key(for: instanceID)),
            let preferences = try? JSONDecoder().decode(
                HealthBridgePreferences.self,
                from: data
            )
        else {
            return HealthBridgePreferences(instanceID: instanceID)
        }
        return preferences
    }

    func save(_ preferences: HealthBridgePreferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key(for: preferences.instanceID))
    }

    func reviewedAuthorizationSections() -> Set<HealthSummarySection> {
        Set(
            defaults.stringArray(forKey: authorizationKey)?
                .compactMap(HealthSummarySection.init(rawValue:))
                ?? []
        )
    }

    func markAuthorizationReviewed(for sections: Set<HealthSummarySection>) {
        let reviewed = reviewedAuthorizationSections().union(sections)
        defaults.set(
            reviewed.map(\.rawValue).sorted(),
            forKey: authorizationKey
        )
    }

    private func key(for instanceID: String) -> String {
        "\(keyPrefix).\(instanceID)"
    }
}

enum HealthBridgeError: Error, LocalizedError {
    case authorizationRequired
    case healthUnavailable
    case invalidTimeZone
    case sectionRequired
    case serverUnsupported
    case unavailable

    var errorDescription: String? {
        switch self {
        case .authorizationRequired:
            String(
                localized: "Review the selected read types in Apple Health before syncing."
            )
        case .healthUnavailable:
            String(localized: "Apple Health data is not available on this device.")
        case .invalidTimeZone:
            String(localized: "The Tesserae server reported an invalid time zone.")
        case .sectionRequired:
            String(localized: "Choose at least one Health summary before syncing.")
        case .serverUnsupported:
            String(
                localized: "This Tesserae server does not advertise Apple Health support."
            )
        case .unavailable:
            String(localized: "A connected Tesserae instance is required.")
        }
    }
}

@MainActor
protocol HealthBridgeServing: AnyObject {
    var supportsHealthSummaryPersonalData: Bool { get }
    var personalDataMaximumTTLSeconds: Int? { get }
    var activeHealthInstanceID: String? { get }
    var activeHealthTimeZone: String? { get }

    func healthSummaryPersonalDataStatus() async throws
        -> PersonalDataSourceStatus?
    func putHealthSummarySnapshot(
        _ snapshot: HealthSummarySnapshot
    ) async throws -> PersonalDataSourceStatus
    func deleteHealthSummaryPersonalData() async throws
}

@MainActor
@Observable
final class HealthBridgeModel {
    private let health: any HealthDataAccessing
    private let preferencesStore: HealthBridgePreferencesStore
    private var instanceID: String?
    private var publicationSalt = Data()
    private var lastSuccessfulContentDigest: String?
    private var lastSuccessfulSections: Set<HealthSummarySection> = []

    var authorizationState: HealthAuthorizationState = .reviewRequired
    var selectedSections: Set<HealthSummarySection> = []
    var isEnabled = false
    var isBusy = false
    var sourceStatus: PersonalDataSourceStatus?
    var activityDayCount: Int?
    var sleepNightCount: Int?
    var workoutCount: Int?
    var confirmationMessage: String?
    var errorMessage: String?

    var hasPendingSelectionChanges: Bool {
        isEnabled && selectedSections != lastSuccessfulSections
    }

    init(
        health: any HealthDataAccessing = HealthKitStore(),
        preferencesStore: HealthBridgePreferencesStore = .init()
    ) {
        self.health = health
        self.preferencesStore = preferencesStore
        updateAuthorizationState()
    }

    func load(using server: any HealthBridgeServing) async {
        errorMessage = nil
        guard let currentInstanceID = instanceIdentifier(from: server) else {
            errorMessage = HealthBridgeError.unavailable.localizedDescription
            return
        }
        instanceID = currentInstanceID
        let preferences = preferencesStore.preferences(for: currentInstanceID)
        selectedSections = Set(preferences.selectedSections)
        publicationSalt = preferences.publicationSalt
        lastSuccessfulContentDigest = preferences.lastSuccessfulContentDigest
        lastSuccessfulSections = Set(preferences.lastSuccessfulSections)
        isEnabled = preferences.isEnabled
        updateAuthorizationState()
        guard server.supportsHealthSummaryPersonalData else { return }
        do {
            sourceStatus = try await server.healthSummaryPersonalDataStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func foregroundCatchUp(using server: any HealthBridgeServing) async {
        updateAuthorizationState()
        guard isEnabled, !selectedSections.isEmpty else { return }
        await synchronize(using: server, enabling: false, forceUpload: false)
    }

    func toggleSection(_ section: HealthSummarySection) {
        if selectedSections.contains(section) {
            selectedSections.remove(section)
        } else {
            selectedSections.insert(section)
        }
        confirmationMessage = nil
        errorMessage = nil
        updateAuthorizationState()
        savePreferences()
    }

    func requestAccess() async {
        guard !selectedSections.isEmpty else {
            errorMessage = HealthBridgeError.sectionRequired.localizedDescription
            return
        }
        isBusy = true
        errorMessage = nil
        confirmationMessage = nil
        defer { isBusy = false }
        do {
            try await health.requestAuthorization(for: selectedSections)
            preferencesStore.markAuthorizationReviewed(for: selectedSections)
            updateAuthorizationState()
            confirmationMessage = String(
                localized: "Apple Health access was reviewed. Tesserae cannot see which individual read types you allowed."
            )
        } catch {
            updateAuthorizationState()
            errorMessage = error.localizedDescription
        }
    }

    func enableAndSync(using server: any HealthBridgeServing) async {
        await synchronize(using: server, enabling: true, forceUpload: true)
    }

    func syncNow(using server: any HealthBridgeServing) async {
        await synchronize(using: server, enabling: false, forceUpload: true)
    }

    func disableAndDelete(using server: any HealthBridgeServing) async {
        guard server.supportsHealthSummaryPersonalData else {
            errorMessage = HealthBridgeError.serverUnsupported.localizedDescription
            return
        }
        isBusy = true
        errorMessage = nil
        confirmationMessage = nil
        defer { isBusy = false }
        do {
            try await server.deleteHealthSummaryPersonalData()
            isEnabled = false
            sourceStatus = nil
            activityDayCount = nil
            sleepNightCount = nil
            workoutCount = nil
            lastSuccessfulContentDigest = nil
            lastSuccessfulSections = []
            savePreferences()
            confirmationMessage = String(
                localized: "Apple Health sync is off and the raw server snapshot was deleted."
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func synchronize(
        using server: any HealthBridgeServing,
        enabling: Bool,
        forceUpload: Bool
    ) async {
        guard !isBusy else { return }
        guard server.supportsHealthSummaryPersonalData else {
            errorMessage = HealthBridgeError.serverUnsupported.localizedDescription
            return
        }
        guard health.isAvailable else {
            errorMessage = HealthBridgeError.healthUnavailable.localizedDescription
            return
        }
        guard !selectedSections.isEmpty else {
            errorMessage = HealthBridgeError.sectionRequired.localizedDescription
            return
        }
        guard authorizationState == .reviewed else {
            errorMessage = HealthBridgeError.authorizationRequired.localizedDescription
            return
        }
        guard let timeZone = server.activeHealthTimeZone else {
            errorMessage = HealthBridgeError.unavailable.localizedDescription
            return
        }

        isBusy = true
        errorMessage = nil
        if forceUpload { confirmationMessage = nil }
        defer { isBusy = false }

        do {
            let window = try HealthDateWindow.sevenDays(
                endingAt: .now,
                timeZoneIdentifier: timeZone
            )
            let activity = selectedSections.contains(.activity)
                ? try await health.activityDays(in: window)
                : []
            let sleep = selectedSections.contains(.sleep)
                ? try await health.sleepSamples(in: window)
                : []
            let workouts = selectedSections.contains(.workouts)
                ? try await health.workouts(in: window)
                : []
            let snapshot = try HealthSnapshotFactory.makeSnapshot(
                window: window,
                selectedSections: selectedSections,
                activityDays: activity,
                sleepSamples: sleep,
                workouts: workouts,
                publicationSalt: publicationSalt,
                serverMaximumTTLSeconds: server.personalDataMaximumTTLSeconds
            )
            let digest = try Self.contentDigest(for: snapshot.data)
            activityDayCount = snapshot.data.activity?.days.count
            sleepNightCount = snapshot.data.sleep?.nights.count
            workoutCount = snapshot.data.workouts?.items.count

            var uploadRequired = forceUpload
                || digest != lastSuccessfulContentDigest
            if !uploadRequired {
                sourceStatus = try await server.healthSummaryPersonalDataStatus()
                uploadRequired = sourceStatus?.state != .fresh
            }
            guard uploadRequired else { return }

            sourceStatus = try await server.putHealthSummarySnapshot(snapshot)
            lastSuccessfulContentDigest = digest
            lastSuccessfulSections = selectedSections
            if enabling { isEnabled = true }
            savePreferences()
            if forceUpload {
                confirmationMessage = uploadConfirmation
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    static func contentDigest(for data: HealthSummaryData) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try encoder.encode(data)
        return SHA256.hash(data: encoded)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private var uploadConfirmation: String {
        var values: [String] = []
        if let activityDayCount {
            values.append(
                String.localizedStringWithFormat(
                    String(localized: "%lld activity days"),
                    activityDayCount
                )
            )
        }
        if let sleepNightCount {
            values.append(
                String.localizedStringWithFormat(
                    String(localized: "%lld sleep nights"),
                    sleepNightCount
                )
            )
        }
        if let workoutCount {
            values.append(
                String.localizedStringWithFormat(
                    String(localized: "%lld workouts"),
                    workoutCount
                )
            )
        }
        return String(localized: "Synced \(values.joined(separator: ", ")).")
    }

    private func updateAuthorizationState() {
        guard health.isAvailable else {
            authorizationState = .unavailable
            return
        }
        let reviewed = preferencesStore.reviewedAuthorizationSections()
        authorizationState = !selectedSections.isEmpty
            && reviewed.isSuperset(of: selectedSections)
            ? .reviewed
            : .reviewRequired
    }

    private func savePreferences() {
        guard let instanceID else { return }
        preferencesStore.save(
            HealthBridgePreferences(
                instanceID: instanceID,
                selectedSections: selectedSections.sorted { $0.rawValue < $1.rawValue },
                publicationSaltBase64: publicationSalt.base64EncodedString(),
                lastSuccessfulContentDigest: lastSuccessfulContentDigest,
                lastSuccessfulSections: lastSuccessfulSections.sorted {
                    $0.rawValue < $1.rawValue
                },
                isEnabled: isEnabled
            )
        )
    }

    private func instanceIdentifier(
        from server: any HealthBridgeServing
    ) -> String? {
        server.activeHealthInstanceID
    }
}

extension AppModel: HealthBridgeServing {}
