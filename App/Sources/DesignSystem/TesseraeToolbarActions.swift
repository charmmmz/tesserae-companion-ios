import SwiftUI

/// The shared trailing capsule for page actions. Keep native Back and modal
/// Cancel/Done placements separate; see DESIGN.md for the screen conventions.
struct TesseraeToolbarActions<Actions: View>: ToolbarContent {
    var identifier = "toolbar-actions"
    @ViewBuilder let actions: Actions

    var body: some ToolbarContent {
        ToolbarItem(id: "tesserae-page-actions", placement: .topBarTrailing) {
            // One item keeps all actions in the same native capsule.
            HStack(spacing: TesseraeActionMetrics.spacing) {
                actions
            }
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .buttonStyle(TesseraeToolbarButtonStyle())
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(identifier)
        }
    }
}

@Observable
private final class TesseraeTabSendPosition {
    var contentBottom: CGFloat?
}

private enum TesseraeFloatingSendMetrics {
    static let size: CGFloat = 56
    static let horizontalPadding: CGFloat = 16
    static let bottomPadding: CGFloat = 12
    static let reservedHeight = size + bottomPadding
}

private struct TesseraeTabSendViewport: ViewModifier {
    @Environment(TesseraeTabSendPosition.self) private var position: TesseraeTabSendPosition?
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.bottom, position == nil ? 0 : TesseraeFloatingSendMetrics.reservedHeight)
            .overlay(alignment: .bottom) {
                if isSelected, let position {
                    Color.clear.frame(height: 0)
                        .allowsHitTesting(false)
                        .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).minY } action: {
                            position.contentBottom = $0
                        }
                }
            }
    }
}

private struct TesseraeTabSendChrome: ViewModifier {
    let isEnabled: Bool
    @State private var position = TesseraeTabSendPosition()

    func body(content: Content) -> some View {
        content
            .environment(isEnabled ? position : nil)
            .overlay {
                if isEnabled {
                    GeometryReader { geometry in
                        if let contentBottom = position.contentBottom {
                            TesseraeFloatingSendAction()
                                .padding(.bottom, max(0, geometry.frame(in: .global).maxY - contentBottom))
                                .frame(maxHeight: .infinity, alignment: .bottom)
                        }
                    }
                }
            }
    }
}

private struct TesseraeFloatingSendAction: View {
    var body: some View {
        HStack {
            Spacer(minLength: 0)
            TesseraeSendButton()
                .buttonStyle(TesseraeFloatingSendButtonStyle())
        }
        .padding(.horizontal, TesseraeFloatingSendMetrics.horizontalPadding)
        .padding(.bottom, TesseraeFloatingSendMetrics.bottomPadding)
    }
}

private struct TesseraeFloatingSendButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: TesseraeFloatingSendMetrics.size, height: TesseraeFloatingSendMetrics.size)
            .background {
                Circle()
                    .fill(TesseraeTheme.accentFill)
                    .overlay {
                        Circle().fill(.black.opacity(configuration.isPressed ? 0.14 : 0))
                    }
            }
            .shadow(
                color: .black.opacity(0.18),
                radius: configuration.isPressed ? 3 : 8,
                y: configuration.isPressed ? 1 : 4
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(
                reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.72),
                value: configuration.isPressed
            )
            .frame(width: TesseraeFloatingSendMetrics.size, height: TesseraeFloatingSendMetrics.size)
            .contentShape(Circle())
    }
}

extension View {
    /// Reserve room in the tab's navigation container and report the edge above its tab bar.
    func tesseraeTabSendViewport(isSelected: Bool) -> some View {
        modifier(TesseraeTabSendViewport(isSelected: isSelected))
    }

    /// Keep one Send action above the tab content throughout navigation transitions.
    func tesseraeTabSendChrome(isEnabled: Bool = true) -> some View {
        modifier(TesseraeTabSendChrome(isEnabled: isEnabled))
    }
}
