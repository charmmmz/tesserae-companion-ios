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
