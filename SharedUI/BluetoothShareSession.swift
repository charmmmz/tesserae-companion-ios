import Observation
import Foundation
import TesseraeKit
import UIKit

/// A foreground-only session. Only the existing authenticated photo service is used.
@MainActor @Observable
final class BluetoothShareSession {
    let nearby: NearbyDeviceManager
    private(set) var selectedDevice: NearbyTesseraeDevice?
    private(set) var isPreparing = false
    private(set) var errorMessage: String?
    private var sendTask: Task<Void, Never>?

    init(nearby: NearbyDeviceManager? = nil) {
        self.nearby = nearby ?? NearbyDeviceManager(
            displayRecords: BluetoothDisplayStore(fileURL: BluetoothDisplayStore.sharedInventoryURL,
                receiptDirectoryURL: BluetoothDisplayStore.sharedReceiptDirectoryURL, isReadOnly: true), photoSharingOnly: true
        )
    }

    var devices: [NearbyTesseraeDevice] {
        var devices = nearby.nearbyDevices.filter { $0.mode == .photo }
        // An authenticated display may stop advertising while connected.
        if nearby.connectionState == .ready, let active = nearby.activeDevice,
           active.mode == .photo, !devices.contains(where: { $0.id == active.id }) {
            devices.append(active)
        }
        return devices
    }
    var isBusy: Bool {
        if case .failed = nearby.connectionState { return isPreparing }
        return isPreparing || nearby.photoState == .sending
    }
    var canSend: Bool {
        selectedDevice?.suggestionSessionKey == nearby.activeDevice?.suggestionSessionKey
            && selectedDevice != nil && nearby.connectionState == .ready
            && nearby.bluetoothUnavailableMessage == nil
            && nearby.photoState != .received && !isBusy
    }
    var panel: PanelProfile {
        nearby.photoCapabilities?.panel
            ?? PanelProfile(width: 400, height: 300, gamut: "bwry_4", orientation: "landscape")
    }
    var connectedPanel: PanelProfile? {
        guard nearby.connectionState == .ready, let selectedDevice,
              selectedDevice.id == nearby.activeDevice?.id else { return nil }
        return panel
    }
    func panel(for target: ShareDisplayTarget) -> PanelProfile? {
        if target.isBluetooth, target.nearby?.id == selectedDevice?.id,
           let connectedPanel { return connectedPanel }
        return target.panel
    }
    var failure: String? {
        if let errorMessage { return errorMessage }
        if case .failed(let message) = nearby.connectionState { return message }
        return nil
    }

    func start() { nearby.updateApplicationActivity(true) }

    func select(_ device: NearbyTesseraeDevice) {
        guard !isBusy, device.mode == .photo, nearby.bluetoothUnavailableMessage == nil else { return }
        errorMessage = nil
        selectedDevice = device
        nearby.connect(to: device, qrCode: nil)
    }

    func changeDisplay() {
        guard !isBusy else { return }
        selectedDevice = nil
        errorMessage = nil
        nearby.disconnect()
    }

    func send(image: UIImage, fit: ImageFitMode, framing: ImageFraming,
              preparationChanged: @escaping (Bool) -> Void) {
        guard canSend, let device = selectedDevice else { return }
        isPreparing = true
        preparationChanged(true)
        errorMessage = nil
        let capabilities = nearby.photoCapabilities
        sendTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.isPreparing = false
                preparationChanged(self.isBusy)
            }
            do {
                let rgba: Data
                let data: Data
                if device.photoProtocol == .tesseraeV2 {
                    guard let capabilities else { throw BLESetupProtocolError.unsupportedVersion }
                    rgba = try LocalBluetoothPhotoRenderer.raster(
                        image: image, fit: fit, framing: framing, capabilities: capabilities
                    )
                    data = try await LocalBluetoothPhotoRenderer.encode(rgba: rgba, capabilities: capabilities)
                } else {
                    rgba = try PicPakPhotoEncoder.raster(image: image, fit: fit, framing: framing)
                    let encoder = Task.detached(priority: .userInitiated) { try PicPakPhotoEncoder.encode(rgba: rgba) }
                    data = try await withTaskCancellationHandler {
                        try await encoder.value
                    } onCancel: { encoder.cancel() }
                }
                try Task.checkCancellation()
                let preview = try LocalBluetoothPhotoRenderer.previewPNG(
                    rgba: rgba, width: capabilities?.visibleWidth ?? PicPakPhotoEncoder.width,
                    height: capabilities?.visibleHeight ?? PicPakPhotoEncoder.height
                )
                try nearby.sendPhoto(data, to: device, capabilityDigest: capabilities?.digest, previewPNG: preview)
            } catch {
                if !Task.isCancelled { self.errorMessage = error.localizedDescription }
            }
        }
    }

    func stop() {
        sendTask?.cancel()
        sendTask = nil
        nearby.updateApplicationActivity(false)
        nearby.disconnect()
    }
}
