@preconcurrency import CoreBluetooth
import Foundation
import Observation

enum NearbyDeviceMode: String, Sendable {
    case setup
    case maintenance
}

struct NearbyTesseraeDevice: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let rssi: Int
    let mode: NearbyDeviceMode
    let hardwareSuffix: String
    let sessionID: Data?

    var suggestionSessionKey: String {
        "\(id.uuidString):\(sessionID?.hexString ?? "legacy")"
    }
}

struct NearbyWiFiNetwork: Identifiable, Equatable, Sendable {
    var id: String { ssid }
    let ssid: String
    let rssi: Int
    let isSecure: Bool
}

struct NearbyDeviceDiagnostics: Equatable, Sendable {
    let firmware: String
    let model: String
    let batteryMillivolts: Int
    let freeHeapBytes: Int
    let resetReason: Int
    let isWiFiConfigured: Bool
    let isServerConfigured: Bool
    let rssi: Int
    let ssid: String?
    let ipAddress: String?
    let logs: [String]
}

enum NearbyDeviceConnectionState: Equatable, Sendable {
    case idle
    case connecting
    case authenticating
    case ready
    case testingWiFi
    case testingServer
    case performingMaintenanceAction
    case restarting
    case configured
    case failed(String)
}

@MainActor
@Observable
final class NearbyDeviceManager: NSObject {
    private(set) var nearbyDevices: [NearbyTesseraeDevice] = []
    var suggestedDevice: NearbyTesseraeDevice?
    private(set) var activeDevice: NearbyTesseraeDevice?
    private(set) var deviceInfo: BLESetupDeviceInfo?
    private(set) var networks: [NearbyWiFiNetwork] = []
    private(set) var diagnostics: NearbyDeviceDiagnostics?
    private(set) var connectionState: NearbyDeviceConnectionState = .idle
    private(set) var statusMessage: String?
    private(set) var isScanning = false

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var sightings: [UUID: Int] = [:]
    private var suppressedSuggestionSessions: Set<String> = []
    private var lastSeenAt: [UUID: Date] = [:]
    private var lastSeenScanGeneration: [UUID: Int] = [:]
    private var scanGeneration = 0
    private var scanStartedAt = Date.distantPast
    private var presenceExpiryTask: Task<Void, Never>?
    private var connectedPeripheral: CBPeripheral?
    private var infoCharacteristic: CBCharacteristic?
    private var qrControlCharacteristic: CBCharacteristic?
    private var passkeyControlCharacteristic: CBCharacteristic?
    private var eventsCharacteristic: CBCharacteristic?
    private var controlCharacteristic: CBCharacteristic?
    private var qrCode: BLESetupQRCode?
    private var crypto: BLESetupCrypto?
    private var reassembler = BLESetupReassembler()
    private var outgoingMessageID: UInt16 = 0
    private var pendingWrites: [Data] = []
    private var isWriteInFlight = false
    private var disconnectWasRequested = false
    private var appIsActive = false

    private func trace(_ message: String) {
#if DEBUG
        print("[BLE setup] \(message)")
#endif
    }

    private func describe(_ error: Error?) -> String {
        guard let error else { return "none" }
        let nsError = error as NSError
        return "\(nsError.domain)(\(nsError.code)): \(nsError.localizedDescription)"
    }

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: .main)
    }

    func updateApplicationActivity(_ isActive: Bool) {
        appIsActive = isActive
        if isActive {
            startScanning()
        } else {
            stopScanning()
        }
    }

    func startScanning() {
        guard appIsActive, central.state == .poweredOn, !isScanning else { return }
        isScanning = true
        scanGeneration &+= 1
        scanStartedAt = Date()
        central.scanForPeripherals(
            withServices: [CBUUID(string: BLESetupProtocol.serviceUUID)],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        startPresenceExpiryTask(for: scanGeneration)
    }

    func stopScanning() {
        guard isScanning else { return }
        presenceExpiryTask?.cancel()
        presenceExpiryTask = nil
        central.stopScan()
        isScanning = false
    }

    private func startPresenceExpiryTask(for generation: Int) {
        presenceExpiryTask?.cancel()
        presenceExpiryTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled,
                      let self,
                      self.isScanning,
                      self.scanGeneration == generation
                else { return }
                self.expireAbsentDevices(now: Date())
            }
        }
    }

    private func expireAbsentDevices(now: Date) {
        let timeout: TimeInterval = 2.5
        let ids = nearbyDevices.compactMap { device -> UUID? in
            if lastSeenScanGeneration[device.id] != scanGeneration {
                return now.timeIntervalSince(scanStartedAt) >= timeout ? device.id : nil
            }
            guard let lastSeen = lastSeenAt[device.id] else { return device.id }
            return now.timeIntervalSince(lastSeen) >= timeout ? device.id : nil
        }
        for id in ids { resetPresence(for: id) }
    }

    private func resetPresence(for id: UUID) {
        nearbyDevices.removeAll { $0.id == id }
        peripherals[id] = nil
        sightings[id] = nil
        suppressedSuggestionSessions.remove("\(id.uuidString):legacy")
        lastSeenAt[id] = nil
        lastSeenScanGeneration[id] = nil
        if suggestedDevice?.id == id, activeDevice?.id != id {
            suggestedDevice = nil
        }
    }

    func dismissSuggestion(for device: NearbyTesseraeDevice) {
        suppressedSuggestionSessions.insert(device.suggestionSessionKey)
        if suggestedDevice?.id == device.id {
            suggestedDevice = nil
        }
    }

    func present(_ device: NearbyTesseraeDevice) {
        suggestedDevice = device
    }

    func parseQRCode(_ value: String) throws -> BLESetupQRCode {
        try BLESetupQRCode(string: value)
    }

    func connect(to device: NearbyTesseraeDevice, qrCode: BLESetupQRCode?) {
        guard let peripheral = peripherals[device.id] else {
            fail(String(localized: "That display is no longer nearby."))
            return
        }
        resetConnectionState()
        disconnectWasRequested = false
        self.qrCode = qrCode
        crypto = qrCode.map(BLESetupCrypto.init(qrCode:))
        activeDevice = device
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        statusMessage = String(localized: "Connecting to display…")
        stopScanning()
        trace("connect requested id=\(peripheral.identifier) state=\(peripheral.state.rawValue) rssi=\(device.rssi) qr=\(qrCode != nil)")
        central.connect(peripheral)
    }

    func disconnect() {
        if let connectedPeripheral {
            disconnectWasRequested = true
            central.cancelPeripheralConnection(connectedPeripheral)
        }
        resetConnectionState()
        if appIsActive { startScanning() }
    }

    func scanWiFi() {
        networks = []
        statusMessage = String(localized: "Looking for Wi-Fi networks…")
        sendCommand(["op": "scan"])
    }

    func applyConfiguration(
        ssid: String,
        password: String,
        serverURL: URL,
        pairingCode: String
    ) {
        sendCommand([
            "op": "stage",
            "ssid": ssid,
            "password": password,
            "server_url": serverURL.absoluteString,
            "pairing_code": pairingCode,
        ])
    }

    func requestDiagnostics() {
        sendCommand(["op": "diagnostics"])
    }

    func reboot() {
        connectionState = .performingMaintenanceAction
        statusMessage = String(localized: "Sending restart command…")
        sendCommand(["op": "reboot"])
    }

    func clearWiFi() {
        connectionState = .performingMaintenanceAction
        statusMessage = String(localized: "Clearing Wi-Fi settings…")
        sendCommand(["op": "clear_wifi"])
    }

    func factoryReset() {
        connectionState = .performingMaintenanceAction
        statusMessage = String(localized: "Resetting display…")
        sendCommand(["op": "factory_reset"])
    }

    private func resetConnectionState() {
        connectedPeripheral = nil
        infoCharacteristic = nil
        qrControlCharacteristic = nil
        passkeyControlCharacteristic = nil
        eventsCharacteristic = nil
        controlCharacteristic = nil
        qrCode = nil
        crypto = nil
        reassembler.reset()
        pendingWrites = []
        isWriteInFlight = false
        outgoingMessageID = 0
        activeDevice = nil
        deviceInfo = nil
        networks = []
        diagnostics = nil
        connectionState = .idle
        statusMessage = nil
    }

    private func sendCommand(_ object: [String: Any]) {
        guard
            let peripheral = connectedPeripheral,
            controlCharacteristic != nil
        else {
            fail(String(localized: "Connect to the display first."))
            return
        }
        do {
            let message = try JSONSerialization.data(
                withJSONObject: object,
                options: [.sortedKeys]
            )
            guard message.count <= BLESetupProtocol.maximumMessageBytes else {
                throw BLESetupProtocolError.messageTooLarge
            }
            outgoingMessageID &+= 1
            let secured = qrCode != nil
            let overhead = 4 + (secured ? 21 : 1)
            let maximumWrite = peripheral.maximumWriteValueLength(for: .withResponse)
            let payloadLimit = max(1, maximumWrite - overhead)
            let count = max(1, (message.count + payloadLimit - 1) / payloadLimit)
            guard count <= Int(UInt8.max) else {
                throw BLESetupProtocolError.messageTooLarge
            }
            for index in 0..<count {
                let lower = index * payloadLimit
                let upper = min(message.count, lower + payloadLimit)
                var chunk = Data([
                    UInt8(truncatingIfNeeded: outgoingMessageID >> 8),
                    UInt8(truncatingIfNeeded: outgoingMessageID),
                    UInt8(index),
                    UInt8(count),
                ])
                chunk.append(message[lower..<upper])
                if var crypto {
                    let frame = try crypto.seal(chunk, direction: .appToDevice)
                    self.crypto = crypto
                    pendingWrites.append(frame)
                } else {
                    pendingWrites.append(Data([BLESetupProtocol.nativeFrame]) + chunk)
                }
            }
            writeNextFrameIfNeeded()
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func writeNextFrameIfNeeded() {
        guard
            let peripheral = connectedPeripheral,
            let controlCharacteristic = controlCharacteristic,
            !isWriteInFlight,
            let next = pendingWrites.first
        else { return }
        isWriteInFlight = true
        peripheral.writeValue(next, for: controlCharacteristic, type: .withResponse)
    }

    private func receiveEventFrame(_ frame: Data) {
        do {
            let chunk: Data
            if frame.first == BLESetupProtocol.qrFrame {
                guard var crypto else { throw BLESetupProtocolError.authenticationFailed }
                chunk = try crypto.open(frame, direction: .deviceToApp)
                self.crypto = crypto
            } else {
                guard frame.first == BLESetupProtocol.nativeFrame else {
                    throw BLESetupProtocolError.invalidFrame
                }
                chunk = Data(frame.dropFirst())
            }
            if let message = try reassembler.push(chunk) {
                try handleEvent(message)
            }
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func handleEvent(_ data: Data) throws {
        guard
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let event = object["event"] as? String
        else { throw BLESetupProtocolError.invalidFrame }
        trace("received event=\(event)")

        switch event {
        case "scan_started":
            networks = []
            statusMessage = String(localized: "Looking for Wi-Fi networks…")
        case "network":
            guard let ssid = object["ssid"] as? String, !ssid.isEmpty else { return }
            let network = NearbyWiFiNetwork(
                ssid: ssid,
                rssi: object["rssi"] as? Int ?? -100,
                isSecure: object["secure"] as? Bool ?? true
            )
            if let index = networks.firstIndex(where: { $0.ssid == ssid }) {
                if network.rssi > networks[index].rssi { networks[index] = network }
            } else {
                networks.append(network)
            }
            networks.sort { $0.rssi > $1.rssi }
        case "scan_complete":
            statusMessage = networks.isEmpty
                ? String(localized: "No Wi-Fi networks found.")
                : nil
        case "staged":
            statusMessage = String(localized: "Testing Wi-Fi before saving…")
            sendCommand(["op": "apply"])
        case "testing_wifi":
            connectionState = .testingWiFi
            statusMessage = String(localized: "Connecting to Wi-Fi…")
        case "wifi_connected":
            statusMessage = String(localized: "Wi-Fi connected. Checking server…")
        case "testing_server":
            connectionState = .testingServer
            statusMessage = String(localized: "Checking Tesserae server…")
        case "server_connected":
            statusMessage = String(localized: "Server verified. Saving configuration…")
        case "configured":
            connectionState = .configured
            statusMessage = String(localized: "Display configured. It is restarting now.")
        case "diagnostics":
            diagnostics = NearbyDeviceDiagnostics(
                firmware: object["firmware"] as? String ?? "—",
                model: object["model"] as? String ?? "—",
                batteryMillivolts: object["battery_mv"] as? Int ?? 0,
                freeHeapBytes: object["free_heap"] as? Int ?? 0,
                resetReason: object["reset_reason"] as? Int ?? 0,
                isWiFiConfigured: object["wifi_configured"] as? Bool ?? false,
                isServerConfigured: object["server_configured"] as? Bool ?? false,
                rssi: object["rssi"] as? Int ?? 0,
                ssid: object["ssid"] as? String,
                ipAddress: object["ip"] as? String,
                logs: object["logs"] as? [String] ?? []
            )
            statusMessage = nil
        case "rebooting":
            connectionState = .restarting
            statusMessage = String(localized: "Display is restarting…")
        case "clearing_wifi":
            connectionState = .restarting
            statusMessage = String(localized: "Wi-Fi settings cleared. Display is restarting…")
        case "factory_resetting":
            connectionState = .restarting
            statusMessage = String(localized: "Display reset. It is restarting…")
        case "wifi_failed", "server_failed", "error":
            fail(object["message"] as? String ?? String(localized: "Display setup failed."))
        default:
            break
        }
    }

    private func fail(_ message: String) {
        trace("failed state=\(String(describing: connectionState)) message=\(message)")
        let peripheral = connectedPeripheral
        connectedPeripheral = nil
        infoCharacteristic = nil
        qrControlCharacteristic = nil
        passkeyControlCharacteristic = nil
        eventsCharacteristic = nil
        controlCharacteristic = nil
        qrCode = nil
        crypto = nil
        reassembler.reset()
        pendingWrites = []
        isWriteInFlight = false
        connectionState = .failed(message)
        statusMessage = message
        if let peripheral, peripheral.state != .disconnected {
            central.cancelPeripheralConnection(peripheral)
        }
        if appIsActive { startScanning() }
    }

    private func decodeAdvertisement(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) -> NearbyTesseraeDevice? {
        guard
            let serviceData = advertisementData[CBAdvertisementDataServiceDataKey]
                as? [CBUUID: Data],
            let data = serviceData[CBUUID(string: BLESetupProtocol.serviceUUID)],
            let advertisement = BLESetupAdvertisement(serviceData: data)
        else { return nil }
        let suffix = advertisement.hardwareSuffix
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let displayName = advertisedName?.hasPrefix("Tes-") == true
            ? "Tesserae-\(suffix)"
            : advertisedName ?? "Tesserae-\(suffix)"
        return NearbyTesseraeDevice(
            id: peripheral.identifier,
            name: displayName,
            rssi: rssi.intValue,
            mode: advertisement.mode,
            hardwareSuffix: suffix,
            sessionID: advertisement.sessionID
        )
    }
}

extension NearbyDeviceManager: @preconcurrency CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        trace("central state=\(central.state.rawValue)")
        if central.state == .poweredOn {
            startScanning()
        } else {
            stopScanning()
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        guard let device = decodeAdvertisement(
            peripheral: peripheral,
            advertisementData: advertisementData,
            rssi: RSSI
        ) else { return }
        let now = Date()
        if lastSeenScanGeneration[device.id] == scanGeneration,
           let lastSeen = lastSeenAt[device.id],
           now.timeIntervalSince(lastSeen) >= 2.5 {
            resetPresence(for: device.id)
        } else if lastSeenScanGeneration[device.id] != scanGeneration,
                  now.timeIntervalSince(scanStartedAt) >= 2.5 {
            resetPresence(for: device.id)
        }
        lastSeenAt[device.id] = now
        lastSeenScanGeneration[device.id] = scanGeneration
        if sightings[device.id] == nil {
            trace("discovered id=\(peripheral.identifier) state=\(peripheral.state.rawValue) rssi=\(RSSI) mode=\(device.mode.rawValue)")
        }
        peripherals[device.id] = peripheral
        sightings[device.id, default: 0] += 1
        if let index = nearbyDevices.firstIndex(where: { $0.id == device.id }) {
            nearbyDevices[index] = device
        } else {
            nearbyDevices.append(device)
        }
        nearbyDevices.sort { $0.rssi > $1.rssi }

        if suggestedDevice == nil,
           sightings[device.id, default: 0] >= 2,
           device.rssi >= -78,
           !suppressedSuggestionSessions.contains(device.suggestionSessionKey) {
            // Suggest once per ephemeral firmware session. A new maintenance
            // session has a new advertised session ID, even when scanning did
            // not observe a long enough advertising gap between sessions.
            suppressedSuggestionSessions.insert(device.suggestionSessionKey)
            suggestedDevice = device
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        trace("connected id=\(peripheral.identifier)")
        statusMessage = String(localized: "Reading display information…")
        peripheral.discoverServices([CBUUID(string: BLESetupProtocol.serviceUUID)])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        trace("connect failed id=\(peripheral.identifier) error=\(describe(error))")
        fail(error?.localizedDescription ?? String(localized: "Could not connect to the display."))
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        trace("disconnected id=\(peripheral.identifier) error=\(describe(error))")
        connectedPeripheral = nil
        let requestedDisconnect = disconnectWasRequested
        disconnectWasRequested = false
        let alreadyFailed: Bool
        if case .failed = connectionState { alreadyFailed = true } else { alreadyFailed = false }
        let expectedDisconnect = requestedDisconnect
            || connectionState == .configured
            || connectionState == .restarting
        if !expectedDisconnect, !alreadyFailed {
            fail(error?.localizedDescription
                 ?? String(localized: "The display disconnected unexpectedly."))
        }
        if appIsActive { startScanning() }
    }
}

extension NearbyDeviceManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        trace("services discovered count=\(peripheral.services?.count ?? 0) error=\(describe(error))")
        if let error { fail(error.localizedDescription); return }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: BLESetupProtocol.serviceUUID)
        }) else {
            fail(String(localized: "This display does not support nearby setup."))
            return
        }
        peripheral.discoverCharacteristics([
            CBUUID(string: BLESetupProtocol.infoUUID),
            CBUUID(string: BLESetupProtocol.qrControlUUID),
            CBUUID(string: BLESetupProtocol.passkeyControlUUID),
            CBUUID(string: BLESetupProtocol.eventsUUID),
        ], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        let uuids = (service.characteristics ?? []).map(\.uuid.uuidString).joined(separator: ",")
        trace("characteristics discovered uuids=\(uuids) error=\(describe(error))")
        if let error { fail(error.localizedDescription); return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid.uuidString.uppercased() {
            case BLESetupProtocol.infoUUID: infoCharacteristic = characteristic
            case BLESetupProtocol.qrControlUUID: qrControlCharacteristic = characteristic
            case BLESetupProtocol.passkeyControlUUID: passkeyControlCharacteristic = characteristic
            case BLESetupProtocol.eventsUUID: eventsCharacteristic = characteristic
            default: break
            }
        }
        guard infoCharacteristic != nil, let eventsCharacteristic else {
            fail(String(localized: "The display setup service is incomplete."))
            return
        }
        peripheral.setNotifyValue(true, for: eventsCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error { fail(error.localizedDescription); return }
        guard
            characteristic.uuid == CBUUID(string: BLESetupProtocol.eventsUUID),
            characteristic.isNotifying,
            let infoCharacteristic
        else { return }
        // Subscribe before reading info. The info callback may immediately
        // trigger a Wi-Fi scan, whose first notifications must not be lost.
        peripheral.readValue(for: infoCharacteristic)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error { fail(error.localizedDescription); return }
        guard let value = characteristic.value else { return }
        if characteristic.uuid == CBUUID(string: BLESetupProtocol.infoUUID) {
            do {
                let info = try JSONDecoder().decode(BLESetupDeviceInfo.self, from: value)
                if let qrCode { try info.validate(qrCode: qrCode) }
                deviceInfo = info
                controlCharacteristic = qrCode == nil
                    ? passkeyControlCharacteristic
                    : qrControlCharacteristic
                guard controlCharacteristic != nil else {
                    throw BLESetupProtocolError.invalidFrame
                }
                connectionState = .ready
                statusMessage = nil
                if activeDevice?.mode == .maintenance {
                    requestDiagnostics()
                } else {
                    scanWiFi()
                }
            } catch {
                fail(error.localizedDescription)
            }
        } else if characteristic.uuid == CBUUID(string: BLESetupProtocol.eventsUUID) {
            receiveEventFrame(value)
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        isWriteInFlight = false
        if let error { fail(error.localizedDescription); pendingWrites = []; return }
        if !pendingWrites.isEmpty { pendingWrites.removeFirst() }
        writeNextFrameIfNeeded()
    }
}
