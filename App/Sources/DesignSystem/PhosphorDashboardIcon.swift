import SwiftUI

struct PhosphorIcon: View {
    let name: String?
    let size: CGFloat
    let color: Color
    let fallbackSystemName: String?

    init(
        name: String?,
        size: CGFloat,
        color: Color = .accentColor,
        fallbackSystemName: String? = nil
    ) {
        self.name = name
        self.size = size
        self.color = color
        self.fallbackSystemName = fallbackSystemName
    }

    @ViewBuilder
    var body: some View {
        if let glyph = Self.glyph(named: name) {
            Text(glyph)
                .font(.custom("Phosphor", fixedSize: size))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else if let fallbackSystemName {
            Image(systemName: fallbackSystemName)
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Text(Self.glyph(named: "cube") ?? "□")
                .font(.custom("Phosphor", fixedSize: size))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }

    private static let glyphs: [String: String] = {
        guard
            let url = Bundle.main.url(
                forResource: "PhosphorRegularGlyphs",
                withExtension: "json"
            ),
            let data = try? Data(contentsOf: url),
            let values = try? JSONDecoder().decode([String: String].self, from: data)
        else {
            return [:]
        }
        return values
    }()

    private static func glyph(named name: String?) -> String? {
        guard
            let hex = name.flatMap({ glyphs[$0] }),
            let codePoint = UInt32(hex, radix: 16),
            let scalar = UnicodeScalar(codePoint)
        else {
            return nil
        }
        return String(Character(scalar))
    }
}
