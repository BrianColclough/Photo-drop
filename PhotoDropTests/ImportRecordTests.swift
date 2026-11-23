import Foundation
import PhotoDropCore
import Testing

struct RecordHarness {
    let base: URL
    let defaults: UserDefaults
    let record: ImportRecord
    let folder = "/Volumes/Camera/Photos"

    func createRecordFile(withOneImport: Bool = false) throws {
        let ledger = try ImportLedger(databaseURL: record.fileURL)
        if withOneImport {
            let photo = base.appendingPathComponent("DSC100.jpg")
            try Data("photo".utf8).write(to: photo)
            guard case .new(let fingerprint) = try ledger.check(photo) else { return }
            try ledger.markImported(fingerprint, url: photo, modified: .now, assetID: nil)
        }
        ledger.close()
    }
}

func withRecordHarness(_ body: (RecordHarness) async throws -> Void) async throws {
    let name = "PhotoDropTests-\(UUID().uuidString)"
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(name)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    // A suite named by a path keeps its file in the temporary folder, not in ~/Library/Preferences.
    let suite = base.appendingPathComponent("settings").path
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: base)
    }
    let record = ImportRecord(fileURL: base.appendingPathComponent("support/ledger.sqlite"), defaults: defaults)
    try await body(RecordHarness(base: base, defaults: defaults, record: record))
}

@Suite struct ImportRecordTests {
    @Test func brandNewFolderMustBeAskedAbout() async throws {
        try await withRecordHarness { harness in
            #expect(!harness.record.fileExists)
            #expect(!harness.record.forgetPreparedFoldersIfFileIsMissing())
            #expect(harness.record.existingFiles(in: harness.folder) == .mustAsk)
        }
    }

    @Test func preparedFolderIsNotAskedAboutAgainWhileTheRecordExists() async throws {
        try await withRecordHarness { harness in
            try harness.createRecordFile()
            harness.record.markPrepared(harness.folder)

            #expect(!harness.record.forgetPreparedFoldersIfFileIsMissing())
            #expect(harness.record.existingFiles(in: harness.folder) == .alreadyDealtWith)
            #expect(harness.record.existingFiles(in: "/Volumes/Camera/Other") == .mustAsk)
        }
    }

    @Test func interruptedRecordingPassResumesFromWhenItStarted() async throws {
        try await withRecordHarness { harness in
            try harness.createRecordFile()
            let started = Date(timeIntervalSince1970: 1_800_000_000)
            harness.record.startRecordingExistingFiles(in: harness.folder, at: started)

            #expect(!harness.record.forgetPreparedFoldersIfFileIsMissing())
            #expect(harness.record.existingFiles(in: harness.folder) == .stillBeingRecorded(since: started))

            harness.record.markPrepared(harness.folder)
            #expect(harness.record.existingFiles(in: harness.folder) == .alreadyDealtWith)
            #expect(harness.defaults.dictionary(forKey: "recordingExistingStarted")?.isEmpty == true)
        }
    }

    @Test func missingRecordMakesAPreparedFolderAskAgain() async throws {
        try await withRecordHarness { harness in
            try harness.createRecordFile()
            harness.record.markPrepared(harness.folder)
            try FileManager.default.removeItem(at: harness.record.fileURL)

            #expect(harness.record.forgetPreparedFoldersIfFileIsMissing())
            #expect(harness.record.existingFiles(in: harness.folder) == .mustAsk)
            #expect(harness.defaults.object(forKey: "preparedFolders") == nil)
        }
    }

    @Test func missingRecordMakesAnInterruptedRecordingPassAskAgain() async throws {
        try await withRecordHarness { harness in
            harness.record.startRecordingExistingFiles(in: harness.folder, at: .now)

            #expect(harness.record.forgetPreparedFoldersIfFileIsMissing())
            #expect(harness.record.existingFiles(in: harness.folder) == .mustAsk)
            #expect(harness.defaults.object(forKey: "recordingExistingStarted") == nil)
        }
    }

    @Test func resetDeletesTheRecordSwitchesWatchingOffAndAsksAgain() async throws {
        try await withRecordHarness { harness in
            try harness.createRecordFile(withOneImport: true)
            try Data().write(to: URL(fileURLWithPath: harness.record.fileURL.path + "-journal"))
            harness.record.markPrepared(harness.folder)
            harness.record.startRecordingExistingFiles(in: "/Volumes/Camera/Other", at: .now)
            harness.record.watchingIsOn = true
            harness.defaults.set("Holiday", forKey: "albumTitle")

            try harness.record.reset()

            let support = harness.record.fileURL.deletingLastPathComponent()
            #expect(try FileManager.default.contentsOfDirectory(atPath: support.path).isEmpty)
            #expect(!harness.record.watchingIsOn)
            #expect(harness.defaults.bool(forKey: "watching") == false)
            #expect(harness.defaults.object(forKey: "preparedFolders") == nil)
            #expect(harness.defaults.object(forKey: "recordingExistingStarted") == nil)
            #expect(harness.record.existingFiles(in: harness.folder) == .mustAsk)
            #expect(harness.record.existingFiles(in: "/Volumes/Camera/Other") == .mustAsk)
            #expect(harness.defaults.string(forKey: "albumTitle") == "Holiday")

            #expect(try ImportLedger(databaseURL: harness.record.fileURL).entryCount() == 0)
        }
    }

    @Test func resetWithNoRecordFileStillClearsTheSettings() async throws {
        try await withRecordHarness { harness in
            harness.record.markPrepared(harness.folder)
            harness.record.watchingIsOn = true

            try harness.record.reset()

            #expect(!harness.record.watchingIsOn)
            #expect(harness.record.existingFiles(in: harness.folder) == .mustAsk)
        }
    }

    @Test func afterAResetAFileImportedBeforeIsImportedAgain() async throws {
        try await withRecordHarness { harness in
            let watched = harness.base.appendingPathComponent("watched")
            try FileManager.default.createDirectory(at: watched, withIntermediateDirectories: true)
            try Data("photo".utf8).write(to: watched.appendingPathComponent("DSC101.jpg"))
            let importer = FakeImporter()

            func openCoordinator() throws -> ImportCoordinator {
                try ImportCoordinator(ledgerURL: harness.record.fileURL, importer: importer, timing: .fast, log: { _ in })
            }

            let first = try openCoordinator()
            await first.start(root: watched)
            #expect(try await eventually { try first.ledger.entryCount() == 1 })
            harness.record.markPrepared(watched.path)

            await first.stop()
            first.ledger.close()
            try harness.record.reset()

            let second = try openCoordinator()
            #expect(try second.ledger.entryCount() == 0)
            #expect(harness.record.existingFiles(in: watched.path) == .mustAsk)

            await second.start(root: watched)
            #expect(try await eventually { importer.requests.count == 2 })
            await second.stop()
            #expect(importer.importedNames == ["DSC101.jpg", "DSC101.jpg"])
            #expect(try second.ledger.entryCount() == 1)
        }
    }
}
