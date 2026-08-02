import SwiftUI

struct FittedPreviewLayout: Layout {
    let aspectRatio: CGFloat
    let maximumHeight: CGFloat
    var shrinksWidthAtMaximumHeight = false

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else {
            return .zero
        }

        let fallback = subview.sizeThatFits(.unspecified)
        let safeRatio = max(aspectRatio, 0.01)
        let proposedWidth = proposal.width ?? fallback.width
        let width = shrinksWidthAtMaximumHeight
            ? min(proposedWidth, maximumHeight * safeRatio)
            : proposedWidth
        return CGSize(
            width: width,
            height: min(width / safeRatio, maximumHeight)
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: CGPoint(x: bounds.midX, y: bounds.midY),
            anchor: .center,
            proposal: ProposedViewSize(
                width: bounds.width,
                height: bounds.height
            )
        )
    }
}
