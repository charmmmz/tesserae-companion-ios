import SwiftUI

/// Own draft, selection, framing, and submission state above this layout. Only the
/// presentation changes when the window or fold changes; neither region owns a job.
struct AdaptiveComposerLayout<Preview: View, Controls: View>: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @ViewBuilder let preview: () -> Preview
    @ViewBuilder let controls: () -> Controls

    var body: some View {
        GeometryReader { geometry in
            let usesColumns = horizontalSizeClass == .regular
                && geometry.size.width >= 720 && !dynamicTypeSize.isAccessibilitySize
            if usesColumns {
                #if compiler(>=6.4)
                if #available(iOS 27.1, *) {
                    ArrangementView {
                        region { preview() }
                    } secondary: {
                        region { controls() }
                    }
                    .arrangementViewStyle(.split)
                } else {
                    columns
                }
                #else
                columns
                #endif
            } else {
                ScrollView {
                    VStack(spacing: TesseraeComposerLayout.sectionSpacing) {
                        preview()
                        controls()
                    }
                    .frame(maxWidth: 680)
                    .padding(TesseraeComposerLayout.pagePadding)
                    .frame(maxWidth: .infinity)
                }
                .scrollBounceBehavior(.basedOnSize)
                .scrollDismissesKeyboard(.interactively)
            }
        }
    }

    private var columns: some View {
        HStack(alignment: .top, spacing: 0) {
            region { preview() }
            region { controls() }
        }
    }

    private func region<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        ScrollView {
            VStack(spacing: TesseraeComposerLayout.sectionSpacing, content: content)
                .frame(maxWidth: 680)
                .padding(TesseraeComposerLayout.pagePadding)
                .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }
}

func composerCanvasHeight(in size: CGSize) -> CGFloat {
    min(size.width >= 720 ? 520 : 276, max(180, size.height * 0.55))
}
