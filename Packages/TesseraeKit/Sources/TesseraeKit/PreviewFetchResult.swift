import Foundation

public enum PreviewFetchResult: Equatable, Sendable {
    case image(data: Data, eTag: String?)
    case notModified
    case preparing(retryAfterSeconds: TimeInterval)
    case notFound
}
