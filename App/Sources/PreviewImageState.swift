import Foundation

struct PreviewImageState: Equatable {
    enum Phase: Equatable {
        case idle
        case loading
        case ready
        case unavailable
    }

    var data: Data?
    var eTag: String?
    var phase: Phase

    static let idle = PreviewImageState(
        data: nil,
        eTag: nil,
        phase: .idle
    )

    var showsProgress: Bool {
        phase == .loading && data == nil
    }
}
