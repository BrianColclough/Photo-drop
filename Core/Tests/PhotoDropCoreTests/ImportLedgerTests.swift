import Foundation
import PhotoDropCore
import Testing

@Suite struct ImportLedgerTests {
    let modified = Date(timeIntervalSince1970: 1_750_000_000)
    let day = Date(timeIntervalSince1970: 1_800_000_000)

    func openLedger(in directory: URL) throws -> ImportLedger {
        try ImportLedger(databaseURL: directory.appendingPathComponent("support/ledger.sqlite"))
    }

    func newFingerprint(_ ledger: ImportLedger, _ url: URL) throws -> FileFingerprint {
        guard case .new(let fingerprint) = try ledger.check(url) else {
            throw LedgerError(message: "Expected \(url.lastPathComponent) to be new")
        }
        return fingerprint
    }

    @Test func newFileBecomesHandledOnceImported() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            let url = try writeFile("photos/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 1), modified: modified)

            #expect(try ledger.entryCount() == 0)
            let fingerprint = try newFingerprint(ledger, url)
            #expect(fingerprint == (try FileFingerprint(url: url)))
            #expect(try ledger.check(url) == .new(fingerprint))

            try ledger.markImported(fingerprint, url: url, modified: modified, assetID: "asset-1", at: day)
            #expect(try ledger.check(url) == .handled)
            #expect(try ledger.entryCount() == 1)

            let entry = try #require(try ledger.recent(limit: 10).first)
            #expect(entry.fingerprint == fingerprint)
            #expect(entry.path == url.path)
            #expect(entry.url.path == url.path)
            #expect(entry.modified == modified)
            #expect(entry.status == .imported)
            #expect(entry.timestamp == day)
            #expect(entry.assetID == "asset-1")
            #expect(entry.errorMessage == nil)
            #expect(entry.attempts == 1)
        }
    }

    @Test func recordsSurviveClosingAndReopeningTheDatabase() throws {
        try withTempDirectory { directory in
            let imported = try writeFile("photos/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 1), modified: modified)
            let failed = try writeFile("photos/IMG_2.jpg", in: directory, contents: bytes(4000, filledWith: 2), modified: modified)
            let baseline = try writeFile("photos/IMG_3.jpg", in: directory, contents: bytes(4000, filledWith: 3), modified: modified)
            var failedFingerprint: FileFingerprint?

            do {
                let ledger = try openLedger(in: directory)
                try ledger.markImported(try newFingerprint(ledger, imported), url: imported, modified: modified, assetID: "asset-1", at: day)
                failedFingerprint = try newFingerprint(ledger, failed)
                try ledger.markFailed(try #require(failedFingerprint), url: failed, modified: modified, error: "Photos said no", at: day + 1)
                try ledger.markBaseline(try newFingerprint(ledger, baseline), url: baseline, modified: modified, at: day + 2)
            }

            let reopened = try openLedger(in: directory)
            #expect(try reopened.check(imported) == .handled)
            #expect(try reopened.check(failed) == .previouslyFailed(try #require(failedFingerprint)))
            #expect(try reopened.check(baseline) == .handled)
            #expect(try reopened.entryCount() == 3)

            let recent = try reopened.recent(limit: 10)
            #expect(recent.map(\.status) == [.failed, .imported])
            #expect(recent[0].errorMessage == "Photos said no")
            #expect(recent[1].assetID == "asset-1")
        }
    }

    @Test func deletingTheDatabaseFileResetsEverything() throws {
        try withTempDirectory { directory in
            let url = try writeFile("photos/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 1), modified: modified)
            do {
                let ledger = try openLedger(in: directory)
                try ledger.markImported(try newFingerprint(ledger, url), url: url, modified: modified, assetID: nil)
            }
            try FileManager.default.removeItem(at: directory.appendingPathComponent("support/ledger.sqlite"))

            let fresh = try openLedger(in: directory)
            #expect(try fresh.entryCount() == 0)
            _ = try newFingerprint(fresh, url)
        }
    }

    @Test func fileMovedToARenamedFolderIsStillHandledAndThenTakesTheFastPath() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            let original = try writeFile("2026/Trip/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 1), modified: modified)
            try ledger.markImported(try newFingerprint(ledger, original), url: original, modified: modified, assetID: "asset-1", at: day)

            let renamedFolder = directory.appendingPathComponent("2026/Iceland Trip")
            try FileManager.default.moveItem(at: directory.appendingPathComponent("2026/Trip"), to: renamedFolder)
            let moved = renamedFolder.appendingPathComponent("IMG_1.jpg")

            #expect(try ledger.check(moved) == .handled)
            #expect(try ledger.recent(limit: 1).first?.path == moved.path)
            #expect(try ledger.entryCount() == 1)

            // Same size and date but different bytes: only a check that skips hashing still says handled.
            try writeFile("2026/Iceland Trip/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 9), modified: modified)
            #expect(try ledger.check(moved) == .handled)
        }
    }

    @Test func unchangedFileIsHandledWithoutHashing() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            let url = try writeFile("photos/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 1), modified: modified)
            try ledger.markImported(try newFingerprint(ledger, url), url: url, modified: modified, assetID: nil)

            try writeFile("photos/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 9), modified: modified)
            #expect(try ledger.check(url) == .handled)
        }
    }

    @Test func touchedFileIsRehashedAndStillHandled() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            let url = try writeFile("photos/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 1), modified: modified)
            try ledger.markImported(try newFingerprint(ledger, url), url: url, modified: modified, assetID: nil, at: day)

            let touched = modified + 500
            try FileManager.default.setAttributes([.modificationDate: touched], ofItemAtPath: url.path)
            #expect(try ledger.check(url) == .handled)
            #expect(try ledger.recent(limit: 1).first?.modified == touched)
        }
    }

    @Test func sameNameAndSizeWithDifferentContentIsNew() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            let first = try writeFile("card1/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 1), modified: modified)
            let second = try writeFile("card2/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 2), modified: modified)
            try ledger.markImported(try newFingerprint(ledger, first), url: first, modified: modified, assetID: nil)

            let secondFingerprint = try newFingerprint(ledger, second)
            #expect(secondFingerprint.headHash != (try FileFingerprint(url: first)).headHash)
            #expect(try ledger.check(first) == .handled)

            try ledger.markImported(secondFingerprint, url: second, modified: modified, assetID: nil)
            #expect(try ledger.entryCount() == 2)
        }
    }

    @Test func editedInPlaceWithANewDateIsNew() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            let url = try writeFile("photos/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 1), modified: modified)
            try ledger.markImported(try newFingerprint(ledger, url), url: url, modified: modified, assetID: nil)

            try writeFile("photos/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 2), modified: modified + 60)
            _ = try newFingerprint(ledger, url)
        }
    }

    @Test func failedThenRetriedThenImported() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            let url = try writeFile("photos/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 1), modified: modified)
            let fingerprint = try newFingerprint(ledger, url)

            try ledger.markFailed(fingerprint, url: url, modified: modified, error: "Library busy", at: day)
            #expect(try ledger.check(url) == .previouslyFailed(fingerprint))
            #expect(try ledger.failedEntries().map(\.path) == [url.path])
            #expect(try ledger.failedEntries().first?.attempts == 1)

            try ledger.markFailed(fingerprint, url: url, modified: modified, error: "Library still busy", at: day + 10)
            let failure = try #require(try ledger.failedEntries().first)
            #expect(failure.attempts == 2)
            #expect(failure.errorMessage == "Library still busy")
            #expect(failure.status == .failed)
            #expect(failure.timestamp == day + 10)
            #expect(try ledger.importedCount(since: day) == 0)

            try ledger.markImported(fingerprint, url: url, modified: modified, assetID: "asset-9", at: day + 20)
            #expect(try ledger.check(url) == .handled)
            #expect(try ledger.failedEntries().isEmpty)
            #expect(try ledger.importedCount(since: day) == 1)

            let entry = try #require(try ledger.recent(limit: 10).first)
            #expect(try ledger.recent(limit: 10).count == 1)
            #expect(entry.status == .imported)
            #expect(entry.errorMessage == nil)
            #expect(entry.assetID == "asset-9")
            #expect(entry.attempts == 3)
        }
    }

    @Test func movedFailedFileIsRecognisedAndItsRetryPathFollowsIt() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            let original = try writeFile("inbox/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 1), modified: modified)
            let fingerprint = try newFingerprint(ledger, original)
            try ledger.markFailed(fingerprint, url: original, modified: modified, error: "Nope")

            let moved = directory.appendingPathComponent("sorted/IMG_1.jpg")
            try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: original, to: moved)

            #expect(try ledger.check(moved) == .previouslyFailed(fingerprint))
            #expect(try ledger.failedEntries().map(\.path) == [moved.path])
        }
    }

    @Test func laterFailureDoesNotUndoAnImport() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            let url = try writeFile("photos/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 1), modified: modified)
            let fingerprint = try newFingerprint(ledger, url)
            try ledger.markImported(fingerprint, url: url, modified: modified, assetID: "asset-1")

            try ledger.markFailed(fingerprint, url: url, modified: modified, error: "Duplicate")
            #expect(try ledger.check(url) == .handled)
            #expect(try ledger.failedEntries().isEmpty)
        }
    }

    @Test func baselineRowsAreHandledButLeftOutOfCountsAndRecent() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            var items: [BaselineItem] = []
            var urls: [URL] = []
            for index in 0..<50 {
                let url = try writeFile("archive/IMG_\(index).jpg", in: directory, contents: bytes(2000 + index, filledWith: 1), modified: modified)
                urls.append(url)
                items.append(BaselineItem(fingerprint: try newFingerprint(ledger, url), url: url, modified: modified))
            }
            try ledger.markBaseline(items, at: day)

            #expect(try ledger.entryCount() == 50)
            #expect(try urls.allSatisfy { try ledger.check($0) == .handled })
            #expect(try ledger.importedCount(since: .distantPast) == 0)
            #expect(try ledger.recent(limit: 100).isEmpty)
            #expect(try ledger.failedEntries().isEmpty)

            let fresh = try writeFile("archive/NEW.jpg", in: directory, contents: bytes(999, filledWith: 4), modified: modified)
            try ledger.markImported(try newFingerprint(ledger, fresh), url: fresh, modified: modified, assetID: nil, at: day + 5)
            #expect(try ledger.importedCount(since: .distantPast) == 1)
            #expect(try ledger.recent(limit: 100).map(\.path) == [fresh.path])
        }
    }

    @Test func baselineClearsAFailureButLeavesAnImportAlone() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            let imported = try writeFile("a/IMG_1.jpg", in: directory, contents: bytes(4000, filledWith: 1), modified: modified)
            let failed = try writeFile("a/IMG_2.jpg", in: directory, contents: bytes(4000, filledWith: 2), modified: modified)
            let importedFingerprint = try newFingerprint(ledger, imported)
            let failedFingerprint = try newFingerprint(ledger, failed)
            try ledger.markImported(importedFingerprint, url: imported, modified: modified, assetID: "asset-1", at: day)
            try ledger.markFailed(failedFingerprint, url: failed, modified: modified, error: "Nope", at: day)

            try ledger.markBaseline([
                BaselineItem(fingerprint: importedFingerprint, url: imported, modified: modified),
                BaselineItem(fingerprint: failedFingerprint, url: failed, modified: modified),
            ], at: day + 1)

            #expect(try ledger.check(failed) == .handled)
            #expect(try ledger.failedEntries().isEmpty)
            #expect(try ledger.importedCount(since: day) == 1)
            #expect(try ledger.recent(limit: 10).map(\.assetID) == ["asset-1"])
        }
    }

    @Test func importedCountOnlyCountsImportsSinceTheGivenTime() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            for (index, offset) in [-3600.0, -1, 0, 30, 7200].enumerated() {
                let url = try writeFile("photos/IMG_\(index).jpg", in: directory, contents: bytes(1000 + index, filledWith: 1), modified: modified)
                try ledger.markImported(try newFingerprint(ledger, url), url: url, modified: modified, assetID: nil, at: day + offset)
            }
            let failed = try writeFile("photos/BAD.jpg", in: directory, contents: bytes(50, filledWith: 1), modified: modified)
            try ledger.markFailed(try newFingerprint(ledger, failed), url: failed, modified: modified, error: "Nope", at: day + 40)

            #expect(try ledger.importedCount(since: day) == 3)
            #expect(try ledger.importedCount(since: day + 31) == 1)
            #expect(try ledger.importedCount(since: .distantPast) == 5)
            #expect(try ledger.importedCount(since: day + 10_000) == 0)
        }
    }

    @Test func recentListsImportedAndFailedNewestFirstUpToTheLimit() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            var urls: [URL] = []
            for index in 0..<5 {
                let url = try writeFile("photos/IMG_\(index).jpg", in: directory, contents: bytes(1000 + index, filledWith: 1), modified: modified)
                urls.append(url)
                let fingerprint = try newFingerprint(ledger, url)
                if index == 3 {
                    try ledger.markFailed(fingerprint, url: url, modified: modified, error: "Unsupported", at: day + Double(index))
                } else {
                    try ledger.markImported(fingerprint, url: url, modified: modified, assetID: "asset-\(index)", at: day + Double(index))
                }
            }

            let recent = try ledger.recent(limit: 3)
            #expect(recent.map(\.path) == [urls[4].path, urls[3].path, urls[2].path])
            #expect(recent.map(\.status) == [.imported, .failed, .imported])
            #expect(recent.map(\.timestamp) == [day + 4, day + 3, day + 2])
            #expect(recent[1].errorMessage == "Unsupported")
            #expect(try ledger.recent(limit: 100).count == 5)
            #expect(try ledger.recent(limit: 0).isEmpty)
        }
    }

    @Test func checkingAMissingFileThrows() throws {
        try withTempDirectory { directory in
            let ledger = try openLedger(in: directory)
            #expect(throws: LedgerError.self) {
                try ledger.check(directory.appendingPathComponent("gone.jpg"))
            }
        }
    }

    @Test func ledgerCanBeUsedFromSeveralThreadsAtOnce() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PhotoDropCoreTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ledger = try openLedger(in: directory)
        let modified = modified

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let url = try writeFile("photos/IMG_\(index).jpg", in: directory, contents: bytes(1000 + index, filledWith: 1), modified: modified)
                    guard case .new(let fingerprint) = try ledger.check(url) else { return }
                    try ledger.markImported(fingerprint, url: url, modified: modified, assetID: nil)
                    _ = try ledger.recent(limit: 5)
                }
            }
            try await group.waitForAll()
        }
        #expect(try ledger.importedCount(since: .distantPast) == 40)
    }
}
