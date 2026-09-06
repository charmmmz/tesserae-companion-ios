import TesseraeKit
import XCTest

@testable import Tesserae_Companion

@MainActor
final class PhotoFramingSessionTests: XCTestCase {
    private let portrait = PanelAspectRatio(width: 3, height: 4)
    private let landscape = PanelAspectRatio(width: 4, height: 3)
    private let data = Data([1, 2, 3])

    func testAppliesSuggestionOnlyToRequestedAspectAndReusesAnalysis() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        await analyzer.complete(0, with: .success(edgeAnalysis))
        try await eventually { session.feedback == .applied }
        XCTAssertGreaterThan(session.framing(for: portrait).focusX, 0.5)
        XCTAssertEqual(session.framing(for: landscape), .centeredFill)
        session.invalidateApplication()
        session.request(data: data, aspect: landscape, maximumZoom: 4)
        XCTAssertEqual(session.feedback, .applied)
        let count = await analyzer.count
        XCTAssertEqual(count, 1)
    }

    func testGestureStartPreventsLateApplicationBeforeBindingCommit() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        session.invalidateApplication()
        await analyzer.complete(0, with: .success(edgeAnalysis))
        await drain()
        XCTAssertEqual(session.framing(for: portrait), .centeredFill)
        XCTAssertNil(session.feedback)
        let manual = ImageFraming(focusX: 0.4, focusY: 0.5, zoom: 1.5)
        session.setFraming(manual, for: portrait)
        XCTAssertEqual(session.framing(for: portrait), manual)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await eventually { session.feedback == .applied }
        let count = await analyzer.count
        XCTAssertEqual(count, 1)
    }

    func testOldImageCannotOverwriteNewImageOrItsAnalysisTask() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        session.replaceImage()
        session.request(data: Data([4]), aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 2)
        await analyzer.complete(0, with: .success(edgeAnalysis))
        await drain()
        XCTAssertTrue(session.isAnalyzing)
        XCTAssertEqual(session.framing(for: portrait), .centeredFill)
        await analyzer.complete(1, with: .success(emptyAnalysis))
        try await eventually { session.feedback == .noSubject }
        XCTAssertEqual(session.framing(for: portrait), .centeredFill)
    }

    func testLeavingPreviewDiscardsApplicationAndCanReuseRunningAnalysis() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        session.invalidateApplication()
        session.request(data: data, aspect: landscape, maximumZoom: 4)
        await analyzer.complete(0, with: .success(edgeAnalysis))
        try await eventually { session.feedback == .applied }
        XCTAssertEqual(session.framing(for: portrait), .centeredFill)
        let count = await analyzer.count
        XCTAssertEqual(count, 1)
    }

    func testExitRejectsLateResultsAndNextAppearanceCanAnalyzeAgain() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        session.discardAnalysis()
        await analyzer.complete(0, with: .success(edgeAnalysis))
        await drain()
        XCTAssertNil(session.feedback)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 2)
        await analyzer.complete(1, with: .success(edgeAnalysis))
        try await eventually { session.feedback == .applied }
    }

    func testFailureCanRetryAndNoSubjectDoesNotResetManualFraming() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        let manual = ImageFraming(focusX: 0.3, focusY: 0.6, zoom: 2)
        session.setFraming(manual, for: portrait)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        await analyzer.complete(0, with: .failure(UploadImagePreparationError.decoding))
        try await eventually { session.feedback == .failed }
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 2)
        await analyzer.complete(1, with: .success(emptyAnalysis))
        try await eventually { session.feedback == .noSubject }
        XCTAssertEqual(session.framing(for: portrait), manual)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        let count = await analyzer.count
        XCTAssertEqual(count, 2)
    }

    func testOversizedSubjectAppliesInsteadOfSuggestingAnotherFitMode() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        await analyzer.complete(
            0,
            with: .success(
                PhotoSubjectAnalysis(
                    sourceWidth: 4, sourceHeight: 3, faces: [],
                    subjects: [
                        PhotoSubjectRegion(bounds: .init(x: 0.35, y: 0.1, width: 0.65, height: 0.8))
                    ]
                )))
        try await eventually { session.feedback == .applied }
        XCTAssertGreaterThan(session.framing(for: portrait).focusX, 0.5)
        XCTAssertEqual(session.framing(for: portrait).zoom, 1)
        XCTAssertEqual(session.framing(for: landscape), .centeredFill)
    }

    func testUncontainableFacesStillPreserveManualFraming() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        let manual = ImageFraming(focusX: 0.3, focusY: 0.6, zoom: 2)
        session.setFraming(manual, for: portrait)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        await analyzer.complete(
            0,
            with: .success(
                PhotoSubjectAnalysis(
                    sourceWidth: 4, sourceHeight: 3,
                    faces: [
                        PhotoSubjectRegion(bounds: .init(x: 0.02, y: 0.2, width: 0.1, height: 0.1)),
                        PhotoSubjectRegion(bounds: .init(x: 0.88, y: 0.2, width: 0.1, height: 0.1)),
                    ],
                    subjects: [PhotoSubjectRegion(bounds: .full)]
                )))
        try await eventually { session.feedback == .cannotPreserve }
        XCTAssertEqual(session.framing(for: portrait), manual)
    }

    func testFreezePreservesTheFramingSerializedForRetry() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        let manual = ImageFraming(focusX: 0.3, focusY: 0.6, zoom: 2)
        session.setFraming(manual, for: portrait)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        session.freeze()
        let request = SharedImageRequest(
            instanceID: "test", fileName: "photo.jpg", contentType: "image/jpeg",
            fit: .fill, framing: session.framing(for: portrait), deviceIDs: ["desk"])
        session.setFraming(.centeredFill, for: portrait)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        await analyzer.complete(0, with: .success(edgeAnalysis))
        await drain()
        let saved = try TesseraeJSON.decoder().decode(
            SharedImageRequest.self, from: TesseraeJSON.encoder().encode(request))
        XCTAssertEqual(saved.framing, manual)
        XCTAssertEqual(saved.idempotencyKey, request.idempotencyKey)
        XCTAssertEqual(session.framing(for: portrait), saved.framing)
        XCTAssertNil(session.feedback)
        XCTAssertTrue(session.isFrozen)
        session.resumeEditing()
        session.setFraming(.centeredFill, for: portrait)
        XCTAssertEqual(session.framing(for: portrait), .centeredFill)
    }

    func testResetAndInvalidCapabilityDoNotStartAnalysis() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        session.request(data: data, aspect: portrait, maximumZoom: 0)
        let count = await analyzer.count
        XCTAssertEqual(count, 0)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        session.setFraming(.centeredFill, for: portrait)
        await analyzer.complete(0, with: .success(edgeAnalysis))
        await drain()
        XCTAssertEqual(session.framing(for: portrait), .centeredFill)
        XCTAssertNil(session.feedback)
    }

    func testAutomaticContextWaitsForPhotoAndReadyTargets() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        session.updateAutomaticContext(context(session, ready: false), data: data)
        session.updateAutomaticContext(context(session, targets: []), data: data)
        session.updateAutomaticContext(context(session), data: nil)
        let initialCount = await analyzer.count
        XCTAssertEqual(initialCount, 0)
        session.updateAutomaticContext(context(session), data: data)
        try await waitForRequest(analyzer, count: 1)
        await analyzer.complete(0, with: .success(edgeAnalysis))
        try await eventually { session.feedback == .applied }
        XCTAssertEqual(session.framing(for: portrait).zoom, 2)
    }

    func testAutomaticFramingRunsOncePerAspectAndResetIsPreserved() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        session.requestAutomatically(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        await analyzer.complete(0, with: .success(edgeAnalysis))
        try await eventually { session.feedback == .applied }
        session.setFraming(.centeredFill, for: portrait)
        session.updateAutomaticContext(context(session, ready: false), data: data)
        session.updateAutomaticContext(context(session), data: data)
        XCTAssertEqual(session.framing(for: portrait), .centeredFill)
        XCTAssertNil(session.feedback)
        session.requestAutomatically(data: data, aspect: landscape, maximumZoom: 4)
        XCTAssertEqual(session.feedback, .applied)
        let count = await analyzer.count
        XCTAssertEqual(count, 1)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        XCTAssertEqual(session.feedback, .applied)
        XCTAssertEqual(session.framing(for: portrait).zoom, 2)
    }

    func testManualInteractionBeforeAutomaticStartIsPreservedUntilImageChanges() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        session.userDidInteract(with: portrait)
        session.requestAutomatically(data: data, aspect: portrait, maximumZoom: 4)
        let count = await analyzer.count
        XCTAssertEqual(count, 0)
        session.replaceImage()
        session.requestAutomatically(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        await analyzer.complete(0, with: .success(edgeAnalysis))
        try await eventually { session.feedback == .applied }
    }

    func testAutomaticResultCannotOverrideGestureOrRestartItself() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        session.requestAutomatically(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        session.userDidInteract(with: portrait)
        await analyzer.complete(0, with: .success(edgeAnalysis))
        await drain()
        session.requestAutomatically(data: data, aspect: portrait, maximumZoom: 4)
        XCTAssertEqual(session.framing(for: portrait), .centeredFill)
        XCTAssertNil(session.feedback)
        let count = await analyzer.count
        XCTAssertEqual(count, 1)
    }

    func testAutomaticFailureOnlyRetriesOnExplicitRequest() async throws {
        let analyzer = ControlledPhotoAnalyzer()
        let session = PhotoFramingSession(analyzer: analyzer)
        session.requestAutomatically(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 1)
        await analyzer.complete(0, with: .failure(UploadImagePreparationError.decoding))
        try await eventually { session.feedback == .failed }
        session.requestAutomatically(data: data, aspect: portrait, maximumZoom: 4)
        let count = await analyzer.count
        XCTAssertEqual(count, 1)
        session.request(data: data, aspect: portrait, maximumZoom: 4)
        try await waitForRequest(analyzer, count: 2)
        await analyzer.complete(1, with: .success(edgeAnalysis))
        try await eventually { session.feedback == .applied }
    }

    private func context(
        _ session: PhotoFramingSession, ready: Bool = true, targets: Set<String> = ["desk"]
    ) -> PhotoFramingSession.AutomaticContext {
        .init(
            imageID: session.imageID, instanceID: "test", aspect: portrait,
            targetIDs: targets, maximumZoom: 4, isReady: ready)
    }

    private var edgeAnalysis: PhotoSubjectAnalysis {
        PhotoSubjectAnalysis(
            sourceWidth: 4, sourceHeight: 3,
            faces: [PhotoSubjectRegion(bounds: .init(x: 0.84, y: 0.2, width: 0.1, height: 0.1))],
            subjects: [])
    }

    private var emptyAnalysis: PhotoSubjectAnalysis {
        PhotoSubjectAnalysis(sourceWidth: 4, sourceHeight: 3, faces: [], subjects: [])
    }

    private func waitForRequest(_ analyzer: ControlledPhotoAnalyzer, count: Int) async throws {
        for _ in 0..<200 {
            if await analyzer.count >= count { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Analysis did not start")
        throw CancellationError()
    }

    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<200 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Session did not reach expected state")
    }

    private func drain() async {
        for _ in 0..<30 { await Task.yield() }
    }
}

private actor ControlledPhotoAnalyzer: PhotoSubjectAnalyzing {
    private var requests: [CheckedContinuation<PhotoSubjectAnalysis, Error>?] = []
    var count: Int { requests.count }

    func analyze(_ data: Data) async throws -> PhotoSubjectAnalysis {
        // Deliberately ignores cancellation to exercise late framework callbacks.
        try await withCheckedThrowingContinuation { requests.append($0) }
    }

    func complete(_ index: Int, with result: Result<PhotoSubjectAnalysis, Error>) {
        requests[index]?.resume(with: result)
        requests[index] = nil
    }
}
