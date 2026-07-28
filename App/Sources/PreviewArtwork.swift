import SwiftUI
import UIKit

struct PreviewArtwork: View {
    let state: PreviewImageState?
    let placeholderSystemName: String
    let placeholderLabel: String
    let imageLabel: String
    let accessibilityIdentifier: String
    var placeholderDetail: String?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TesseraeTheme.accentSoft, TesseraeTheme.paper],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(spacing: 4) {
                    Image(systemName: placeholderSystemName)
                        .font(.headline)
                    if let placeholderDetail {
                        Text(placeholderDetail)
                            .font(.caption2.monospaced())
                            .lineLimit(1)
                            .minimumScaleFactor(0.68)
                    }
                }
                .padding(5)
                .foregroundStyle(TesseraeTheme.accent)
            }

            if state?.showsProgress == true {
                ProgressView()
                    .controlSize(.small)
                    .padding(8)
                    .background(.thinMaterial, in: Circle())
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityIdentifier(accessibilityIdentifier)
        .accessibilityLabel(image == nil ? placeholderLabel : imageLabel)
    }

    private var image: UIImage? {
        state?.data.flatMap(UIImage.init(data:))
    }
}
