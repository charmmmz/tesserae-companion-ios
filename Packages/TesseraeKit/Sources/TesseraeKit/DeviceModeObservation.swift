import Foundation

/// A last-confirmed observation, not a command or a live reachability signal.
public struct DeviceModeObservation: Codable, Hashable, Sendable {
    public struct Battery: Codable, Hashable, Sendable {
        public let percent: Int
        public let observedAt: Date

        public init(percent: Int, observedAt: Date) {
            self.percent = percent
            self.observedAt = DeviceModeObservation.seconds(observedAt)
        }
    }

    public struct Firmware: Codable, Hashable, Sendable {
        public let version: String
        public let observedAt: Date

        public init(version: String, observedAt: Date) {
            self.version = version
            self.observedAt = DeviceModeObservation.seconds(observedAt)
        }
    }

    public enum Mode: String, Codable, Hashable, Sendable {
        case wifi, bluetooth
    }

    public let mode: Mode
    public let observedAt: Date
    public let source: String
    public let battery: Battery?
    public let firmware: Firmware?

    public init(mode: Mode, observedAt: Date, battery: Battery? = nil, firmware: Firmware? = nil) {
        self.mode = mode
        // Companion's ISO-8601 encoder uses whole seconds.
        self.observedAt = Self.seconds(observedAt)
        self.source = "ios_ble"
        self.battery = battery
        self.firmware = firmware
    }

    private static func seconds(_ date: Date) -> Date {
        Date(timeIntervalSince1970: floor(date.timeIntervalSince1970))
    }
}
