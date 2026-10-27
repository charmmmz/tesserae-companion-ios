import Foundation
import ImageIO
import Photos
import Testing
import UIKit
import UniformTypeIdentifiers
@testable import Tesserae_Companion

@MainActor struct MediaFrameTests {
    @Test func ordinaryItemProviderImageRemainsAStaticPhoto() async throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 40))
        let image = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 64, height: 40))
        }
        let selection = MediaPickerSelection(provider: NSItemProvider(object: image))
        let source = try await selection.load(maximumPixelSize: 32)
        #expect(source.kind == .photo)
        #expect(source.primaryImage.pixelWidth <= 32)
        let session = MediaFrameSession()
        session.adopt(source)
        #expect(!session.hasTimeline)
        #expect(!session.isBusy)
    }

    @Test func livePhotoKeepsPrimaryUntilExplicitlyExpandedAndRestoresIt() async throws {
        let fixture = try await MediaFrameFixtures.source(kind: .livePhoto)
        var movieLoads = 0
        let source = MediaFrameSource(kind: .livePhoto, primaryImage: fixture.primaryImage, maximumPixelSize: 320) {
            movieLoads += 1
            return try await fixture.loadMovie()
        }
        let session = MediaFrameSession()
        session.adopt(source)
        #expect(movieLoads == 0)
        #expect(session.output == source.primaryImage)
        #expect(!session.isExpanded)
        session.expand()
        try await eventually { session.duration > 0 && !session.isBusy }
        #expect(movieLoads == 1)
        session.select(position: 0.8, immediately: true)
        try await eventually { !session.isBusy }
        #expect(!session.usesPrimaryImage)
        #expect(session.output?.data != source.primaryImage.data)
        session.select(position: 0.2)
        session.restorePrimaryImage()
        try await Task.sleep(for: .milliseconds(120))
        #expect(session.output == source.primaryImage)
        #expect(session.usesPrimaryImage)
        #expect(!session.isExpanded)
        #expect(!session.isBusy)
        session.cancelWork()
    }

    @Test func replacingVideoRejectsDelayedFramesAndReadsNewSource() async throws {
        let first = try await MediaFrameFixtures.source(kind: .video)
        let second = try await MediaFrameFixtures.source(kind: .livePhoto)
        let session = MediaFrameSession()
        session.adopt(first)
        try await eventually { session.duration > 0 && !session.isBusy }
        session.select(position: 1)
        session.adopt(second)
        try await Task.sleep(for: .milliseconds(120))
        #expect(session.output == second.primaryImage)
        #expect(session.duration == 0)
        #expect(session.scrubbingPreview == nil)
        #expect(!session.isScrubbing)
        session.expand()
        try await eventually { session.duration > 0 && !session.isBusy }
        #expect(session.output == second.primaryImage)
        session.cancelWork()
    }

    @Test(arguments: [MediaFrameSource.Kind.video, .livePhoto])
    func continuousDraggingUpdatesPreviewBeforeReleaseAndOnlyCommitsTheExactFinalFrame(kind: MediaFrameSource.Kind) async throws {
        let source = try await MediaFrameFixtures.source(kind: kind)
        let session = MediaFrameSession()
        session.adopt(source)
        session.expand()
        try await eventually { session.duration > 0 && !session.isBusy }
        let originalRevision = session.outputRevision

        var isMoving = true
        let drag = Task {
            defer { isMoving = false }
            for index in 0..<150 {
                try Task.checkCancellation()
                session.select(position: Double(index % 100) / 100)
                try await Task.sleep(for: .milliseconds(8))
            }
        }
        defer { drag.cancel(); session.cancelWork() }
        try await eventually { session.scrubbingPreview != nil }
        let firstPreview = try #require(session.scrubbingPreview?.pngData())
        try await eventually {
            guard let data = session.scrubbingPreview?.pngData() else { return false }
            return data != firstPreview
        }
        #expect(isMoving, "Preview must change while touch events continue, before release.")
        #expect(session.isBusy)
        #expect(session.isScrubbing)
        #expect(session.output == source.primaryImage)
        #expect(session.outputRevision == originalRevision)

        drag.cancel()
        _ = await drag.result
        session.select(position: 0.85, immediately: true)
        try await eventually { !session.isBusy }
        let movie = try await source.loadMovie()
        let expected = try await VideoFrameReader(file: movie, maximumPixelSize: source.maximumPixelSize)
            .image(at: session.duration * 0.85)
        #expect(session.output == expected)
        #expect(session.scrubbingPreview == nil)
        #expect(!session.isScrubbing)
    }

    @Test func cancellingADragDiscardsPreviewAndKeepsTheLastCommittedFrame() async throws {
        let source = try await MediaFrameFixtures.source(kind: .video)
        let session = MediaFrameSession()
        session.adopt(source)
        defer { session.cancelWork() }
        try await eventually { session.duration > 0 && !session.isBusy }
        session.select(position: 0.5, immediately: true)
        try await eventually { !session.isBusy }
        let committed = session.output
        let revision = session.outputRevision
        session.select(position: 0.9)
        try await eventually { session.scrubbingPreview != nil }
        session.select(position: 0.1)
        session.cancelWork()
        #expect(session.scrubbingPreview == nil)
        #expect(!session.isScrubbing)
        #expect(!session.isBusy)
        #expect(session.position == 0.5)
        try await Task.sleep(for: .milliseconds(120))
        #expect(session.output == committed)
        #expect(session.outputRevision == revision)
        #expect(session.scrubbingPreview == nil)
    }

    @Test func unavailableLiveMotionPreservesPrimaryAndAllowsRetry() async throws {
        let fixture = try await MediaFrameFixtures.source(kind: .livePhoto)
        let source = MediaFrameSource(kind: .livePhoto, primaryImage: fixture.primaryImage, maximumPixelSize: 320) {
            throw MediaFrameError.unavailable
        }
        let session = MediaFrameSession()
        session.adopt(source)
        session.expand()
        try await eventually { session.errorMessage != nil }
        #expect(!session.isBusy)
        #expect(session.output == fixture.primaryImage)
        session.restorePrimaryImage()
        #expect(session.errorMessage == nil)
        #expect(!session.isExpanded)
    }

    @Test func hidingAStillLoadingLivePhotoKeepsPrimaryImmediatelySendable() async throws {
        let fixture = try await MediaFrameFixtures.source(kind: .livePhoto)
        var pending: CheckedContinuation<MediaTemporaryFile, Error>?
        let source = MediaFrameSource(kind: .livePhoto, primaryImage: fixture.primaryImage, maximumPixelSize: 320) {
            try await withCheckedThrowingContinuation { pending = $0 }
        }
        let session = MediaFrameSession()
        session.adopt(source)
        session.expand()
        try await eventually { pending != nil }
        session.toggleExpanded()
        #expect(!session.isBusy)
        #expect(!session.isExpanded)
        #expect(session.output == fixture.primaryImage)
        pending?.resume(throwing: MediaFrameError.unavailable)
        await Task.yield()
        #expect(session.errorMessage == nil)
    }

    @Test func movieFramesBakeOrientationRespectSizeAndDifferByTime() async throws {
        let file = try await MediaFrameFixtureWriter().makeMovie(rotated: true)
        let reader = VideoFrameReader(file: file, maximumPixelSize: 80)
        let first = try await reader.image(at: 0)
        let later = try await reader.image(at: 2)
        #expect(first.pixelHeight == 80)
        #expect(first.pixelWidth == 50)
        #expect(first.data != later.data)
        #expect(first.contentType == "image/jpeg")
        #expect(UIImage(data: first.data)?.imageOrientation == .up)
    }

    @Test func scrubbingPreviewDoesNotReduceFinalFrameResolution() async throws {
        let file = try await MediaFrameFixtureWriter().makeMovie(width: 1280, height: 800)
        let reader = VideoFrameReader(file: file, maximumPixelSize: 1280)
        let preview = try await reader.image(at: 1, quality: .preview)
        let final = try await reader.image(at: 1)
        #expect(preview.pixelWidth == 640)
        #expect(preview.pixelHeight == 400)
        #expect(final.pixelWidth == 1280)
        #expect(final.pixelHeight == 800)
    }

    @Test func timelineEndpointSelectsTheFinalFrameOfSixtyFPSVideo() async throws {
        let movie = try await MediaFrameFixtureWriter().makeMovie(frameRate: 60)
        let reader = VideoFrameReader(file: movie, maximumPixelSize: 320)
        let first = try await reader.image(at: 0)
        let last = try await reader.image(at: 11.0 / 60)
        let source = MediaFrameSource(kind: .video, primaryImage: first, maximumPixelSize: 320) { movie }
        let session = MediaFrameSession()
        session.adopt(source)
        try await eventually { session.duration > 0 && !session.isBusy }
        session.select(position: 1, immediately: true)
        try await eventually { !session.isBusy }
        #expect(session.output?.data == last.data)
        #expect(session.output?.data != first.data)
        session.cancelWork()
    }

    @Test func realLivePhotoResourcesCanExportMotionWithoutLibraryAccess() async throws {
        let identifier = UUID().uuidString
        let movie = try await MediaFrameFixtureWriter().makeMovie(contentIdentifier: identifier)
        let frame = try await VideoFrameReader(file: movie, maximumPixelSize: 320).image(at: 1.5)
        let still = try MediaTemporaryFile(fileExtension: "jpg")
        let imageSource = try #require(CGImageSourceCreateWithData(frame.data as CFData, nil))
        let destination = try #require(CGImageDestinationCreateWithURL(still.url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImageFromSource(destination, imageSource, 0, [kCGImagePropertyMakerAppleDictionary: ["17": identifier]] as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        let permission = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let exported = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<MediaTemporaryFile, Error>) in
            PHLivePhoto.request(withResourceFileURLs: [still.url, movie.url], placeholderImage: nil, targetSize: .zero, contentMode: .aspectFit) { photo, info in
                guard (info[PHLivePhotoInfoIsDegradedKey] as? Bool) != true else { return }
                if let photo {
                    MediaPickerSelection.exportMovie(from: photo) { continuation.resume(with: $0) }
                }
                else { continuation.resume(throwing: (info[PHLivePhotoInfoErrorKey] as? Error) ?? MediaFrameError.unavailable) }
            }
        }
        let actual = try await VideoFrameReader(file: exported, maximumPixelSize: 320).image(at: 2)
        #expect(actual.pixelWidth == 320)
        #expect(actual.data != frame.data)
        #expect(PHPhotoLibrary.authorizationStatus(for: .readWrite) == permission)
    }

    private func eventually(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(condition())
    }
}
