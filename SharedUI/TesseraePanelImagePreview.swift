import SwiftUI
import TesseraeKit
import UIKit

/// A fixed Tesserae panel canvas that mirrors the server's five image-fit
/// modes. The image is laid out explicitly and clipped by the canvas, avoiding
/// SwiftUI's implicit `aspectRatio` sizing from escaping its parent.
struct TesseraePanelImagePreview: View {
    let image: UIImage?
    let panel: PanelProfile
    let fit: ImageFitMode
    let maximumCanvasHeight: CGFloat
    let emptyTitle: String
    let accessibilityIdentifier: String
    let imageAccessibilityIdentifier: String

    var body: some View {
        PanelAspectLayout(
            aspectRatio: CGFloat(max(panel.width, 1))
                / CGFloat(max(panel.height, 1)),
            maximumHeight: maximumCanvasHeight
        ) {
            GeometryReader { proxy in
                panelCanvas(size: proxy.size)
            }
        }
        .padding(7)
        .background(
            Color.black.opacity(0.82),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    @ViewBuilder
    private func panelCanvas(size: CGSize) -> some View {
        ZStack(alignment: .topLeading) {
            Color.white

            if let image {
                if fit == .blur {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width, height: size.height)
                        .blur(
                            radius: max(
                                2,
                                min(size.width, size.height) / 16
                            )
                        )
                        .clipped()
                }

                let sourceWidth = image.size.width * image.scale
                let sourceHeight = image.size.height * image.scale
                let rect = fit.previewRect(
                    sourceWidth: sourceWidth,
                    sourceHeight: sourceHeight,
                    canvasWidth: size.width,
                    canvasHeight: size.height,
                    targetPixelWidth: Double(panel.width),
                    targetPixelHeight: Double(panel.height)
                )

                Image(uiImage: image)
                    .resizable()
                    .frame(
                        width: max(0, rect.width),
                        height: max(0, rect.height)
                    )
                    .offset(x: rect.x, y: rect.y)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 36))
                    Text(emptyTitle)
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(TesseraeTheme.accent)
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity
                )
            }
        }
        .frame(
            width: size.width,
            height: size.height,
            alignment: .topLeading
        )
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Display image preview")
        .accessibilityIdentifier(imageAccessibilityIdentifier)
    }
}

private struct PanelAspectLayout: Layout {
    let aspectRatio: CGFloat
    let maximumHeight: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let safeRatio = aspectRatio.isFinite && aspectRatio > 0
            ? aspectRatio
            : 1
        let proposedWidth = proposal.width ?? maximumHeight * safeRatio
        let availableWidth = proposedWidth.isFinite
            ? max(1, proposedWidth)
            : maximumHeight * safeRatio
        let height = min(maximumHeight, availableWidth / safeRatio)
        return CGSize(width: height * safeRatio, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: bounds.width,
                height: bounds.height
            )
        )
    }
}
