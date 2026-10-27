import SwiftUI
import TesseraeKit
import UIKit

struct DisplayHardwareBadge: View {
    let presentation: DisplayHardwarePresentation
    var fallbackModelName = String(localized: "Custom display")
    @Environment(\.colorScheme) private var colorScheme
    @ScaledMetric(relativeTo: .caption) private var logoHeight: CGFloat = 20

    private var logoScale: CGFloat { logoHeight / 20 }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 4) {
                logo
                modelLabel.fixedSize()
            }

            VStack(alignment: .leading, spacing: 3) {
                logo
                modelLabel.fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(
            "display-hardware-\(presentation.brand?.rawValue ?? "generic")"
        )
    }

    @ViewBuilder
    private var logo: some View {
        if let brand = presentation.brand {
            brandLogo(brand)
        } else {
            genericLogo
        }
    }

    private var modelLabel: some View {
        Text(presentation.modelName ?? fallbackModelName)
            .font(.caption.weight(.medium))
            .foregroundStyle(.secondary)
    }

    private func brandLogo(_ brand: DisplayHardwareBrand) -> some View {
        let width = brand.logoWidth * logoScale
        let insets = DisplayHardwareLogoInsets.resolve(brand: brand, scheme: colorScheme)
        return DisplayHardwareLogoLayout(canvas: CGSize(width: width, height: logoHeight),
            leading: insets.leading * logoScale, trailing: insets.trailing * logoScale) {
                Image(brand.assetName)
                    .resizable()
                    .renderingMode(brand.renderingMode(for: colorScheme))
                    .foregroundStyle(brand.foregroundColor(for: colorScheme))
                    .aspectRatio(contentMode: brand.contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: brand.logoAlignment)
                    .clipped()
            }
            .clipped()
            .accessibilityLabel(brand.displayName)
            .accessibilityIdentifier("display-brand-\(brand.rawValue)")
    }

    private var genericLogo: some View {
        Image(systemName: "display")
            .font(.caption.weight(.semibold))
            .foregroundStyle(TesseraeTheme.accent)
            .frame(width: 28 * logoScale, height: 26 * logoScale)
            .background(
                TesseraeTheme.accentSoft,
                in: RoundedRectangle(cornerRadius: 6 * logoScale, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        [
            presentation.brand?.displayName,
            presentation.modelName ?? fallbackModelName,
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

/// Give the label only the painted logo's width. Narrow proposals shrink the
/// whole canvas uniformly, retaining the existing height for row alignment.
private struct DisplayHardwareLogoLayout: Layout {
    let canvas: CGSize
    let leading: CGFloat
    let trailing: CGFloat
    private var visibleWidth: CGFloat { max(1, canvas.width - leading - trailing) }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: min(visibleWidth, max(0, proposal.width ?? visibleWidth)), height: canvas.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let scale = bounds.width / visibleWidth
        let size = CGSize(width: canvas.width * scale, height: canvas.height * scale)
        subviews.first?.place(at: CGPoint(x: bounds.minX - leading * scale,
                                         y: bounds.midY - size.height / 2),
                              anchor: .topLeading, proposal: ProposedViewSize(size))
    }
}

/// Measures the existing logo canvas once per appearance. Only its horizontal
/// empty space is removed; SwiftUI still draws the original vector/colour asset.
@MainActor private struct DisplayHardwareLogoInsets {
    let leading: CGFloat
    let trailing: CGFloat
    private static var cache: [String: Self] = [:]

    static func resolve(brand: DisplayHardwareBrand, scheme: ColorScheme) -> Self {
        let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
        let key = "\(brand.rawValue)-\(style.rawValue)"
        if let cached = cache[key] { return cached }
        let result = measure(brand: brand, style: style)
        cache[key] = result
        return result
    }

    private static func measure(brand: DisplayHardwareBrand, style: UIUserInterfaceStyle) -> Self {
        let empty = Self(leading: 0, trailing: 0)
        guard let image = UIImage(named: brand.assetName, in: .main,
                                  compatibleWith: UITraitCollection(userInterfaceStyle: style)),
              image.size.width > 0, image.size.height > 0
        else { return empty }
        // An eight-times sampling canvas keeps edge rounding below 0.125 pt.
        // This is a bounded alpha measurement, independent of display scale.
        let samplingScale: CGFloat = 8
        let width = Int(brand.logoWidth * samplingScale)
        let height = Int(20 * samplingScale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)
        else { return empty }
        let sx = CGFloat(width) / image.size.width
        let sy = CGFloat(height) / image.size.height
        let scale = brand.contentMode == .fill ? max(sx, sy) : min(sx, sy)
        let imageWidth = image.size.width * scale
        let imageHeight = image.size.height * scale
        let x = brand.logoAlignment == .leading ? 0 : (CGFloat(width) - imageWidth) / 2
        UIGraphicsPushContext(context)
        image.draw(in: CGRect(x: x, y: (CGFloat(height) - imageHeight) / 2,
                              width: imageWidth, height: imageHeight))
        UIGraphicsPopContext()
        guard let data = context.data else { return empty }
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        var first = width
        var last = -1
        for y in 0..<height {
            for x in 0..<width where pixels[(y * width + x) * 4 + 3] > 0 {
                first = min(first, x)
                last = max(last, x)
            }
        }
        guard last >= first else { return empty }
        return Self(leading: CGFloat(first) / samplingScale,
                    trailing: CGFloat(width - last - 1) / samplingScale)
    }
}

extension DisplayHardwareBrand {
    var assetName: String {
        switch self {
        case .seeedStudio:
            "BrandSeeedStudio"
        case .pimoroni:
            "BrandPimoroni"
        case .trmnl:
            "BrandTRMNL"
        case .waveshare:
            "BrandWaveshare"
        case .picPak:
            "BrandPicPak"
        case .xteink:
            "BrandXteink"
        case .m5stack:
            "BrandM5Stack"
        case .soldered:
            "BrandSoldered"
        case .paperlesspaper:
            "BrandPaperlesspaper"
        case .amazon:
            "BrandAmazon"
        case .kobo:
            "BrandKobo"
        case .remarkable:
            "BrandRemarkable"
        case .elecrow:
            "BrandElecrow"
        case .goodDisplay:
            "BrandGoodDisplay"
        case .zectrix:
            "BrandZectrix"
        case .bloomin8:
            "BrandBloomin8"
        }
    }

    func renderingMode(for colorScheme: ColorScheme) -> Image.TemplateRenderingMode {
        switch (self, colorScheme) {
        case (.seeedStudio, .dark), (.pimoroni, _), (.trmnl, _),
            (.xteink, .dark), (.paperlesspaper, _), (.remarkable, _),
            (.zectrix, _), (.bloomin8, _), (.goodDisplay, .dark):
            .template
        case (.seeedStudio, _), (.waveshare, _), (.picPak, _), (.xteink, _),
            (.m5stack, _), (.soldered, _), (.kobo, _), (.amazon, _),
            (.elecrow, _), (.goodDisplay, _):
            .original
        }
    }

    func foregroundColor(for colorScheme: ColorScheme) -> Color {
        if self == .seeedStudio, colorScheme == .dark {
            // Sampled from the official colour wordmark: RGB 141, 194, 31.
            return Color(red: 141 / 255, green: 194 / 255, blue: 31 / 255)
        }
        if self == .pimoroni {
            return .secondary
        }
        return .primary
    }

    var logoWidth: CGFloat {
        switch self {
        case .seeedStudio:
            78
        case .pimoroni:
            58
        case .trmnl:
            20
        case .waveshare:
            20
        case .picPak:
            52
        case .xteink:
            68
        case .m5stack:
            80
        case .soldered, .paperlesspaper:
            68
        case .amazon, .kobo:
            72
        case .remarkable:
            78
        case .elecrow:
            80
        case .goodDisplay:
            94
        case .zectrix, .bloomin8:
            20
        }
    }

    var contentMode: ContentMode {
        self == .waveshare ? .fill : .fit
    }

    var logoAlignment: Alignment {
        self == .waveshare ? .leading : .center
    }
}
