import SwiftUI
import TesseraeKit

struct DisplayHardwareBadge: View {
    let presentation: DisplayHardwarePresentation
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 4) {
            if let brand = presentation.brand {
                brandLogo(brand)
            } else {
                genericLogo
            }

            Text(presentation.modelName ?? String(localized: "Custom display"))
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(
            "display-hardware-\(presentation.brand?.rawValue ?? "generic")"
        )
    }

    private func brandLogo(_ brand: DisplayHardwareBrand) -> some View {
        Image(brand.assetName)
            .resizable()
            .renderingMode(brand.renderingMode(for: colorScheme))
            .foregroundStyle(brand.foregroundColor(for: colorScheme))
            .aspectRatio(contentMode: brand.contentMode)
            .frame(
                width: brand.logoWidth,
                height: 20,
                alignment: brand.logoAlignment
            )
            .clipped()
            .offset(x: brand.opticalLeadingCorrection)
            .frame(width: brand.logoWidth, alignment: .leading)
            .accessibilityLabel(brand.displayName)
            .accessibilityIdentifier("display-brand-\(brand.rawValue)")
    }

    private var genericLogo: some View {
        Image(systemName: "display")
            .font(.caption.weight(.semibold))
            .foregroundStyle(TesseraeTheme.accent)
            .frame(width: 28, height: 26)
            .background(
                TesseraeTheme.accentSoft,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .accessibilityHidden(true)
    }

    private var accessibilityLabel: String {
        [
            presentation.brand?.displayName,
            presentation.modelName ?? String(localized: "Custom display"),
        ]
        .compactMap { $0 }
        .joined(separator: ", ")
    }
}

private extension DisplayHardwareBrand {
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
        }
    }

    func renderingMode(for colorScheme: ColorScheme) -> Image.TemplateRenderingMode {
        switch (self, colorScheme) {
        case (.seeedStudio, .dark), (.pimoroni, _), (.trmnl, _),
            (.xteink, .dark):
            .template
        case (.seeedStudio, _), (.waveshare, _), (.picPak, _), (.xteink, _):
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
        }
    }

    var contentMode: ContentMode {
        self == .waveshare ? .fill : .fit
    }

    var logoAlignment: Alignment {
        self == .waveshare ? .leading : .center
    }

    var opticalLeadingCorrection: CGFloat {
        switch self {
        case .seeedStudio:
            // The official PNG includes transparent space before the wordmark.
            -4.5
        case .pimoroni, .trmnl, .waveshare, .picPak, .xteink:
            0
        }
    }
}
