import SwiftUI
import UIKit

/// One recognizer owns the whole touch sequence. SwiftUI's separate drag and
/// magnify values do not expose touch membership changes needed for rebasing.
struct PhotoFramingGesture: UIGestureRecognizerRepresentable {
    var isEnabled: Bool
    var minimumDistance: CGFloat
    var onChanged: ([Int: CGPoint]) -> Void
    var onEnded: () -> Void

    func makeUIGestureRecognizer(context: Context) -> PhotoFramingGestureRecognizer {
        let recognizer = PhotoFramingGestureRecognizer()
        recognizer.isEnabled = isEnabled
        recognizer.minimumDistance = minimumDistance
        return recognizer
    }

    func updateUIGestureRecognizer(_ recognizer: PhotoFramingGestureRecognizer, context: Context) {
        recognizer.isEnabled = isEnabled
        recognizer.minimumDistance = minimumDistance
    }

    func handleUIGestureRecognizerAction(_ recognizer: PhotoFramingGestureRecognizer, context: Context) {
        // UIKit can deliver several touch events before dispatching an action.
        // Consume every sample exactly once, including the final release position.
        for sample in recognizer.takeSamples() {
            onChanged(sample.mapValues { context.converter.convert(globalPoint: $0) })
        }
        if recognizer.state == .ended || recognizer.state == .cancelled {
            onEnded()
        }
    }
}

final class PhotoFramingGestureRecognizer: UIGestureRecognizer {
    var minimumDistance: CGFloat = 0
    private var trackedTouches: [UITouch: Int] = [:]
    private var nextTouchID = 0
    private var initialLocation: CGPoint?
    private var pendingSamples: [[Int: CGPoint]] = []

    func takeSamples() -> [[Int: CGPoint]] {
        let samples = pendingSamples
        pendingSamples.removeAll(keepingCapacity: true)
        return samples
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        for touch in touches {
            trackedTouches[touch] = nextTouchID
            nextTouchID += 1
        }
        let sample = locations()
        pendingSamples.append(sample)
        if initialLocation == nil { initialLocation = sample.values.first }
        if state == .possible {
            if minimumDistance == 0 || trackedTouches.count > 1 { state = .began }
        } else {
            state = .changed
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        let sample = locations()
        pendingSamples.append(sample)
        if state == .possible {
            if let start = initialLocation, let point = sample.values.first,
               hypot(point.x - start.x, point.y - start.y) >= minimumDistance {
                state = .began
            }
        } else {
            state = .changed
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard state != .possible else {
            state = .failed
            return
        }
        pendingSamples.append(locations())
        for touch in touches { trackedTouches.removeValue(forKey: touch) }
        // Adding/removing a finger changes the centroid without moving the image.
        pendingSamples.append(locations())
        state = trackedTouches.isEmpty ? .ended : .changed
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        state = state == .possible ? .failed : .cancelled
    }

    override func reset() {
        super.reset()
        trackedTouches.removeAll(keepingCapacity: true)
        pendingSamples.removeAll(keepingCapacity: true)
        initialLocation = nil
        nextTouchID = 0
    }

    private func locations() -> [Int: CGPoint] {
        Dictionary(uniqueKeysWithValues: trackedTouches.map { touch, id in
            (id, touch.location(in: nil))
        })
    }
}

/// Converts stable touch identities into incremental transforms, independent of
/// UIKit so finger handoffs can be checked with deterministic touch sequences.
struct PhotoFramingTouchTracker {
    struct Change {
        let translation: CGSize
        let magnification: CGFloat
        let anchor: CGPoint
    }

    private var previousTouches: [Int: CGPoint] = [:]

    mutating func update(touches: [Int: CGPoint]) -> Change? {
        let previous = previousTouches
        previousTouches = touches
        guard !touches.isEmpty, touches.count <= 2,
              touches.keys.allSatisfy({ previous[$0] != nil }),
              touches.count == previous.count else {
            // Rebase on membership, not just count: a replacement finger can
            // have a different position even when there are still two touches.
            return nil
        }
        let ids = touches.keys.sorted()
        let oldPoints = ids.compactMap { previous[$0] }
        let newPoints = ids.compactMap { touches[$0] }
        let oldCenter = centroid(oldPoints)
        let newCenter = centroid(newPoints)
        var magnification: CGFloat = 1
        if ids.count == 2 {
            let oldDistance = distance(oldPoints[0], oldPoints[1])
            let newDistance = distance(newPoints[0], newPoints[1])
            // Nearly coincident fingers cannot provide a stable scale ratio.
            if oldDistance >= 1, newDistance >= 1 { magnification = newDistance / oldDistance }
        }
        return Change(
            translation: CGSize(width: newCenter.x - oldCenter.x, height: newCenter.y - oldCenter.y),
            magnification: magnification,
            anchor: oldCenter
        )
    }

    private func centroid(_ points: [CGPoint]) -> CGPoint {
        CGPoint(
            x: points.reduce(0) { $0 + $1.x } / CGFloat(points.count),
            y: points.reduce(0) { $0 + $1.y } / CGFloat(points.count)
        )
    }

    private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(second.x - first.x, second.y - first.y)
    }
}
