@preconcurrency import CoreBluetooth
import Foundation
import Observation

enum NearbyDeviceMode: String, Sendable {
    case setup
    case maintenance
    case photo
}

struct NearbyTesseraeDevice: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let rssi: Int
    let mode: NearbyDeviceMode
    let hardware: BLESetupHardware
    let hardwareSuffix: String
    let sessionID: Data

    var suggestionSessionKey: String {
        "\(id.uuidString):\(sessionID.hexString)"
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
    let screenMode: BLEScreenMode?
    let refreshSpeed: BLERefreshSpeed?

    init(event: [String: Any]) {
        firmware = event["firmware"] as? String ?? "—"
        model = event["model"] as? String ?? "—"
        batteryMillivolts = event["battery_mv"] as? Int ?? 0
        freeHeapBytes = event["free_heap"] as? Int ?? 0
        resetReason = event["reset_reason"] as? Int ?? 0
        isWiFiConfigured = event["wifi_configured"] as? Bool ?? false
        isServerConfigured = event["server_configured"] as? Bool ?? false
        rssi = event["rssi"] as? Int ?? 0
        ssid = event["ssid"] as? String
        ipAddress = event["ip"] as? String
        logs = event["logs"] as? [String] ?? []
        screenMode = (event["screen_mode"] as? String).flatMap(BLEScreenMode.init)
        refreshSpeed = (event["refresh_speed"] as? String).flatMap(BLERefreshSpeed.init)
    }
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

/// Core Bluetooth's terminal callbacks do not carry an attempt identifier.
/// Drain the previous connection before starting another, including reconnects
/// to the same peripheral, and ignore callbacks belonging to other peripherals.
struct NearbyConnectionLifecycle {
    enum ConnectAction: Equatable {
        case connect(UUID)
        case disconnect(UUID)
        case wait
    }

    enum EndAction: Equatable {
        case ignored
        case closed
        case connect(UUID)
        case unexpected
    }

    private(set) var activePeripheralID: UUID?
    private(set) var closingPeripheralID: UUID?
    private(set) var pendingPeripheralID: UUID?

    mutating func requestConnection(
        to peripheralID: UUID,
        isAlreadyConnected: Bool = false
    ) -> ConnectAction {
        if closingPeripheralID != nil {
            pendingPeripheralID = peripheralID
            return .wait
        }
        if let previousID = activePeripheralID {
            activePeripheralID = nil
            closingPeripheralID = previousID
            pendingPeripheralID = peripheralID
            return .disconnect(previousID)
        }
        if isAlreadyConnected {
            closingPeripheralID = peripheralID
            pendingPeripheralID = peripheralID
            return .disconnect(peripheralID)
        }
        activePeripheralID = peripheralID
        return .connect(peripheralID)
    }

    mutating func requestDisconnect() -> UUID? {
        pendingPeripheralID = nil
        guard let activePeripheralID else { return nil }
        self.activePeripheralID = nil
        closingPeripheralID = activePeripheralID
        return activePeripheralID
    }

    /// Both didDisconnect and didFailToConnect finish a pending cancellation.
    mutating func connectionEnded(for peripheralID: UUID) -> EndAction {
        if closingPeripheralID == peripheralID {
            closingPeripheralID = nil
            if let pendingPeripheralID {
                self.pendingPeripheralID = nil
                activePeripheralID = pendingPeripheralID
                return .connect(pendingPeripheralID)
            }
            return .closed
        }
        guard activePeripheralID == peripheralID else { return .ignored }
        activePeripheralID = nil
        return .unexpected
    }
}

@MainActor
@Observable
final class NearbyDeviceManager: NSObject {
    private struct PendingConnection {
        let device: NearbyTesseraeDevice
        let peripheral: CBPeripheral
        let qrCode: BLESetupQRCode?
    }

    private(set) var nearbyDevices: [NearbyTesseraeDevice] = []
    var suggestedDevice: NearbyTesseraeDevice?
    private(set) var activeDevice: NearbyTesseraeDevice?
    private(set) var deviceInfo: BLESetupDeviceInfo?
    private(set) var networks: [NearbyWiFiNetwork] = []
    private(set) var diagnostics: NearbyDeviceDiagnostics?
    private(set) var refreshSpeedSetting = NearbyRefreshSpeedSetting()
    private(set) var connectionState: NearbyDeviceConnectionState = .idle
    private(set) var statusMessage: String?
    private(set) var isScanning = false

    private(set) var screenMode: BLEScreenMode?
    private(set) var isSavingScreenMode = false
    private(set) var screenModeNeedsReadback = false
    private(set) var screenModeError: String?
    private(set) var photoAuthorized = false
    private(set) var photoState: BLEPhotoState = .idle
    private(set) var photoProgress: Double = 0
    private(set) var photoDeviceStatus: BLEPhotoDeviceStatus?
    private var screenModeRequest: UInt32?
    private var screenModeTimeoutTask: Task<Void, Never>?
    private var photoTimeoutTask: Task<Void, Never>?
    private var photoTransfer: BLEPhotoTransfer?
    private var pendingPhotoMessage: Data?
    private var pendingPhotoIsBinary = false
    private var photoRetries = 0
    private var photoCharacteristic: CBCharacteristic?

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
    private var pendingWrites: [(data: Data, characteristic: CBCharacteristic)] = []
    private var isWriteInFlight = false
    private var connectionLifecycle = NearbyConnectionLifecycle()
    private var pendingConnection: PendingConnection?
    private var appIsActive = false
    private var refreshSpeedTimeoutTask: Task<Void, Never>?
#if DEBUG
    private let isPhotoUIFixture = ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_PICPAK_PHOTO"] == "1"
    private let isPicPakUIFixture = ProcessInfo.processInfo.environment[
        "TESSERAE_UI_TEST_PICPAK_BLE"
    ] == "1"
#endif

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
#if DEBUG
        if isPicPakUIFixture {
            nearbyDevices = [NearbyTesseraeDevice(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                name: "Tesserae-A1B2C3", rssi: -45, mode: isPhotoUIFixture ? .photo : .maintenance,
                hardware: .picPak42, hardwareSuffix: "A1B2C3",
                sessionID: Data([1, 2, 3, 4])
            )]
            return
        }
#endif
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
#if DEBUG
        if isPicPakUIFixture {
            if ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_PICPAK_AUTO_DISCOVERY"] == "1",
               suggestedDevice == nil, activeDevice == nil,
               let device = nearbyDevices.first,
               !suppressedSuggestionSessions.contains(device.suggestionSessionKey) {
                suggestedDevice = device
            }
            return
        }
#endif
        guard appIsActive, central.state == .poweredOn, !isScanning else { return }
        isScanning = true
        scanGeneration &+= 1
        scanStartedAt = Date()
        central.scanForPeripherals(
            withServices: [CBUUID(string: BLESetupProtocol.serviceUUID), CBUUID(string: BLESetupProtocol.photoServiceUUID)],
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
#if DEBUG
        if isPicPakUIFixture {
            resetConnectionState()
            activeDevice = device
            deviceInfo = BLESetupDeviceInfo(
                protocol: 2, id: "picpak-a1b2c3", sid: "01020304",
                connectionNonce: "000102030405060708090a0b0c0d0e0f",
                hardware: 11, model: "picpak_4_2", firmware: "0.9.3",
                mode: device.mode.rawValue
            )
            connectionState = .authenticating
            if device.mode == .photo {
                let delay = Int(ProcessInfo.processInfo.environment[
                    "TESSERAE_UI_TEST_PICPAK_CONNECTION_DELAY_MS"
                ] ?? "0") ?? 0
                photoTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(min(max(delay, 0), 10_000)))
                    guard !Task.isCancelled else { return }
                    self?.sendCommand(["op": "photo_info"])
                }
            } else { requestDiagnostics() }
            return
        }
#endif
        guard let peripheral = peripherals[device.id] else {
            fail(String(localized: "That display is no longer nearby."))
            return
        }
        pendingConnection = PendingConnection(
            device: device,
            peripheral: peripheral,
            qrCode: qrCode
        )
        let action = connectionLifecycle.requestConnection(
            to: peripheral.identifier,
            isAlreadyConnected: peripheral.state != .disconnected
        )
        switch action {
        case .connect:
            beginConnection(to: device, peripheral: peripheral, qrCode: qrCode)
        case .disconnect, .wait:
            let peripheralToClose = connectedPeripheral ?? peripheral
            resetConnectionState()
            activeDevice = device
            connectionState = .connecting
            statusMessage = String(localized: "Closing the previous connection…")
            stopScanning()
            if case .disconnect = action {
                central.cancelPeripheralConnection(peripheralToClose)
            }
        }
    }

    private func beginConnection(
        to device: NearbyTesseraeDevice,
        peripheral: CBPeripheral,
        qrCode: BLESetupQRCode?
    ) {
        resetConnectionState()
        pendingConnection = nil
        self.qrCode = qrCode
        activeDevice = device
        connectedPeripheral = peripheral
        peripheral.delegate = self
        connectionState = .connecting
        statusMessage = String(localized: "Connecting to display…")
        stopScanning()
        trace("connect requested id=\(peripheral.identifier) state=\(peripheral.state.rawValue) rssi=\(device.rssi) qr=\(qrCode != nil)")
        central.connect(peripheral)
        if device.mode == .photo {
            photoTimeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(20))
                guard !Task.isCancelled, let self, self.connectionState != .ready else { return }
                self.fail(String(localized: "Could not connect. Press PicPak's button and try again."))
            }
        }
    }

    func disconnect() {
        pendingConnection = nil
        if let closingID = connectionLifecycle.requestDisconnect(),
           let connectedPeripheral,
           connectedPeripheral.identifier == closingID {
            central.cancelPeripheralConnection(connectedPeripheral)
        }
        resetConnectionState()
        if appIsActive { startScanning() }
    }

    func endSession(for device: NearbyTesseraeDevice) {
        dismissSuggestion(for: device)
        guard activeDevice?.id == device.id
                || pendingConnection?.device.id == device.id
        else { return }
        disconnect()
    }

    func scanWiFi() {
        networks = []
        statusMessage = String(localized: "Looking for Wi-Fi networks…")
        sendCommand(["op": "scan"])
    }

    func applyConfiguration(
        ssid: String,
        password: String,
        serverURL: URL?,
        pairingCode: String
    ) {
        var command: [String: Any] = [
            "op": "stage",
            "ssid": ssid,
            "password": password,
            "server_url": serverURL?.absoluteString ?? "",
            "pairing_code": pairingCode,
        ]
        if activeDevice?.mode == .maintenance {
            command["preserve_server"] = true
        }
        sendCommand(command)
    }

    func requestDiagnostics() {
        sendCommand(["op": "diagnostics"])
    }

    func setRefreshSpeed(_ value: BLERefreshSpeed) {
        guard activeDevice?.hardware == .picPak42,
              activeDevice?.mode == .maintenance,
              connectionState == .ready,
              refreshSpeedSetting.beginSaving(value) else { return }
        refreshSpeedTimeoutTask?.cancel()
        refreshSpeedTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self,
                  self.refreshSpeedSetting.isSaving else { return }
            self.refreshSpeedSetting.fail(
                String(localized: "Save not confirmed. Checking display…"),
                needsReadback: true
            )
            self.requestDiagnostics()
        }
        sendCommand(["op": "set_refresh_speed", "value": value.rawValue])
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
        resetRefreshSpeedSetting()
        resetPhotoSession()
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

    private func resetRefreshSpeedSetting() {
        refreshSpeedTimeoutTask?.cancel()
        refreshSpeedTimeoutTask = nil
        refreshSpeedSetting.reset()
    }

    private func sendCommand(_ object: [String: Any]) {
#if DEBUG
        if isPicPakUIFixture {
            receivePicPakFixtureCommand(object)
            return
        }
#endif
        do {
            let message = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            queueMessage(message, binary: false)
        } catch { fail(error.localizedDescription) }
    }

    private func queueMessage(_ message: Data, binary: Bool) {
#if DEBUG
        if isPicPakUIFixture {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(15))
                guard let self, self.activeDevice != nil else { return }
                if binary, message.count > 8 {
                    let id = message.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    let offset = message.dropFirst(4).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    self.receiveFixtureEvent(["event": "photo_ack", "id": id, "offset": Int(offset) + message.count - 8])
                } else if let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] {
                    self.receivePicPakFixtureCommand(object)
                }
            }
            return
        }
#endif
        guard let peripheral = connectedPeripheral,
              let characteristic = binary ? photoCharacteristic : controlCharacteristic
        else { fail(String(localized: "Connect to the display first.")); return }
        do {
            guard message.count <= BLESetupProtocol.maximumMessageBytes else {
                throw BLESetupProtocolError.messageTooLarge
            }
            outgoingMessageID &+= 1
            let overhead = 4 + (qrCode != nil ? 21 : 1)
            let maximumWrite = peripheral.maximumWriteValueLength(for: .withResponse)
            guard maximumWrite > overhead else { throw BLESetupProtocolError.invalidFrame }
            let payloadLimit = maximumWrite - overhead
            let count = max(1, (message.count + payloadLimit - 1) / payloadLimit)
            guard count <= Int(UInt8.max) else { throw BLESetupProtocolError.messageTooLarge }
            for index in 0..<count {
                let lower = index * payloadLimit
                let upper = min(message.count, lower + payloadLimit)
                var chunk = Data([
                    UInt8(truncatingIfNeeded: outgoingMessageID >> 8),
                    UInt8(truncatingIfNeeded: outgoingMessageID), UInt8(index), UInt8(count),
                ])
                chunk.append(message[lower..<upper])
                let frame: Data
                if var crypto {
                    frame = try crypto.seal(chunk, direction: .appToDevice)
                    self.crypto = crypto
                } else {
                    frame = Data([BLESetupProtocol.nativeFrame]) + chunk
                }
                pendingWrites.append((frame, characteristic))
            }
            writeNextFrameIfNeeded()
        } catch { fail(error.localizedDescription) }
    }

#if DEBUG
    /// Transport-only fixture: exercise the real event and setting state logic
    /// without discovering, pairing with, or writing to a physical display.
    private func receiveFixtureEvent(_ event: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: event) { try? handleEvent(data) }
    }
    private func receivePicPakFixtureCommand(_ command: [String: Any]) {
        switch command["op"] as? String {
        case "diagnostics":
            let event: [String: Any] = [
                "event": "diagnostics", "firmware": "0.9.3",
                "model": "picpak_4_2", "battery_mv": 3900,
                "wifi_configured": true, "server_configured": true,
                "ssid": "Home Wi-Fi", "refresh_speed": "5s", "screen_mode": screenMode?.rawValue ?? "wifi",
            ]
            if let data = try? JSONSerialization.data(withJSONObject: event) {
                try? handleEvent(data)
            }
        case "set_screen_mode":
            receiveFixtureEvent(["event": "screen_mode", "value": command["value"] ?? "wifi",
                                 "request": command["request"] ?? 0,
                                 "photo_key": Data(repeating: 0x5a, count: 32).base64EncodedString()])
        case "photo_info":
            receiveFixtureEvent(["event": "photo_info", "version": 1, "width": 400, "height": 300,
                                 "bytes": 30000, "chunk_bytes": 192, "format": BLEPhotoTransfer.format,
                                 "battery_mv": 3900, "low_battery": false,
                                 "refresh_speed": "5s", "screen_mode": "bluetooth"])
        case "photo_begin":
            receiveFixtureEvent(["event": "photo_ack", "id": command["id"] ?? 0, "offset": 0])
        case "photo_end":
            receiveFixtureEvent(["event": "photo_received", "id": command["id"] ?? 0])
        case "set_refresh_speed":
            guard let value = command["value"] as? String,
                  let sessionDeviceID = activeDevice?.id else { return }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(700))
                guard let self, self.activeDevice?.id == sessionDeviceID,
                      self.refreshSpeedSetting.isSaving else { return }
                let event = ["event": "refresh_speed", "value": value]
                if let data = try? JSONSerialization.data(withJSONObject: event) {
                    try? self.handleEvent(data)
                }
            }
        default:
            break
        }
    }
#endif

    private func writeNextFrameIfNeeded() {
        guard
            let peripheral = connectedPeripheral,
            !isWriteInFlight,
            let next = pendingWrites.first
        else { return }
        isWriteInFlight = true
        peripheral.writeValue(next.data, for: next.characteristic, type: .withResponse)
    }

    private func receiveEventFrame(_ frame: Data) {
        do {
            let chunk: Data
            if frame.first == BLESetupProtocol.qrFrame {
                guard var crypto else { throw BLESetupProtocolError.authenticationFailed }
                chunk = try crypto.open(frame, direction: .deviceToApp)
                self.crypto = crypto
            } else {
                guard crypto == nil, frame.first == BLESetupProtocol.nativeFrame else {
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
            if connectionState == .authenticating {
                connectionState = .ready
            }
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
            statusMessage = activeDevice?.hardware == .picPak42
                ? String(localized: "Wi-Fi connected. Saving settings…")
                : String(localized: "Wi-Fi connected. Checking server…")
        case "testing_server":
            connectionState = .testingServer
            statusMessage = String(localized: "Checking Tesserae server…")
        case "server_connected":
            statusMessage = String(localized: "Server verified. Saving configuration…")
        case "configured":
            connectionState = .configured
            statusMessage = activeDevice?.hardware == .picPak42
                ? String(localized: "Wi-Fi saved. Display is restarting…")
                : String(localized: "Display configured. It is restarting now.")
        case "diagnostics":
            diagnostics = NearbyDeviceDiagnostics(event: object)
            screenMode = diagnostics?.screenMode
            screenModeNeedsReadback = false
            photoAuthorized = deviceInfo.map { BLEPhotoKeyStore.read($0.id) != nil } ?? false
            refreshSpeedSetting.receiveDiagnostics(
                diagnostics?.refreshSpeed,
                hardware: activeDevice?.hardware
            )
            if connectionState == .authenticating {
                connectionState = .ready
            }
            statusMessage = nil
        case "screen_mode":
            guard let request = object["request"] as? UInt32,
                  request == screenModeRequest,
                  let mode = (object["value"] as? String).flatMap(BLEScreenMode.init),
                  let id = deviceInfo?.id else { return }
            screenModeTimeoutTask?.cancel()
            screenModeRequest = nil
            isSavingScreenMode = false
            screenMode = mode
            do {
                if mode == .bluetooth {
                    guard let encoded = object["photo_key"] as? String,
                          let key = Data(base64URLEncoded: encoded) else {
                        throw BLESetupProtocolError.invalidFrame
                    }
                    try BLEPhotoKeyStore.save(key, for: id)
                    photoAuthorized = true
                } else {
                    BLEPhotoKeyStore.remove(id)
                    photoAuthorized = false
                }
                screenModeError = nil
            } catch {
                trace("Photo authorization storage failed: \(describe(error))")
                screenModeError = String(localized: "Mode saved, but this iPhone could not be authorized. Try Allow This iPhone again.")
            }
        case "photo_info":
            guard activeDevice?.mode == .photo,
                  object["version"] as? Int == 1,
                  object["width"] as? Int == 400, object["height"] as? Int == 300,
                  object["bytes"] as? Int == BLEPhotoTransfer.byteCount,
                  object["format"] as? String == BLEPhotoTransfer.format,
                  object["chunk_bytes"] as? Int == BLEPhotoTransfer.chunkBytes else {
                throw BLESetupProtocolError.invalidFrame
            }
            photoDeviceStatus = BLEPhotoDeviceStatus(event: object)
            photoTimeoutTask?.cancel()
            connectionState = .ready
            statusMessage = nil
        case "photo_ack":
            guard var transfer = photoTransfer,
                  object["id"] as? UInt32 == transfer.id,
                  let offset = object["offset"] as? Int,
                  try transfer.acknowledge(offset) else { return }
            photoTimeoutTask?.cancel()
            photoProgress = Double(offset) / Double(transfer.data.count)
            let packet = transfer.nextPacket()
            photoTransfer = transfer
            if let packet { sendPhotoMessage(packet, binary: true) }
            else { sendPhotoControl(["op": "photo_end", "id": transfer.id]) }
        case "photo_received":
            guard let transfer = photoTransfer, transfer.waitingForReceipt,
                  object["id"] as? UInt32 == transfer.id else { return }
            photoTimeoutTask?.cancel()
            photoTransfer = nil
            pendingPhotoMessage = nil
            photoProgress = 1
            photoState = .received
        case "refresh_speed":
            guard refreshSpeedSetting.isSaving else { return }
            refreshSpeedTimeoutTask?.cancel()
            refreshSpeedTimeoutTask = nil
            if !refreshSpeedSetting.acknowledge(object["value"] as? String) {
                refreshSpeedSetting.fail(
                    String(localized: "Save not confirmed. Checking display…"),
                    needsReadback: true
                )
                requestDiagnostics()
            }
        case "rebooting":
            connectionState = .restarting
            statusMessage = String(localized: "Display is restarting…")
        case "clearing_wifi":
            connectionState = .restarting
            statusMessage = String(localized: "Wi-Fi settings cleared. Display is restarting…")
        case "factory_resetting":
            if let id = deviceInfo?.id { BLEPhotoKeyStore.remove(id) }
            connectionState = .restarting
            statusMessage = String(localized: "Display reset. It is restarting…")
        case "error" where isSavingScreenMode:
            screenModeTimeoutTask?.cancel()
            screenModeRequest = nil
            isSavingScreenMode = false
            screenModeError = object["message"] as? String ?? String(localized: "Could not save screen mode.")
            screenModeNeedsReadback = true
            requestDiagnostics()
        case "error" where refreshSpeedSetting.isSaving || refreshSpeedSetting.needsReadback:
            refreshSpeedTimeoutTask?.cancel()
            refreshSpeedTimeoutTask = nil
            refreshSpeedSetting.fail(
                object["message"] as? String
                    ?? String(localized: "Couldn't save refresh speed. Try again."),
                needsReadback: refreshSpeedSetting.needsReadback
            )
        case "wifi_failed", "server_failed", "error":
            fail(object["message"] as? String ?? String(localized: "Display setup failed."))
        default:
            break
        }
    }

    private func fail(_ message: String) {
        resetRefreshSpeedSetting()
        photoTimeoutTask?.cancel()
        screenModeTimeoutTask?.cancel()
        isSavingScreenMode = false
        photoCharacteristic = nil
        photoTransfer = nil
        pendingPhotoMessage = nil
        trace("failed state=\(String(describing: connectionState)) message=\(message)")
        let peripheral = connectedPeripheral
        let closingID = connectionLifecycle.requestDisconnect()
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
        pendingConnection = nil
        connectionState = .failed(message)
        statusMessage = message
        if let peripheral, peripheral.identifier == closingID {
            central.cancelPeripheralConnection(peripheral)
        }
        if appIsActive { startScanning() }
    }

    private var activeServiceUUID: String {
        activeDevice?.mode == .photo ? BLESetupProtocol.photoServiceUUID : BLESetupProtocol.serviceUUID
    }

    func setScreenMode(_ mode: BLEScreenMode) {
        guard activeDevice?.mode == .maintenance, activeDevice?.hardware == .picPak42,
              screenMode != nil, connectionState == .ready,
              !isSavingScreenMode, !screenModeNeedsReadback, !refreshSpeedSetting.isSaving,
              !refreshSpeedSetting.needsReadback else { return }
        let request = UInt32.random(in: 1...UInt32.max)
        screenModeRequest = request
        isSavingScreenMode = true
        screenModeError = nil
        screenModeTimeoutTask?.cancel()
        screenModeTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.screenModeRequest == request else { return }
            self.screenModeRequest = nil
            self.isSavingScreenMode = false
            self.screenModeNeedsReadback = true
            self.screenModeError = String(localized: "Save not confirmed. Checking display…")
            self.requestDiagnostics()
        }
        sendCommand(["op": "set_screen_mode", "value": mode.rawValue, "request": request])
    }

    func sendPhoto(_ data: Data) {
        guard connectionState == .ready, activeDevice?.mode == .photo,
              photoState != .sending else { return }
        do {
            let transfer = try BLEPhotoTransfer(data: data, id: .random(in: 1...UInt32.max))
            photoTransfer = transfer
            photoState = .sending
            photoProgress = 0
            sendPhotoControl(["op": "photo_begin", "id": transfer.id,
                              "bytes": data.count, "format": BLEPhotoTransfer.format,
                              "sha256": transfer.digest])
        } catch { fail(error.localizedDescription) }
    }

    private func sendPhotoControl(_ object: [String: Any]) {
        do {
            sendPhotoMessage(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), binary: false)
        } catch { fail(error.localizedDescription) }
    }

    private func sendPhotoMessage(_ data: Data, binary: Bool) {
        pendingPhotoMessage = data
        pendingPhotoIsBinary = binary
        photoRetries = 0
        queueMessage(data, binary: binary)
        armPhotoTimeout()
    }

    private func armPhotoTimeout() {
        photoTimeoutTask?.cancel()
        photoTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, let data = self.pendingPhotoMessage,
                  self.photoTransfer != nil else { return }
            guard self.photoRetries < 2, !self.isWriteInFlight, self.pendingWrites.isEmpty else {
                self.fail(String(localized: "Transfer was not confirmed. Press PicPak's button and try again."))
                return
            }
            self.photoRetries += 1
            // Re-frame with fresh authenticated counters; never replay ciphertext.
            self.queueMessage(data, binary: self.pendingPhotoIsBinary)
            self.armPhotoTimeout()
        }
    }

    private func resetPhotoSession() {
        photoTimeoutTask?.cancel()
        screenModeTimeoutTask?.cancel()
        screenModeRequest = nil
        screenMode = nil
        isSavingScreenMode = false
        screenModeNeedsReadback = false
        screenModeError = nil
        photoAuthorized = false
        photoCharacteristic = nil
        photoTransfer = nil
        pendingPhotoMessage = nil
        photoState = .idle
        photoProgress = 0
        photoDeviceStatus = nil
    }

    private func decodeAdvertisement(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) -> NearbyTesseraeDevice? {
        guard
            let serviceData = advertisementData[CBAdvertisementDataServiceDataKey]
                as? [CBUUID: Data],
            let data = serviceData[CBUUID(string: BLESetupProtocol.serviceUUID)]
                ?? serviceData[CBUUID(string: BLESetupProtocol.photoServiceUUID)],
            let advertisement = BLESetupAdvertisement(serviceData: data)
        else { return nil }
        let photoService = serviceData[CBUUID(string: BLESetupProtocol.photoServiceUUID)] != nil
        guard (advertisement.mode == .photo) == photoService,
              !photoService || advertisement.hardware == .picPak42 else { return nil }
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
            hardware: advertisement.hardware,
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
        guard connectedPeripheral?.identifier == peripheral.identifier else {
            if connectionLifecycle.closingPeripheralID != peripheral.identifier {
                central.cancelPeripheralConnection(peripheral)
            }
            return
        }
        trace("connected id=\(peripheral.identifier)")
        statusMessage = String(localized: "Reading display information…")
        peripheral.discoverServices([CBUUID(string: activeServiceUUID)])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        trace("connect failed id=\(peripheral.identifier) error=\(describe(error))")
        finishConnection(peripheral, error: error, failedToConnect: true)
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        trace("disconnected id=\(peripheral.identifier) error=\(describe(error))")
        finishConnection(peripheral, error: error, failedToConnect: false)
    }

    private func finishConnection(
        _ peripheral: CBPeripheral,
        error: Error?,
        failedToConnect: Bool
    ) {
        switch connectionLifecycle.connectionEnded(for: peripheral.identifier) {
        case .ignored:
            return
        case let .connect(peripheralID):
            guard let pendingConnection,
                  pendingConnection.peripheral.identifier == peripheralID else { return }
            beginConnection(
                to: pendingConnection.device,
                peripheral: pendingConnection.peripheral,
                qrCode: pendingConnection.qrCode
            )
            return
        case .closed:
            break
        case .unexpected:
            let expectedDisconnect = connectionState == .configured
                || connectionState == .restarting
                || photoState == .received
            if failedToConnect || !expectedDisconnect {
                let fallback = failedToConnect
                    ? String(localized: "Could not connect to the display.")
                    : String(localized: "The display disconnected unexpectedly.")
                fail(error?.localizedDescription ?? fallback)
                return
            }
        }
        resetRefreshSpeedSetting()
        connectedPeripheral = nil
        if appIsActive { startScanning() }
    }
}

extension NearbyDeviceManager: @preconcurrency CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        trace("services discovered count=\(peripheral.services?.count ?? 0) error=\(describe(error))")
        if let error { fail(error.localizedDescription); return }
        guard let service = peripheral.services?.first(where: {
            $0.uuid == CBUUID(string: activeServiceUUID)
        }) else {
            fail(String(localized: "This display does not support nearby setup."))
            return
        }
        peripheral.discoverCharacteristics([
            CBUUID(string: BLESetupProtocol.infoUUID),
            CBUUID(string: BLESetupProtocol.qrControlUUID),
            CBUUID(string: BLESetupProtocol.passkeyControlUUID),
            CBUUID(string: BLESetupProtocol.eventsUUID),
            CBUUID(string: BLESetupProtocol.photoDataUUID),
        ], for: service)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        let uuids = (service.characteristics ?? []).map(\.uuid.uuidString).joined(separator: ",")
        trace("characteristics discovered uuids=\(uuids) error=\(describe(error))")
        if let error { fail(error.localizedDescription); return }
        for characteristic in service.characteristics ?? [] {
            switch characteristic.uuid.uuidString.uppercased() {
            case BLESetupProtocol.infoUUID: infoCharacteristic = characteristic
            case BLESetupProtocol.qrControlUUID: qrControlCharacteristic = characteristic
            case BLESetupProtocol.passkeyControlUUID: passkeyControlCharacteristic = characteristic
            case BLESetupProtocol.eventsUUID: eventsCharacteristic = characteristic
            case BLESetupProtocol.photoDataUUID: photoCharacteristic = characteristic
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
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
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
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        if let error { fail(error.localizedDescription); return }
        guard let value = characteristic.value else { return }
        if characteristic.uuid == CBUUID(string: BLESetupProtocol.infoUUID) {
            do {
                let info = try JSONDecoder().decode(BLESetupDeviceInfo.self, from: value)
                if activeDevice?.mode == .photo {
                    guard info.protocol == 2, info.mode == "photo", info.hardware == 11,
                          info.model == "picpak_4_2", photoCharacteristic != nil,
                          let device = activeDevice, info.sid == device.sessionID.hexString,
                          let key = BLEPhotoKeyStore.read(info.id) else {
                        fail(String(localized: "Authorize this iPhone in PicPak Maintenance first: hold the button for 10 seconds, release before 20, then choose Manual (Bluetooth)."))
                        return
                    }
                    qrCode = BLESetupQRCode(deviceID: info.id, sessionID: device.sessionID, secret: key)
                }
                if let qrCode {
                    let connectionNonce = try info.validate(qrCode: qrCode)
                    crypto = try BLESetupCrypto(
                        qrCode: qrCode,
                        connectionNonce: connectionNonce
                    )
                }
                deviceInfo = info
                controlCharacteristic = qrCode == nil
                    ? passkeyControlCharacteristic
                    : qrControlCharacteristic
                guard controlCharacteristic != nil else {
                    throw BLESetupProtocolError.invalidFrame
                }
                connectionState = .authenticating
                statusMessage = String(localized: "Verifying secure access…")
                if activeDevice?.mode == .photo {
                    sendCommand(["op": "photo_info"])
                } else if activeDevice?.mode == .maintenance {
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
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        isWriteInFlight = false
        if let error { fail(error.localizedDescription); pendingWrites = []; return }
        if !pendingWrites.isEmpty { pendingWrites.removeFirst() }
        writeNextFrameIfNeeded()
    }
}
