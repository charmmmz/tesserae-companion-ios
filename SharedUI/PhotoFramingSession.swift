import Foundation
import Observation
import TesseraeKit

@MainActor @Observable
final class PhotoFramingSession {
    enum Feedback: Equatable {
        case applied, unchanged, noSubject, cannotPreserve, failed

        var text: String {
            switch self {
            case .applied: String(localized: "Adjusted")
            case .unchanged: String(localized: "Unchanged")
            case .noSubject: String(localized: "No subject")
            case .cannotPreserve: String(localized: "Try Fit")
            case .failed: String(localized: "Try again")
            }
        }

        var explanation: String {
            switch self {
            case .applied: String(localized: "Framing adjusted")
            case .unchanged: String(localized: "Framing already fits")
            case .noSubject: String(localized: "No clear subject found")
            case .cannotPreserve: String(localized: "Faces won't all fit. Try Fit or Blur.")
            case .failed: String(localized: "Couldn't analyze photo. Try again.")
            }
        }
    }

    struct AutomaticContext: Equatable {
        let imageID: UUID
        let instanceID: String?
        let aspect: PanelAspectRatio?
        let targetIDs: Set<String>
        let maximumZoom: Double
        let isReady: Bool
    }

    private(set) var framings: [PanelAspectRatio: ImageFraming] = [:]
    private(set) var isAnalyzing = false
    private(set) var feedback: Feedback?
    private(set) var isFrozen = false
    private(set) var imageID = UUID()
    @ObservationIgnored private var automaticAspects: Set<PanelAspectRatio> = []
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var analysis: PhotoSubjectAnalysis?
    @ObservationIgnored private var analysisTask: Task<PhotoSubjectAnalysis, Error>?
    @ObservationIgnored private var analysisID = UUID()
    @ObservationIgnored private var applicationTask: Task<Void, Never>?
    @ObservationIgnored private let analyzer: any PhotoSubjectAnalyzing

    init(analyzer: (any PhotoSubjectAnalyzing)? = nil) {
        if let analyzer {
            self.analyzer = analyzer
        } else {
            #if DEBUG
                if ProcessInfo.processInfo.environment["TESSERAE_UI_TEST_AUTO_FRAMING"] == "1" {
                    self.analyzer = FixturePhotoSubjectAnalyzer()
                } else {
                    self.analyzer = VisionPhotoSubjectAnalyzer()
                }
            #else
                self.analyzer = VisionPhotoSubjectAnalyzer()
            #endif
        }
    }

    func framing(for aspect: PanelAspectRatio) -> ImageFraming {
        framings[aspect] ?? .centeredFill
    }

    func setFraming(_ framing: ImageFraming, for aspect: PanelAspectRatio) {
        guard !isFrozen else { return }
        userDidInteract(with: aspect)
        framings[aspect] = framing
    }

    func userDidInteract(with aspect: PanelAspectRatio) {
        automaticAspects.insert(aspect)
        invalidateApplication()
    }

    func updateAutomaticContext(_ context: AutomaticContext, data: Data?) {
        invalidateApplication()
        guard context.imageID == imageID, context.isReady, !context.targetIDs.isEmpty,
            let aspect = context.aspect, let data
        else { return }
        requestAutomatically(data: data, aspect: aspect, maximumZoom: context.maximumZoom)
    }

    func requestAutomatically(data: Data, aspect: PanelAspectRatio, maximumZoom: Double) {
        guard !automaticAspects.contains(aspect) else { return }
        request(data: data, aspect: aspect, maximumZoom: maximumZoom)
    }

    /// Called at gesture start, before the preview commits its Binding at gesture end.
    func invalidateApplication() {
        generation = UUID()
        applicationTask?.cancel()
        applicationTask = nil
        isAnalyzing = false
        feedback = nil
    }

    func replaceImage() {
        discardAnalysis()
        imageID = UUID()
        framings = [:]
        automaticAspects = []
        isFrozen = false
    }

    func discardAnalysis() {
        invalidateApplication()
        imageID = UUID()
        analysisTask?.cancel()
        analysisTask = nil
        analysis = nil
    }

    func freeze() {
        invalidateApplication()
        isFrozen = true
    }

    func resumeEditing() {
        isFrozen = false
    }

    func request(data: Data, aspect: PanelAspectRatio, maximumZoom: Double) {
        guard !isFrozen, !isAnalyzing, maximumZoom.isFinite, maximumZoom >= 1 else { return }
        automaticAspects.insert(aspect)
        invalidateApplication()
        let requestGeneration = generation
        let requestImage = imageID
        let current = framing(for: aspect)
        if let analysis {
            apply(analysis, aspect: aspect, current: current, maximumZoom: maximumZoom)
            return
        }
        isAnalyzing = true
        if analysisTask == nil {
            let analyzer = analyzer
            analysisID = UUID()
            analysisTask = Task { try await analyzer.analyze(data) }
        }
        guard let work = analysisTask else { return }
        let workID = analysisID
        applicationTask = Task { [weak self] in
            do {
                let result = try await work.value
                guard let self, self.imageID == requestImage, self.analysisID == workID else {
                    return
                }
                // Cache remains useful after a gesture or a target change, but applying does not.
                self.analysis = result
                self.analysisTask = nil
                guard !Task.isCancelled, self.generation == requestGeneration, !self.isFrozen else {
                    return
                }
                self.isAnalyzing = false
                self.applicationTask = nil
                self.apply(result, aspect: aspect, current: current, maximumZoom: maximumZoom)
            } catch {
                guard let self, self.imageID == requestImage, self.analysisID == workID else {
                    return
                }
                self.analysisTask = nil
                guard !Task.isCancelled, self.generation == requestGeneration, !self.isFrozen else {
                    return
                }
                self.isAnalyzing = false
                self.applicationTask = nil
                self.feedback = .failed
            }
        }
    }

    private func apply(
        _ analysis: PhotoSubjectAnalysis, aspect: PanelAspectRatio,
        current: ImageFraming, maximumZoom: Double
    ) {
        switch AutoFramingSolver.suggest(
            analysis: analysis, target: aspect, current: current, maximumZoom: maximumZoom
        ) {
        case .suggested(let framing):
            framings[aspect] = framing
            feedback = .applied
        case .unchanged: feedback = .unchanged
        case .noReliableSubject: feedback = .noSubject
        case .cannotPreserveSubjects: feedback = .cannotPreserve
        case .invalidInput: feedback = .failed
        }
    }
}
