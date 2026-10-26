import Foundation
import Observation
import CryptoKit
import TesseraeKit

struct BluetoothDisplayRecord: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    var observedServerIDs: Set<String> = []
    var hardwareMAC: String?
    var hardwareKind: String?
    var peripheralID: UUID?
    var mode: BLEScreenMode?
    var modeConfirmedAt: Date?
    var modeChangedAt: Date?
    var batteryMillivolts: Int?
    var batteryRecordedAt: Date?
    var batteryPercent: Int?
    var batteryPercentRecordedAt: Date?
    var previewPNG: Data?
    var photoReceivedAt: Date?

    var photoSupersededByWiFi: Bool {
        guard mode == .wifi else { return false }
        guard let photoReceivedAt, let confirmedAt = modeConfirmedAt ?? modeChangedAt else { return true }
        return confirmedAt >= photoReceivedAt
    }
}

struct DisplayServerRecord: Codable, Equatable {
    // Only a lookup of a locally known BLE identity may populate this field.
    // The different coding key deliberately ignores legacy server-enumerated MACs.
    var associationMAC: String?
    var batteryPercent: Int?
    var batteryRecordedAt: Date?
    var lastSeenAt: Date?
    var previewToken: String?
    var previewChangedAt: Date?
}

struct BluetoothModeReport: Codable, Hashable {
    let displayID: String
    let bluetoothID: String
    let observation: DeviceModeObservation
}

/// Local evidence only. BLE advertisements, keys and server silence never establish a mode.
/// Images retain the original colours and sent crop, saved only after photo_received.
@MainActor @Observable
final class BluetoothDisplayStore {
    private struct Snapshot: Codable {
        var records: [String: BluetoothDisplayRecord] = [:]
        var links: [String: [String: String]] = [:]
        var servers: [String: [String: DisplayServerRecord]] = [:]
        var reportedModes: [String: [String: BluetoothModeReport]]?
    }

    private var snapshot = Snapshot()
    private let fileURL: URL?
    private let receiptDirectoryURL: URL?
    private let isReadOnly: Bool
    private var hasPersistedSnapshot = false
    var activeServerID: String?
    private(set) var storageError: String?

    static var defaultFileURL: URL {
        URL.applicationSupportDirectory.appending(path: "BluetoothDisplays/records.plist")
    }

    static var sharedReceiptDirectoryURL: URL? {
        guard let group = Bundle.main.object(forInfoDictionaryKey: "TesseraeAppGroupIdentifier") as? String else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?
            .appending(path: "BluetoothShareReceipts", directoryHint: .isDirectory)
    }

    static var sharedInventoryURL: URL? {
        sharedReceiptDirectoryURL?.deletingLastPathComponent().appending(path: "BluetoothDisplays.plist")
    }

    init(fileURL: URL? = BluetoothDisplayStore.defaultFileURL, receiptDirectoryURL: URL? = nil,
         isReadOnly: Bool = false) {
        self.fileURL = fileURL
        self.receiptDirectoryURL = receiptDirectoryURL
        self.isReadOnly = isReadOnly
        guard let fileURL, FileManager.default.fileExists(atPath: fileURL.path) else { return }
        do {
            snapshot = try PropertyListDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
            hasPersistedSnapshot = true
            let linksChanged = discardConflictingLinks()
            // Migrate records saved by versions that waited for a changed server image.
            let previewsChanged = discardSupersededPreviews()
            if linksChanged || previewsChanged { persist() }
            publishSharedInventory()
        } catch {
            storageError = String(localized: "Bluetooth records could not be read.")
        }
    }

    var records: [BluetoothDisplayRecord] { snapshot.records.values.sorted { $0.id < $1.id } }

    /// The durable local records are the outbox. Only resolved identities can be reported.
    func pendingModeReports(displayIDs: [String], serverID: String?) -> [BluetoothModeReport] {
        guard !isReadOnly, hasPersistedSnapshot, let serverID else { return [] }
        return displayIDs.sorted().compactMap { displayID in
            guard let record = record(for: displayID, serverID: serverID),
                  let mode = record.mode, let date = record.modeConfirmedAt,
                  let reportedMode = DeviceModeObservation.Mode(rawValue: mode.rawValue) else { return nil }
            let report = BluetoothModeReport(displayID: displayID, bluetoothID: record.id,
                observation: DeviceModeObservation(mode: reportedMode, observedAt: date))
            return snapshot.reportedModes?[serverID]?[displayID] == report ? nil : report
        }
    }

    func markModeReported(_ report: BluetoothModeReport, serverID: String) {
        var reports = snapshot.reportedModes ?? [:]
        reports[serverID, default: [:]][report.displayID] = report
        snapshot.reportedModes = reports
        persist()
    }

    func record(for peripheralID: UUID) -> BluetoothDisplayRecord? {
        let matches = records.filter { $0.peripheralID == peripheralID }
        return matches.count == 1 ? matches.first : nil
    }

    /// The app publishes metadata only. The extension reads it without overwriting inventory or previews.
    func publishSharedInventory(to url: URL? = BluetoothDisplayStore.sharedInventoryURL) {
        guard !isReadOnly, fileURL == Self.defaultFileURL, let url else { return }
        do {
            var metadata = snapshot
            for id in metadata.records.keys { metadata.records[id]?.previewPNG = nil }
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try PropertyListEncoder().encode(metadata).write(to: url,
                options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            storageError = String(localized: "Bluetooth devices could not be shared with the Share Sheet.")
        }
    }

    /// A cosmetic hint only; a partial broadcast suffix never establishes identity or mode.
    func hardwareHint(code: UInt8, suffix: String) -> BLESetupHardware? {
        guard suffix.utf8.count == 6 else { return nil }
        let matches = records.filter {
            hardwareMAC(for: $0)?.replacingOccurrences(of: ":", with: "").hasSuffix(suffix.lowercased()) == true
        }
        guard matches.count == 1, let match = matches.first,
              let kind = match.hardwareKind ?? (DeviceHardwareIdentity.picPakMAC(bluetoothID: match.id) == nil ? nil : "picpak_4_2")
        else { return nil }
        let hardware = BLESetupHardware.resolve(code: code, model: kind)
        if case .unknown = hardware { return nil }
        return hardware
    }

    private func hardwareMAC(for record: BluetoothDisplayRecord) -> String? {
        record.hardwareMAC ?? DeviceHardwareIdentity.picPakMAC(bluetoothID: record.id)
    }

    func record(for displayID: String, serverID: String?) -> BluetoothDisplayRecord? {
        guard let serverID else { return nil }
        if let linkedID = snapshot.links[serverID]?[displayID] {
            return snapshot.records[linkedID] // Empty ID explicitly disables automatic association.
        }
        let serverMAC = snapshot.servers[serverID]?[displayID]?.associationMAC
        if let exact = snapshot.records[displayID], exact.observedServerIDs.contains(serverID),
           snapshot.links[serverID]?.contains(where: { $0.key != displayID && $0.value == exact.id }) != true {
            let bluetoothMAC = exact.hardwareMAC ?? DeviceHardwareIdentity.picPakMAC(bluetoothID: exact.id)
            // Native firmware already uses its canonical server ID over BLE.
            // Preserve that path unless complete hardware identities conflict.
            if serverMAC == nil || bluetoothMAC == nil || serverMAC == bluetoothMAC { return exact }
        }
        if let mac = serverMAC {
            // Refuse ambiguous inventories or competing BLE identities, even if names agree.
            guard snapshot.servers[serverID]?.values.filter({ $0.associationMAC == mac }).count == 1 else { return nil }
            let matches = snapshot.records.values.filter {
                ($0.hardwareMAC ?? DeviceHardwareIdentity.picPakMAC(bluetoothID: $0.id)) == mac
            }
            guard matches.count == 1, let match = matches.first,
                  snapshot.links[serverID]?.contains(where: { $0.key != displayID && $0.value == match.id }) != true
            else { return nil }
            return match
        }
        return nil
    }

    func link(_ bluetoothID: String?, to displayID: String, serverID: String) {
        if let bluetoothID, snapshot.records[bluetoothID] == nil { return }
        if let bluetoothID, let record = snapshot.records[bluetoothID],
           let mac = snapshot.servers[serverID]?[displayID]?.associationMAC,
           let recordedMAC = hardwareMAC(for: record), mac != recordedMAC { return }
        var links = snapshot.links[serverID] ?? [:]
        if let bluetoothID {
            for key in Array(links.keys) where links[key] == bluetoothID { links[key] = "" }
            // Also suppress an automatic exact-ID association to a different display.
            if bluetoothID != displayID { links[bluetoothID] = "" }
        }
        links[displayID] = bluetoothID ?? ""
        snapshot.links[serverID] = links
        persist()
    }

    func observe(deviceID: String, name: String, mode: BLEScreenMode?, batteryMillivolts: Int?,
                 batteryPercent: Int? = nil, hardwareMAC: String? = nil, hardwareKind: String? = nil,
                 peripheralID: UUID? = nil,
                 at date: Date = Date()) {
        var record = snapshot.records[deviceID] ?? BluetoothDisplayRecord(id: deviceID, name: name)
        record.name = name
        if let hardwareKind { record.hardwareKind = hardwareKind }
        if let peripheralID { record.peripheralID = peripheralID }
        if let mac = DeviceHardwareIdentity.normalizedMAC(hardwareMAC)
            ?? DeviceHardwareIdentity.picPakMAC(bluetoothID: deviceID) {
            record.hardwareMAC = mac
        }
        if let activeServerID { record.observedServerIDs.insert(activeServerID) }
        if let mode {
            if record.mode != mode || record.modeChangedAt == nil {
                record.modeChangedAt = date
            }
            record.modeConfirmedAt = date
            record.mode = mode
            if mode == .wifi {
                // Confirmed Wi-Fi selects server previews even when its image is unchanged.
                record.previewPNG = nil
                record.photoReceivedAt = nil
            }
        }
        if let batteryMillivolts, (2500...5000).contains(batteryMillivolts),
           record.batteryRecordedAt.map({ date >= $0 }) ?? true {
            record.batteryMillivolts = batteryMillivolts
            record.batteryRecordedAt = date
        }
        if let batteryPercent, (0...100).contains(batteryPercent),
           record.batteryPercentRecordedAt.map({ date >= $0 }) ?? true {
            record.batteryPercent = batteryPercent
            record.batteryPercentRecordedAt = date
        }
        snapshot.records[deviceID] = record
        discardConflictingLinks()
        persist()
    }

    private func discardSupersededPreviews() -> Bool {
        var changed = false
        for id in Array(snapshot.records.keys) {
            guard let record = snapshot.records[id], record.previewPNG != nil,
                  record.photoSupersededByWiFi else { continue }
            snapshot.records[id]?.previewPNG = nil
            snapshot.records[id]?.photoReceivedAt = nil
            changed = true
        }
        return changed
    }

    func receivedPhoto(deviceID: String, previewPNG: Data, at date: Date = Date()) {
        guard !previewPNG.isEmpty, var record = snapshot.records[deviceID] else { return }
        record.previewPNG = previewPNG
        record.photoReceivedAt = date
        snapshot.records[deviceID] = record
        persist()
        // Append an immutable receipt; an extension must never overwrite the app's inventory.
        if let receiptDirectoryURL {
            do {
                try FileManager.default.createDirectory(at: receiptDirectoryURL, withIntermediateDirectories: true)
                let data = try PropertyListEncoder().encode(record)
                try data.write(to: receiptDirectoryURL.appending(path: UUID().uuidString + ".plist"),
                               options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            } catch {
                storageError = String(localized: "Photo sent, but its preview could not be saved for the app.")
            }
        }
    }

    /// Called by the containing app on foreground. Observation times protect newer local evidence.
    func importSharedPhotoReceipts(from directory: URL? = BluetoothDisplayStore.sharedReceiptDirectoryURL) {
        guard fileURL != nil, let directory,
              let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        else { return }
        let receipts = files.compactMap { file -> (URL, BluetoothDisplayRecord)? in
            guard file.pathExtension == "plist", let data = try? Data(contentsOf: file),
                  let record = try? PropertyListDecoder().decode(BluetoothDisplayRecord.self, from: data),
                  record.photoReceivedAt != nil, record.previewPNG?.isEmpty == false else { return nil }
            return (file, record)
        }.sorted { ($0.1.photoReceivedAt ?? .distantPast) < ($1.1.photoReceivedAt ?? .distantPast) }
        for (file, incoming) in receipts {
            let current = snapshot.records[incoming.id]
            let incomingDate = incoming.photoReceivedAt ?? .distantPast
            if (current?.modeConfirmedAt ?? .distantPast) <= incomingDate,
               (current?.photoReceivedAt ?? .distantPast) <= incomingDate {
                var merged = incoming
                merged.observedServerIDs.formUnion(current?.observedServerIDs ?? [])
                if (current?.batteryRecordedAt ?? .distantPast) > (incoming.batteryRecordedAt ?? .distantPast) {
                    merged.batteryMillivolts = current?.batteryMillivolts
                    merged.batteryRecordedAt = current?.batteryRecordedAt
                }
                if (current?.batteryPercentRecordedAt ?? .distantPast) > (incoming.batteryPercentRecordedAt ?? .distantPast) {
                    merged.batteryPercent = current?.batteryPercent
                    merged.batteryPercentRecordedAt = current?.batteryPercentRecordedAt
                }
                snapshot.records[incoming.id] = merged
                persist()
                guard storageError == nil else { continue }
            }
            try? FileManager.default.removeItem(at: file)
        }
    }

    func remove(deviceID: String) {
        snapshot.records.removeValue(forKey: deviceID)
        for serverID in Array(snapshot.links.keys) {
            snapshot.links[serverID] = snapshot.links[serverID]?.filter { $0.value != deviceID }
        }
        persist()
    }

    func serverRecord(displayID: String, serverID: String?) -> DisplayServerRecord? {
        serverID.flatMap { snapshot.servers[$0]?[displayID] }
    }

    var knownHardwareMACs: [String] {
        Array(Set(records.compactMap { hardwareMAC(for: $0) })).sorted()
    }

    /// Matching IDs contain no new hardware identity: each MAC came from our BLE records.
    func observeMACMatches(_ matches: [String: String], serverID: String) {
        var entries = snapshot.servers[serverID] ?? [:]
        for id in entries.keys { entries[id]?.associationMAC = nil }
        let known = Set(knownHardwareMACs)
        let grouped = Dictionary(grouping: matches.filter { known.contains($0.key) }, by: { $0.value })
        for (id, candidates) in grouped where candidates.count == 1 && entries[id] != nil {
            entries[id]?.associationMAC = candidates.first?.key
        }
        snapshot.servers[serverID] = entries
        discardConflictingLinks()
        persist()
    }

    func observeServer(displays: [DisplaySummary], previews: [String: PreviewImageState], serverID: String?, at date: Date = Date()) {
        guard let serverID else { return }
        var entries = snapshot.servers[serverID] ?? [:]
        let currentIDs = Set(displays.map(\.id))
        for id in Array(entries.keys) where !currentIDs.contains(id) {
            entries[id]?.associationMAC = nil
        }
        for display in displays {
            var entry = entries[display.id] ?? DisplayServerRecord()
            // Unknown sample times stay unknown. Poll time is not measurement time.
            let acceptsBattery = display.lastSeenAt.map { incoming in
                entry.batteryRecordedAt.map { incoming >= $0 } ?? true
            } ?? (entry.batteryRecordedAt == nil)
            if let percent = display.batteryPercent, (0...100).contains(percent), acceptsBattery {
                entry.batteryPercent = percent
                entry.batteryRecordedAt = display.lastSeenAt
            }
            // Restored or incomplete server snapshots must not erase newer evidence.
            if let seenAt = display.lastSeenAt, entry.lastSeenAt.map({ seenAt > $0 }) ?? true {
                entry.lastSeenAt = seenAt
            }
            if let preview = previews[display.id], preview.phase == .ready, let data = preview.data {
                let token = preview.eTag ?? SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                if entry.previewToken != token {
                    // The first known server image is a baseline, not proof of a new frame.
                    entry.previewChangedAt = entry.previewToken == nil ? nil : date
                    entry.previewToken = token
                }
            }
            entries[display.id] = entry
        }
        let serverChanged = snapshot.servers[serverID] != entries
        snapshot.servers[serverID] = entries
        let linksChanged = discardConflictingLinks()
        var previewsChanged = false
        for display in displays {
            guard var record = record(for: display.id, serverID: serverID), record.previewPNG != nil,
                  !showsBluetoothPreview(record, displayID: display.id, serverID: serverID) else { continue }
            record.previewPNG = nil
            record.photoReceivedAt = nil
            snapshot.records[record.id] = record
            previewsChanged = true
        }
        if serverChanged || linksChanged || previewsChanged { persist() }
    }

    @discardableResult
    private func discardConflictingLinks() -> Bool {
        var changed = false
        for serverID in Array(snapshot.links.keys) {
            for (displayID, bluetoothID) in snapshot.links[serverID] ?? [:] where !bluetoothID.isEmpty {
                let record = snapshot.records[bluetoothID]
                let mac = snapshot.servers[serverID]?[displayID]?.associationMAC
                let recordedMAC = record.flatMap { hardwareMAC(for: $0) }
                if record == nil || (mac != nil && recordedMAC != nil && mac != recordedMAC) {
                    snapshot.links[serverID]?.removeValue(forKey: displayID)
                    changed = true
                }
            }
        }
        return changed
    }

    func showsBluetoothPreview(_ record: BluetoothDisplayRecord?, displayID: String, serverID: String?) -> Bool {
        guard let record, record.previewPNG != nil else { return false }
        return !record.photoSupersededByWiFi
    }

    func presentation(for display: DisplaySummary, serverID: String?) -> DisplayBluetoothPresentation {
        let record = record(for: display.id, serverID: serverID)
        let server = serverRecord(displayID: display.id, serverID: serverID)
        return DisplayBluetoothPresentation(record: record, server: server,
            fallbackPercent: display.batteryPercent, fallbackBatteryDate: display.lastSeenAt,
            usesLocalPreview: showsBluetoothPreview(record, displayID: display.id, serverID: serverID))
    }

    private func persist() {
        guard !isReadOnly, let fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(snapshot).write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            hasPersistedSnapshot = true
            storageError = nil
            publishSharedInventory()
        } catch {
            hasPersistedSnapshot = false
            storageError = String(localized: "Bluetooth records could not be saved. They may be lost when the app closes.")
        }
    }
}

struct DisplayBluetoothPresentation {
    let record: BluetoothDisplayRecord?
    let server: DisplayServerRecord?
    let fallbackPercent: Int?
    let fallbackBatteryDate: Date?
    let usesLocalPreview: Bool

    var isBluetooth: Bool { record?.mode == .bluetooth }
    func lastSeenAt(fallback: Date?) -> Date? {
        guard isBluetooth, let record else { return server?.lastSeenAt ?? fallback }
        return [record.modeConfirmedAt, record.batteryRecordedAt, record.batteryPercentRecordedAt, record.photoReceivedAt]
            .compactMap { $0 }.max()
    }
    var batteryText: String {
        latestBattery.map { "\($0.percent)%" } ?? "—"
    }
    private var latestBattery: (percent: Int, date: Date?)? {
        var latest: (percent: Int, date: Date?)?
        // Prefer the authenticated local sample on a timestamp tie.
        for (percent, date) in [(record?.batteryPercent, record?.batteryPercentRecordedAt),
                                (server?.batteryPercent, server?.batteryRecordedAt),
                                (fallbackPercent, fallbackBatteryDate)] {
            guard let percent, (0...100).contains(percent) else { continue }
            if let current = latest, (date ?? .distantPast) <= (current.date ?? .distantPast) { continue }
            latest = (percent, date)
        }
        return latest
    }
    var voltageText: String? {
        record?.batteryMillivolts.map { (Double($0) / 1000).formatted(.number.precision(.fractionLength(2))) + " V" }
    }
    var batteryDate: Date? {
        if let reading = latestBattery { return reading.date }
        return record?.batteryRecordedAt
    }
    var preview: PreviewImageState? {
        guard usesLocalPreview, let data = record?.previewPNG else { return nil }
        return PreviewImageState(data: data, eTag: nil, phase: .ready)
    }
}
