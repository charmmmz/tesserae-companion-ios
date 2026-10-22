import TesseraeKit
import Testing
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

@Suite("Manual photo framing continuity")
struct PhotoFramingInteractionTests {
    private let geometry = PhotoFramingInteraction.Geometry(
        canvas: CGSize(width: 300, height: 400),
        source: CGSize(width: 1_600, height: 1_200),
        target: CGSize(width: 1_200, height: 1_600),
        maximumZoom: 4
    )

    @Test("Reversing a drag at either edge moves immediately", arguments: [-1.0, 1.0])
    func reversesAtEdge(direction: Double) throws {
        var interaction = PhotoFramingInteraction()
        interaction.begin(at: .centeredFill)
        interaction.update(touches: [0: .zero], geometry: geometry)
        interaction.update(touches: [0: CGPoint(x: direction * 1_000, y: 0)], geometry: geometry)
        let edge = rect(try #require(interaction.previewFraming))
        interaction.update(touches: [0: CGPoint(x: direction * 990, y: 0)], geometry: geometry)
        let reversed = rect(try #require(interaction.previewFraming))
        #expect(abs(reversed.x - edge.x + direction * 10) < 0.000_001)
    }

    @Test("Pinching back from either zoom limit responds immediately", arguments: [false, true])
    func reversesAtZoomLimit(maximum: Bool) throws {
        var interaction = PhotoFramingInteraction()
        interaction.begin(at: ImageFraming(focusX: 0.5, focusY: 0.5, zoom: 2))
        interaction.update(touches: pinch(scale: 1), geometry: geometry)
        interaction.update(touches: pinch(scale: maximum ? 10 : 0.1), geometry: geometry)
        #expect(interaction.previewFraming?.zoom == (maximum ? 4 : 1))
        interaction.update(touches: pinch(scale: maximum ? 9 : 0.11), geometry: geometry)
        let framing = try #require(interaction.previewFraming)
        #expect(abs(framing.zoom - (maximum ? 3.6 : 1.1)) < 0.000_001)
    }

    @Test("Release does not apply the final translation twice, and the next drag starts in place")
    func releaseAndNextDrag() throws {
        var interaction = PhotoFramingInteraction()
        interaction.begin(at: .centeredFill)
        interaction.update(touches: [0: .zero], geometry: geometry)
        let touches = [0: CGPoint(x: 40, y: 0)]
        interaction.update(touches: touches, geometry: geometry)
        let visible = try #require(interaction.previewFraming)
        interaction.update(touches: touches, geometry: geometry)
        interaction.update(touches: [:], geometry: geometry)
        let result = interaction.end()
        let committed = try #require(result)
        #expect(committed == visible)
        #expect(!interaction.isActive)

        interaction.begin(at: committed)
        #expect(interaction.previewFraming == visible)
        interaction.update(touches: [1: CGPoint(x: 100, y: 80)], geometry: geometry)
        interaction.update(touches: [1: CGPoint(x: 110, y: 80)], geometry: geometry)
        let next = rect(try #require(interaction.previewFraming))
        #expect(abs(next.x - rect(visible).x - 10) < 0.000_001)
    }

    @Test("Drag to pinch to drag rebases without a jump, whichever finger lifts", arguments: [0, 1])
    func fingerHandoffs(liftedFinger: Int) throws {
        var interaction = PhotoFramingInteraction()
        interaction.begin(at: ImageFraming(focusX: 0.5, focusY: 0.5, zoom: 2))
        interaction.update(touches: [0: CGPoint(x: 50, y: 80)], geometry: geometry)
        interaction.update(touches: [0: CGPoint(x: 60, y: 90)], geometry: geometry)
        let dragged = try #require(interaction.previewFraming)
        // The new finger moves the centroid 50pt without any physical motion.
        interaction.update(touches: [0: CGPoint(x: 60, y: 90), 1: CGPoint(x: 160, y: 90)], geometry: geometry)
        #expect(interaction.previewFraming == dragged)
        let oldRect = rect(dragged)
        let sourcePoint = CGPoint(x: (110 - oldRect.x) / oldRect.width,
                                  y: (90 - oldRect.y) / oldRect.height)
        let expanded = [0: CGPoint(x: 35, y: 100), 1: CGPoint(x: 185, y: 100)]
        interaction.update(touches: expanded, geometry: geometry)
        let pinched = try #require(interaction.previewFraming)
        let pinchedRect = rect(pinched)
        #expect(abs(pinched.zoom - 3) < 0.000_001)
        #expect(abs(pinchedRect.x + sourcePoint.x * pinchedRect.width - 110) < 0.000_001)
        #expect(abs(pinchedRect.y + sourcePoint.y * pinchedRect.height - 100) < 0.000_001)

        let remainingID = 1 - liftedFinger
        let remaining = try #require(expanded[remainingID])
        interaction.update(touches: [remainingID: remaining], geometry: geometry)
        #expect(interaction.previewFraming == pinched)
        interaction.update(touches: [remainingID: CGPoint(x: remaining.x + 7, y: remaining.y - 5)], geometry: geometry)
        let resumed = rect(try #require(interaction.previewFraming))
        #expect(abs(resumed.x - pinchedRect.x - 7) < 0.000_001)
        #expect(abs(resumed.y - pinchedRect.y + 5) < 0.000_001)

        // A second pinch within the same touch sequence starts from scale 1.
        let beforeSecondPinch = interaction.previewFraming
        interaction.update(touches: [remainingID: CGPoint(x: 80, y: 100), 2: CGPoint(x: 180, y: 100)], geometry: geometry)
        #expect(interaction.previewFraming == beforeSecondPinch)
        interaction.update(touches: [remainingID: CGPoint(x: 90, y: 100), 2: CGPoint(x: 170, y: 100)], geometry: geometry)
        #expect(abs(try #require(interaction.previewFraming).zoom - 2.4) < 0.000_001)
    }

    @Test("Replacing a finger or adding a third finger cannot introduce a crop jump")
    func changedTouchMembership() throws {
        var interaction = PhotoFramingInteraction()
        interaction.begin(at: ImageFraming(focusX: 0.5, focusY: 0.5, zoom: 2))
        interaction.update(touches: pinch(scale: 1), geometry: geometry)
        interaction.update(touches: pinch(scale: 1.2), geometry: geometry)
        let before = try #require(interaction.previewFraming)
        interaction.update(touches: [0: CGPoint(x: 100, y: 200), 2: CGPoint(x: 250, y: 80)], geometry: geometry)
        #expect(interaction.previewFraming == before)
        interaction.update(touches: [0: CGPoint(x: 100, y: 200), 2: CGPoint(x: 250, y: 80), 3: .zero], geometry: geometry)
        #expect(interaction.previewFraming == before)
        interaction.update(touches: [0: CGPoint(x: 100, y: 200), 2: CGPoint(x: 250, y: 80)], geometry: geometry)
        #expect(interaction.previewFraming == before)
    }

    @Test("Cancellation without a final sample preserves the last visible crop")
    func interruptedGesture() throws {
        var interaction = PhotoFramingInteraction()
        interaction.begin(at: .centeredFill)
        interaction.update(touches: pinch(scale: 1), geometry: geometry)
        interaction.update(touches: pinch(scale: 2), geometry: geometry)
        let visible = try #require(interaction.previewFraming)
        let committed = interaction.end()
        let duplicateCompletion = interaction.end()
        #expect(committed == visible)
        #expect(duplicateCompletion == nil)
        #expect(!interaction.isActive)
    }

    @Test("A previous toolbar timer cannot reveal controls during or after a new drag")
    func staleControlsTimer() {
        var interaction = PhotoFramingInteraction()
        interaction.begin(at: .centeredFill)
        interaction.end()
        let oldTimer = interaction.controlsRevealGeneration

        interaction.begin(at: .centeredFill)
        interaction.revealControls(generation: oldTimer)
        #expect(interaction.controlsHidden)
        interaction.revealControls(generation: interaction.controlsRevealGeneration)
        #expect(interaction.controlsHidden)
        interaction.end()
        interaction.revealControls(generation: oldTimer)
        #expect(interaction.controlsHidden)
        interaction.revealControls(generation: interaction.controlsRevealGeneration)
        #expect(!interaction.controlsHidden)
    }

    @Test("Changing the preview clears the gesture and invalidates pending controls timers")
    func resetPreview() {
        var interaction = PhotoFramingInteraction()
        interaction.begin(at: .centeredFill)
        let previousGeneration = interaction.controlsRevealGeneration
        interaction.reset()
        #expect(interaction.previewFraming == nil)
        #expect(!interaction.isActive)
        #expect(!interaction.controlsHidden)
        #expect(interaction.controlsRevealGeneration != previousGeneration)
    }

    private func pinch(scale: CGFloat) -> [Int: CGPoint] {
        [0: CGPoint(x: 150 - 50 * scale, y: 200), 1: CGPoint(x: 150 + 50 * scale, y: 200)]
    }

    private func rect(_ framing: ImageFraming) -> PanelImagePreviewRect {
        framing.framedPreviewRect(
            sourceWidth: geometry.source.width, sourceHeight: geometry.source.height,
            canvasWidth: geometry.canvas.width, canvasHeight: geometry.canvas.height,
            targetWidth: geometry.target.width, targetHeight: geometry.target.height
        )
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
