import Foundation

/// A last-confirmed observation, not a command or a live reachability signal.
public struct DeviceModeObservation: Codable, Hashable, Sendable {
    public enum Mode: String, Codable, Hashable, Sendable {
        case wifi, bluetooth
    }

    public let mode: Mode
    public let observedAt: Date
    public let source: String

    public init(mode: Mode, observedAt: Date) {
        self.mode = mode
        // Companion's ISO-8601 encoder uses whole seconds.
        self.observedAt = Date(timeIntervalSince1970: floor(observedAt.timeIntervalSince1970))
        self.source = "ios_ble"
    }
}
