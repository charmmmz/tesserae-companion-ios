import Foundation

public enum CompanionCompatibility {
    public static let apiName = "companion"
    public static let apiVersion = 1

    /// The first upstream revision known to contain the complete v1 surface.
    /// Compatibility is still negotiated by API version and features so a
    /// backport or downstream build is not rejected solely by its app version.
    public static let firstKnownUpstreamServerVersion = "0.207.0"

    public static let requiredFeatures: Set<String> = [
        "devices",
        "dashboards",
        "dashboard_push",
        "image_push",
        "jobs",
    ]

    public static func validate(
        _ capabilities: ServerCapabilities
    ) throws {
        guard
            capabilities.product == "tesserae",
            capabilities.api.name == apiName,
            capabilities.api.version == apiVersion
        else {
            throw TesseraeClientError.incompatibleServer
        }
        guard capabilities.pairing.supported else {
            throw TesseraeClientError.pairingUnavailable
        }
        let missing = requiredFeatures.subtracting(capabilities.features)
        guard missing.isEmpty else {
            throw TesseraeClientError.missingFeatures(missing.sorted())
        }
    }
}
