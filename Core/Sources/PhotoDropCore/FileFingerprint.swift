import CryptoKit
import Foundation

public struct FileFingerprint: Hashable, Sendable {
    public static let headByteCount = 1_048_576

    public let name: String
    public let size: Int64
    public let headHash: String

    public init(name: String, size: Int64, headHash: String) {
        self.name = name
        self.size = size
        self.headHash = headHash
    }

    public init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var head = Data()
        // A single read can come back short on network or external volumes.
        while head.count < Self.headByteCount,
              let chunk = try handle.read(upToCount: Self.headByteCount - head.count),
              !chunk.isEmpty {
            head.append(chunk)
        }
        let size = try handle.seekToEnd()

        self.init(
            name: url.lastPathComponent,
            size: Int64(size),
            headHash: SHA256.hash(data: head).map { String(format: "%02x", $0) }.joined()
        )
    }
}
