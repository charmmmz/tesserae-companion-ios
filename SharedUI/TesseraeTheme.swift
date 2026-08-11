import SwiftUI

enum TesseraeTheme {
    static let accent = Color(red: 13 / 255, green: 140 / 255, blue: 126 / 255)
    static let darkAccent = Color(red: 45 / 255, green: 212 / 255, blue: 191 / 255)
    static let accentSoft = Color(red: 230 / 255, green: 243 / 255, blue: 241 / 255)
    static let paper = Color(red: 241 / 255, green: 240 / 255, blue: 236 / 255)
    static let darkPaper = Color(red: 14 / 255, green: 16 / 255, blue: 21 / 255)
    static let ochre = Color(red: 186 / 255, green: 134 / 255, blue: 43 / 255)
    static let terracotta = Color(red: 180 / 255, green: 91 / 255, blue: 65 / 255)

    static func background(for colorScheme: ColorScheme) -> Color {
        colorScheme == .dark ? darkPaper : paper
    }
}

enum TesseraeComposerLayout {
    static let pagePadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 14
    static let contentCardSpacing: CGFloat = 12
    static let controlCardSpacing: CGFloat = 10
    static let selectionCardSpacing: CGFloat = 8
}

struct ReorderDragPreview<Icon: View>: View {
    let title: String
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)

        return Label {
            Text(title)
        } icon: {
            icon()
        }
        .font(.subheadline.weight(.semibold))
        .lineLimit(1)
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            TesseraeTheme.accent.opacity(0.9),
            in: shape
        )
        .clipShape(shape)
        .contentShape(.dragPreview, shape)
    }
}

private struct TesseraeScreenBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.displayScale) private var displayScale

    private let gridSpacing: CGFloat = 24

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .top) {
                TesseraeTheme.background(for: colorScheme)

                ambientGlow

                Canvas { context, size in
                    let lineWidth = 1 / displayScale
                    let pixelOffset = lineWidth / 2
                    var grid = Path()

                    for x in stride(
                        from: pixelOffset,
                        through: size.width,
                        by: gridSpacing
                    ) {
                        grid.move(to: CGPoint(x: x, y: 0))
                        grid.addLine(to: CGPoint(x: x, y: size.height))
                    }

                    for y in stride(
                        from: pixelOffset,
                        through: size.height,
                        by: gridSpacing
                    ) {
                        grid.move(to: CGPoint(x: 0, y: y))
                        grid.addLine(to: CGPoint(x: size.width, y: y))
                    }

                    context.stroke(
                        grid,
                        with: .color(gridColor),
                        lineWidth: lineWidth
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var ambientGlow: some View {
        let accent = colorScheme == .dark
            ? TesseraeTheme.darkAccent
            : TesseraeTheme.accent
        let opacity = colorScheme == .dark ? 0.10 : 0.05

        return Rectangle()
            .fill(
                EllipticalGradient(
                    gradient: Gradient(stops: [
                        .init(
                            color: accent.opacity(opacity),
                            location: 0
                        ),
                        .init(
                            color: accent.opacity(0),
                            location: 0.55
                        ),
                        .init(color: .clear, location: 1)
                    ]),
                    center: UnitPoint(x: 0.5, y: -0.2),
                    startRadiusFraction: 0,
                    endRadiusFraction: 1
                )
            )
    }

    private var gridColor: Color {
        colorScheme == .dark
            ? .white.opacity(0.015)
            : Color(red: 16 / 255, green: 12 / 255, blue: 8 / 255)
                .opacity(0.03)
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

    @ViewBuilder
    func tesseraeModalChromeButtonStyle() -> some View {
#if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.plain)
        }
#else
        buttonStyle(.plain)
#endif
    }
}

struct TesseraeDisplaySelectionRow: View {
    let name: String
    let resolution: String
    let isSelected: Bool

    var body: some View {
        HStack {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? TesseraeTheme.accent : .secondary)
            Text(name)
                .foregroundStyle(.primary)
            Spacer()
            Text(resolution)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
    }
}

struct TesseraeSuccessBanner: View {
    let message: String

    var body: some View {
        Label(message, systemImage: "checkmark.circle.fill")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .regularMaterial,
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("send-success-banner")
    }
}

private struct TesseraeScreenBackgroundModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background {
            TesseraeScreenBackdrop()
                .ignoresSafeArea()
        }
    }
}
