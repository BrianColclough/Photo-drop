import Foundation
import PhotoDropCore
import Testing

@Suite struct AssetPairingTests {
    func photo(_ path: String, raw: String? = nil) -> ImportGroup {
        ImportGroup(primary: file(path), kind: .photo, alternateRAW: raw.map(file))
    }

    func video(_ path: String) -> ImportGroup {
        ImportGroup(primary: file(path), kind: .video)
    }

    @Test func jpegAndRawWithTheSameNameBecomeOneGroup() {
        let groups = AssetPairing.groups(for: [file("/r/a/DSC_1.ARW"), file("/r/a/DSC_1.JPG")])
        #expect(groups == [photo("/r/a/DSC_1.JPG", raw: "/r/a/DSC_1.ARW")])
        #expect(groups[0].files == [file("/r/a/DSC_1.JPG"), file("/r/a/DSC_1.ARW")])
    }

    @Test func pairingIgnoresCaseOfTheBaseName() {
        let groups = AssetPairing.groups(for: [file("/r/a/dsc_1.jpeg"), file("/r/a/DSC_1.dng")])
        #expect(groups == [photo("/r/a/dsc_1.jpeg", raw: "/r/a/DSC_1.dng")])
    }

    @Test func rawWithoutJpegIsItsOwnPhotoGroup() {
        let groups = AssetPairing.groups(for: [file("/r/a/DSC_1.NEF"), file("/r/a/DSC_2.JPG")])
        #expect(groups == [photo("/r/a/DSC_1.NEF"), photo("/r/a/DSC_2.JPG")])
    }

    @Test func heicPngAndTiffNeverPair() {
        let groups = AssetPairing.groups(for: [
            file("/r/a/A.HEIC"), file("/r/a/A.ARW"),
            file("/r/b/B.png"), file("/r/b/B.cr3"),
            file("/r/c/C.tiff"), file("/r/c/C.raf"),
        ])
        #expect(groups == [
            photo("/r/a/A.ARW"), photo("/r/a/A.HEIC"),
            photo("/r/b/B.cr3"), photo("/r/b/B.png"),
            photo("/r/c/C.raf"), photo("/r/c/C.tiff"),
        ])
    }

    @Test func videosAreTheirOwnGroups() {
        let groups = AssetPairing.groups(for: [file("/r/a/CLIP.MOV"), file("/r/a/CLIP.JPG"), file("/r/a/CLIP.ARW"), file("/r/a/other.mp4")])
        #expect(groups == [
            photo("/r/a/CLIP.JPG", raw: "/r/a/CLIP.ARW"),
            video("/r/a/CLIP.MOV"),
            video("/r/a/other.mp4"),
        ])
    }

    @Test func twoJpegsShareOneRawWithTheFirstSortedJpeg() {
        let groups = AssetPairing.groups(for: [file("/r/a/a.jpeg"), file("/r/a/a.ARW"), file("/r/a/a.JPG")])
        #expect(groups == [
            photo("/r/a/a.JPG", raw: "/r/a/a.ARW"),
            photo("/r/a/a.jpeg"),
        ])
    }

    @Test func twoRawsShareOneJpegWithTheFirstSortedRaw() {
        let groups = AssetPairing.groups(for: [file("/r/a/a.DNG"), file("/r/a/a.JPG"), file("/r/a/a.ARW")])
        #expect(groups == [
            photo("/r/a/a.DNG"),
            photo("/r/a/a.JPG", raw: "/r/a/a.ARW"),
        ])
    }

    @Test func sameBaseNameInDifferentFoldersDoesNotPair() {
        let groups = AssetPairing.groups(for: [
            file("/r/2026/day1/DSC_1.JPG"),
            file("/r/2026/day2/DSC_1.ARW"),
            file("/r/2026/DSC_1.ARW"),
            file("/r/2026/day1/raw/DSC_1.ARW"),
        ])
        #expect(groups == [
            photo("/r/2026/DSC_1.ARW"),
            photo("/r/2026/day1/DSC_1.JPG"),
            photo("/r/2026/day1/raw/DSC_1.ARW"),
            photo("/r/2026/day2/DSC_1.ARW"),
        ])
    }

    @Test func outputIsSortedAndStableWhateverTheInputOrder() {
        let urls = [
            file("/r/b/2.JPG"), file("/r/a/1.MOV"), file("/r/b/2.RW2"),
            file("/r/a/3.orf"), file("/r/a/1.heic"), file("/r/a/notes.txt"), file("/r/a/1.xmp"),
        ]
        let expected = [
            video("/r/a/1.MOV"),
            photo("/r/a/1.heic"),
            photo("/r/a/3.orf"),
            photo("/r/b/2.JPG", raw: "/r/b/2.RW2"),
        ]
        #expect(AssetPairing.groups(for: urls) == expected)
        #expect(AssetPairing.groups(for: urls.reversed()) == expected)
        #expect(AssetPairing.groups(for: urls + urls) == expected)
    }

    @Test func emptyBatchGivesNoGroups() {
        #expect(AssetPairing.groups(for: []).isEmpty)
    }
}
