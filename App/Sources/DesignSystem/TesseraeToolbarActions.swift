import SwiftUI

/// The shared trailing capsule for page actions. Keep native Back and modal
/// Cancel/Done placements separate; see DESIGN.md for the screen conventions.
struct TesseraeToolbarActions<Actions: View>: ToolbarContent {
    var identifier = "toolbar-actions"
    @ViewBuilder let actions: Actions

    var body: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
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

private struct TesseraeToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .tesseraeIconActionLabel()
            .foregroundStyle(isEnabled ? TesseraeTheme.accent : .secondary)
            .opacity(configuration.isPressed ? 0.5 : 1)
    }
}

private struct TesseraePageSendEnabledKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    // Compact pages place Send above bottom tabs; wide windows have one shared
    // action below the whole tab container, outside either split-view column.
    var tesseraePageSendEnabled: Bool {
        get { self[TesseraePageSendEnabledKey.self] }
        set { self[TesseraePageSendEnabledKey.self] = newValue }
    }
}

private enum TesseraeFloatingSendMetrics {
    static let size: CGFloat = 56
    static let horizontalPadding: CGFloat = 16
    static let bottomPadding: CGFloat = 12
    static let reservedHeight = size + bottomPadding
}

private struct TesseraeRootPageChrome: ViewModifier {
    @Environment(\.tesseraePageSendEnabled) private var pageSendEnabled

    func body(content: Content) -> some View {
        content.tesseraeMessageCenter(
            bottomAccessoryHeight: pageSendEnabled ? TesseraeFloatingSendMetrics.reservedHeight : 0
        ) {
            if pageSendEnabled {
                TesseraeFloatingSendAction()
            }
        }
    }
}

struct TesseraeFloatingSendAction: View {
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
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: 22, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: TesseraeFloatingSendMetrics.size, height: TesseraeFloatingSendMetrics.size)
            .background(TesseraeTheme.accentFill, in: Circle())
            .contentShape(Circle())
            .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
            .opacity(configuration.isPressed ? 0.65 : 1)
    }
}

extension View {
    /// Keep Send above the tab safe area and messages below navigation,
    /// reserving content space without guessing the system bars' heights.
    func tesseraeRootPageChrome() -> some View {
        modifier(TesseraeRootPageChrome())
    }
}
