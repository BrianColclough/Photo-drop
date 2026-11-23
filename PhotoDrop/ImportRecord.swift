import Foundation

struct ImportRecord {
    enum ExistingFiles: Equatable {
        case alreadyDealtWith
        case stillBeingRecorded(since: Date)
        case mustAsk
    }

    private enum Keys {
        static let watching = "watching"
        static let preparedFolders = "preparedFolders"
        static let recordingStarted = "recordingExistingStarted"
    }

    let fileURL: URL
    let defaults: UserDefaults

    var fileExists: Bool {
        FileManager.default.fileExists(atPath: fileURL.path)
    }

    var watchingIsOn: Bool {
        get { defaults.bool(forKey: Keys.watching) }
        nonmutating set { defaults.set(newValue, forKey: Keys.watching) }
    }

    func existingFiles(in folder: String) -> ExistingFiles {
        if preparedFolders.contains(folder) { return .alreadyDealtWith }
        if let started = recordingStarted[folder] { return .stillBeingRecorded(since: started) }
        return .mustAsk
    }

    func startRecordingExistingFiles(in folder: String, at start: Date) {
        var started = recordingStarted
        started[folder] = start
        defaults.set(started, forKey: Keys.recordingStarted)
    }

    func markPrepared(_ folder: String) {
        if !preparedFolders.contains(folder) {
            defaults.set(preparedFolders + [folder], forKey: Keys.preparedFolders)
        }
        var started = recordingStarted
        started[folder] = nil
        defaults.set(started, forKey: Keys.recordingStarted)
    }

    // A prepared folder with no record would be imported again in full, without asking.
    @discardableResult
    func forgetPreparedFoldersIfFileIsMissing() -> Bool {
        guard !fileExists, !(preparedFolders.isEmpty && recordingStarted.isEmpty) else { return false }
        forgetPreparedFolders()
        return true
    }

    // Close the ledger first: an open one keeps writing to the deleted file.
    func reset() throws {
        watchingIsOn = false
        forgetPreparedFolders()
        for suffix in ["", "-journal", "-wal", "-shm"] {
            let path = fileURL.path + suffix
            if FileManager.default.fileExists(atPath: path) {
                try FileManager.default.removeItem(atPath: path)
            }
        }
    }

    private var preparedFolders: [String] {
        defaults.stringArray(forKey: Keys.preparedFolders) ?? []
    }

    private var recordingStarted: [String: Date] {
        defaults.dictionary(forKey: Keys.recordingStarted) as? [String: Date] ?? [:]
    }

    private func forgetPreparedFolders() {
        defaults.removeObject(forKey: Keys.preparedFolders)
        defaults.removeObject(forKey: Keys.recordingStarted)
    }
}
