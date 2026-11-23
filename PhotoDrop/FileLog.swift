import Foundation

final class FileLog: Sendable {
    static let shared = FileLog()

    let fileURL: URL
    private let queue = DispatchQueue(label: "com.briancolclough.PhotoDrop.FileLog")

    init(fileName: String = "PhotoDrop.log") {
        fileURL = Self.realHomeDirectory
            .appendingPathComponent("Library/Logs", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    func write(_ message: String) {
        let line = "\(Date.now.formatted(Self.timestamp))  \(message)\n"
        queue.async { [fileURL] in
            let data = Data(line.utf8)
            if let handle = try? FileHandle(forWritingTo: fileURL) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: fileURL)
            }
        }
    }

    // NSHomeDirectory() is the sandbox container; the password database has the real home.
    static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: home), isDirectory: true)
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    }

    private static let timestamp = Date.VerbatimFormatStyle(
        format: """
            \(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \
            \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)
            """,
        locale: Locale(identifier: "en_US_POSIX"),
        timeZone: .autoupdatingCurrent,
        calendar: Calendar(identifier: .gregorian)
    )
}
