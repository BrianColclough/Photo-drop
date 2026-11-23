import Foundation
import PhotoDropCore
import Testing

@Suite struct SettleTrackerTests {
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let photo = file("/root/a/IMG_1.jpg")

    func snapshot(_ size: Int64, modifiedOffset: TimeInterval = 0) -> FileSnapshot {
        FileSnapshot(size: size, modified: Date(timeIntervalSince1970: 1_700_000_000 + modifiedOffset))
    }

    @Test func notReadyBeforeIntervalAndReadyAfter() {
        var tracker = SettleTracker()
        let disk = [photo: snapshot(100)]
        tracker.track(photo, snapshot: snapshot(100), now: start)

        #expect(tracker.releaseReady(now: start + 59) { disk[$0] } == [])
        #expect(tracker.pendingCount == 1)
        #expect(tracker.releaseReady(now: start + 60) { disk[$0] } == [photo])
        #expect(tracker.pendingCount == 0)
        #expect(tracker.releaseReady(now: start + 200) { disk[$0] } == [])
    }

    @Test func sizeChangeRestartsTheTimer() {
        var tracker = SettleTracker()
        var disk = [photo: snapshot(100)]
        tracker.track(photo, snapshot: snapshot(100), now: start)

        disk[photo] = snapshot(200)
        #expect(tracker.releaseReady(now: start + 50) { disk[$0] } == [])
        #expect(tracker.releaseReady(now: start + 109) { disk[$0] } == [])
        #expect(tracker.releaseReady(now: start + 110) { disk[$0] } == [photo])
    }

    @Test func modificationDateChangeRestartsTheTimer() {
        var tracker = SettleTracker()
        var disk = [photo: snapshot(100)]
        tracker.track(photo, snapshot: snapshot(100), now: start)

        disk[photo] = snapshot(100, modifiedOffset: 5)
        #expect(tracker.releaseReady(now: start + 50) { disk[$0] } == [])
        #expect(tracker.releaseReady(now: start + 109) { disk[$0] } == [])
        #expect(tracker.releaseReady(now: start + 110) { disk[$0] } == [photo])
    }

    @Test func trackingAgainOnlyRestartsTheTimerWhenTheFileChanged() {
        var tracker = SettleTracker()
        var disk = [photo: snapshot(100)]
        tracker.track(photo, snapshot: snapshot(100), now: start)
        tracker.track(photo, snapshot: snapshot(100), now: start + 30)
        #expect(tracker.pendingCount == 1)
        #expect(tracker.releaseReady(now: start + 60) { disk[$0] } == [photo])

        tracker.track(photo, snapshot: snapshot(100), now: start + 100)
        disk[photo] = snapshot(300)
        tracker.track(photo, snapshot: snapshot(300), now: start + 130)
        #expect(tracker.releaseReady(now: start + 160) { disk[$0] } == [])
        #expect(tracker.releaseReady(now: start + 190) { disk[$0] } == [photo])
    }

    @Test func disappearingFileIsDropped() {
        var tracker = SettleTracker()
        tracker.track(photo, snapshot: snapshot(100), now: start)

        #expect(tracker.releaseReady(now: start + 10) { _ in nil } == [])
        #expect(tracker.pendingCount == 0)
    }

    @Test func zeroByteFileWaitsUntilItHasContents() {
        var tracker = SettleTracker()
        var disk = [photo: snapshot(0)]
        tracker.track(photo, snapshot: snapshot(0), now: start)

        #expect(tracker.releaseReady(now: start + 599) { disk[$0] } == [])
        #expect(tracker.pendingCount == 1)

        disk[photo] = snapshot(500)
        #expect(tracker.releaseReady(now: start + 600) { disk[$0] } == [])
        #expect(tracker.releaseReady(now: start + 660) { disk[$0] } == [photo])
    }

    @Test func fileThatStaysEmptyIsDroppedUntilItIsSeenAgain() {
        var tracker = SettleTracker(emptyFileWait: 300)
        var disk = [photo: snapshot(0)]
        tracker.track(photo, snapshot: snapshot(0), now: start)

        #expect(tracker.releaseReady(now: start + 299) { disk[$0] } == [])
        #expect(tracker.pendingCount == 1)
        #expect(tracker.releaseReady(now: start + 300) { disk[$0] } == [])
        #expect(tracker.pendingCount == 0)

        disk[photo] = snapshot(500)
        tracker.track(photo, snapshot: snapshot(500), now: start + 5000)
        #expect(tracker.releaseReady(now: start + 5060) { disk[$0] } == [photo])
    }

    @Test func touchingAnEmptyFileRestartsItsWait() {
        var tracker = SettleTracker(emptyFileWait: 300)
        var disk = [photo: snapshot(0)]
        tracker.track(photo, snapshot: snapshot(0), now: start)

        disk[photo] = snapshot(0, modifiedOffset: 5)
        #expect(tracker.releaseReady(now: start + 200) { disk[$0] } == [])
        #expect(tracker.releaseReady(now: start + 499) { disk[$0] } == [])
        #expect(tracker.pendingCount == 1)
        #expect(tracker.releaseReady(now: start + 500) { disk[$0] } == [])
        #expect(tracker.pendingCount == 0)
    }

    @Test func droppedEmptyFileNoLongerHoldsItsPairBack() {
        let jpeg = file("/root/a/DSC_7.JPG")
        let raw = file("/root/a/DSC_7.ARW")
        var tracker = SettleTracker(emptyFileWait: 300)
        let disk = [jpeg: snapshot(100), raw: snapshot(0)]
        tracker.track(jpeg, snapshot: snapshot(100), now: start)
        tracker.track(raw, snapshot: snapshot(0), now: start)

        #expect(tracker.releaseReady(now: start + 299) { disk[$0] } == [])
        #expect(tracker.releaseReady(now: start + 300) { disk[$0] } == [jpeg])
        #expect(tracker.pendingCount == 0)
    }

    @Test func intervalIsConfigurable() {
        var tracker = SettleTracker(settleInterval: 5)
        let disk = [photo: snapshot(100)]
        tracker.track(photo, snapshot: snapshot(100), now: start)

        #expect(tracker.releaseReady(now: start + 4) { disk[$0] } == [])
        tracker.settleInterval = 10
        #expect(tracker.releaseReady(now: start + 9) { disk[$0] } == [])
        #expect(tracker.releaseReady(now: start + 10) { disk[$0] } == [photo])
    }

    @Test func settledFileWaitsForItsUnsettledPair() {
        let jpeg = file("/root/a/DSC_7.JPG")
        let raw = file("/root/a/dsc_7.arw")
        let other = file("/root/a/DSC_8.JPG")
        var tracker = SettleTracker()
        var disk = [jpeg: snapshot(100), raw: snapshot(1_000), other: snapshot(100)]
        tracker.track(jpeg, snapshot: snapshot(100), now: start)
        tracker.track(other, snapshot: snapshot(100), now: start)
        tracker.track(raw, snapshot: snapshot(1_000), now: start + 20)

        disk[raw] = snapshot(9_000)
        #expect(tracker.releaseReady(now: start + 60) { disk[$0] } == [other])
        #expect(tracker.pendingCount == 2)
        #expect(tracker.releaseReady(now: start + 119) { disk[$0] } == [])
        #expect(tracker.releaseReady(now: start + 120) { disk[$0] } == [jpeg, raw])
        #expect(tracker.pendingCount == 0)
    }

    @Test func sameNameInAnotherFolderDoesNotHoldAFileBack() {
        let jpeg = file("/root/a/DSC_7.JPG")
        let rawElsewhere = file("/root/b/DSC_7.ARW")
        var tracker = SettleTracker()
        let disk = [jpeg: snapshot(100), rawElsewhere: snapshot(1_000)]
        tracker.track(jpeg, snapshot: snapshot(100), now: start)
        tracker.track(rawElsewhere, snapshot: snapshot(1_000), now: start + 30)

        #expect(tracker.releaseReady(now: start + 60) { disk[$0] } == [jpeg])
        #expect(tracker.pendingURLs == [rawElsewhere])
    }

    @Test func pairIsReleasedIfThePartnerDisappears() {
        let jpeg = file("/root/a/DSC_7.JPG")
        let raw = file("/root/a/DSC_7.ARW")
        var tracker = SettleTracker()
        let disk = [jpeg: snapshot(100)]
        tracker.track(jpeg, snapshot: snapshot(100), now: start)
        tracker.track(raw, snapshot: snapshot(0), now: start)

        #expect(tracker.releaseReady(now: start + 60) { disk[$0] } == [jpeg])
        #expect(tracker.pendingCount == 0)
    }

    @Test func snapshotReadsSizeAndDateFromDisk() throws {
        try withTempDirectory { directory in
            let modified = Date(timeIntervalSince1970: 1_750_000_000)
            let url = try writeFile("a.jpg", in: directory, contents: bytes(1234, filledWith: 7), modified: modified)

            #expect(FileSnapshot.read(at: url) == FileSnapshot(size: 1234, modified: modified))
            #expect(FileSnapshot.read(at: directory.appendingPathComponent("missing.jpg")) == nil)
            #expect(FileSnapshot.read(at: directory) == nil)
        }
    }
}
