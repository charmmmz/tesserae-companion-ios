@preconcurrency import CoreBluetooth
import Foundation
import Observation
import OSLog
import TesseraeKit

enum NearbyDeviceMode: String, Sendable {
    case setup
    case maintenance
    case photo
}

enum NearbyPhotoProtocol: Equatable, Sendable {
    case picPakV1, tesseraeV2
}

struct NearbyTesseraeDevice: Identifiable, Equatable, Sendable {
    let id: UUID
    let name: String
    let rssi: Int
    let mode: NearbyDeviceMode
    let hardware: BLESetupHardware
    let hardwareSuffix: String
    let sessionID: Data
    var photoProtocol: NearbyPhotoProtocol = .picPakV1

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
    let screenModeUnavailable: Bool
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
        if let flag = event["screen_mode_error"] as? NSNumber,
           CFGetTypeID(flag) == CFBooleanGetTypeID() {
            screenModeUnavailable = flag.boolValue
        } else {
            screenModeUnavailable = false
        }
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
    let displayRecords: BluetoothDisplayStore
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
    private(set) var photoCapabilities: BluetoothPhotoCapabilities?
    private(set) var isLoadingPhotoCapabilities = false

    var resolvedHardware: BLESetupHardware? { deviceInfo?.resolvedHardware }

    func hardwarePresentation(for device: NearbyTesseraeDevice) -> DisplayHardwarePresentation {
        if activeDevice?.suggestionSessionKey == device.suggestionSessionKey, let info = deviceInfo {
            return DisplayHardwarePresentation(kind: info.model)
        }
        if device.mode == .photo, device.photoProtocol == .picPakV1,
           device.hardware == .picPak42 {
            return DisplayHardwarePresentation(kind: BLESetupHardware.picPak42.catalogKind)
        }
        let hint = displayRecords.hardwareHint(code: device.hardware.rawValue, suffix: device.hardwareSuffix)
        return DisplayHardwarePresentation(kind: (hint ?? device.hardware).catalogKind)
    }
    var supportsScreenMode: Bool {
        activeDevice?.mode == .maintenance
            && (resolvedHardware == .picPak42
                || (deviceInfo?.photo == 2 && deviceInfo?.family == "tesserae"))
    }

    var screenModeUnavailable: Bool {
        supportsScreenMode && deviceInfo?.photo == 2 && deviceInfo?.family == "tesserae"
            && screenMode == nil && diagnostics?.screenModeUnavailable == true
    }

    private var hasPhotoDataChannel: Bool {
#if DEBUG
        if isSetupUIFixture { return true }
#endif
        return photoCharacteristic != nil
    }

    private var photoKeyAccount: String? {
        deviceInfo.map { $0.photo == 2 ? "tesserae-photo-v2:\($0.id)" : $0.id }
    }
    private var screenModeRequest: UInt32?
    private var screenModeTimeoutTask: Task<Void, Never>?
    private var photoTimeoutTask: Task<Void, Never>?
    private var photoTransfer: BLEPhotoTransfer?
    private var pendingPhotoPreview: Data?
    private var photoTransportCapabilities: BLEPhotoTransportCapabilities?
    private var isResynchronizingPhoto = false
    private var photoStatusRequest: UInt32 = 0
    private var photoTransferStartedAt: TimeInterval?
    private var photoRetryCount = 0
    private let photoLogger = Logger(subsystem: "com.charmmmz.tesseraecompanion", category: "BluetoothPhoto")
    private var pendingPhotoMessage: Data?
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
    private var writeQueue = BLEWriteQueue<CBCharacteristic>()
    private var connectionLifecycle = NearbyConnectionLifecycle()
    private var pendingConnection: PendingConnection?
    private var appIsActive = false
    private var refreshSpeedTimeoutTask: Task<Void, Never>?
#if DEBUG
    private var fixturePhotoReceivedOffset = 0
    private var fixturePhotoPacketOffsets: Set<UInt32> = []
    private var fixtureWriteTail: Task<Void, Never>?
    private var fixtureWriteGeneration = 0
    private let isFastPhotoUIFixture = ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_FAST_PHOTO"] == "1"
    private let isUnifiedUIFixture = ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_UNIFIED_BLE"] == "1"
    private let isPhotoUIFixture = ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_PICPAK_PHOTO"] == "1"
        || ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_UNIFIED_PHOTO"] == "1"
    private let isPicPakUIFixture = ProcessInfo.processInfo.environment[
        "TESSERAE_UI_TEST_PICPAK_BLE"
    ] == "1"
    private let hasSavedPhotoUIFixture = ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_SAVED_BLUETOOTH_PHOTO"] == "1"
    private let isE1003UIFixture = ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_E1003_BLE"] == "1"
    private var isSetupUIFixture: Bool {
        isPicPakUIFixture || isE1003UIFixture || isUnifiedUIFixture
    }
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

    init(displayRecords: BluetoothDisplayStore = BluetoothDisplayStore()) {
        self.displayRecords = displayRecords
        super.init()
#if DEBUG
        if isSetupUIFixture {
            nearbyDevices = [NearbyTesseraeDevice(
                id: UUID(uuidString: "00000000-0000-0000-0000-000000000011")!,
                name: "Tesserae-A1B2C3", rssi: -45, mode: isPhotoUIFixture ? .photo : .maintenance,
                hardware: isE1003UIFixture ? .seeedReTerminalE1003
                    : isUnifiedUIFixture ? .seeedReTerminalE1004
                    : .picPak42, hardwareSuffix: "A1B2C3",
                sessionID: Data([1, 2, 3, 4]),
                photoProtocol: isUnifiedUIFixture ? .tesseraeV2 : .picPakV1
            )]
            if hasSavedPhotoUIFixture {
                displayRecords.observe(deviceID: "picpak-f85b1ba1b2c3", name: "Kitchen",
                                       mode: .bluetooth, batteryMillivolts: 3900)
                let png = try! LocalBluetoothPhotoRenderer.previewPNG(
                    rgba: Data([200, 70, 90, 255]), width: 1, height: 1)
                displayRecords.receivedPhoto(deviceID: "picpak-f85b1ba1b2c3", previewPNG: png)
            }
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
        if isSetupUIFixture {
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
            withServices: [CBUUID(string: BLESetupProtocol.serviceUUID),
                           CBUUID(string: BLESetupProtocol.photoServiceUUID),
                           CBUUID(string: BLESetupProtocol.unifiedPhotoServiceUUID)],
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
        if isSetupUIFixture {
            resetConnectionState()
            activeDevice = device
            deviceInfo = BLESetupDeviceInfo(
                protocol: 2, id: "picpak-f85b1ba1b2c3", sid: "01020304",
                connectionNonce: "000102030405060708090a0b0c0d0e0f",
                hardware: device.hardware.rawValue,
                model: isE1003UIFixture ? "seeed_reterminal_e1003"
                    : isUnifiedUIFixture ? "seeed_reterminal_e1004" : "picpak_4_2",
                firmware: isUnifiedUIFixture ? "1.52.0" : isE1003UIFixture ? "1.47.0" : "0.9.3",
                mode: device.mode.rawValue, photo: isUnifiedUIFixture ? 2 : nil,
                family: isUnifiedUIFixture ? "tesserae" : nil,
                kind: isUnifiedUIFixture ? device.hardware.catalogKind : nil
            )
            connectionState = .authenticating
            if device.mode == .photo {
                let delay = Int(ProcessInfo.processInfo.environment[
                    "TESSERAE_UI_TEST_PICPAK_CONNECTION_DELAY_MS"
                ] ?? "0") ?? 0
                photoTimeoutTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .milliseconds(min(max(delay, 0), 10_000)))
                    guard !Task.isCancelled else { return }
                    self?.isLoadingPhotoCapabilities = self?.isUnifiedUIFixture == true
                    self?.sendCommand(["op": self?.isUnifiedUIFixture == true ? "photo_capabilities" : "photo_info"])
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
                self.fail(device.photoProtocol == .tesseraeV2
                    ? String(localized: "Could not connect. Press the display's button and try again.")
                    : String(localized: "Could not connect. Press PicPak's button and try again."))
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
        sendCommand(BLESetupConfiguration(
            ssid: ssid, password: password,
            serverURL: serverURL, pairingCode: pairingCode
        ).stageCommand)
    }

    func requestDiagnostics() {
        sendCommand(["op": "diagnostics"])
    }

    func setRefreshSpeed(_ value: BLERefreshSpeed) {
        guard resolvedHardware == .picPak42,
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
        writeQueue = BLEWriteQueue()
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
        if isSetupUIFixture {
            receiveSetupFixtureCommand(object)
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
        if isSetupUIFixture {
            // ATT delivers writes in order. Independent sleeping tasks can
            // resume out of order and manufacture gaps that no radio sent.
            let previous = fixtureWriteTail
            let generation = fixtureWriteGeneration
            fixtureWriteTail = Task { @MainActor [weak self] in
                await previous?.value
                try? await Task.sleep(for: .milliseconds(
                    self?.isUnifiedUIFixture == true || self?.isFastPhotoUIFixture == true ? 1 : 15))
                guard !Task.isCancelled, let self, self.activeDevice != nil,
                      self.fixtureWriteGeneration == generation else { return }
                if binary, message.count > 8 {
                    let id = message.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    let offset = message.dropFirst(4).prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                    if self.isUnifiedUIFixture || self.isFastPhotoUIFixture {
                        let firstReceipt = self.fixturePhotoPacketOffsets.insert(offset).inserted
                        if self.isFastPhotoUIFixture,
                           ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_DROP_PHOTO_PACKET"] == "1",
                           firstReceipt, Int(offset) == self.photoTransfer?.packetBytes { return }
                        if Int(offset) == self.fixturePhotoReceivedOffset {
                            self.fixturePhotoReceivedOffset += message.count - 8
                        }
                        if ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_DROP_PHOTO_ACKS"] == "1",
                           firstReceipt, self.fixturePhotoReceivedOffset <= 4 * (self.photoTransfer?.packetBytes ?? 384) {
                            return // Simulate all ACKs lost for the first window.
                        }
                        self.receiveFixtureEvent(["event": "photo_ack", "id": id,
                                                  "offset": self.fixturePhotoReceivedOffset])
                    } else {
                        self.receiveFixtureEvent(["event": "photo_ack", "id": id, "offset": Int(offset) + message.count - 8])
                    }
                } else if let object = try? JSONSerialization.jsonObject(with: message) as? [String: Any] {
                    self.receiveSetupFixtureCommand(object)
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
            let withoutResponse = binary && photoTransfer?.transport.usesWriteWithoutResponse == true
            let maximumWrite = peripheral.maximumWriteValueLength(for: withoutResponse ? .withoutResponse : .withResponse)
            guard maximumWrite > overhead else { throw BLESetupProtocolError.invalidFrame }
            let payloadLimit = maximumWrite - overhead
            let count = max(1, (message.count + payloadLimit - 1) / payloadLimit)
            guard count <= Int(UInt8.max) else { throw BLESetupProtocolError.messageTooLarge }
            guard !withoutResponse || count == 1 else { throw BLESetupProtocolError.messageTooLarge }
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
                writeQueue.append(frame, to: characteristic, withoutResponse: withoutResponse)
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
    private func receiveSetupFixtureCommand(_ command: [String: Any]) {
        switch command["op"] as? String {
        case "diagnostics":
            var event: [String: Any] = [
                "event": "diagnostics", "firmware": deviceInfo?.firmware ?? "0.9.3",
                "model": deviceInfo?.model ?? "picpak_4_2", "battery_mv": 3900,
                "wifi_configured": true, "server_configured": true,
                "ssid": "Home Wi-Fi",
            ]
            if isPicPakUIFixture { event["refresh_speed"] = "5s" }
            if isUnifiedUIFixture,
               ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_CORRUPT_PHOTO_MODE"] == "1",
               screenMode == nil {
                event["screen_mode_error"] = true
            } else if isUnifiedUIFixture || !isE1003UIFixture {
                event["screen_mode"] = screenMode?.rawValue ?? (hasSavedPhotoUIFixture ? "bluetooth" : "wifi")
            }
            if let data = try? JSONSerialization.data(withJSONObject: event) {
                try? handleEvent(data)
            }
        case "scan":
            receiveFixtureEvent(["event": "network", "ssid": "Home Wi-Fi", "rssi": -45, "secure": true])
            receiveFixtureEvent(["event": "scan_complete"])
        case "stage":
            guard let server = command["server_url"] as? String else { return }
            let preservesServer = command["preserve_server"] as? Bool == true
            let validChange = !preservesServer && BLESetupConfiguration.serverURL(from: server) != nil
                && BLESetupConfiguration.isValidPairingCode(command["pairing_code"] as? String ?? "")
            receiveFixtureEvent(validChange || (preservesServer && server.isEmpty)
                ? ["event": "staged"]
                : ["event": "error", "message": "Invalid fixture configuration"])
        case "apply":
            receiveFixtureEvent(["event": "configured"])
        case "set_screen_mode":
            receiveFixtureEvent(["event": "screen_mode", "value": command["value"] ?? "wifi",
                                 "request": command["request"] ?? 0,
                                 "photo_key": Data(repeating: 0x5a, count: 32).base64EncodedString()])
        case "photo_info":
            var info: [String: Any] = ["event": "photo_info", "version": 1, "width": 400, "height": 300,
                                 "bytes": 30000, "chunk_bytes": 192, "format": BLEPhotoTransfer.format,
                                 "battery_mv": 3900, "low_battery": false,
                                 "refresh_speed": "5s", "screen_mode": "bluetooth"]
            if isFastPhotoUIFixture {
                info["max_window"] = 4
                info["write_without_response"] = true
            }
            receiveFixtureEvent(info)
        case "photo_capabilities" where isUnifiedUIFixture:
            let width = isE1003UIFixture ? 1872 : 1200
            let height = isE1003UIFixture ? 1404 : 1600
            receiveFixtureEvent(["event": "photo_capabilities", "schema": 2,
                "kind": deviceInfo?.kind ?? "", "width": width, "height": height,
                "visible_width": width, "visible_height": height, "x_offset": 0,
                "format": isE1003UIFixture ? "gray4-msb" : "spectra6-msb",
                "stride": width / 2, "bytes": width * height / 2, "chunk_bytes": 384, "max_window": 4,
                "digest": String(repeating: "a", count: 64), "row_order": "top_down", "lifecycle": "manual"])
        case "photo_begin":
            fixturePhotoReceivedOffset = 0
            fixturePhotoPacketOffsets = []
            receiveFixtureEvent(["event": "photo_ack", "id": command["id"] ?? 0, "offset": 0])
        case "photo_status":
            receiveFixtureEvent(["event": "photo_status", "id": command["id"] ?? 0,
                                 "request": command["request"] ?? 0, "offset": fixturePhotoReceivedOffset])
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
        guard let peripheral = connectedPeripheral else { return }
        while let next = writeQueue.next(canSendWithoutResponse: peripheral.canSendWriteWithoutResponse) {
            peripheral.writeValue(next.data, for: next.destination,
                                  type: next.withoutResponse ? .withoutResponse : .withResponse)
        }
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
            statusMessage = resolvedHardware == .picPak42
                ? String(localized: "Wi-Fi connected. Saving settings…")
                : String(localized: "Wi-Fi connected. Checking server…")
        case "testing_server":
            connectionState = .testingServer
            statusMessage = String(localized: "Checking Tesserae server…")
        case "server_connected":
            statusMessage = String(localized: "Server verified. Saving configuration…")
        case "configured":
            connectionState = .configured
            statusMessage = resolvedHardware == .picPak42
                ? String(localized: "Wi-Fi saved. Display is restarting…")
                : String(localized: "Display configured. It is restarting now.")
        case "diagnostics":
            diagnostics = NearbyDeviceDiagnostics(event: object)
            screenMode = diagnostics?.screenMode
            rememberDisplayStatus(mode: screenMode, batteryMillivolts: diagnostics?.batteryMillivolts)
            screenModeNeedsReadback = false
            photoAuthorized = photoKeyAccount.map { BLEPhotoKeyStore.read($0) != nil } ?? false
            refreshSpeedSetting.receiveDiagnostics(
                diagnostics?.refreshSpeed,
                hardware: resolvedHardware
            )
            if connectionState == .authenticating {
                connectionState = .ready
            }
            statusMessage = nil
        case "photo_capabilities":
            guard isLoadingPhotoCapabilities, deviceInfo?.photo == 2,
                  activeDevice?.photoProtocol == .tesseraeV2,
                  activeDevice?.mode == .photo, hasPhotoDataChannel else {
                throw BLESetupProtocolError.invalidFrame
            }
            let data = try JSONSerialization.data(withJSONObject: object)
            let capabilities = try JSONDecoder().decode(BluetoothPhotoCapabilities.self, from: data)
            try capabilities.validate()
            guard capabilities.kind == deviceInfo?.kind else { throw BLESetupProtocolError.unexpectedDevice }
            // The device's format declaration is authoritative, never its BLE number.
            photoCapabilities = capabilities
            rememberDisplayStatus(mode: .bluetooth)
            photoTransportCapabilities = try JSONDecoder().decode(BLEPhotoTransportCapabilities.self, from: data)
            isLoadingPhotoCapabilities = false
            photoTimeoutTask?.cancel()
            connectionState = .ready
            statusMessage = nil
        case "screen_mode":
            guard let request = object["request"] as? UInt32,
                  request == screenModeRequest,
                  let mode = (object["value"] as? String).flatMap(BLEScreenMode.init),
                  let id = photoKeyAccount else { return }
            screenModeTimeoutTask?.cancel()
            screenModeRequest = nil
            isSavingScreenMode = false
            screenMode = mode
            rememberDisplayStatus(mode: mode)
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
                screenModeError = String(localized: "Mode saved, but this device could not be authorized. Try Allow This Device again.")
            }
        case "photo_info":
            guard activeDevice?.mode == .photo,
                  activeDevice?.photoProtocol == .picPakV1,
                  object["version"] as? Int == 1,
                  object["width"] as? Int == 400, object["height"] as? Int == 300,
                  object["bytes"] as? Int == BLEPhotoTransfer.byteCount,
                  object["format"] as? String == BLEPhotoTransfer.format,
                  object["chunk_bytes"] as? Int == BLEPhotoTransfer.chunkBytes else {
                throw BLESetupProtocolError.invalidFrame
            }
            photoTransportCapabilities = try JSONDecoder().decode(BLEPhotoTransportCapabilities.self,
                from: JSONSerialization.data(withJSONObject: object))
            photoDeviceStatus = BLEPhotoDeviceStatus(event: object)
            rememberDisplayStatus(mode: photoDeviceStatus?.screenMode, batteryMillivolts: photoDeviceStatus?.batteryMillivolts)
            photoTimeoutTask?.cancel()
            connectionState = .ready
            statusMessage = nil
        case "photo_ack":
            guard var transfer = photoTransfer,
                  object["id"] as? UInt32 == transfer.id,
                  let offset = object["offset"] as? Int,
                  try transfer.acknowledge(offset) else { return }
            photoProgress = Double(offset) / Double(transfer.data.count)
            photoRetries = 0
            if isResynchronizingPhoto {
                // Earlier notifications may arrive before the status barrier.
                // Accept progress but do not open another window until it replies.
                photoTransfer = transfer
                return
            }
            photoTimeoutTask?.cancel()
            let packets = transfer.nextPackets()
            photoTransfer = transfer
            pendingPhotoMessage = nil
            if transfer.waitingForReceipt {
                sendPhotoControl(["op": "photo_end", "id": transfer.id])
            } else {
                for packet in packets { queueMessage(packet, binary: true) }
                armPhotoTimeout()
            }
        case "photo_status":
            guard isResynchronizingPhoto, var transfer = photoTransfer,
                  object["id"] as? UInt32 == transfer.id,
                  object["request"] as? UInt32 == photoStatusRequest,
                  let offset = object["offset"] as? Int else { return }
            let advanced = offset > transfer.offset
            try transfer.resynchronize(offset)
            isResynchronizingPhoto = false
            photoTimeoutTask?.cancel()
            photoProgress = Double(offset) / Double(transfer.data.count)
            if advanced { photoRetries = 0 }
            let packets = transfer.nextPackets()
            photoTransfer = transfer
            if transfer.waitingForReceipt {
                sendPhotoControl(["op": "photo_end", "id": transfer.id])
            } else {
                for packet in packets { queueMessage(packet, binary: true) }
                armPhotoTimeout()
            }
        case "photo_received":
            guard let transfer = photoTransfer, transfer.waitingForReceipt,
                  object["id"] as? UInt32 == transfer.id else { return }
            photoTimeoutTask?.cancel()
            if let deviceID = deviceInfo?.id, let pendingPhotoPreview {
                displayRecords.receivedPhoto(deviceID: deviceID, previewPNG: pendingPhotoPreview)
            }
            pendingPhotoPreview = nil
            if let startedAt = photoTransferStartedAt {
                let seconds = ProcessInfo.processInfo.systemUptime - startedAt
                let bytesPerSecond = Double(transfer.data.count) / max(seconds, 0.001)
                photoLogger.notice("Photo verified: bytes=\(transfer.data.count) seconds=\(seconds) bytes_per_second=\(bytesPerSecond) retries=\(self.photoRetryCount)")
            }
            photoTransfer = nil
            isResynchronizingPhoto = false
            photoTransferStartedAt = nil
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
            if let deviceID = deviceInfo?.id { displayRecords.remove(deviceID: deviceID) }
            if let id = photoKeyAccount { BLEPhotoKeyStore.remove(id) }
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
        pendingPhotoPreview = nil
        resetRefreshSpeedSetting()
        photoTimeoutTask?.cancel()
        screenModeTimeoutTask?.cancel()
        isSavingScreenMode = false
        photoCharacteristic = nil
        photoTransfer = nil
        photoTransportCapabilities = nil
        isResynchronizingPhoto = false
        photoTransferStartedAt = nil
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
        writeQueue = BLEWriteQueue()
        pendingConnection = nil
        connectionState = .failed(message)
        statusMessage = message
        if let peripheral, peripheral.identifier == closingID {
            central.cancelPeripheralConnection(peripheral)
        }
        if appIsActive { startScanning() }
    }

    private var activeServiceUUID: String {
        guard activeDevice?.mode == .photo else { return BLESetupProtocol.serviceUUID }
        return activeDevice?.photoProtocol == .tesseraeV2
            ? BLESetupProtocol.unifiedPhotoServiceUUID : BLESetupProtocol.photoServiceUUID
    }

    func setScreenMode(_ mode: BLEScreenMode) {
        guard supportsScreenMode,
              (screenMode != nil || (screenModeUnavailable && mode == .wifi)), connectionState == .ready,
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

    private func rememberDisplayStatus(mode: BLEScreenMode?, batteryMillivolts: Int? = nil) {
        guard let info = deviceInfo else { return }
        displayRecords.observe(deviceID: info.id, name: activeDevice?.name ?? info.model,
                               mode: mode, batteryMillivolts: batteryMillivolts,
                               hardwareMAC: info.hardwareMAC, hardwareKind: info.model)
    }

    func sendPhoto(_ data: Data, to device: NearbyTesseraeDevice, capabilityDigest: String?, previewPNG: Data? = nil) throws {
        guard connectionState == .ready, activeDevice?.mode == .photo,
              hasPhotoDataChannel,
              photoState != .sending,
              activeDevice?.suggestionSessionKey == device.suggestionSessionKey,
              activeDevice?.photoProtocol == device.photoProtocol,
              (device.photoProtocol == .tesseraeV2) == (photoCapabilities != nil),
              capabilityDigest == photoCapabilities?.digest else {
            throw BLESetupProtocolError.unexpectedDevice
        }
        guard let transportCapabilities = photoTransportCapabilities else {
            throw BLESetupProtocolError.invalidFrame
        }
        var maximumWriteWithoutResponse = connectedPeripheral?.maximumWriteValueLength(for: .withoutResponse) ?? 0
        var allowsWriteWithoutResponse = photoCharacteristic?.properties.contains(.writeWithoutResponse) == true
#if DEBUG
        if isSetupUIFixture {
            maximumWriteWithoutResponse = Int(ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_PHOTO_MAX_WRITE"] ?? "") ?? 253
            allowsWriteWithoutResponse = true
        }
#endif
        let transport = try transportCapabilities.negotiate(
            maximumWriteWithoutResponse: maximumWriteWithoutResponse,
            characteristicAllowsWriteWithoutResponse: allowsWriteWithoutResponse)
        let transfer = try BLEPhotoTransfer(data: data, id: .random(in: 1...UInt32.max),
                                           capabilities: photoCapabilities, transport: transport)
        photoTransfer = transfer
        pendingPhotoPreview = previewPNG
        isResynchronizingPhoto = false
        photoTransferStartedAt = ProcessInfo.processInfo.systemUptime
        photoRetryCount = 0
        photoLogger.notice("Photo transport: max_write=\(maximumWriteWithoutResponse) pixels_per_packet=\(transport.packetBytes) window=\(transport.windowSize) without_response=\(transport.usesWriteWithoutResponse)")
        photoState = .sending
        photoProgress = 0
        var command: [String: Any] = ["op": "photo_begin", "id": transfer.id,
            "bytes": data.count, "format": photoCapabilities?.format.rawValue ?? BLEPhotoTransfer.format,
            "sha256": transfer.digest]
        if let photoCapabilities {
            command["schema"] = 2
            command["capability_digest"] = photoCapabilities.digest
        }
        sendPhotoControl(command)
    }

    private func sendPhotoControl(_ object: [String: Any]) {
        do {
            sendPhotoMessage(try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), binary: false)
        } catch { fail(error.localizedDescription) }
    }

    private func sendPhotoMessage(_ data: Data, binary: Bool) {
        pendingPhotoMessage = data
        photoRetries = 0
        queueMessage(data, binary: binary)
        armPhotoTimeout()
    }

    private func armPhotoTimeout() {
        photoTimeoutTask?.cancel()
        photoTimeoutTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self, let transfer = self.photoTransfer else { return }
            let control = self.pendingPhotoMessage
            let resynchronize = control == nil && transfer.transport.usesWriteWithoutResponse
            let retry = control ?? transfer.retryPackets().first
            guard retry != nil || (resynchronize && self.isResynchronizingPhoto) else { return }
            guard self.photoRetries < 2, self.writeQueue.isDrained else {
                self.fail(self.photoCapabilities == nil
                    ? String(localized: "Transfer was not confirmed. Press PicPak's button and try again.")
                    : String(localized: "Transfer was not confirmed. Press the display's button and try again."))
                return
            }
            self.photoRetries += 1
            self.photoRetryCount += 1
            if resynchronize {
                // A queued status command is a device-side drain barrier. Only
                // after its reply is it safe to rewind and resend a whole window.
                self.isResynchronizingPhoto = true
                self.photoStatusRequest &+= 1
                if self.photoStatusRequest == 0 { self.photoStatusRequest = 1 }
                do {
                    let status = try JSONSerialization.data(withJSONObject: ["op": "photo_status",
                        "id": transfer.id, "request": self.photoStatusRequest])
                    self.queueMessage(status, binary: false)
                } catch {
                    self.fail(error.localizedDescription)
                    return
                }
            } else if let retry {
                // Old firmware: probe with the oldest packet for a cumulative
                // ACK. Never blindly replay a window alongside a late refill.
                self.queueMessage(retry, binary: control == nil)
            }
            // Re-frame with fresh authenticated counters; never replay ciphertext.
            self.armPhotoTimeout()
        }
    }

    private func resetPhotoSession() {
        pendingPhotoPreview = nil
#if DEBUG
        fixtureWriteGeneration &+= 1
        fixtureWriteTail?.cancel()
        fixtureWriteTail = nil
#endif
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
        photoTransportCapabilities = nil
        isResynchronizingPhoto = false
        photoTransferStartedAt = nil
        photoRetryCount = 0
        pendingPhotoMessage = nil
        photoState = .idle
        photoProgress = 0
        photoDeviceStatus = nil
        photoCapabilities = nil
        isLoadingPhotoCapabilities = false
    }

    static func decodeAdvertisement(
        id: UUID,
        advertisementData: [String: Any],
        rssi: Int
    ) -> NearbyTesseraeDevice? {
        guard
            let serviceData = advertisementData[CBAdvertisementDataServiceDataKey]
                as? [CBUUID: Data],
            let data = serviceData[CBUUID(string: BLESetupProtocol.serviceUUID)]
                ?? serviceData[CBUUID(string: BLESetupProtocol.photoServiceUUID)]
                ?? serviceData[CBUUID(string: BLESetupProtocol.unifiedPhotoServiceUUID)],
            let advertisement = BLESetupAdvertisement(serviceData: data)
        else { return nil }
        let legacyPhoto = serviceData[CBUUID(string: BLESetupProtocol.photoServiceUUID)] != nil
        let unifiedPhoto = serviceData[CBUUID(string: BLESetupProtocol.unifiedPhotoServiceUUID)] != nil
        guard (advertisement.mode == .photo) == (legacyPhoto || unifiedPhoto),
              !legacyPhoto || advertisement.hardware == .picPak42 else { return nil }
        let suffix = advertisement.hardwareSuffix
        let advertisedName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        let displayName = advertisedName?.hasPrefix("Tes-") == true
            ? "Tesserae-\(suffix)"
            : advertisedName ?? "Tesserae-\(suffix)"
        return NearbyTesseraeDevice(
            id: id,
            name: displayName,
            rssi: rssi,
            mode: advertisement.mode,
            // Preserve the advertised wire code for the subsequent device-info check.
            hardware: advertisement.hardware,
            hardwareSuffix: suffix,
            sessionID: advertisement.sessionID,
            photoProtocol: unifiedPhoto ? .tesseraeV2 : .picPakV1
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
        guard let device = Self.decodeAdvertisement(
            id: peripheral.identifier,
            advertisementData: advertisementData,
            rssi: RSSI.intValue
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
                guard let device = activeDevice,
                      info.protocol == 2, info.hardware == device.hardware.rawValue,
                      info.mode == device.mode.rawValue,
                      info.sid.lowercased() == device.sessionID.hexString else {
                    throw BLESetupProtocolError.unexpectedDevice
                }
                if activeDevice?.mode == .photo {
                    let unified = device.photoProtocol == .tesseraeV2
                    let validIdentity = unified
                        ? info.photo == 2 && info.family == "tesserae" && !(info.kind?.isEmpty ?? true)
                        : info.resolvedHardware == .picPak42
                    let account = unified ? "tesserae-photo-v2:\(info.id)" : info.id
                    guard validIdentity, photoCharacteristic != nil,
                          let key = BLEPhotoKeyStore.read(account) else {
                        fail(unified
                            ? String(localized: "Authorize this phone in Bluetooth Maintenance first, then choose Manual (Bluetooth).")
                            : String(localized: "Authorize this device in PicPak Maintenance first: hold the button for 10 seconds, release before 20, then choose Manual (Bluetooth)."))
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
                    isLoadingPhotoCapabilities = device.photoProtocol == .tesseraeV2
                    sendCommand(["op": isLoadingPhotoCapabilities ? "photo_capabilities" : "photo_info"])
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
        guard connectedPeripheral?.identifier == peripheral.identifier,
              writeQueue.inFlight?.destination === characteristic else { return }
        if let error { fail(error.localizedDescription); return }
        writeQueue.completeResponse()
        writeNextFrameIfNeeded()
    }

    func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
        guard connectedPeripheral?.identifier == peripheral.identifier else { return }
        writeNextFrameIfNeeded()
    }
}
