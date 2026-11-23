import Foundation

public struct FileSnapshot: Equatable, Sendable {
    public let size: Int64
    public let modified: Date

    public init(size: Int64, modified: Date) {
        self.size = size
        self.modified = modified
    }

    public static func read(at url: URL) -> FileSnapshot? {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
        let seconds = Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000
        return FileSnapshot(size: Int64(info.st_size), modified: Date(timeIntervalSince1970: seconds))
    }
}

public struct SettleTracker: Sendable {
    private struct Pending {
        let url: URL
        var snapshot: FileSnapshot
        var unchangedSince: Date
    }

    public var settleInterval: TimeInterval
    public var emptyFileWait: TimeInterval
    private var pending: [String: Pending] = [:]

    public init(settleInterval: TimeInterval = 60, emptyFileWait: TimeInterval = 600) {
        self.settleInterval = settleInterval
        self.emptyFileWait = emptyFileWait
    }

    public var pendingCount: Int { pending.count }

    public var pendingURLs: [URL] {
        pending.values.map(\.url).sorted { $0.path < $1.path }
    }

    public mutating func track(_ url: URL, snapshot: FileSnapshot, now: Date) {
        if pending[url.path]?.snapshot == snapshot { return }
        pending[url.path] = Pending(url: url, snapshot: snapshot, unchangedSince: now)
    }

    public mutating func releaseReady(now: Date, currentSnapshot: (URL) -> FileSnapshot?) -> [URL] {
        for (path, entry) in pending {
            if let snapshot = currentSnapshot(entry.url) {
                track(entry.url, snapshot: snapshot, now: now)
            } else {
                pending[path] = nil
            }
        }
        // Whoever fills an empty file in later sets off a file event, which brings it back.
        pending = pending.filter { !hasStayedEmpty($0.value, now: now) }

        let unsettledNames = Set(pending.values.filter { !isSettled($0, now: now) }.map { PairKey($0.url) })
        let ready = pending.values
            .filter { !unsettledNames.contains(PairKey($0.url)) }
            .map(\.url)
            .sorted { $0.path < $1.path }
        for url in ready {
            pending[url.path] = nil
        }
        return ready
    }

    private func isSettled(_ entry: Pending, now: Date) -> Bool {
        entry.snapshot.size > 0 && now.timeIntervalSince(entry.unchangedSince) >= settleInterval
    }

    private func hasStayedEmpty(_ entry: Pending, now: Date) -> Bool {
        entry.snapshot.size == 0 && now.timeIntervalSince(entry.unchangedSince) >= emptyFileWait
    }
}
