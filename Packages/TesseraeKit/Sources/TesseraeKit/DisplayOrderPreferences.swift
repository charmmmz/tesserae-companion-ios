import Foundation

@MainActor
public struct DisplayOrderPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load(
        for instanceID: String,
        migratingFrom legacyDefaults: UserDefaults? = nil
    ) -> [String] {
        let key = "display-order." + instanceID
        if let saved = defaults.stringArray(forKey: key) {
            return saved
        }
        guard let legacy = legacyDefaults?.stringArray(forKey: key) else {
            return []
        }
        defaults.set(legacy, forKey: key)
        legacyDefaults?.removeObject(forKey: key)
        return legacy
    }

    public func save(_ displayIDs: [String], for instanceID: String) {
        defaults.set(displayIDs, forKey: "display-order." + instanceID)
    }

    public func orderedDisplays(
        _ displays: [DisplaySummary],
        for instanceID: String
    ) -> [DisplaySummary] {
        Self.orderedDisplays(displays, preferredIDs: load(for: instanceID))
    }

    nonisolated public static func orderedDisplays(
        _ displays: [DisplaySummary],
        preferredIDs: [String]
    ) -> [DisplaySummary] {
        var ranking: [String: Int] = [:]
        for displayID in preferredIDs where ranking[displayID] == nil {
            ranking[displayID] = ranking.count
        }
        return displays.sorted { lhs, rhs in
            switch (ranking[lhs.id], ranking[rhs.id]) {
            case let (lhsRank?, rhsRank?):
                return lhsRank < rhsRank
            case (_?, nil):
                return true
            case (nil, _?):
                return false
            case (nil, nil):
                let nameOrder = lhs.name.localizedStandardCompare(rhs.name)
                if nameOrder != .orderedSame {
                    return nameOrder == .orderedAscending
                }
                return lhs.id < rhs.id
            }
        }
    }
}
