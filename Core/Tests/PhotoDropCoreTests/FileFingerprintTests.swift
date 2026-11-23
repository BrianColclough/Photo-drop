import CryptoKit
import Foundation
import PhotoDropCore
import Testing

@Suite struct FileFingerprintTests {
    let megabyte = FileFingerprint.headByteCount

    func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    @Test func smallFileHashesTheWholeFile() throws {
        try withTempDirectory { directory in
            let contents = Data("hello photo drop".utf8)
            let url = try writeFile("sub/IMG_1.JPG", in: directory, contents: contents)

            let fingerprint = try FileFingerprint(url: url)
            #expect(fingerprint.name == "IMG_1.JPG")
            #expect(fingerprint.size == Int64(contents.count))
            #expect(fingerprint.headHash == hex(contents))
        }
    }

    @Test func emptyFileHasAFingerprint() throws {
        try withTempDirectory { directory in
            let url = try writeFile("empty.jpg", in: directory, contents: Data())
            let fingerprint = try FileFingerprint(url: url)
            #expect(fingerprint.size == 0)
            #expect(fingerprint.headHash == hex(Data()))
        }
    }

    @Test func fileOfExactlyOneMegabyteHashesTheWholeFile() throws {
        try withTempDirectory { directory in
            let contents = bytes(megabyte, filledWith: 3)
            let url = try writeFile("exact.mov", in: directory, contents: contents)
            #expect(try FileFingerprint(url: url).headHash == hex(contents))
        }
    }

    @Test func largeFileHashesOnlyTheFirstMegabyte() throws {
        try withTempDirectory { directory in
            let head = bytes(megabyte, filledWith: 1)
            let url = try writeFile("big.mov", in: directory, contents: head + bytes(megabyte / 2, filledWith: 2))

            let fingerprint = try FileFingerprint(url: url)
            #expect(fingerprint.size == Int64(megabyte + megabyte / 2))
            #expect(fingerprint.headHash == hex(head))
        }
    }

    @Test func sameSizeFilesDifferingOnlyAfterTheFirstMegabyteMatch() throws {
        try withTempDirectory { directory in
            let head = bytes(megabyte, filledWith: 1)
            let first = try writeFile("a/clip.mov", in: directory, contents: head + bytes(1000, filledWith: 2))
            let second = try writeFile("b/clip.mov", in: directory, contents: head + bytes(1000, filledWith: 9))

            #expect(try FileFingerprint(url: first) == FileFingerprint(url: second))
        }
    }

    @Test func filesDifferingOnlyAfterTheFirstMegabyteWithDifferentSizesDiffer() throws {
        try withTempDirectory { directory in
            let head = bytes(megabyte, filledWith: 1)
            let first = try writeFile("a/clip.mov", in: directory, contents: head + bytes(1000, filledWith: 2))
            let second = try writeFile("b/clip.mov", in: directory, contents: head + bytes(1001, filledWith: 2))

            let firstFingerprint = try FileFingerprint(url: first)
            let secondFingerprint = try FileFingerprint(url: second)
            #expect(firstFingerprint.headHash == secondFingerprint.headHash)
            #expect(firstFingerprint != secondFingerprint)
        }
    }

    @Test func differentContentInTheFirstMegabyteDiffers() throws {
        try withTempDirectory { directory in
            let first = try writeFile("a/IMG_1.jpg", in: directory, contents: bytes(5000, filledWith: 1))
            let second = try writeFile("b/IMG_1.jpg", in: directory, contents: bytes(5000, filledWith: 2))
            #expect(try FileFingerprint(url: first) != FileFingerprint(url: second))
        }
    }

    @Test func missingFileThrows() throws {
        try withTempDirectory { directory in
            #expect(throws: (any Error).self) {
                try FileFingerprint(url: directory.appendingPathComponent("missing.jpg"))
            }
        }
    }
}
