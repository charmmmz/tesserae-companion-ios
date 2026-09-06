/// A detected region in the upright image, with its origin at the top left.
public struct PhotoSubjectRegion: Equatable, Sendable {
    public let bounds: NormalizedImageCrop
    public let confidence: Double

    public init(bounds: NormalizedImageCrop, confidence: Double = 1) {
        self.bounds = bounds
        self.confidence = confidence
    }

    public static func fromLowerLeft(
        x: Double, y: Double, width: Double, height: Double,
        confidence: Double = 1
    ) -> Self? {
        guard
            let bounds = NormalizedImageCrop(
                x: x, y: 1 - y - height, width: width, height: height
            ).bounded
        else { return nil }
        guard confidence.isFinite else { return nil }
        return Self(bounds: bounds, confidence: confidence)
    }
}

public struct PhotoSubjectAnalysis: Equatable, Sendable {
    public let sourceWidth: Double
    public let sourceHeight: Double
    public let faces: [PhotoSubjectRegion]
    public let subjects: [PhotoSubjectRegion]

    public init(
        sourceWidth: Double, sourceHeight: Double,
        faces: [PhotoSubjectRegion], subjects: [PhotoSubjectRegion]
    ) {
        self.sourceWidth = sourceWidth
        self.sourceHeight = sourceHeight
        self.faces = faces
        self.subjects = subjects
    }
}

public enum AutoFramingResult: Equatable, Sendable {
    case suggested(ImageFraming)
    case unchanged
    case noReliableSubject
    /// The detected faces cannot all be preserved within a Fill crop.
    case cannotPreserveSubjects
    case invalidInput
}

public struct AutoFramingPolicy: Sendable {
    public var minimumFaceConfidence: Double = 0.8
    /// Padding as a fraction of each face's own width and height.
    public var facePadding: Double = 0.15
    public var maximumAutomaticZoom: Double = 2
    /// The subject group's longest relative dimension should occupy this much of the crop.
    public var targetSubjectOccupancy: Double = 0.85
    public init() {}
}

public enum AutoFramingSolver {
    public static func suggest(
        analysis: PhotoSubjectAnalysis,
        target: PanelAspectRatio,
        current: ImageFraming,
        maximumZoom: Double,
        policy: AutoFramingPolicy = AutoFramingPolicy()
    ) -> AutoFramingResult {
        guard
            [
                analysis.sourceWidth, analysis.sourceHeight, maximumZoom,
                current.focusX, current.focusY, current.zoom,
                policy.minimumFaceConfidence, policy.facePadding,
                policy.maximumAutomaticZoom, policy.targetSubjectOccupancy,
            ].allSatisfy(\.isFinite),
            analysis.sourceWidth > 0, analysis.sourceHeight > 0,
            maximumZoom >= 1, policy.facePadding >= 0,
            policy.maximumAutomaticZoom >= 1,
            policy.targetSubjectOccupancy > 0, policy.targetSubjectOccupancy <= 1,
            (0...1).contains(policy.minimumFaceConfidence)
        else { return .invalidInput }

        let faces = analysis.faces.filter {
            $0.confidence.isFinite && $0.confidence >= policy.minimumFaceConfidence
        }.compactMap { $0.bounds.bounded }
        let subjects = analysis.subjects.filter {
            $0.confidence.isFinite
        }.compactMap { $0.bounds.bounded }
        guard !faces.isEmpty || !subjects.isEmpty else { return .noReliableSubject }

        let base = ImageFraming.centeredFill.resolvedCrop(
            sourceWidth: analysis.sourceWidth, sourceHeight: analysis.sourceHeight,
            targetWidth: Double(target.width), targetHeight: Double(target.height)
        )
        guard base.width.isFinite, base.height.isFinite, base.width > 0, base.height > 0 else {
            return .invalidInput
        }
        let paddedFaces = faces.compactMap { face in
            NormalizedImageCrop(
                x: face.x - face.width * policy.facePadding,
                y: face.y - face.height * policy.facePadding,
                width: face.width * (1 + 2 * policy.facePadding),
                height: face.height * (1 + 2 * policy.facePadding)
            ).bounded
        }
        guard let composition = enclosing(subjects + paddedFaces) else { return .noReliableSubject }
        let relativeExtent = max(composition.width / base.width, composition.height / base.height)
        let zoom = max(
            1,
            min(
                maximumZoom, policy.maximumAutomaticZoom,
                policy.targetSubjectOccupancy / relativeExtent
            ))
        let width = base.width / zoom
        let height = base.height / zoom
        // A tighter crop follows the subject group; ordinary Fill retains its center preference.
        let preferredX = zoom > 1 ? composition.x + (composition.width - width) / 2 : base.x
        let preferredY = zoom > 1 ? composition.y + (composition.height - height) / 2 : base.y
        // Faces are protected; ordinary subject boxes only contribute to the visible-area score.
        // Large or scattered subject boxes can still yield a useful partial crop.
        let required = enclosing(faces)
        var ranges = (x: 0...max(0, 1 - width), y: 0...max(0, 1 - height))
        if let required {
            guard
                let faceRanges = placementRanges(
                    for: required, width: width, height: height)
            else { return .cannotPreserveSubjects }
            ranges = faceRanges
        }

        if let padded = enclosing(paddedFaces),
            let paddedRanges = placementRanges(for: padded, width: width, height: height)
        {
            ranges = paddedRanges
        }

        let regions = subjects.isEmpty ? faces : subjects
        let xs = candidates(
            range: ranges.x, length: width, preferred: preferredX,
            intervals: regions.map { ($0.x, $0.maxX) }
        )
        let ys = candidates(
            range: ranges.y, length: height, preferred: preferredY,
            intervals: regions.map { ($0.y, $0.maxY) }
        )
        var best = base
        var bestArea = -Double.infinity
        var bestDistance = Double.infinity
        for x in xs {
            for y in ys {
                let crop = NormalizedImageCrop(x: x, y: y, width: width, height: height)
                let area = unionArea(regions.compactMap { $0.intersection(crop) })
                let dx = x - preferredX
                let dy = y - preferredY
                let distance = dx * dx + dy * dy
                if area > bestArea + epsilon
                    || (abs(area - bestArea) <= epsilon && distance < bestDistance - epsilon)
                {
                    best = crop
                    bestArea = area
                    bestDistance = distance
                }
            }
        }
        let framing = ImageFraming(
            focusX: best.x + best.width / 2,
            focusY: best.y + best.height / 2,
            zoom: zoom
        )
        let resolved = framing.resolvedCrop(
            sourceWidth: analysis.sourceWidth, sourceHeight: analysis.sourceHeight,
            targetWidth: Double(target.width), targetHeight: Double(target.height)
        )
        if let required, !resolved.contains(required) { return .cannotPreserveSubjects }
        let previous = current.resolvedCrop(
            sourceWidth: analysis.sourceWidth, sourceHeight: analysis.sourceHeight,
            targetWidth: Double(target.width), targetHeight: Double(target.height)
        )
        return resolved.approximatelyEquals(previous) ? .unchanged : .suggested(framing)
    }

    private static let epsilon = 0.000_000_001

    private static func enclosing(_ regions: [NormalizedImageCrop]) -> NormalizedImageCrop? {
        guard let first = regions.first else { return nil }
        return regions.dropFirst().reduce(first) { a, b in
            let x = min(a.x, b.x)
            let y = min(a.y, b.y)
            return NormalizedImageCrop(
                x: x, y: y, width: max(a.maxX, b.maxX) - x, height: max(a.maxY, b.maxY) - y
            )
        }
    }

    private static func placementRanges(
        for region: NormalizedImageCrop, width: Double, height: Double
    ) -> (x: ClosedRange<Double>, y: ClosedRange<Double>)? {
        let minX = max(0, region.maxX - width)
        let maxX = min(1 - width, region.x)
        let minY = max(0, region.maxY - height)
        let maxY = min(1 - height, region.y)
        guard minX <= maxX + epsilon, minY <= maxY + epsilon else { return nil }
        return (min(minX, maxX)...maxX, min(minY, maxY)...maxY)
    }

    private static func candidates(
        range: ClosedRange<Double>, length: Double, preferred: Double, intervals: [(Double, Double)]
    ) -> [Double] {
        var values = [range.lowerBound, range.upperBound, preferred]
        for (start, end) in intervals {
            values += [start, end - length, (start + end - length) / 2]
        }
        return Set(values.map { min(max($0, range.lowerBound), range.upperBound) }).sorted()
    }

    /// Exact rectangle-union area; overlapping detections must not get extra votes.
    private static func unionArea(_ rectangles: [NormalizedImageCrop]) -> Double {
        let edges = Set(rectangles.flatMap { [$0.x, $0.maxX] }).sorted()
        var area = 0.0
        for (left, right) in zip(edges, edges.dropFirst()) {
            let intervals = rectangles.filter { $0.x < right && $0.maxX > left }
                .map { ($0.y, $0.maxY) }.sorted { $0.0 < $1.0 }
            var end = 0.0
            var height = 0.0
            for interval in intervals {
                height += max(0, interval.1 - max(end, interval.0))
                end = max(end, interval.1)
            }
            area += (right - left) * height
        }
        return area
    }
}

extension NormalizedImageCrop {
    fileprivate var maxX: Double { x + width }
    fileprivate var maxY: Double { y + height }

    fileprivate var bounded: Self? {
        guard [x, y, width, height, maxX, maxY].allSatisfy(\.isFinite),
            width > 0, height > 0
        else { return nil }
        let left = max(0, x)
        let top = max(0, y)
        let right = min(1, maxX)
        let bottom = min(1, maxY)
        guard right > left, bottom > top else { return nil }
        return Self(x: left, y: top, width: right - left, height: bottom - top)
    }

    fileprivate func intersection(_ other: Self) -> Self? {
        let left = max(x, other.x)
        let top = max(y, other.y)
        let right = min(maxX, other.maxX)
        let bottom = min(maxY, other.maxY)
        guard right > left, bottom > top else { return nil }
        return Self(x: left, y: top, width: right - left, height: bottom - top)
    }

    fileprivate func contains(_ other: Self) -> Bool {
        let epsilon = 0.000_000_001
        return x <= other.x + epsilon && y <= other.y + epsilon
            && maxX >= other.maxX - epsilon && maxY >= other.maxY - epsilon
    }

    fileprivate func approximatelyEquals(_ other: Self) -> Bool {
        zip([x, y, width, height], [other.x, other.y, other.width, other.height])
            .allSatisfy { abs($0 - $1) < 0.000_000_001 }
    }
}
