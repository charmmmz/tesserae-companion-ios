import SwiftUI

/// Keep the media canvas, frame strip and display selector in the same order
/// and geometry in the app and its Share Extension.
struct TesseraeComposerMediaPreview<Canvas: View, Targets: View>: View {
    let session: MediaFrameSession
    let canvasHeight: CGFloat
    var isSending = false
    var onChooseLivePhoto: (() -> Void)?
    @ViewBuilder let canvas: () -> Canvas
    @ViewBuilder let targets: () -> Targets
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                Color.clear
                canvas()
            }
            .frame(minHeight: canvasHeight, maxHeight: dynamicTypeSize.isAccessibilitySize ? nil : canvasHeight)

            MediaFrameControls(session: session, isSending: isSending, onChooseLivePhoto: onChooseLivePhoto)

            targets()
                .frame(maxWidth: .infinity)
                .frame(height: dynamicTypeSize.isAccessibilitySize ? nil : 44)
        }
        .frame(height: dynamicTypeSize.isAccessibilitySize || session.hasTimeline ? nil : canvasHeight + 9 + 44)
    }
}

struct TesseraeComposerPreviewHeader: View {
    let titleAccessibilityIdentifier: String
    let changePhotoAccessibilityIdentifier: String
    var isLoading = false
    var onChoosePhoto: (() -> Void)?
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                title
                changePhoto
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                title
                Spacer(minLength: 8)
                changePhoto
            }
        }
    }

    private var title: some View {
        HStack(spacing: 8) {
            Text("Preview")
                .font(.headline)
                .accessibilityIdentifier(titleAccessibilityIdentifier)
            if isLoading {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("Loading photo or video…")
            }
        }
    }

    @ViewBuilder private var changePhoto: some View {
        if let onChoosePhoto {
            Button(action: onChoosePhoto) {
                Text("Change Photo")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(TesseraeTheme.accent)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 7)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityIdentifier(changePhotoAccessibilityIdentifier)
        }
    }
}
