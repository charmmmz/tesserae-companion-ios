import Foundation

enum NearbyDeviceSetupError: Error, LocalizedError {
    case serverUpdateRequired
    case noServer

    var errorDescription: String? {
        switch self {
        case .serverUpdateRequired:
            "Update Tesserae Server before setting up displays over Bluetooth."
        case .noServer:
            "Connect this app to your Tesserae Server before setting up a display."
        }
    }
}
