import Foundation

public enum DisplayHardwareBrand: String, CaseIterable, Hashable, Sendable {
    case seeedStudio
    case pimoroni
    case trmnl
    case waveshare
    case picPak
    case xteink
    case m5stack
    case soldered
    case paperlesspaper
    case amazon
    case kobo
    case remarkable

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
        case .xteink:
            "Xteink"
        case .m5stack:
            "M5Stack"
        case .soldered:
            "Soldered Electronics"
        case .paperlesspaper:
            "paperlesspaper"
        case .amazon:
            "Amazon"
        case .kobo:
            "Kobo"
        case .remarkable:
            "reMarkable"
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
        case "seeed_reterminal_e1001_gray":
            self.init(brand: .seeedStudio, modelName: "reTerminal E1001 · 4-level grayscale")
        case "seeed_reterminal_e1001_gray_legacy":
            self.init(brand: .seeedStudio, modelName: "reTerminal E1001 · 4-level grayscale (legacy)")
        case "seeed_reterminal_e1002", "reterminal_e1002":
            self.init(brand: .seeedStudio, modelName: "reTerminal E1002")
        case "seeed_reterminal_e1003", "reterminal_e1003":
            self.init(brand: .seeedStudio, modelName: "reTerminal E1003")
        case "seeed_reterminal_e1004", "reterminal_e1004":
            self.init(brand: .seeedStudio, modelName: "reTerminal E1004")
        case "seeed_reterminal_sticky":
            self.init(brand: .seeedStudio, modelName: "reTerminal Sticky")
        case "seeed_ee02", "seeed_xiao_ee02":
            self.init(brand: .seeedStudio, modelName: "XIAO ePaper EE02")
        case "seeed_ee03":
            self.init(brand: .seeedStudio, modelName: "XIAO ePaper EE03 · 10.3″")
        case "seeed_ee04_75":
            self.init(brand: .seeedStudio, modelName: "XIAO ePaper EE04 · 7.5″")
        case "seeed_ee04_73e6":
            self.init(brand: .seeedStudio, modelName: "XIAO ePaper EE04 · 7.3″")
        case "seeed_ee05_213_bwry":
            self.init(brand: .seeedStudio, modelName: "XIAO ePaper EE05 · 2.13″ BWRY")
        case "seeed_xiao_75", "xiao_epaper_75", "xiao_epaper_display":
            self.init(brand: .seeedStudio, modelName: "XIAO 7.5″ ePaper")
        case "xiao_epaper_75_bwr":
            self.init(brand: .seeedStudio, modelName: "XIAO 7.5″ ePaper · B/W/R")
        case "xiao_epaper_panel_75_c3":
            self.init(brand: .seeedStudio, modelName: "XIAO 7.5″ ePaper · C3")
        case "pimoroni_inky_4":
            self.init(brand: .pimoroni, modelName: "Inky Impression 4″")
        case "pimoroni_inky_4_acep":
            self.init(brand: .pimoroni, modelName: "Inky Impression 4″ ACeP")
        case "pimoroni_inky_frame_73":
            self.init(brand: .pimoroni, modelName: "Inky Frame 7.3″ Spectra 6")
        case "pimoroni_inky_frame_73_acep":
            self.init(brand: .pimoroni, modelName: "Inky Frame 7.3″ ACeP")
        case "trmnl_x":
            self.init(brand: .trmnl, modelName: "TRMNL X")
        case "waveshare_photopainter_73", "photopainter_73":
            self.init(brand: .waveshare, modelName: "PhotoPainter 7.3″")
        case "waveshare_4_2_bw", "wave42_bw":
            self.init(brand: .waveshare, modelName: "4.2″ B/W e-Paper")
        case "waveshare_133e6":
            self.init(brand: .waveshare, modelName: "13.3″ Spectra E6")
        case "waveshare_1085g":
            self.init(brand: .waveshare, modelName: "10.85″ e-Paper HAT+ (G)")
        case "waveshare_esp32_driver_75":
            self.init(brand: .waveshare, modelName: "ESP32 Driver · 7.5″ B/W")
        case "picpak", "picpak_client", "picpak_4_2":
            self.init(brand: .picPak, modelName: "PicPak 4.2″")
        case "xteink_x3":
            self.init(brand: .xteink, modelName: "X3")
        case "xteink_x3_gray":
            self.init(brand: .xteink, modelName: "X3 · 4-level grayscale")
        case "xteink_x4":
            self.init(brand: .xteink, modelName: "X4")
        case "xteink_x4_gray":
            self.init(brand: .xteink, modelName: "X4 · 4-level grayscale")
        case "xteink_x4_pro":
            self.init(brand: .xteink, modelName: "X4 Pro")
        case "xteink_x4_pro_gray":
            self.init(brand: .xteink, modelName: "X4 Pro · 4-level grayscale")
        case "m5stack_m5paper":
            self.init(brand: .m5stack, modelName: "M5Paper")
        case "m5stack_papermono":
            self.init(brand: .m5stack, modelName: "PaperMono")
        case "m5stack_papers3":
            self.init(brand: .m5stack, modelName: "PaperS3")
        case "soldered_inkplate_10":
            self.init(brand: .soldered, modelName: "Inkplate 10")
        case "paperlesspaper_openpaper_7":
            self.init(brand: .paperlesspaper, modelName: "OpenPaper 7")
        case "paperlesspaper_openpaper_l":
            self.init(brand: .paperlesspaper, modelName: "OpenPaper L")
        case "kindle_basic_4":
            self.init(brand: .amazon, modelName: "Kindle · 11th gen / Basic 4")
        case "kindle_oasis_3":
            self.init(brand: .amazon, modelName: "Kindle Oasis · 3rd gen")
        case "kindle_paperwhite_2":
            self.init(brand: .amazon, modelName: "Kindle Paperwhite · 2nd gen")
        case "kindle_paperwhite_3":
            self.init(brand: .amazon, modelName: "Kindle Paperwhite 3 / 4 / Voyage")
        case "kindle_paperwhite_5":
            self.init(brand: .amazon, modelName: "Kindle Paperwhite · 5th gen")
        case "kindle_scribe":
            self.init(brand: .amazon, modelName: "Kindle Scribe")
        case "kobo_aura_edition_2":
            self.init(brand: .kobo, modelName: "Aura Edition 2 / Nia")
        case "kobo_clara_colour":
            self.init(brand: .kobo, modelName: "Clara Colour")
        case "kobo_clara_hd":
            self.init(brand: .kobo, modelName: "Clara HD / 2E")
        case "kobo_libra_2":
            self.init(brand: .kobo, modelName: "Libra 2 / H2O")
        case "kobo_libra_colour":
            self.init(brand: .kobo, modelName: "Libra Colour")
        case "kobo_sage":
            self.init(brand: .kobo, modelName: "Sage")
        case "remarkable_1":
            self.init(brand: .remarkable, modelName: "reMarkable 1")
        case "remarkable_2":
            self.init(brand: .remarkable, modelName: "reMarkable 2")
        case "remarkable_paper_pro":
            self.init(brand: .remarkable, modelName: "Paper Pro")
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
        case "koreader_client":
            self.init(brand: nil, modelName: "KOReader")
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
        if kind.hasPrefix("xteink_") {
            return .xteink
        }
        if kind.hasPrefix("m5stack_") {
            return .m5stack
        }
        if kind.hasPrefix("soldered_") {
            return .soldered
        }
        if kind.hasPrefix("paperlesspaper_") {
            return .paperlesspaper
        }
        if kind.hasPrefix("kindle_") || kind.hasPrefix("amazon_") {
            return .amazon
        }
        if kind.hasPrefix("kobo_") {
            return .kobo
        }
        if kind.hasPrefix("remarkable_") {
            return .remarkable
        }
        return nil
    }
}

public extension DisplaySummary {
    var hardwarePresentation: DisplayHardwarePresentation {
        DisplayHardwarePresentation(kind: kind)
    }
}
