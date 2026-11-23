import Foundation
import PhotoDropCore

protocol MediaImporting: Sendable {
    func importFiles(_ requests: [ImportRequest]) async -> [ImportResult]
}

actor ImportCoordinator {
    struct Timing: Sendable {
        var settle: TimeInterval = 60
        var poll: TimeInterval = 5
        var retryThrottle: TimeInterval = 60
        var retryEvery: TimeInterval = 600
        var watcherLatency: TimeInterval = 1
        var eventGrace: TimeInterval = 3
    }

    enum Activity: Equatable, Sendable {
        case stopped
        case checking(Int)
        case recordingExisting(Int)
        case importing(Int)
        case watching
    }

    struct Status: Equatable, Sendable {
        var activity = Activity.stopped
        var waitingCount = 0
    }

    enum Update: Sendable {
        case status(Status)
        case ledgerChanged
        case existingFilesRecorded(URL)
    }

    nonisolated let ledger: ImportLedger
    nonisolated let updates: AsyncStream<Update>

    private typealias Known = (fingerprint: FileFingerprint, modified: Date)
    private typealias SeenItem = (seen: Date, item: BaselineItem)

    private let importer: any MediaImporting
    private let timing: Timing
    private let log: @Sendable (String) -> Void
    private let send: AsyncStream<Update>.Continuation

    private var root: URL?
    private var session = 0
    private var watcher: FolderWatcher?
    private var tracker = SettleTracker()
    private var scanTask: Task<Void, Never>?
    private var pollTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var rescanWanted = false
    private var recordExistingSince: Date?
    private var arrivedWhileRecording: Set<String> = []
    private var scanProgress: Activity?
    private var importsLeft: Int?
    private var lastRetry = Date.distantPast
    private var lastStatus = Status()
    private var napGuard: (any NSObjectProtocol)?

    init(
        ledgerURL: URL,
        importer: any MediaImporting,
        timing: Timing = Timing(),
        log: @escaping @Sendable (String) -> Void
    ) throws {
        ledger = try ImportLedger(databaseURL: ledgerURL)
        self.importer = importer
        self.timing = timing
        self.log = log
        (updates, send) = AsyncStream.makeStream(of: Update.self)
    }

    // FSEvents reports real paths, so the root must be in the same form (/private/var, not /var).
    static func realURL(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else {
            return URL(fileURLWithPath: url.path, isDirectory: true)
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    func start(root folder: URL, settleInterval: TimeInterval? = nil, recordExistingSince since: Date? = nil) async {
        let newRoot = Self.realURL(folder)
        if root?.path == newRoot.path { return }
        await stop()

        session += 1
        let current = session
        root = newRoot
        tracker = SettleTracker(settleInterval: settleInterval ?? timing.settle)
        recordExistingSince = since
        lastRetry = .distantPast

        let watcher = FolderWatcher(root: newRoot, latency: timing.watcherLatency) { [weak self] event in
            Task { await self?.handle(event, session: current) }
        }
        self.watcher = watcher
        if watcher.start() {
            log("Started watching \(newRoot.path) (files must be unchanged for \(Int(tracker.settleInterval))s)")
        } else {
            log("Started watching \(newRoot.path), but live file events could not be set up")
        }
        retryTask = Task { await self.retryPeriodically(session: current) }
        requestScan()
    }

    func stop() async {
        guard root != nil else { return }
        session += 1
        root = nil
        watcher?.stop()
        watcher = nil
        let unfinished = [scanTask, pollTask, retryTask]
        scanTask = nil
        pollTask = nil
        retryTask = nil
        rescanWanted = false
        tracker = SettleTracker()
        recordExistingSince = nil
        arrivedWhileRecording = []
        log("Stopped watching")
        publish()

        // An import already handed to Photos must finish and be recorded before anything restarts.
        for task in unfinished {
            task?.cancel()
            await task?.value
        }
    }

    private func handle(_ event: FolderWatcher.Event, session current: Int) {
        guard session == current, let root else { return }
        switch event {
        case .rescanNeeded:
            log("Folders changed, checking the whole folder again")
            requestScan()
        case .filesChanged(let urls):
            let now = Date()
            for url in urls where MediaFilter.accepts(url, under: root) {
                guard let snapshot = FileSnapshot.read(at: url) else { continue }
                if recordExistingSince != nil {
                    arrivedWhileRecording.insert(url.path)
                }
                tracker.track(url, snapshot: snapshot, now: now)
            }
            requeueFailed(now: now)
            ensurePolling()
            publish()
        }
    }

    // MARK: - Scanning

    private func requestScan() {
        if scanTask != nil {
            rescanWanted = true
            return
        }
        let current = session
        scanTask = Task { await self.runScans(session: current) }
        publish()
    }

    private func runScans(session current: Int) async {
        repeat {
            rescanWanted = false
            await scan(session: current)
        } while session == current && rescanWanted

        if session == current {
            scanTask = nil
            ensurePolling()
            publish()
        }
    }

    private func scan(session current: Int) async {
        guard let root else { return }
        let recordingSince = recordExistingSince
        var visited = 0
        var checked = 0
        var queued = 0
        var recorded = 0
        var unrecorded: [SeenItem] = []

        func progress() -> Activity {
            recordingSince == nil ? .checking(checked) : .recordingExisting(checked)
        }
        scanProgress = progress()
        defer { scanProgress = nil }
        publish()

        let entries = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [],
            errorHandler: { _, _ in true }
        )
        while let url = entries?.nextObject() as? URL {
            visited += 1
            if visited.isMultiple(of: 256) {
                scanProgress = progress()
                ensurePolling()
                publish()
                await Task.yield()
                guard session == current else { return }
                recorded += recordExisting(&unrecorded, seenBefore: Date() - timing.eventGrace)
            }

            if url.lastPathComponent.hasPrefix(".") {
                entries?.skipDescendants()
                continue
            }
            guard MediaFilter.accepts(url, under: root),
                  let snapshot = FileSnapshot.read(at: url),
                  let check = try? ledger.check(url) else { continue }
            checked += 1

            switch check {
            case .handled:
                break
            case .new(let fingerprint), .previouslyFailed(let fingerprint):
                let now = Date()
                if let recordingSince, snapshot.modified < recordingSince, !arrivedWhileRecording.contains(url.path) {
                    unrecorded.append((now, BaselineItem(fingerprint: fingerprint, url: url, modified: snapshot.modified)))
                } else {
                    tracker.track(url, snapshot: snapshot, now: now)
                    queued += 1
                }
            }
        }

        guard recordingSince != nil else {
            log("Checked the folder: \(checked) photos and videos, \(queued) to import")
            return
        }

        // A file seen here may be a new arrival whose file event has not been delivered yet.
        try? await Task.sleep(for: .seconds(timing.eventGrace))
        guard session == current else { return }
        guard Self.isFolder(root) else {
            log("The folder went away before all existing files were recorded")
            return
        }
        recorded += recordExisting(&unrecorded, seenBefore: .distantFuture)
        guard unrecorded.isEmpty else { return }

        recordExistingSince = nil
        arrivedWhileRecording = []
        log("Recorded \(recorded) existing files as already imported, \(queued) newer ones to import")
        send.yield(.ledgerChanged)
        send.yield(.existingFilesRecorded(root))
    }

    private func recordExisting(_ unrecorded: inout [SeenItem], seenBefore cutoff: Date) -> Int {
        let ready = unrecorded.prefix { $0.seen <= cutoff }
        let items = ready.map(\.item).filter { !arrivedWhileRecording.contains($0.url.path) }
        guard !ready.isEmpty else { return 0 }
        do {
            try ledger.markBaseline(items)
            unrecorded.removeFirst(ready.count)
            return items.count
        } catch {
            log("Could not record existing files: \(error.localizedDescription)")
            return 0
        }
    }

    private static func isFolder(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: - Settling and importing

    private func ensurePolling() {
        guard pollTask == nil, tracker.pendingCount > 0 else { return }
        let current = session
        pollTask = Task { await self.pollUntilNothingIsPending(session: current) }
    }

    private func pollUntilNothingIsPending(session current: Int) async {
        while session == current, tracker.pendingCount > 0 {
            try? await Task.sleep(for: .seconds(timing.poll))
            guard session == current else { return }
            let ready = tracker.releaseReady(now: Date()) { FileSnapshot.read(at: $0) }
            if !ready.isEmpty {
                await importReleased(ready, session: current)
            }
            publish()
        }
        if session == current {
            pollTask = nil
            publish()
        }
    }

    private func importReleased(_ released: [URL], session current: Int) async {
        guard let root else { return }
        var left = released.count
        defer { importsLeft = nil }

        // Pairs always share a folder, so each folder can be checked and imported on its own.
        let byFolder = Dictionary(grouping: released) { $0.deletingLastPathComponent().path }
        for folder in byFolder.keys.sorted() {
            let files = byFolder[folder] ?? []
            var known: [URL: Known] = [:]
            for url in files {
                guard let snapshot = FileSnapshot.read(at: url), let check = try? ledger.check(url) else { continue }
                switch check {
                case .handled:
                    break
                case .new(let fingerprint), .previouslyFailed(let fingerprint):
                    known[url] = (fingerprint, snapshot.modified)
                }
            }
            left -= files.count - known.count

            for group in AssetPairing.groups(for: Array(known.keys)) {
                guard session == current else { return }
                importsLeft = left
                publish()

                let request = ImportRequest(primary: group.primary, isVideo: group.kind == .video, alternateRAW: group.alternateRAW)
                let outcome = await importer.importFiles([request]).first?.outcome ?? .failed("No result came back for this file.")
                record(outcome, for: group, known: known, root: root)
                left -= group.files.count
            }
        }
    }

    private func record(_ outcome: ImportResult.Outcome, for group: ImportGroup, known: [URL: Known], root: URL) {
        for file in group.files {
            guard let (fingerprint, modified) = known[file] else { continue }
            do {
                switch outcome {
                case .imported(let assetID):
                    try ledger.markImported(fingerprint, url: file, modified: modified, assetID: assetID)
                case .failed(let reason):
                    try ledger.markFailed(fingerprint, url: file, modified: modified, error: reason)
                }
            } catch {
                log("Could not update the import record for \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }

        let names = group.files.map(\.lastPathComponent).joined(separator: " + ")
        let place = Self.subfolder(of: group.primary, under: root)
        switch outcome {
        case .imported:
            log("Imported \(names)\(place.isEmpty ? "" : " from \(place)")")
        case .failed(let reason):
            log("Could not import \(names)\(place.isEmpty ? "" : " from \(place)"): \(reason)")
        }
        send.yield(.ledgerChanged)
    }

    static func subfolder(of file: URL, under root: URL?) -> String {
        let folder = file.deletingLastPathComponent().path
        guard let root = root?.path else { return folder }
        if folder == root { return "" }
        return folder.hasPrefix(root + "/") ? String(folder.dropFirst(root.count + 1)) : folder
    }

    // MARK: - Retrying failures

    private func retryPeriodically(session current: Int) async {
        while session == current {
            try? await Task.sleep(for: .seconds(timing.retryEvery))
            guard session == current else { return }
            requeueFailed(now: Date())
            ensurePolling()
            publish()
        }
    }

    private func requeueFailed(now: Date) {
        guard let root, now.timeIntervalSince(lastRetry) >= timing.retryThrottle else { return }
        lastRetry = now

        var requeued = 0
        for entry in (try? ledger.failedEntries()) ?? [] {
            let url = entry.url
            guard url.path.hasPrefix(root.path + "/"),
                  MediaFilter.accepts(url, under: root),
                  let snapshot = FileSnapshot.read(at: url) else { continue }
            tracker.track(url, snapshot: snapshot, now: now)
            requeued += 1
        }
        if requeued > 0 {
            log("Trying \(requeued) failed files again")
        }
    }

    // MARK: - Status

    private var activity: Activity {
        if root == nil { return .stopped }
        if let importsLeft { return .importing(importsLeft) }
        return scanProgress ?? .watching
    }

    private func publish() {
        let status = Status(activity: activity, waitingCount: tracker.pendingCount)
        keepAwake(while: status.waitingCount > 0 || ![.stopped, .watching].contains(status.activity))
        guard status != lastStatus else { return }
        lastStatus = status
        send.yield(.status(status))
    }

    // App Nap would otherwise slow the timers down while the window is closed.
    private func keepAwake(while busy: Bool) {
        if busy, napGuard == nil {
            napGuard = ProcessInfo.processInfo.beginActivity(
                options: .userInitiatedAllowingIdleSystemSleep,
                reason: "Importing new photos"
            )
        } else if !busy, let napGuard {
            ProcessInfo.processInfo.endActivity(napGuard)
            self.napGuard = nil
        }
    }
}
