import Foundation

/// Encodes an optional value as an explicit JSON value or `null` rather than
/// omitting its key. Health summary nullable fields are required by contract so
/// widgets can distinguish unreadable data from a real zero.
@propertyWrapper
public struct ExplicitNull<Value>: Codable, Hashable, Sendable
where Value: Codable & Hashable & Sendable {
    public private(set) var wrappedValue: Value?

    public init(wrappedValue: Value?) {
        self.wrappedValue = wrappedValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        wrappedValue = container.decodeNil() ? nil : try container.decode(Value.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let wrappedValue {
            try container.encode(wrappedValue)
        } else {
            try container.encodeNil()
        }
    }
}

public enum HealthMoveMode: String, Codable, Hashable, Sendable {
    case activeEnergy = "active_energy"
    case moveTime = "move_time"
}

public struct HealthActivityDay: Codable, Hashable, Sendable {
    public let date: String
    @ExplicitNull public var steps: Int?
    @ExplicitNull public var walkingRunningDistanceMeters: Double?
    @ExplicitNull public var moveMode: HealthMoveMode?
    @ExplicitNull public var activeEnergyKcal: Double?
    @ExplicitNull public var activeEnergyGoalKcal: Double?
    @ExplicitNull public var moveMinutes: Int?
    @ExplicitNull public var moveGoalMinutes: Int?
    @ExplicitNull public var exerciseMinutes: Int?
    @ExplicitNull public var exerciseGoalMinutes: Int?
    @ExplicitNull public var standHours: Int?
    @ExplicitNull public var standGoalHours: Int?

    public init(
        date: String,
        steps: Int?,
        walkingRunningDistanceMeters: Double?,
        moveMode: HealthMoveMode?,
        activeEnergyKcal: Double?,
        activeEnergyGoalKcal: Double?,
        moveMinutes: Int?,
        moveGoalMinutes: Int?,
        exerciseMinutes: Int?,
        exerciseGoalMinutes: Int?,
        standHours: Int?,
        standGoalHours: Int?
    ) {
        self.date = date
        _steps = ExplicitNull(wrappedValue: steps)
        _walkingRunningDistanceMeters = ExplicitNull(
            wrappedValue: walkingRunningDistanceMeters
        )
        _moveMode = ExplicitNull(wrappedValue: moveMode)
        _activeEnergyKcal = ExplicitNull(wrappedValue: activeEnergyKcal)
        _activeEnergyGoalKcal = ExplicitNull(wrappedValue: activeEnergyGoalKcal)
        _moveMinutes = ExplicitNull(wrappedValue: moveMinutes)
        _moveGoalMinutes = ExplicitNull(wrappedValue: moveGoalMinutes)
        _exerciseMinutes = ExplicitNull(wrappedValue: exerciseMinutes)
        _exerciseGoalMinutes = ExplicitNull(wrappedValue: exerciseGoalMinutes)
        _standHours = ExplicitNull(wrappedValue: standHours)
        _standGoalHours = ExplicitNull(wrappedValue: standGoalHours)
    }
}

public struct HealthActivityData: Codable, Hashable, Sendable {
    public let days: [HealthActivityDay]

    public init(days: [HealthActivityDay]) {
        self.days = days
    }
}

public struct HealthSleepNight: Codable, Hashable, Sendable {
    public let wakeDate: String
    public let startAt: Date
    public let endAt: Date
    @ExplicitNull public var inBedMinutes: Int?
    @ExplicitNull public var asleepMinutes: Int?
    @ExplicitNull public var awakeMinutes: Int?
    @ExplicitNull public var coreMinutes: Int?
    @ExplicitNull public var deepMinutes: Int?
    @ExplicitNull public var remMinutes: Int?
    @ExplicitNull public var unspecifiedMinutes: Int?

    public init(
        wakeDate: String,
        startAt: Date,
        endAt: Date,
        inBedMinutes: Int?,
        asleepMinutes: Int?,
        awakeMinutes: Int?,
        coreMinutes: Int?,
        deepMinutes: Int?,
        remMinutes: Int?,
        unspecifiedMinutes: Int?
    ) {
        self.wakeDate = wakeDate
        self.startAt = startAt
        self.endAt = endAt
        _inBedMinutes = ExplicitNull(wrappedValue: inBedMinutes)
        _asleepMinutes = ExplicitNull(wrappedValue: asleepMinutes)
        _awakeMinutes = ExplicitNull(wrappedValue: awakeMinutes)
        _coreMinutes = ExplicitNull(wrappedValue: coreMinutes)
        _deepMinutes = ExplicitNull(wrappedValue: deepMinutes)
        _remMinutes = ExplicitNull(wrappedValue: remMinutes)
        _unspecifiedMinutes = ExplicitNull(wrappedValue: unspecifiedMinutes)
    }
}

public struct HealthSleepData: Codable, Hashable, Sendable {
    public let nights: [HealthSleepNight]

    public init(nights: [HealthSleepNight]) {
        self.nights = nights
    }
}

public enum HealthWorkoutActivityType: String, Codable, CaseIterable, Hashable, Sendable {
    case americanFootball = "american_football"
    case archery
    case australianFootball = "australian_football"
    case badminton
    case barre
    case baseball
    case basketball
    case bowling
    case boxing
    case cardioDance = "cardio_dance"
    case climbing
    case cooldown
    case coreTraining = "core_training"
    case cricket
    case crossCountrySkiing = "cross_country_skiing"
    case crossTraining = "cross_training"
    case curling
    case cycling
    case dance
    case danceInspiredTraining = "dance_inspired_training"
    case discSports = "disc_sports"
    case downhillSkiing = "downhill_skiing"
    case elliptical
    case equestrianSports = "equestrian_sports"
    case fencing
    case fishing
    case fitnessGaming = "fitness_gaming"
    case flexibility
    case functionalStrengthTraining = "functional_strength_training"
    case golf
    case gymnastics
    case handCycling = "hand_cycling"
    case handball
    case highIntensityIntervalTraining = "high_intensity_interval_training"
    case hiking
    case hockey
    case hunting
    case jumpRope = "jump_rope"
    case kickboxing
    case lacrosse
    case martialArts = "martial_arts"
    case mindAndBody = "mind_and_body"
    case mixedCardio = "mixed_cardio"
    case mixedMetabolicCardioTraining = "mixed_metabolic_cardio_training"
    case other
    case paddleSports = "paddle_sports"
    case pickleball
    case pilates
    case play
    case preparationAndRecovery = "preparation_and_recovery"
    case racquetball
    case rowing
    case rugby
    case running
    case sailing
    case skatingSports = "skating_sports"
    case snowSports = "snow_sports"
    case snowboarding
    case soccer
    case socialDance = "social_dance"
    case softball
    case squash
    case stairClimbing = "stair_climbing"
    case stairs
    case stepTraining = "step_training"
    case surfingSports = "surfing_sports"
    case swimBikeRun = "swim_bike_run"
    case swimming
    case tableTennis = "table_tennis"
    case taiChi = "tai_chi"
    case tennis
    case trackAndField = "track_and_field"
    case traditionalStrengthTraining = "traditional_strength_training"
    case transition
    case underwaterDiving = "underwater_diving"
    case volleyball
    case walking
    case waterFitness = "water_fitness"
    case waterPolo = "water_polo"
    case waterSports = "water_sports"
    case wheelchairRunPace = "wheelchair_run_pace"
    case wheelchairWalkPace = "wheelchair_walk_pace"
    case wrestling
    case yoga
}

public struct HealthWorkoutSegment: Codable, Hashable, Sendable {
    public let ordinal: Int
    public let activityType: HealthWorkoutActivityType
    public let startAt: Date
    public let endAt: Date
    public let durationSeconds: Int
    @ExplicitNull public var activeEnergyKcal: Double?
    @ExplicitNull public var walkingRunningDistanceMeters: Double?
    @ExplicitNull public var cyclingDistanceMeters: Double?
    @ExplicitNull public var swimmingDistanceMeters: Double?
    @ExplicitNull public var wheelchairDistanceMeters: Double?
    @ExplicitNull public var flightsClimbed: Int?
    @ExplicitNull public var swimmingStrokeCount: Int?

    public init(
        ordinal: Int,
        activityType: HealthWorkoutActivityType,
        startAt: Date,
        endAt: Date,
        durationSeconds: Int,
        activeEnergyKcal: Double?,
        walkingRunningDistanceMeters: Double?,
        cyclingDistanceMeters: Double?,
        swimmingDistanceMeters: Double?,
        wheelchairDistanceMeters: Double?,
        flightsClimbed: Int?,
        swimmingStrokeCount: Int?
    ) {
        self.ordinal = ordinal
        self.activityType = activityType
        self.startAt = startAt
        self.endAt = endAt
        self.durationSeconds = durationSeconds
        _activeEnergyKcal = ExplicitNull(wrappedValue: activeEnergyKcal)
        _walkingRunningDistanceMeters = ExplicitNull(
            wrappedValue: walkingRunningDistanceMeters
        )
        _cyclingDistanceMeters = ExplicitNull(wrappedValue: cyclingDistanceMeters)
        _swimmingDistanceMeters = ExplicitNull(wrappedValue: swimmingDistanceMeters)
        _wheelchairDistanceMeters = ExplicitNull(wrappedValue: wheelchairDistanceMeters)
        _flightsClimbed = ExplicitNull(wrappedValue: flightsClimbed)
        _swimmingStrokeCount = ExplicitNull(wrappedValue: swimmingStrokeCount)
    }
}

public struct HealthWorkout: Codable, Identifiable, Hashable, Sendable {
    public let id: String
    public let activityType: HealthWorkoutActivityType
    public let startAt: Date
    public let endAt: Date
    public let durationSeconds: Int
    @ExplicitNull public var activeEnergyKcal: Double?
    @ExplicitNull public var walkingRunningDistanceMeters: Double?
    @ExplicitNull public var cyclingDistanceMeters: Double?
    @ExplicitNull public var swimmingDistanceMeters: Double?
    @ExplicitNull public var wheelchairDistanceMeters: Double?
    @ExplicitNull public var flightsClimbed: Int?
    @ExplicitNull public var swimmingStrokeCount: Int?
    public let segments: [HealthWorkoutSegment]
    public let segmentsTruncated: Bool

    public init(
        id: String,
        activityType: HealthWorkoutActivityType,
        startAt: Date,
        endAt: Date,
        durationSeconds: Int,
        activeEnergyKcal: Double?,
        walkingRunningDistanceMeters: Double?,
        cyclingDistanceMeters: Double?,
        swimmingDistanceMeters: Double?,
        wheelchairDistanceMeters: Double?,
        flightsClimbed: Int?,
        swimmingStrokeCount: Int?,
        segments: [HealthWorkoutSegment],
        segmentsTruncated: Bool
    ) {
        self.id = id
        self.activityType = activityType
        self.startAt = startAt
        self.endAt = endAt
        self.durationSeconds = durationSeconds
        _activeEnergyKcal = ExplicitNull(wrappedValue: activeEnergyKcal)
        _walkingRunningDistanceMeters = ExplicitNull(
            wrappedValue: walkingRunningDistanceMeters
        )
        _cyclingDistanceMeters = ExplicitNull(wrappedValue: cyclingDistanceMeters)
        _swimmingDistanceMeters = ExplicitNull(wrappedValue: swimmingDistanceMeters)
        _wheelchairDistanceMeters = ExplicitNull(wrappedValue: wheelchairDistanceMeters)
        _flightsClimbed = ExplicitNull(wrappedValue: flightsClimbed)
        _swimmingStrokeCount = ExplicitNull(wrappedValue: swimmingStrokeCount)
        self.segments = segments
        self.segmentsTruncated = segmentsTruncated
    }
}

public struct HealthWorkoutsData: Codable, Hashable, Sendable {
    public let items: [HealthWorkout]
    public let itemsTruncated: Bool

    public init(items: [HealthWorkout], itemsTruncated: Bool) {
        self.items = items
        self.itemsTruncated = itemsTruncated
    }
}

public struct HealthSummaryData: Codable, Hashable, Sendable {
    public let timeZone: String
    public let windowStartDate: String
    public let windowEndDate: String
    @ExplicitNull public var activity: HealthActivityData?
    @ExplicitNull public var sleep: HealthSleepData?
    @ExplicitNull public var workouts: HealthWorkoutsData?

    public init(
        timeZone: String,
        windowStartDate: String,
        windowEndDate: String,
        activity: HealthActivityData?,
        sleep: HealthSleepData?,
        workouts: HealthWorkoutsData?
    ) {
        self.timeZone = timeZone
        self.windowStartDate = windowStartDate
        self.windowEndDate = windowEndDate
        _activity = ExplicitNull(wrappedValue: activity)
        _sleep = ExplicitNull(wrappedValue: sleep)
        _workouts = ExplicitNull(wrappedValue: workouts)
    }
}

public struct HealthSummarySnapshot: Codable, Hashable, Sendable {
    public let version: PersonalDataSnapshotVersion
    public let sourceID: PersonalDataSourceID
    public let generatedAt: Date
    public let expiresAt: Date
    public let data: HealthSummaryData

    public init(
        version: PersonalDataSnapshotVersion = .v1,
        sourceID: PersonalDataSourceID = .healthSummary,
        generatedAt: Date,
        expiresAt: Date,
        data: HealthSummaryData
    ) {
        self.version = version
        self.sourceID = sourceID
        self.generatedAt = generatedAt
        self.expiresAt = expiresAt
        self.data = data
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case sourceID = "sourceId"
        case generatedAt
        case expiresAt
        case data
    }
}
