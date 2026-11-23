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
        static let watching = "watching"
        static let albumTitle = "albumTitle"
        static let settleSeconds = "settleSeconds"
        static let preparedFolders = "preparedFolders"
        static let recordingStarted = "recordingExistingStarted"
    }

    static let defaultAlbum = "Camera Photos"

    static var ledgerURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PhotoDrop", isDirectory: true)
            .appendingPathComponent("ledger.sqlite")
    }

    private(set) var folderPath: String?
    private(set) var albumTitle: String
    private(set) var isWatching: Bool
    private(set) var blocker: Blocker?
    private(set) var status = ImportCoordinator.Status()
    private(set) var importedToday = 0
    private(set) var recent: [RecentImport] = []
    private(set) var openAtLogin = false
    private(set) var loginItemNote: String?
    private var knownAlbums: [String] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let folderAccess: FolderAccess
    @ObservationIgnored private let photos = PhotosImporter()
    @ObservationIgnored private let albumImporter: AlbumImporter
    @ObservationIgnored private let coordinator: ImportCoordinator?
    @ObservationIgnored private var queuedWork: Task<Void, Never>?

    init() {
        let defaults = UserDefaults.standard
        let title = defaults.string(forKey: Keys.albumTitle) ?? Self.defaultAlbum
        let importer = AlbumImporter(title: title)
        self.defaults = defaults
        folderAccess = FolderAccess(defaults: defaults)
        albumTitle = title
        albumImporter = importer
        isWatching = defaults.bool(forKey: Keys.watching)
        do {
            coordinator = try ImportCoordinator(ledgerURL: Self.ledgerURL, importer: importer) { FileLog.shared.write($0) }
        } catch {
            coordinator = nil
            blocker = .problem("Could not open the import record: \(error.localizedDescription)")
        }

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

        if let updates = coordinator?.updates {
            Task { [weak self] in
                for await update in updates {
                    self?.handle(update)
                }
            }
        }
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
        defaults.set(on, forKey: Keys.watching)
        enqueueReconcile()
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
        guard let coordinator else { return }
        guard isWatching, folderAccess.hasSavedFolder else {
            await coordinator.stop()
            blocker = nil
            return
        }
        guard await PhotosImporter.requestAuthorization() == .authorized else {
            await coordinator.stop()
            blocker = .photosAccessNeeded
            return
        }
        do {
            _ = try await photos.findOrCreateAlbum(titled: albumTitle)
        } catch {
            await coordinator.stop()
            blocker = .problem("Could not open the album in Photos: \(error.localizedDescription)")
            return
        }
        loadAlbumsIfAllowed()

        guard folderAccess.refresh(), let folder = folderAccess.folderURL else {
            await coordinator.stop()
            blocker = .driveNotConnected
            return
        }
        blocker = nil
        let root = ImportCoordinator.realURL(folder)
        await coordinator.start(
            root: root,
            settleInterval: settleSeconds,
            recordExistingSince: existingFilesCutoff(for: root.path)
        )
    }

    private var settleSeconds: TimeInterval {
        let saved = defaults.double(forKey: Keys.settleSeconds)
        return saved > 0 ? saved : 60
    }

    private func handle(_ update: ImportCoordinator.Update) {
        switch update {
        case .status(let newStatus):
            status = newStatus
        case .ledgerChanged:
            refreshRecent()
        case .existingFilesRecorded(let root):
            markPrepared(root.path)
        }
    }

    // MARK: - First run for a folder

    private func existingFilesCutoff(for folder: String) -> Date? {
        if (defaults.stringArray(forKey: Keys.preparedFolders) ?? []).contains(folder) { return nil }

        var started = defaults.dictionary(forKey: Keys.recordingStarted) as? [String: Date] ?? [:]
        if let unfinished = started[folder] { return unfinished }

        guard askToTreatExistingFilesAsImported(in: folder) else {
            FileLog.shared.write("First time watching \(folder): importing everything in it")
            markPrepared(folder)
            return nil
        }
        FileLog.shared.write("First time watching \(folder): treating what is already there as imported")
        let now = Date()
        started[folder] = now
        defaults.set(started, forKey: Keys.recordingStarted)
        return now
    }

    private func markPrepared(_ folder: String) {
        var prepared = defaults.stringArray(forKey: Keys.preparedFolders) ?? []
        if !prepared.contains(folder) {
            prepared.append(folder)
            defaults.set(prepared, forKey: Keys.preparedFolders)
        }
        var started = defaults.dictionary(forKey: Keys.recordingStarted) ?? [:]
        started[folder] = nil
        defaults.set(started, forKey: Keys.recordingStarted)
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

    // MARK: - Refreshing what is shown

    private func refreshRecent() {
        guard let ledger = coordinator?.ledger else { return }
        let root = folderPath.map { ImportCoordinator.realURL(URL(fileURLWithPath: $0)) }
        recent = ((try? ledger.recent(limit: 100)) ?? []).map { RecentImport($0, under: root) }
        importedToday = (try? ledger.importedCount(since: Calendar.current.startOfDay(for: .now))) ?? 0
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
