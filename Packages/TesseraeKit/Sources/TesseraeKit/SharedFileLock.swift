import Darwin
import Foundation

struct SharedFileLock: Sendable {
    let url: URL

    func withLock<T>(timeout: TimeInterval = 10, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw ConnectionError.unavailable }
        defer { close(descriptor) }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EAGAIN else { throw ConnectionError.unavailable }
            try Task.checkCancellation()
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw ConnectionError.coordinationTimeout }
            Thread.sleep(forTimeInterval: 0.01)
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}

func writeProtected<T: Encodable>(_ value: T, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ConnectionCoding.encoder().encode(value).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
}

enum ConnectionCoding {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}
