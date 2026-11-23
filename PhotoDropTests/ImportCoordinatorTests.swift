import Foundation
import PhotoDropCore
import Synchronization
import Testing

final class FakeImporter: MediaImporting {
    private struct State {
        var requests: [ImportRequest] = []
        var failing: Set<String> = []
    }

    private let state = Mutex(State())

    var requests: [ImportRequest] {
        state.withLock { $0.requests }
    }

    var importedNames: [String] {
        requests.map(\.primary.lastPathComponent).sorted()
    }

    func fail(_ names: Set<String>) {
        state.withLock { $0.failing = names }
    }

    func importFiles(_ requests: [ImportRequest]) async -> [ImportResult] {
        state.withLock { state in
            state.requests += requests
            return requests.map { request in
                let fails = state.failing.contains(request.primary.lastPathComponent)
                return ImportResult(request: request, outcome: fails ? .failed("Fake failure") : .imported(assetID: UUID().uuidString))
            }
        }
    }
}

struct Harness {
    let folder: URL
    let importer = FakeImporter()
    let coordinator: ImportCoordinator

    var ledger: ImportLedger { coordinator.ledger }

    init(in base: URL, _ timing: ImportCoordinator.Timing) throws {
        folder = base.appendingPathComponent("watched")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        coordinator = try ImportCoordinator(
            ledgerURL: base.appendingPathComponent("ledger.sqlite"),
            importer: importer,
            timing: timing,
            log: { _ in }
        )
    }

    func start(recordExistingSince: Date? = nil) async throws {
        await coordinator.start(root: folder, recordExistingSince: recordExistingSince)
        // Gives the file event stream a moment to go live before the test writes anything.
        try await Task.sleep(for: .milliseconds(300))
    }

    @discardableResult
    func write(_ relativePath: String, modified: Date? = nil) throws -> URL {
        let url = folder.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("\(relativePath) \(UUID().uuidString)".utf8).write(to: url)
        if let modified {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    func importedPaths() throws -> [String] {
        try ledger.recent(limit: 100).filter { $0.status == .imported }.map(\.path).sorted()
    }
}

extension ImportCoordinator.Timing {
    static let fast = ImportCoordinator.Timing(
        settle: 1,
        poll: 0.2,
        retryThrottle: 0.2,
        retryEvery: 3600,
        watcherLatency: 0.1,
        eventGrace: 0.5
    )
}

func withHarness(
    _ timing: ImportCoordinator.Timing = .fast,
    _ body: (Harness) async throws -> Void
) async throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoDropTests-\(UUID().uuidString)")
    // Removed only after the harness is gone, so the ledger file is closed first.
    defer { try? FileManager.default.removeItem(at: base) }
    try await runHarness(in: base, timing, body)
}

private func runHarness(
    in base: URL,
    _ timing: ImportCoordinator.Timing,
    _ body: (Harness) async throws -> Void
) async throws {
    let harness = try Harness(in: base, timing)
    do {
        try await body(harness)
    } catch {
        await harness.coordinator.stop()
        throw error
    }
    await harness.coordinator.stop()
}

func eventually(within seconds: TimeInterval = 20, _ condition: () throws -> Bool) async throws -> Bool {
    let deadline = Date() + seconds
    while Date() < deadline {
        if try condition() { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return try condition()
}

// Long enough for a wrongly queued file to settle and reach the importer.
func waitForStragglers() async throws {
    try await Task.sleep(for: .seconds(3))
}

@Suite struct ImportCoordinatorTests {
    @Test func fileInNestedSubfolderIsImportedOnce() async throws {
        try await withHarness { harness in
            try await harness.start()
            try harness.write("2026/12/christmas/DSC001.jpg")

            #expect(try await eventually { harness.importer.requests.count == 1 })
            try await waitForStragglers()

            let requests = harness.importer.requests
            #expect(requests.count == 1)
            #expect(requests.first?.primary.path.hasSuffix("/watched/2026/12/christmas/DSC001.jpg") == true)
            #expect(requests.first?.isVideo == false)
            #expect(requests.first?.alternateRAW == nil)
            #expect(try harness.importedPaths().count == 1)
        }
    }

    @Test func jpegAndRawArriveAsOneRequest() async throws {
        try await withHarness { harness in
            try await harness.start()
            try harness.write("shoot/DSC002.ARW")
            try harness.write("shoot/DSC002.jpg")

            #expect(try await eventually { !harness.importer.requests.isEmpty })
            try await waitForStragglers()

            let requests = harness.importer.requests
            #expect(requests.count == 1)
            #expect(requests.first?.primary.lastPathComponent == "DSC002.jpg")
            #expect(requests.first?.alternateRAW?.lastPathComponent == "DSC002.ARW")

            let rows = try harness.ledger.recent(limit: 10)
            #expect(rows.count == 2)
            #expect(rows.allSatisfy { $0.status == .imported })
            #expect(Set(rows.map(\.assetID)).count == 1)
        }
    }

    @Test func fileStillBeingWrittenWaitsUntilItStopsChanging() async throws {
        var timing = ImportCoordinator.Timing.fast
        timing.settle = 2
        try await withHarness(timing) { harness in
            try await harness.start()
            let url = try harness.write("slow/DSC003.jpg")

            let handle = try FileHandle(forWritingTo: url)
            for _ in 0..<16 {
                try await Task.sleep(for: .milliseconds(250))
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(repeating: 7, count: 4096))
                #expect(harness.importer.requests.isEmpty)
            }
            try handle.close()
            let finalSize = try #require(FileSnapshot.read(at: url)?.size)

            #expect(try await eventually { harness.importer.requests.count == 1 })
            try await waitForStragglers()

            #expect(harness.importer.requests.count == 1)
            #expect(try harness.ledger.recent(limit: 10).map(\.fingerprint.size) == [finalSize])
        }
    }

    @Test func renamedParentFolderIsNotImportedAgain() async throws {
        try await withHarness { harness in
            try await harness.start()
            try harness.write("2026/12/christmas/DSC004.jpg")
            try harness.write("2026/12/christmas/clip.mov")
            #expect(try await eventually { try harness.importedPaths().count == 2 })

            try FileManager.default.moveItem(
                at: harness.folder.appendingPathComponent("2026/12/christmas"),
                to: harness.folder.appendingPathComponent("2026/12/xmas")
            )
            #expect(try await eventually { try harness.importedPaths().allSatisfy { $0.contains("/2026/12/xmas/") } })
            try await waitForStragglers()
            #expect(harness.importer.requests.count == 2)

            await harness.coordinator.stop()
            try await harness.start()
            try await waitForStragglers()
            #expect(harness.importer.requests.count == 2)
            #expect(try harness.ledger.entryCount() == 2)
        }
    }

    @Test func failedImportIsRecordedThenRetriedOnTheNextFileEvent() async throws {
        try await withHarness { harness in
            harness.importer.fail(["DSC005.jpg"])
            try await harness.start()
            try harness.write("DSC005.jpg")

            #expect(try await eventually { try harness.ledger.failedEntries().count == 1 })
            let failure = try #require(try harness.ledger.failedEntries().first)
            #expect(failure.errorMessage == "Fake failure")
            #expect(failure.url.lastPathComponent == "DSC005.jpg")

            try await waitForStragglers()
            #expect(harness.importer.requests.count == 1)

            harness.importer.fail([])
            try harness.write("DSC006.jpg")

            #expect(try await eventually { try harness.importedPaths().count == 2 })
            #expect(try harness.ledger.failedEntries().isEmpty)
            #expect(harness.importer.importedNames == ["DSC005.jpg", "DSC005.jpg", "DSC006.jpg"])
        }
    }

    @Test func failedImportIsRetriedOnATimer() async throws {
        var timing = ImportCoordinator.Timing.fast
        timing.retryEvery = 1
        try await withHarness(timing) { harness in
            harness.importer.fail(["DSC007.jpg"])
            try await harness.start()
            try harness.write("DSC007.jpg")

            #expect(try await eventually { try harness.ledger.failedEntries().first?.attempts ?? 0 >= 2 })
            harness.importer.fail([])

            #expect(try await eventually { try harness.importedPaths().count == 1 })
            #expect(try harness.ledger.failedEntries().isEmpty)
        }
    }

    @Test func hiddenAndNonMediaFilesAreIgnored() async throws {
        try await withHarness { harness in
            try await harness.start()
            try harness.write(".hidden.jpg")
            try harness.write(".cache/inside.jpg")
            try harness.write("keep/.thumbs/small.jpg")
            try harness.write("keep/notes.txt")
            try harness.write("keep/DSC008.xmp")
            try harness.write("keep/DSC008.jpg")

            #expect(try await eventually { !harness.importer.requests.isEmpty })
            try await waitForStragglers()
            #expect(harness.importer.importedNames == ["DSC008.jpg"])

            await harness.coordinator.stop()
            try await harness.start()
            try await waitForStragglers()
            #expect(harness.importer.importedNames == ["DSC008.jpg"])
            #expect(try harness.ledger.entryCount() == 1)
        }
    }

    @Test func filesAddedWhileStoppedAreCaughtOnTheNextStart() async throws {
        try await withHarness { harness in
            try await harness.start()
            try harness.write("first/DSC009.jpg")
            #expect(try await eventually { harness.importer.requests.count == 1 })

            await harness.coordinator.stop()
            try harness.write("later/deep/DSC010.jpg")
            try harness.write("later/DSC011.mov")
            try await waitForStragglers()
            #expect(harness.importer.requests.count == 1)

            try await harness.start()
            #expect(try await eventually { harness.importer.requests.count == 3 })
            try await waitForStragglers()
            #expect(harness.importer.importedNames == ["DSC009.jpg", "DSC010.jpg", "DSC011.mov"])
            #expect(harness.importer.requests.first(where: { $0.primary.pathExtension == "mov" })?.isVideo == true)
        }
    }

    @Test func existingFilesCanBeRecordedAsAlreadyImported() async throws {
        try await withHarness { harness in
            let anHourAgo = Date() - 3600
            try harness.write("old/DSC012.jpg", modified: anHourAgo)
            try harness.write("old/DSC012.ARW", modified: anHourAgo)
            try harness.write("old/deep/DSC013.jpg", modified: anHourAgo)
            // File events from just before a watcher starts can still be delivered to it.
            try await Task.sleep(for: .seconds(2))
            try harness.write("old/DSC014.jpg")

            let finished = Mutex(false)
            let updates = harness.coordinator.updates
            let listener = Task {
                for await update in updates {
                    if case .existingFilesRecorded = update { finished.withLock { $0 = true } }
                }
            }
            defer { listener.cancel() }

            try await harness.start(recordExistingSince: Date() - 60)
            #expect(try await eventually { finished.withLock { $0 } })
            try harness.write("new/DSC015.jpg")

            #expect(try await eventually { harness.importer.requests.count == 2 })
            try await waitForStragglers()
            #expect(harness.importer.importedNames == ["DSC014.jpg", "DSC015.jpg"])
            #expect(try harness.ledger.entryCount() == 5)

            await harness.coordinator.stop()
            try await harness.start()
            try await waitForStragglers()
            #expect(harness.importer.requests.count == 2)
        }
    }
}
