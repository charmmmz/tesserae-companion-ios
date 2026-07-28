import Foundation

public enum DisplayHardwareBrand: String, CaseIterable, Hashable, Sendable {
    case seeedStudio
    case pimoroni
    case trmnl
    case waveshare
    case picPak

    public var displayName: String {
        switch self {
        case .seeedStudio:
            "Seeed Studio"
        case .pimoroni:
            "Pimoroni"
        case .trmnl:
            "TRMNL"
        case .waveshare:
            "Waveshare"
        case .picPak:
            "PicPak"
        }
    }
}

public struct DisplayHardwarePresentation: Equatable, Hashable, Sendable {
    public let brand: DisplayHardwareBrand?
    public let modelName: String?

    public init(brand: DisplayHardwareBrand?, modelName: String?) {
        self.brand = brand
        self.modelName = modelName
    }

    public init(kind: String) {
        let normalizedKind = kind
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        switch normalizedKind {
        case "seeed_reterminal_e1001", "reterminal_e1001":
            self.init(brand: .seeedStudio, modelName: "reTerminal E1001")
        case "seeed_reterminal_e1002", "reterminal_e1002":
            self.init(brand: .seeedStudio, modelName: "reTerminal E1002")
        case "seeed_reterminal_e1003", "reterminal_e1003":
            self.init(brand: .seeedStudio, modelName: "reTerminal E1003")
        case "seeed_reterminal_e1004", "reterminal_e1004":
            self.init(brand: .seeedStudio, modelName: "reTerminal E1004")
        case "seeed_ee02", "seeed_xiao_ee02":
            self.init(brand: .seeedStudio, modelName: "XIAO ePaper EE02")
        case "seeed_xiao_75", "xiao_epaper_75", "xiao_epaper_display":
            self.init(brand: .seeedStudio, modelName: "XIAO 7.5″ ePaper")
        case "pimoroni_inky_4":
            self.init(brand: .pimoroni, modelName: "Inky Impression 4″")
        case "pimoroni_inky_4_acep":
            self.init(brand: .pimoroni, modelName: "Inky Impression 4″ ACeP")
        case "trmnl_x":
            self.init(brand: .trmnl, modelName: "TRMNL X")
        case "waveshare_photopainter_73", "photopainter_73":
            self.init(brand: .waveshare, modelName: "PhotoPainter 7.3″")
        case "waveshare_4_2_bw", "wave42_bw":
            self.init(brand: .waveshare, modelName: "4.2″ B/W e-Paper")
        case "waveshare_133e6":
            self.init(brand: .waveshare, modelName: "13.3″ Spectra E6")
        case "picpak", "picpak_client", "picpak_4_2":
            self.init(brand: .picPak, modelName: "PicPak 4.2″")
        case "circuitpython_generic":
            self.init(brand: nil, modelName: "CircuitPython")
        case "esp32_client", "esp32_bw_client":
            self.init(brand: nil, modelName: "ESP32")
        case "opendisplay", "opendisplay_ha":
            self.init(brand: nil, modelName: "OpenDisplay")
        case "pi_bin_client", "pi_png_client":
            self.init(brand: nil, modelName: "Raspberry Pi")
        case "pico_bin_client":
            self.init(brand: nil, modelName: "Pico")
        case "trmnl_client":
            self.init(brand: nil, modelName: "TRMNL-compatible")
        default:
            self.init(
                brand: Self.brandInferred(from: normalizedKind),
                modelName: nil
            )
        }
    }

    private static func brandInferred(from kind: String) -> DisplayHardwareBrand? {
        if kind.hasPrefix("seeed_") || kind.hasPrefix("reterminal_")
            || kind.hasPrefix("xiao_")
        {
            return .seeedStudio
        }
        if kind.hasPrefix("pimoroni_") {
            return .pimoroni
        }
        if kind.hasPrefix("trmnl_") {
            return .trmnl
        }
        if kind.hasPrefix("waveshare_") {
            return .waveshare
        }
        if kind.hasPrefix("picpak_") {
            return .picPak
        }
        return nil
    }
}

public extension DisplaySummary {
    var hardwarePresentation: DisplayHardwarePresentation {
        DisplayHardwarePresentation(kind: kind)
    }
}
