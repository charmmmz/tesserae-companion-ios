import AVFoundation
import ImageIO
import Observation
import TesseraeKit
import UIKit
import UniformTypeIdentifiers

enum MediaFrameError: Error, LocalizedError {
    case unavailable, invalidVideo, encoding
    var errorDescription: String? {
        switch self {
        case .unavailable: String(localized: "This item's video could not be loaded. Your current photo is unchanged.")
        case .invalidVideo: String(localized: "This video does not contain a readable picture.")
        case .encoding: String(localized: "This frame could not be prepared. Try another moment.")
        }
    }
}

@MainActor final class MediaFrameSource: Identifiable {
    enum Kind { case photo, video, livePhoto }
    let id = UUID()
    let kind: Kind
    let primaryImage: PreparedUploadImage
    let maximumPixelSize: Int
    let loadMovie: @MainActor () async throws -> MediaTemporaryFile

    init(kind: Kind, primaryImage: PreparedUploadImage, maximumPixelSize: Int,
         loadMovie: @escaping @MainActor () async throws -> MediaTemporaryFile) {
        self.kind = kind
        self.primaryImage = primaryImage
        self.maximumPixelSize = maximumPixelSize
        self.loadMovie = loadMovie
    }
}

/// AVFoundation decoding and JPEG encoding stay on this actor, away from the UI actor.
actor VideoFrameReader {
    enum Quality { case thumbnail, preview, fullSize }

    private let file: MediaTemporaryFile
    private let asset: AVURLAsset
    private let maximumPixelSize: Int
    private var generators: [UUID: AVAssetImageGenerator] = [:]
    private var videoRange: (start: Double, duration: Double)?

    init(file: MediaTemporaryFile, maximumPixelSize: Int) {
        self.file = file
        self.asset = AVURLAsset(url: file.url)
        self.maximumPixelSize = max(1, maximumPixelSize)
    }

    func duration() async throws -> Double {
        try await range().duration
    }

    private func range() async throws -> (start: Double, duration: Double) {
        if let videoRange { return videoRange }
        let result = try await Self.loadVideoRange(url: file.url)
        videoRange = result
        return result
    }

    // Older AVFoundation SDKs return non-Sendable tracks. Keep them local to
    // this nonisolated async operation and return only immutable timing values.
    private nonisolated static func loadVideoRange(url: URL) async throws -> (start: Double, duration: Double) {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw MediaFrameError.invalidVideo }
        let timeRange = try await track.load(.timeRange)
        let start = max(0, timeRange.start.seconds)
        let end = timeRange.end.seconds
        guard start.isFinite, end.isFinite, end > start else { throw MediaFrameError.invalidVideo }
        return (start: start, duration: end - start)
    }

    func image(at seconds: Double, quality: Quality = .fullSize) async throws -> PreparedUploadImage {
        try Task.checkCancellation()
        let range = try await range()
        // Stay inside the actual video track, including its final frame at 60/120 fps.
        let offset = min(max(0, seconds), max(0, range.duration - min(1 / 60_000, range.duration / 2)))
        let time = CMTime(seconds: range.start + offset, preferredTimescale: 60_000)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        let edge = switch quality {
        case .thumbnail: 160
        case .preview: min(640, maximumPixelSize)
        case .fullSize: maximumPixelSize
        }
        generator.maximumSize = CGSize(width: edge, height: edge)
        // Dragging allows a nearby frame; the final selection remains exact.
        let tolerance = quality == .preview ? CMTime(seconds: 0.1, preferredTimescale: 600) : .zero
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        if #available(iOS 18, *) { generator.dynamicRangePolicy = .forceSDR }
        let id = UUID()
        generators[id] = generator
        defer { generators[id] = nil }
        let image = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CGImage, Error>) in
                generator.generateCGImageAsynchronously(for: time) { image, _, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? MediaFrameError.invalidVideo) }
                }
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
        try Task.checkCancellation()
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw MediaFrameError.encoding }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MediaFrameError.encoding }
        return PreparedUploadImage(data: bytes as Data, contentType: "image/jpeg", fileExtension: "jpg",
                                   pixelWidth: image.width, pixelHeight: image.height)
    }

    private func cancel(_ id: UUID) { generators[id]?.cancelAllCGImageGeneration() }
}

@MainActor @Observable final class MediaFrameSession {
    struct Thumbnail: Identifiable {
        let id: Int
        let image: UIImage
    }

    private(set) var source: MediaFrameSource?
    private(set) var output: PreparedUploadImage?
    private(set) var outputRevision = UUID()
    private(set) var scrubbingPreview: UIImage?
    private(set) var isScrubbing = false
    private(set) var thumbnails: [Thumbnail] = []
    private(set) var duration: Double = 0
    private(set) var position: Double = 0
    private(set) var usesPrimaryImage = true
    private(set) var isLoadingMovie = false
    private(set) var isRenderingFrame = false
    private(set) var errorMessage: String?
    @ObservationIgnored private var reader: VideoFrameReader?
    @ObservationIgnored private var movieTask: Task<Void, Never>?
    @ObservationIgnored private var thumbnailTask: Task<Void, Never>?
    @ObservationIgnored private var frameTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var frameGeneration = UUID()
    @ObservationIgnored private var committedPosition: Double = 0
    @ObservationIgnored private var failedPosition: Double?
    @ObservationIgnored private var pendingPreviewPosition: Double?

    // Loading optional motion must not block sending the already prepared key photo.
    var isBusy: Bool { isRenderingFrame }
    var hasTimeline: Bool { source?.kind == .video || source?.kind == .livePhoto }

    func adopt(_ source: MediaFrameSource) {
        clear()
        self.source = source
        output = source.primaryImage
        outputRevision = UUID()
        usesPrimaryImage = true
        loadTimeline()
    }

    func clear() {
        cancelWork()
        reader = nil
        source = nil
        output = nil
        thumbnails = []
        duration = 0
        position = 0
        committedPosition = 0
        failedPosition = nil
        usesPrimaryImage = true
        errorMessage = nil
    }

    func cancelWork() {
        generation = UUID()
        movieTask?.cancel(); movieTask = nil
        thumbnailTask?.cancel(); thumbnailTask = nil
        cancelFrameWork()
        isLoadingMovie = false
        position = committedPosition
    }

    private func cancelFrameWork() {
        frameGeneration = UUID()
        frameTask?.cancel(); frameTask = nil
        pendingPreviewPosition = nil
        scrubbingPreview = nil
        isScrubbing = false
        isRenderingFrame = false
    }

    func loadTimeline() {
        guard let source, hasTimeline else { return }
        guard reader == nil, !isLoadingMovie else { return }
        errorMessage = nil
        isLoadingMovie = true
        let token = generation
        movieTask = Task {
            do {
                let movie = try await source.loadMovie()
                let reader = VideoFrameReader(file: movie, maximumPixelSize: source.maximumPixelSize)
                let duration = try await reader.duration()
                try Task.checkCancellation()
                guard generation == token else { return }
                self.reader = reader
                self.duration = duration
                isLoadingMovie = false
                makeThumbnails(reader: reader, token: token)
            } catch {
                guard generation == token, !Task.isCancelled else { return }
                isLoadingMovie = false
                errorMessage = error.localizedDescription
            }
        }
    }

    func select(position: Double, immediately: Bool = false) {
        guard let reader, position.isFinite else { return }
        self.position = min(1, max(0, position))
        errorMessage = nil
        isRenderingFrame = true
        if !immediately {
            if !isScrubbing {
                frameTask?.cancel(); frameTask = nil
                frameGeneration = UUID()
                isScrubbing = true
            }
            // Keep one decode running and replace only the queued position.
            // Cancelling on every touch would starve decoding during a drag.
            pendingPreviewPosition = self.position
            if frameTask == nil { renderPreviews(reader: reader) }
            return
        }

        frameTask?.cancel()
        pendingPreviewPosition = nil
        isScrubbing = false
        let token = UUID()
        frameGeneration = token
        let requestedPosition = self.position
        let seconds = requestedPosition * duration
        frameTask = Task {
            defer { if frameGeneration == token { frameTask = nil } }
            do {
                let image = try await reader.image(at: seconds)
                try Task.checkCancellation()
                guard frameGeneration == token else { return }
                output = image
                usesPrimaryImage = false
                committedPosition = requestedPosition
                failedPosition = nil
                outputRevision = UUID()
                scrubbingPreview = nil
                isRenderingFrame = false
            } catch {
                guard frameGeneration == token, !Task.isCancelled else { return }
                isRenderingFrame = false
                scrubbingPreview = nil
                failedPosition = requestedPosition
                self.position = committedPosition
                errorMessage = error.localizedDescription
            }
        }
    }

    private func renderPreviews(reader: VideoFrameReader) {
        let token = frameGeneration
        frameTask = Task {
            defer { if frameGeneration == token { frameTask = nil } }
            let clock = ContinuousClock()
            while frameGeneration == token, !Task.isCancelled, let requestedPosition = pendingPreviewPosition {
                pendingPreviewPosition = nil
                let nextUpdate = clock.now + .milliseconds(33)
                do {
                    let image = try await reader.image(at: requestedPosition * duration, quality: .preview)
                    try Task.checkCancellation()
                    guard frameGeneration == token else { return }
                    scrubbingPreview = UIImage(data: image.data)
                } catch {
                    guard frameGeneration == token, !Task.isCancelled else { return }
                    // Keep the previous preview on transient seek errors. The
                    // exact frame requested on release owns error reporting.
                }
                do { try await clock.sleep(until: nextUpdate) }
                catch { return }
            }
        }
    }

    func restorePrimaryImage() {
        guard let source, source.kind == .livePhoto else { return }
        cancelFrameWork()
        output = source.primaryImage
        outputRevision = UUID()
        usesPrimaryImage = true
        // A missing movie still needs its retry/reselection action when the
        // user taps the key photo. Only frame-extraction errors can be cleared.
        if reader != nil { errorMessage = nil }
        failedPosition = nil
    }

    func retry() {
        if reader != nil { select(position: failedPosition ?? position, immediately: true) }
        else { loadTimeline() }
    }

    private func makeThumbnails(reader: VideoFrameReader, token: UUID) {
        thumbnailTask = Task {
            var frames: [Thumbnail] = []
            for index in 0..<10 {
                do {
                    let frame = try await reader.image(at: duration * (Double(index) + 0.5) / 10, quality: .thumbnail)
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    if let image = UIImage(data: frame.data) {
                        frames.append(Thumbnail(id: index, image: image))
                    }
                } catch { if Task.isCancelled { return } }
            }
            guard generation == token else { return }
            thumbnails = frames
        }
    }
}
