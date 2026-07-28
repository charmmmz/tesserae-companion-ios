import XCTest
@testable import TesseraeKit

final class DisplayHardwarePresentationTests: XCTestCase {
    func testHardwareCatalogKindsResolveToTheirBrandsAndModels() {
        let expected: [(String, DisplayHardwareBrand, String)] = [
            ("seeed_reterminal_e1004", .seeedStudio, "reTerminal E1004"),
            ("pimoroni_inky_4", .pimoroni, "Inky Impression 4″"),
            ("trmnl_x", .trmnl, "TRMNL X"),
            ("waveshare_photopainter_73", .waveshare, "PhotoPainter 7.3″"),
            ("picpak_4_2", .picPak, "PicPak 4.2″"),
        ]

        for (kind, brand, modelName) in expected {
            let presentation = DisplayHardwarePresentation(kind: kind)

            XCTAssertEqual(presentation.brand, brand, kind)
            XCTAssertEqual(presentation.modelName, modelName, kind)
        }
    }

    func testLegacyFixtureAliasesRemainRecognizable() {
        XCTAssertEqual(
            DisplayHardwarePresentation(kind: "reterminal_e1004"),
            DisplayHardwarePresentation(
                brand: .seeedStudio,
                modelName: "reTerminal E1004"
            )
        )
        XCTAssertEqual(
            DisplayHardwarePresentation(kind: "picpak"),
            DisplayHardwarePresentation(
                brand: .picPak,
                modelName: "PicPak 4.2″"
            )
        )
    }

    func testGenericProtocolsDoNotClaimADeviceManufacturer() {
        let kinds = [
            "circuitpython_generic",
            "esp32_client",
            "pi_bin_client",
            "pico_bin_client",
            "trmnl_client",
        ]

        for kind in kinds {
            XCTAssertNil(DisplayHardwarePresentation(kind: kind).brand, kind)
        }
    }

    func testFutureVendorSKUCanStillShowTheVendorWithoutExposingRawKind() {
        let presentation = DisplayHardwarePresentation(
            kind: "waveshare_future_panel"
        )

        XCTAssertEqual(presentation.brand, .waveshare)
        XCTAssertNil(presentation.modelName)
    }

    func testUnknownKindFallsBackWithoutInventingABrand() {
        let presentation = DisplayHardwarePresentation(kind: "custom_lab_panel")

        XCTAssertNil(presentation.brand)
        XCTAssertNil(presentation.modelName)
    }
}
