import SwiftUI
import UIKit

@MainActor
private final class PreviewImageCache {
    static let shared = PreviewImageCache()

    private let images = NSCache<NSData, UIImage>()

    private init() {
        images.countLimit = 48
    }

    func image(for data: Data?) -> UIImage? {
        guard let data else { return nil }
        let key = data as NSData
        if let cached = images.object(forKey: key) {
            return cached
        }
        guard let image = UIImage(data: data) else { return nil }
        images.setObject(image, forKey: key)
        return image
    }
}

struct PreviewArtwork: View {
    let state: PreviewImageState?
    let placeholderSystemName: String
    let placeholderLabel: String
    let imageLabel: String
    let accessibilityIdentifier: String
    var placeholderDetail: String?
    var contentMode: ContentMode = .fit

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [TesseraeTheme.accentSoft, TesseraeTheme.paper],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            if let image {
                previewImage(image)
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
        PreviewImageCache.shared.image(for: state?.data)
    }

    @ViewBuilder
    private func previewImage(_ image: UIImage) -> some View {
        if contentMode == .fill {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            Image(uiImage: image)
                .resizable()
                .interpolation(.none)
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
