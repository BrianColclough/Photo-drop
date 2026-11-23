import SwiftUI

@main
struct PhotoDropApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        Self.quitIfAnotherCopyIsRunning()
        _model = State(initialValue: AppModel())
    }

    var body: some Scene {
        Window("Photo Drop", id: "main") {
            MainView(model: model)
        }
        .defaultSize(width: 680, height: 520)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Reset Import Record…") { model.resetImportRecord() }
            }
        }
    }

    // Two copies share one record and would both import the same new file.
    private static func quitIfAnotherCopyIsRunning() {
        guard earlierCopy() != nil else { return }
        // A copy that was just quit can still be listed for a moment.
        Thread.sleep(forTimeInterval: 0.5)
        guard let stillRunning = earlierCopy() else { return }
        let handOver = HandOver(to: stillRunning)
        NSApplication.shared.delegate = handOver
        withExtendedLifetime(handOver) { NSApplication.shared.run() }
        exit(0)
    }

    private static func earlierCopy() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let me = NSRunningApplication.current
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first {
            $0 != me && !$0.isTerminated && wasLaunched($0, before: me)
        }
    }

    // When two copies start together, only the later one may quit, or neither would be left.
    private static func wasLaunched(_ other: NSRunningApplication, before me: NSRunningApplication) -> Bool {
        guard let theirs = other.launchDate, let mine = me.launchDate else { return true }
        return theirs < mine || (theirs == mine && other.processIdentifier < me.processIdentifier)
    }
}

// macOS only lets the front app pass the front on, so the extra copy waits to become it before quitting.
private final class HandOver: NSObject, NSApplicationDelegate {
    private let runningCopy: NSRunningApplication

    init(to runningCopy: NSRunningApplication) {
        self.runningCopy = runningCopy
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { exit(0) }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        runningCopy.activate(from: .current)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { exit(0) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
