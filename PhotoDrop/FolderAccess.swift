import AppKit

@MainActor
final class FolderAccess {
    static let suggestedFolder = URL(fileURLWithPath: "/Volumes/T7 Shield/Photos", isDirectory: true)

    var onAvailabilityChange: ((Bool) -> Void)?

    private(set) var folderURL: URL?
    private(set) var isAvailable = false

    private let defaults: UserDefaults
    private let bookmarkKey: String
    private let pathKey: String
    private var volumeObservers: [NSObjectProtocol] = []
    private var recheck: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, key: String = "watchedFolder") {
        self.defaults = defaults
        bookmarkKey = key + "Bookmark"
        pathKey = key + "Path"
    }

    isolated deinit {
        stopObservingVolumes()
        stopAccessing()
    }

    var hasSavedFolder: Bool {
        defaults.data(forKey: bookmarkKey) != nil
    }

    var savedPath: String? {
        defaults.string(forKey: pathKey)
    }

    func save(_ url: URL) throws {
        let bookmark = try url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        stopAccessing()
        defaults.set(bookmark, forKey: bookmarkKey)
        defaults.set(url.path, forKey: pathKey)
        refresh()
    }

    func forget() {
        stopAccessing()
        defaults.removeObject(forKey: bookmarkKey)
        defaults.removeObject(forKey: pathKey)
        refresh()
    }

    @discardableResult
    func refresh() -> Bool {
        if let folderURL, !Self.isReachable(folderURL) {
            stopAccessing()
        }
        if folderURL == nil {
            folderURL = resolveAndStartAccessing()
        }
        let available = folderURL != nil
        if available != isAvailable {
            isAvailable = available
            onAvailabilityChange?(available)
        }
        return available
    }

    func stopAccessing() {
        folderURL?.stopAccessingSecurityScopedResource()
        folderURL = nil
    }

    func startObservingVolumes() {
        guard volumeObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter

        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            volumeObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { _ = self?.refresh() }
            })
        }
        volumeObservers.append(center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.volumeWillUnmount(volume) }
        })
    }

    func stopObservingVolumes() {
        recheck?.cancel()
        recheck = nil
        let center = NSWorkspace.shared.notificationCenter
        volumeObservers.forEach(center.removeObserver)
        volumeObservers = []
    }

    static func chooseFolder(startingAt suggested: URL = suggestedFolder) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Watch This Folder"
        panel.message = "Choose the folder Photo Drop should watch for new photos and videos."
        panel.directoryURL = nearestExistingFolder(to: suggested)
        return panel.runModal() == .OK ? panel.url : nil
    }

    private func volumeWillUnmount(_ volume: URL?) {
        guard let volume, let folderURL, Self.isInside(folderURL, volume) else { return }
        stopAccessing()
        if isAvailable {
            isAvailable = false
            onAvailabilityChange?(false)
        }
        // An eject can be refused, and then no mount notification follows.
        recheck?.cancel()
        recheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    private func resolveAndStartAccessing() -> URL? {
        guard let bookmark = defaults.data(forKey: bookmarkKey) else { return nil }
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: bookmark,
            options: [.withSecurityScope, .withoutUI, .withoutMounting],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else { return nil }

        guard url.startAccessingSecurityScopedResource() else { return nil }
        guard Self.isReachable(url) else {
            url.stopAccessingSecurityScopedResource()
            return nil
        }

        defaults.set(url.path, forKey: pathKey)
        if isStale, let fresh = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            defaults.set(fresh, forKey: bookmarkKey)
        }
        return url
    }

    private static func isReachable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func isInside(_ url: URL, _ volume: URL) -> Bool {
        let folder = url.standardizedFileURL.path
        let root = volume.standardizedFileURL.path
        return folder == root || folder.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    private static func nearestExistingFolder(to url: URL) -> URL? {
        var candidate = url.standardizedFileURL
        while candidate.path != "/" {
            if isReachable(candidate) { return candidate }
            candidate.deleteLastPathComponent()
        }
        return nil
    }
}
