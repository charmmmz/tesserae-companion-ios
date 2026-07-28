import SwiftUI

enum TesseraeTheme {
    static let accent = Color(red: 13 / 255, green: 140 / 255, blue: 126 / 255)
    static let accentSoft = Color(red: 230 / 255, green: 243 / 255, blue: 241 / 255)
    static let paper = Color(red: 241 / 255, green: 240 / 255, blue: 236 / 255)
    static let darkPaper = Color(red: 14 / 255, green: 16 / 255, blue: 21 / 255)
    static let ochre = Color(red: 186 / 255, green: 134 / 255, blue: 43 / 255)
    static let terracotta = Color(red: 180 / 255, green: 91 / 255, blue: 65 / 255)

    static func background(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkPaper : paper
    }
}

private struct TesseraeCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                colorScheme == .dark
                    ? Color(red: 24 / 255, green: 27 / 255, blue: 34 / 255)
                    : .white,
                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
            )
    }
}

extension View {
    func tesseraeCard() -> some View {
        modifier(TesseraeCardModifier())
    }

    func tesseraeScreenBackground() -> some View {
        modifier(TesseraeScreenBackgroundModifier())
    }
}

private struct TesseraeScreenBackgroundModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content.background(TesseraeTheme.background(for: colorScheme).ignoresSafeArea())
    }
}

