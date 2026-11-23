import CoreServices
import Foundation

final class FolderWatcher: @unchecked Sendable {
    enum Event: Sendable {
        case filesChanged([URL])
        case rescanNeeded
    }

    typealias Handler = @Sendable (Event) -> Void

    let root: URL
    private let latency: TimeInterval
    private let handler: Handler
    private let queue = DispatchQueue(label: "com.briancolclough.PhotoDrop.FolderWatcher")
    private let lock = NSLock()
    private var stream: FSEventStreamRef?

    init(root: URL, latency: TimeInterval = 1.0, handler: @escaping Handler) {
        self.root = root
        self.latency = latency
        self.handler = handler
    }

    deinit {
        stop()
    }

    var isRunning: Bool {
        lock.withLock { stream != nil }
    }

    @discardableResult
    func start() -> Bool {
        lock.withLock {
            if stream != nil { return true }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passRetained(HandlerBox(handler)).toOpaque(),
                retain: nil,
                release: { info in
                    guard let info else { return }
                    Unmanaged<HandlerBox>.fromOpaque(info).release()
                },
                copyDescription: nil
            )
            let flags = kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot

            guard let created = FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.callback,
                &context,
                [root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(flags)
            ) else {
                Unmanaged<HandlerBox>.fromOpaque(context.info!).release()
                return false
            }

            FSEventStreamSetDispatchQueue(created, queue)
            guard FSEventStreamStart(created) else {
                FSEventStreamInvalidate(created)
                FSEventStreamRelease(created)
                return false
            }
            stream = created
            return true
        }
    }

    func stop() {
        lock.withLock {
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    private static let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
        guard let info else { return }
        let box = Unmanaged<HandlerBox>.fromOpaque(info).takeUnretainedValue()
        let paths = unsafeBitCast(paths, to: CFArray.self) as? [String] ?? []

        var changed: [URL] = []
        var rescan = false
        for index in 0..<min(count, paths.count) {
            let flag = Int(flags[index])
            let path = paths[index]

            if flag & rescanFlags != 0 {
                rescan = true
            } else if flag & kFSEventStreamEventFlagItemIsDir != 0 {
                // A folder moved in arrives as one event, with nothing for the files inside it.
                if flag & kFSEventStreamEventFlagItemRenamed != 0, FileManager.default.fileExists(atPath: path) {
                    rescan = true
                }
            } else if flag & kFSEventStreamEventFlagItemIsFile != 0, flag & changeFlags != 0 {
                // A rename reports both the old and the new path; only the new one still exists.
                if flag & kFSEventStreamEventFlagItemRenamed != 0, !FileManager.default.fileExists(atPath: path) {
                    continue
                }
                changed.append(URL(fileURLWithPath: path, isDirectory: false))
            }
        }

        if rescan {
            box.handler(.rescanNeeded)
        } else if !changed.isEmpty {
            box.handler(.filesChanged(changed))
        }
    }

    private static let rescanFlags = kFSEventStreamEventFlagMustScanSubDirs
        | kFSEventStreamEventFlagUserDropped
        | kFSEventStreamEventFlagKernelDropped
        | kFSEventStreamEventFlagEventIdsWrapped
        | kFSEventStreamEventFlagRootChanged
        | kFSEventStreamEventFlagMount
        | kFSEventStreamEventFlagUnmount

    private static let changeFlags = kFSEventStreamEventFlagItemCreated
        | kFSEventStreamEventFlagItemModified
        | kFSEventStreamEventFlagItemRenamed
}

private final class HandlerBox: Sendable {
    let handler: FolderWatcher.Handler

    init(_ handler: @escaping FolderWatcher.Handler) {
        self.handler = handler
    }
}
