import SwiftUI

struct PhosphorDashboardIcon: View {
    let name: String?
    let size: CGFloat

    var body: some View {
        Text(Self.glyph(named: name))
            .font(.custom("Phosphor", fixedSize: size))
            .foregroundStyle(Color.accentColor)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
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

    private static func glyph(named name: String?) -> String {
        let hex = name.flatMap { glyphs[$0] } ?? glyphs["cube"]
        guard
            let hex,
            let codePoint = UInt32(hex, radix: 16),
            let scalar = UnicodeScalar(codePoint)
        else {
            return "□"
        }
        return String(Character(scalar))
    }
}
