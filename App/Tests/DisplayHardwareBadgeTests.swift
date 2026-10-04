import SwiftUI
import TesseraeKit
import Testing
import UIKit
import XCTest
@testable import Tesserae_Companion

@Suite("Bundled hardware logos")
@MainActor
struct DisplayHardwareLogoTests {
    @Test(arguments: DisplayHardwareBrand.allCases, [UIUserInterfaceStyle.light, .dark])
    func brandAssetLoads(brand: DisplayHardwareBrand, style: UIUserInterfaceStyle) throws {
        let image = try #require(UIImage(
            named: brand.assetName,
            in: .main,
            compatibleWith: UITraitCollection(userInterfaceStyle: style)
        ))
        #expect(image.size.width > 0)
        #expect(image.size.height > 0)
    }
}

// These attachments exercise the actual asset catalog and SwiftUI layout for visual
// review, including narrow card columns and enlarged accessibility text.
@MainActor
final class DisplayHardwareBadgeSnapshotTests: XCTestCase {
    func testLightAndDarkHardwareBadges() throws {
        try attachBadges(scheme: .light, typeSize: .large, name: "Hardware badges — light")
        try attachBadges(scheme: .dark, typeSize: .large, name: "Hardware badges — dark")
    }

    func testHardwareBadgesWithAccessibilityText() throws {
        try attachBadges(scheme: .light, typeSize: .accessibility3, name: "Hardware badges — large text")
    }

    private func attachBadges(scheme: ColorScheme, typeSize: DynamicTypeSize, name: String) throws {
        let kinds = [
            "m5stack_papers3", "soldered_inkplate_10", "paperlesspaper_openpaper_7",
            "kindle_paperwhite_3", "kobo_clara_colour", "remarkable_paper_pro",
            "seeed_reterminal_e1001_gray_legacy", "pimoroni_inky_frame_73",
            "waveshare_1085g", "xteink_x4_pro_gray", "picpak_4_2", "trmnl_x",
            "custom_lab_panel",
        ]
        let content = VStack(alignment: .leading, spacing: 0) {
            ForEach(kinds, id: \.self) { kind in
                VStack(alignment: .leading, spacing: 8) {
                    DisplayHardwareBadge(presentation: .init(kind: kind))
                        .frame(width: 185, alignment: .leading)
                    Text(kind)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
            }
        }
        .frame(width: 330)
        .background(scheme == .dark ? Color(white: 0.08) : .white)
        .environment(\.colorScheme, scheme)
        .environment(\.dynamicTypeSize, typeSize)
        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.uiImage)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
