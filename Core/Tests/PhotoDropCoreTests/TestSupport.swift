import Foundation

@discardableResult
func withTempDirectory<Result>(_ body: (URL) throws -> Result) throws -> Result {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PhotoDropCoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    return try body(directory)
}

@discardableResult
func writeFile(_ relativePath: String, in directory: URL, contents: Data, modified: Date? = nil) throws -> URL {
    let url = directory.appendingPathComponent(relativePath)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url)
    if let modified {
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    }
    return url
}

func bytes(_ count: Int, filledWith value: UInt8) -> Data {
    Data(repeating: value, count: count)
}

func file(_ path: String) -> URL {
    URL(fileURLWithPath: path)
}
