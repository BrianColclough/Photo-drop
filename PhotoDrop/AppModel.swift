import AppKit
import Observation
import Photos
import PhotoDropCore
import Synchronization

final class AlbumImporter: MediaImporting {
    private let title: Mutex<String>
    private let photos = PhotosImporter()

    init(title: String) {
        self.title = Mutex(title)
    }

    func setTitle(_ newTitle: String) {
        title.withLock { $0 = newTitle }
    }

    func importFiles(_ requests: [ImportRequest]) async -> [ImportResult] {
        do {
            let album = try await photos.findOrCreateAlbum(titled: title.withLock { $0 })
            return await photos.importFiles(requests, intoAlbumWithID: album.id)
        } catch {
            return requests.map { ImportResult(request: $0, outcome: .failed(error.localizedDescription)) }
        }
    }
}

struct RecentImport: Identifiable {
    let id: String
    let fileName: String
    let subfolder: String
    let time: Date
    let error: String?

    init(_ entry: LedgerEntry, under root: URL?) {
        let fingerprint = entry.fingerprint
        id = "\(fingerprint.name)|\(fingerprint.size)|\(fingerprint.headHash)"
        fileName = entry.url.lastPathComponent
        subfolder = ImportCoordinator.subfolder(of: entry.url, under: root)
        time = entry.timestamp
        error = entry.status == .failed ? entry.errorMessage ?? "Import failed" : nil
    }
}

@MainActor
@Observable
final class AppModel {
    enum Blocker: Equatable {
        case driveNotConnected
        case photosAccessNeeded
        case problem(String)
    }

    private enum Keys {
        static let albumTitle = "albumTitle"
        static let settleSeconds = "settleSeconds"
    }

    static let defaultAlbum = "Camera Photos"
    static let settleRange = 5...600

    static var ledgerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoDrop", isDirectory: true)
            .appendingPathComponent("ledger.sqlite")
    }

    private(set) var folderPath: String?
    private(set) var albumTitle: String
    private(set) var isWatching: Bool
    private(set) var settleSeconds: Int
    private(set) var blocker: Blocker?
    private(set) var status = ImportCoordinator.Status()
    private(set) var importedToday = 0
    private(set) var recent: [RecentImport] = []
    private(set) var openAtLogin = false
    private(set) var loginItemNote: String?
    private var knownAlbums: [String] = []
    private var coordinator: ImportCoordinator?

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let record: ImportRecord
    @ObservationIgnored private let folderAccess: FolderAccess
    @ObservationIgnored private let photos = PhotosImporter()
    @ObservationIgnored private let albumImporter: AlbumImporter
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var queuedWork: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let record = ImportRecord(fileURL: Self.ledgerURL, defaults: defaults)
        let title = defaults.string(forKey: Keys.albumTitle) ?? Self.defaultAlbum
        let savedSettle = defaults.integer(forKey: Keys.settleSeconds)
        self.defaults = defaults
        self.record = record
        folderAccess = FolderAccess(defaults: defaults)
        albumTitle = title
        albumImporter = AlbumImporter(title: title)
        isWatching = record.watchingIsOn
        settleSeconds = savedSettle > 0 ? Self.settleRange.clamping(savedSettle) : 60
        openRecord()

        folderAccess.onAvailabilityChange = { [weak self] available in
            FileLog.shared.write(available ? "Drive connected" : "Drive not connected")
            self?.enqueue { model in
                // A re-plugged drive needs a fresh watcher even when the path is the same.
                if !available { await model.coordinator?.stop() }
                await model.reconcile()
            }
        }
        folderAccess.startObservingVolumes()
        folderAccess.refresh()
        folderPath = folderAccess.savedPath

        observe(NSApplication.didBecomeActiveNotification) { model in
            model.refreshLoginItem()
            if model.blocker == .photosAccessNeeded { model.enqueueReconcile() }
            else { model.loadAlbumsIfAllowed() }
        }
        observe(.NSCalendarDayChanged) { $0.refreshRecent() }

        refreshLoginItem()
        refreshRecent()
        loadAlbumsIfAllowed()
        enqueueReconcile()
    }

    // MARK: - What the window shows

    var albumChoices: [String] {
        Set(knownAlbums).union([albumTitle]).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var canWatch: Bool {
        coordinator != nil && (isWatching || folderPath != nil)
    }

    var statusText: String {
        switch blocker {
        case .driveNotConnected: return "Drive not connected"
        case .photosAccessNeeded: return "Photos access needed"
        case .problem(let text): return text
        case nil: break
        }
        guard folderPath != nil else { return "Choose a folder to watch" }

        switch status.activity {
        case .stopped:
            return isWatching ? "Starting…" : "Not watching"
        case .checking(let count):
            return "Checking the folder for new files • \(count.formatted()) checked"
        case .recordingExisting(let count):
            return "Recording existing files • \(count.formatted()) so far"
        case .importing(let count):
            return "Importing \(Self.files(count))"
        case .watching where status.waitingCount > 0:
            return "Waiting for \(Self.files(status.waitingCount)) to finish copying"
        case .watching:
            return "Watching • \(importedToday.formatted()) imported today"
        }
    }

    private static func files(_ count: Int) -> String {
        count == 1 ? "1 file" : "\(count.formatted()) files"
    }

    // MARK: - What the window does

    func chooseFolder() {
        guard let url = FolderAccess.chooseFolder() else { return }
        do {
            try folderAccess.save(url)
        } catch {
            blocker = .problem("Could not remember that folder: \(error.localizedDescription)")
            return
        }
        folderPath = folderAccess.savedPath
        refreshRecent()
        enqueueReconcile()
    }

    func setWatching(_ on: Bool) {
        isWatching = on
        record.watchingIsOn = on
        enqueueReconcile()
    }

    func setSettleSeconds(_ seconds: Int) {
        let seconds = Self.settleRange.clamping(seconds)
        guard seconds != settleSeconds else { return }
        settleSeconds = seconds
        defaults.set(seconds, forKey: Keys.settleSeconds)
        enqueue { await $0.coordinator?.setSettleInterval(TimeInterval(seconds)) }
    }

    func resetImportRecord() {
        guard confirmResettingImportRecord() else { return }
        isWatching = false
        enqueue { model in
            await model.closeRecord()
            model.blocker = nil
            do {
                try model.record.reset()
                FileLog.shared.write("Reset the import record: watching is off, and the first-time question will be asked when it is switched on again")
            } catch {
                let problem = "Could not delete the import record: \(error.localizedDescription)"
                model.blocker = .problem(problem)
                FileLog.shared.write(problem)
            }
            model.openRecord()
            model.refreshRecent()
        }
    }

    func selectAlbum(_ name: String) {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        albumTitle = title
        defaults.set(title, forKey: Keys.albumTitle)
        albumImporter.setTitle(title)
        enqueueReconcile()
    }

    func setOpenAtLogin(_ on: Bool) {
        loginItemNote = on ? LoginItem.register() : LoginItem.unregister()
        refreshLoginItem()
    }

    func openPhotosPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Photos") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Keeping the coordinator in step

    private func enqueueReconcile() {
        enqueue { await $0.reconcile() }
    }

    private func enqueue(_ work: @escaping @MainActor (AppModel) async -> Void) {
        let earlier = queuedWork
        queuedWork = Task { [weak self] in
            await earlier?.value
            if let self { await work(self) }
        }
    }

    private func reconcile() async {
        guard coordinator != nil else { return }
        guard isWatching, folderAccess.hasSavedFolder else {
            await coordinator?.stop()
            blocker = nil
            return
        }
        guard await PhotosImporter.requestAuthorization() == .authorized else {
            await coordinator?.stop()
            blocker = .photosAccessNeeded
            return
        }
        do {
            _ = try await photos.findOrCreateAlbum(titled: albumTitle)
        } catch {
            await coordinator?.stop()
            blocker = .problem("Could not open the album in Photos: \(error.localizedDescription)")
            return
        }
        loadAlbumsIfAllowed()

        guard folderAccess.refresh(), let folder = folderAccess.folderURL else {
            await coordinator?.stop()
            blocker = .driveNotConnected
            return
        }
        blocker = nil
        if !record.fileExists {
            await closeRecord()
            openRecord()
            refreshRecent()
        }
        guard let coordinator else { return }
        let root = ImportCoordinator.realURL(folder)
        await coordinator.start(
            root: root,
            settleInterval: TimeInterval(settleSeconds),
            recordExistingSince: existingFilesCutoff(for: root.path)
        )
    }

    // MARK: - The import record

    private func openRecord() {
        if record.forgetPreparedFoldersIfFileIsMissing() {
            FileLog.shared.write("The import record is missing: the first-time question will be asked again")
        }
        do {
            let opened = try ImportCoordinator(ledgerURL: record.fileURL, importer: albumImporter) { FileLog.shared.write($0) }
            coordinator = opened
            let updates = opened.updates
            updatesTask = Task { [weak self, weak opened] in
                for await update in updates {
                    // A late update from a record that has since been reset must not mark its folder as prepared.
                    guard let self, let opened, self.coordinator === opened else { return }
                    self.handle(update)
                }
            }
        } catch {
            blocker = .problem("Could not open the import record: \(error.localizedDescription)")
        }
    }

    private func closeRecord() async {
        guard let closing = coordinator else { return }
        await closing.stop()
        closing.ledger.close()
        coordinator = nil
        updatesTask?.cancel()
        updatesTask = nil
        status = ImportCoordinator.Status()
    }

    private func handle(_ update: ImportCoordinator.Update) {
        switch update {
        case .status(let newStatus):
            status = newStatus
        case .ledgerChanged:
            refreshRecent()
        case .existingFilesRecorded(let root):
            record.markPrepared(root.path)
        }
    }

    // MARK: - First run for a folder

    private func existingFilesCutoff(for folder: String) -> Date? {
        switch record.existingFiles(in: folder) {
        case .alreadyDealtWith: return nil
        case .stillBeingRecorded(let since): return since
        case .mustAsk: break
        }
        guard askToTreatExistingFilesAsImported(in: folder) else {
            FileLog.shared.write("First time watching \(folder): importing everything in it")
            record.markPrepared(folder)
            return nil
        }
        FileLog.shared.write("First time watching \(folder): treating what is already there as imported")
        let now = Date()
        record.startRecordingExistingFiles(in: folder, at: now)
        return now
    }

    private func askToTreatExistingFilesAsImported(in folder: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "What about the photos already in this folder?"
        alert.informativeText = "\(folder)\n\nPhoto Drop can skip everything that is there now and only add what arrives from here on, or add all of it to Photos."
        alert.addButton(withTitle: "Treat everything already in this folder as imported")
        alert.addButton(withTitle: "Import everything now")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func confirmResettingImportRecord() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Reset the import record?"
        alert.informativeText = """
            Photo Drop will forget which files it has already imported, and watching will be switched off.

            The next time you switch watching on, it will ask again whether to treat the files already in the folder \
            as imported or to import everything. Nothing in Photos or in the folder is changed.
            """
        let reset = alert.addButton(withTitle: "Reset")
        reset.hasDestructiveAction = true
        reset.keyEquivalent = ""
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        return alert.runModal() == .alertFirstButtonReturn
    }

    // MARK: - Refreshing what is shown

    private func refreshRecent() {
        let ledger = coordinator?.ledger
        let root = folderPath.map { ImportCoordinator.realURL(URL(fileURLWithPath: $0)) }
        recent = ((try? ledger?.recent(limit: 100)) ?? []).map { RecentImport($0, under: root) }
        importedToday = (try? ledger?.importedCount(since: Calendar.current.startOfDay(for: .now))) ?? 0
    }

    private func refreshLoginItem() {
        let status = LoginItem.status
        openAtLogin = status == .enabled || status == .needsApproval
        if status == .needsApproval {
            loginItemNote = "Allow Photo Drop under System Settings › General › Login Items."
        }
    }

    // Asking Photos for albums before access is granted would bring up the permission prompt.
    private func loadAlbumsIfAllowed() {
        guard PhotosImporter.authorizationStatus == .authorized else { return }
        Task {
            knownAlbums = await Task.detached { [photos] in photos.albums().map(\.title) }.value
        }
    }

    private func observe(_ name: Notification.Name, _ action: @escaping @MainActor (AppModel) -> Void) {
        NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                if let self { action(self) }
            }
        }
    }
}

private extension ClosedRange {
    func clamping(_ value: Bound) -> Bound {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
