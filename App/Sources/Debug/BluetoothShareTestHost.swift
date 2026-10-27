#if DEBUG
import SwiftUI
import UIKit

/// Exercises the same composer used by the extension, without requiring Photos or a radio.
struct BluetoothShareTestHost: View {
    @State private var busy = false
    @State private var completed = false
    @State private var sharing = false
    @State private var mediaFrames = MediaFrameSession()
    @State private var movie: MediaTemporaryFile?
    @State private var fixtureError: String?
    private let image: UIImage = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 600, height: 400), format: format).image { context in
            UIColor.systemYellow.setFill(); context.fill(CGRect(x: 0, y: 0, width: 600, height: 400))
            UIColor.systemRed.setFill(); context.fill(CGRect(x: 60, y: 60, width: 160, height: 240))
            UIColor.black.setFill(); context.fill(CGRect(x: 280, y: 130, width: 200, height: 140))
        }
    }()

    var body: some View {
        Group {
            if let fixtureError { Text(fixtureError).accessibilityIdentifier("media-fixture-error") }
            else if ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_SYSTEM_SHARE"] == "1" {
                Button("Open System Share Sheet") { sharing = true }
                    .disabled(ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_MEDIA"] != nil && movie == nil)
                    .sheet(isPresented: $sharing) { BluetoothShareActivityHost(image: image, movieURL: movie?.url) }
            } else if completed {
                Text("Sharing Complete").accessibilityIdentifier("share-test-complete")
            } else {
                ShareComposerTestView(image: mediaFrames.output.flatMap { UIImage(data: $0.data) } ?? image,
                    imageData: mediaFrames.output?.data ?? image.pngData()!, mediaFrames: mediaFrames,
                    onBusyChange: { busy = $0 }, onSent: { completed = true })
                    .tesseraeScreenBackground()

            }
        }
        .tesseraeScreenBackground()
        .task {
            if let value = ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_MEDIA"] {
                do {
                    let fixture = try await MediaFrameFixtures.source(kind: value.hasPrefix("live") ? .livePhoto : .video)
                    let source = value == "live-unavailable"
                        ? MediaFrameSource(kind: .livePhoto, primaryImage: fixture.primaryImage, maximumPixelSize: 640) {
                            throw MediaFrameError.unavailable
                        } : fixture
                    mediaFrames.adopt(source)
                    movie = try await fixture.loadMovie()
                } catch { fixtureError = String(reflecting: error) }
            }
        }
    }
}

private struct BluetoothShareActivityHost: UIViewControllerRepresentable {
    let image: UIImage
    let movieURL: URL?
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: movieURL.map { [$0] } ?? [image], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
