import Testing
@testable import TesseraeKit

struct DisplayHardwarePresentationTests {
    // All 54 hardware IDs from Tesserae v0.442.3 (22f2aeb9).
    @Test("Catalog hardware has a recognizable brand and model", arguments: [
        ("kindle_basic_4", DisplayHardwareBrand.amazon, "Kindle · 11th gen / Basic 4"),
        ("kindle_oasis_3", .amazon, "Kindle Oasis · 3rd gen"),
        ("kindle_paperwhite_2", .amazon, "Kindle Paperwhite · 2nd gen"),
        ("kindle_paperwhite_3", .amazon, "Kindle Paperwhite 3 / 4 / Voyage"),
        ("kindle_paperwhite_5", .amazon, "Kindle Paperwhite · 5th gen"),
        ("kindle_scribe", .amazon, "Kindle Scribe"),
        ("picpak_4_2", .picPak, "PicPak 4.2″"),
        ("kobo_aura_edition_2", .kobo, "Aura Edition 2 / Nia"),
        ("kobo_clara_colour", .kobo, "Clara Colour"),
        ("kobo_clara_hd", .kobo, "Clara HD / 2E"),
        ("kobo_libra_2", .kobo, "Libra 2 / H2O"),
        ("kobo_libra_colour", .kobo, "Libra Colour"),
        ("kobo_sage", .kobo, "Sage"),
        ("m5stack_m5paper", .m5stack, "M5Paper"),
        ("m5stack_papermono", .m5stack, "PaperMono"),
        ("m5stack_papers3", .m5stack, "PaperS3"),
        ("paperlesspaper_openpaper_7", .paperlesspaper, "OpenPaper 7"),
        ("paperlesspaper_openpaper_l", .paperlesspaper, "OpenPaper L"),
        ("pimoroni_inky_frame_73", .pimoroni, "Inky Frame 7.3″ Spectra 6"),
        ("pimoroni_inky_frame_73_acep", .pimoroni, "Inky Frame 7.3″ ACeP"),
        ("pimoroni_inky_4", .pimoroni, "Inky Impression 4″"),
        ("pimoroni_inky_4_acep", .pimoroni, "Inky Impression 4″ ACeP"),
        ("remarkable_paper_pro", .remarkable, "Paper Pro"),
        ("remarkable_1", .remarkable, "reMarkable 1"),
        ("remarkable_2", .remarkable, "reMarkable 2"),
        ("seeed_ee02", .seeedStudio, "XIAO ePaper EE02"),
        ("seeed_ee03", .seeedStudio, "XIAO ePaper EE03 · 10.3″"),
        ("seeed_ee04_73e6", .seeedStudio, "XIAO ePaper EE04 · 7.3″"),
        ("seeed_ee04_75", .seeedStudio, "XIAO ePaper EE04 · 7.5″"),
        ("seeed_ee05_213_bwry", .seeedStudio, "XIAO ePaper EE05 · 2.13″ BWRY"),
        ("seeed_reterminal_e1001", .seeedStudio, "reTerminal E1001"),
        ("seeed_reterminal_e1001_gray", .seeedStudio, "reTerminal E1001 · 4-level grayscale"),
        ("seeed_reterminal_e1001_gray_legacy", .seeedStudio, "reTerminal E1001 · 4-level grayscale (legacy)"),
        ("seeed_reterminal_e1002", .seeedStudio, "reTerminal E1002"),
        ("seeed_reterminal_e1003", .seeedStudio, "reTerminal E1003"),
        ("seeed_reterminal_e1004", .seeedStudio, "reTerminal E1004"),
        ("seeed_reterminal_sticky", .seeedStudio, "reTerminal Sticky"),
        ("seeed_xiao_75", .seeedStudio, "XIAO 7.5″ ePaper"),
        ("xiao_epaper_75", .seeedStudio, "XIAO 7.5″ ePaper"),
        ("xiao_epaper_75_bwr", .seeedStudio, "XIAO 7.5″ ePaper · B/W/R"),
        ("xiao_epaper_panel_75_c3", .seeedStudio, "XIAO 7.5″ ePaper · C3"),
        ("soldered_inkplate_10", .soldered, "Inkplate 10"),
        ("trmnl_x", .trmnl, "TRMNL X"),
        ("waveshare_photopainter_73", .waveshare, "PhotoPainter 7.3″"),
        ("waveshare_4_2_bw", .waveshare, "4.2″ B/W e-Paper"),
        ("waveshare_1085g", .waveshare, "10.85″ e-Paper HAT+ (G)"),
        ("waveshare_133e6", .waveshare, "13.3″ Spectra E6"),
        ("waveshare_esp32_driver_75", .waveshare, "ESP32 Driver · 7.5″ B/W"),
        ("xteink_x3", .xteink, "X3"),
        ("xteink_x3_gray", .xteink, "X3 · 4-level grayscale"),
        ("xteink_x4", .xteink, "X4"),
        ("xteink_x4_gray", .xteink, "X4 · 4-level grayscale"),
        ("xteink_x4_pro", .xteink, "X4 Pro"),
        ("xteink_x4_pro_gray", .xteink, "X4 Pro · 4-level grayscale"),
    ])
    func hardwareCatalogKindsResolveToTheirBrandsAndModels(
        kind: String,
        brand: DisplayHardwareBrand,
        modelName: String
    ) {
        let presentation = DisplayHardwarePresentation(kind: kind)

        #expect(presentation.brand == brand)
        #expect(presentation.modelName == modelName)
    }

    @Test("Previously supported aliases retain their presentation", arguments: [
        ("reterminal_e1001", DisplayHardwareBrand.seeedStudio, "reTerminal E1001"),
        ("reterminal_e1002", .seeedStudio, "reTerminal E1002"),
        ("reterminal_e1003", .seeedStudio, "reTerminal E1003"),
        ("reterminal_e1004", .seeedStudio, "reTerminal E1004"),
        ("seeed_xiao_ee02", .seeedStudio, "XIAO ePaper EE02"),
        ("xiao_epaper_display", .seeedStudio, "XIAO 7.5″ ePaper"),
        ("photopainter_73", .waveshare, "PhotoPainter 7.3″"),
        ("wave42_bw", .waveshare, "4.2″ B/W e-Paper"),
        ("picpak", .picPak, "PicPak 4.2″"),
        ("picpak_client", .picPak, "PicPak 4.2″"),
    ])
    func legacyAliasesRemainRecognizable(
        kind: String,
        brand: DisplayHardwareBrand,
        modelName: String
    ) {
        #expect(DisplayHardwarePresentation(kind: kind) == .init(brand: brand, modelName: modelName))
    }

    @Test("Generic protocols do not claim a device manufacturer", arguments: [
        ("circuitpython_generic", "CircuitPython"),
        ("esp32_client", "ESP32"),
        ("esp32_bw_client", "ESP32"),
        ("opendisplay", "OpenDisplay"),
        ("opendisplay_ha", "OpenDisplay"),
        ("pi_bin_client", "Raspberry Pi"),
        ("pi_png_client", "Raspberry Pi"),
        ("pico_bin_client", "Pico"),
        ("trmnl_client", "TRMNL-compatible"),
        ("koreader_client", "KOReader"),
    ])
    func genericProtocolsDoNotClaimADeviceManufacturer(kind: String, modelName: String) {
        let presentation = DisplayHardwarePresentation(kind: kind)

        #expect(presentation.brand == nil)
        #expect(presentation.modelName == modelName)
    }

    @Test("Future vendor SKUs show their brand without inventing a model", arguments: [
        ("seeed_future_panel", DisplayHardwareBrand.seeedStudio),
        ("reterminal_future_panel", .seeedStudio),
        ("xiao_future_panel", .seeedStudio),
        ("pimoroni_future_panel", .pimoroni),
        ("trmnl_future_panel", .trmnl),
        ("waveshare_future_panel", .waveshare),
        ("picpak_future_panel", .picPak),
        ("xteink_future_panel", .xteink),
        ("m5stack_future_panel", .m5stack),
        ("soldered_future_panel", .soldered),
        ("paperlesspaper_future_panel", .paperlesspaper),
        ("amazon_future_reader", .amazon),
        ("kindle_future_reader", .amazon),
        ("kobo_future_reader", .kobo),
        ("remarkable_future_reader", .remarkable),
    ])
    func futureVendorSKUShowsOnlyTheVendor(kind: String, brand: DisplayHardwareBrand) {
        let presentation = DisplayHardwarePresentation(kind: kind)

        #expect(presentation.brand == brand)
        #expect(presentation.modelName == nil)
    }

    @Test("Unrecognized kinds never invent hardware information", arguments: [
        "custom_lab_panel", "", "  \n", "koreader", "kindleness_reader", "kobold_reader",
    ])
    func unknownKindFallsBackWithoutInventingABrand(kind: String) {
        let presentation = DisplayHardwarePresentation(kind: kind)

        #expect(presentation.brand == nil)
        #expect(presentation.modelName == nil)
    }

    @Test("Hardware identifiers tolerate casing and surrounding whitespace", arguments: [
        ("  M5STACK_PAPERS3\n", DisplayHardwareBrand.m5stack, "PaperS3"),
        ("\tKindle_Scribe ", .amazon, "Kindle Scribe"),
        (" REMARKABLE_2 ", .remarkable, "reMarkable 2"),
    ])
    func hardwareKindsAreNormalized(kind: String, brand: DisplayHardwareBrand, modelName: String) {
        #expect(DisplayHardwarePresentation(kind: kind) == .init(brand: brand, modelName: modelName))
    }

    @Test("New brands use their public names", arguments: [
        (DisplayHardwareBrand.m5stack, "M5Stack"),
        (.soldered, "Soldered Electronics"),
        (.paperlesspaper, "paperlesspaper"),
        (.amazon, "Amazon"),
        (.kobo, "Kobo"),
        (.remarkable, "reMarkable"),
    ])
    func newBrandDisplayNames(brand: DisplayHardwareBrand, name: String) {
        #expect(brand.displayName == name)
    }
}
