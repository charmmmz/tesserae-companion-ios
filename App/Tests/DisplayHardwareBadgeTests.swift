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

@Suite("Paper palette readability")
@MainActor
struct TesseraeThemeContrastTests {
    @Test(arguments: [UIUserInterfaceStyle.light, .dark])
    func foregroundAndFilledActionsHaveReadableContrast(style: UIUserInterfaceStyle) {
        let traits = UITraitCollection(userInterfaceStyle: style)
        for background in [TesseraeTheme.background, TesseraeTheme.surface, TesseraeTheme.surfaceInset, TesseraeTheme.accentSoft] {
            #expect(contrast(TesseraeTheme.accent, background, traits: traits) >= 4.5)
        }
        #expect(contrast(.white, TesseraeTheme.accentFill, traits: traits) >= 4.5)
        #expect(contrast(TesseraeTheme.accentOnPaper, .white, traits: traits) >= 4.5)
        for status in [TesseraeTheme.success, TesseraeTheme.warning, TesseraeTheme.danger, TesseraeTheme.info] {
            #expect(contrast(status, TesseraeTheme.surface, traits: traits) >= 4.5)
        }
        for background in [TesseraeTheme.background, TesseraeTheme.surface] {
            #expect(contrast(TesseraeTheme.warning, background, traits: traits, tintOpacity: 0.09) >= 4.5)
        }
    }

    private func contrast(_ foreground: Color, _ background: Color, traits: UITraitCollection, tintOpacity: Double = 0) -> Double {
        func components(_ color: Color) -> [Double] {
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            UIColor(color).resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
            return [Double(red), Double(green), Double(blue)]
        }
        func luminance(_ rgb: [Double]) -> Double {
            func linear(_ component: Double) -> Double {
                return component <= 0.04045 ? component / 12.92 : pow((component + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(rgb[0]) + 0.7152 * linear(rgb[1]) + 0.0722 * linear(rgb[2])
        }
        let foregroundRGB = components(foreground)
        let backgroundRGB = zip(foregroundRGB, components(background)).map {
            $0 * tintOpacity + $1 * (1 - tintOpacity)
        }
        let a = luminance(foregroundRGB), b = luminance(backgroundRGB)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
