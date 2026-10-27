import Foundation
import TesseraeKit

/// UI routing uses established record links and peripheral UUIDs, never names or partial MAC suffixes.
struct ShareDisplayTarget: Identifiable, Equatable {
    let id: String
    let name: String
    let display: DisplaySummary?
    let record: BluetoothDisplayRecord?
    let nearby: NearbyTesseraeDevice?
    var isBluetooth: Bool { record?.mode == .bluetooth || nearby != nil }
    var isAvailable: Bool { !isBluetooth || nearby != nil }
    var panel: PanelProfile? { display?.panel }

    @MainActor
    static func catalog(displays: [DisplaySummary], serverID: String?, records: BluetoothDisplayStore,
                        nearby: [NearbyTesseraeDevice]) -> [Self] {
        var associatedRecords: Set<String> = []
        var matchedPeripherals: Set<UUID> = []
        func device(for record: BluetoothDisplayRecord) -> NearbyTesseraeDevice? {
            guard let id = record.peripheralID,
                  records.record(for: id)?.id == record.id else { return nil }
            return nearby.first { $0.id == id && $0.mode == .photo }
        }
        var targets = displays.map { display in
            let record = records.record(for: display.id, serverID: serverID)
            if let record { associatedRecords.insert(record.id) }
            let nearby = record.flatMap(device)
            if let nearby { matchedPeripherals.insert(nearby.id) }
            return Self(id: display.id, name: display.name, display: display, record: record, nearby: nearby)
        }
        for record in records.records where record.mode == .bluetooth && !associatedRecords.contains(record.id) {
            let nearby = device(for: record)
            if let nearby { matchedPeripherals.insert(nearby.id) }
            targets.append(Self(id: "bluetooth:\(record.id)", name: record.name,
                                display: nil, record: record, nearby: nearby))
        }
        for device in nearby where device.mode == .photo && !matchedPeripherals.contains(device.id) {
            targets.append(Self(id: "nearby:\(device.id.uuidString)", name: device.name,
                                display: nil, record: nil, nearby: device))
        }
        return targets
    }
}
