import Foundation

enum NearbyDeviceSetupError: Error, LocalizedError {
    case serverUpdateRequired
    case noServer
    case invalidServerConfiguration
    case serverConnectionChanged

    var errorDescription: String? {
        switch self {
        case .serverUpdateRequired:
            "Update Tesserae Server before setting up displays over Bluetooth."
        case .noServer:
            "Connect this app to your Tesserae Server before setting up a display."
        case .invalidServerConfiguration:
            String(localized: "Enter a valid HTTP or HTTPS server URL and a six-digit device pairing code.")
        case .serverConnectionChanged:
            String(localized: "The app's server or Bluetooth connection changed. Review the destination and try again.")
        }
    }
}
