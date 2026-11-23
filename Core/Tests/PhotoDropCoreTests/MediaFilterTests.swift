import Foundation
import PhotoDropCore
import Testing

@Suite struct MediaFilterTests {
    let root = file("/Volumes/Archive/Photos")

    @Test(arguments: [
        ("jpg", MediaKind.renderedPhoto), ("jpeg", .renderedPhoto), ("heic", .renderedPhoto),
        ("heif", .renderedPhoto), ("png", .renderedPhoto), ("tif", .renderedPhoto), ("tiff", .renderedPhoto),
        ("dng", .rawPhoto), ("arw", .rawPhoto), ("cr2", .rawPhoto), ("cr3", .rawPhoto),
        ("nef", .rawPhoto), ("raf", .rawPhoto), ("orf", .rawPhoto), ("rw2", .rawPhoto),
        ("mov", .video), ("mp4", .video),
    ])
    func allowedExtensionInAnyCase(ext: String, kind: MediaKind) {
        let mixedCase = String(ext.enumerated().map { $0.offset.isMultiple(of: 2) ? Character($0.element.uppercased()) : $0.element })
        for spelling in [ext, ext.uppercased(), mixedCase] {
            let url = root.appendingPathComponent("2026/IMG_0001.\(spelling)")
            #expect(MediaFilter.kind(of: url) == kind)
            #expect(MediaFilter.accepts(url, under: root))
        }
    }

    @Test func allowedListHasExactlyTheSeventeenExtensions() {
        #expect(MediaFilter.allowedExtensions.count == 17)
    }

    @Test(arguments: ["xmp", "txt", "XMP", "pdf", "gif", "psd", "aae", "avi", "jpg_original", ""])
    func otherExtensionsAreRejected(ext: String) {
        let url = root.appendingPathComponent(ext.isEmpty ? "README" : "IMG_0001.\(ext)")
        #expect(MediaFilter.kind(of: url) == nil)
        #expect(!MediaFilter.accepts(url, under: root))
    }

    @Test func onlyJpgAndJpegCountAsJPEG() {
        #expect(MediaFilter.isJPEG(file("/a/b.jpg")))
        #expect(MediaFilter.isJPEG(file("/a/b.JPEG")))
        #expect(!MediaFilter.isJPEG(file("/a/b.heic")))
        #expect(!MediaFilter.isJPEG(file("/a/b.png")))
        #expect(!MediaFilter.isJPEG(file("/a/b.arw")))
    }

    @Test func hiddenFileIsRejected() {
        let url = root.appendingPathComponent("2026/._IMG_0001.jpg")
        #expect(MediaFilter.isHidden(url, under: root))
        #expect(!MediaFilter.accepts(url, under: root))
    }

    @Test func fileInsideHiddenFolderIsRejected() {
        let direct = root.appendingPathComponent(".trash/IMG_0001.jpg")
        let deep = root.appendingPathComponent("2026/.cache/thumbs/IMG_0001.jpg")
        #expect(MediaFilter.isHidden(direct, under: root))
        #expect(MediaFilter.isHidden(deep, under: root))
        #expect(!MediaFilter.accepts(deep, under: root))
    }

    @Test func dotFolderAboveRootDoesNotMatter() {
        let hiddenRoot = file("/Users/me/.archive/Photos/")
        let url = hiddenRoot.appendingPathComponent("2026/IMG_0001.jpg")
        #expect(!MediaFilter.isHidden(url, under: hiddenRoot))
        #expect(MediaFilter.accepts(url, under: hiddenRoot))
        #expect(MediaFilter.isHidden(hiddenRoot.appendingPathComponent("2026/.IMG_0001.jpg"), under: hiddenRoot))
    }

    @Test func visibleNestedFileIsAccepted() {
        let url = root.appendingPathComponent("2026/11 November/IMG_0001.HEIC")
        #expect(!MediaFilter.isHidden(url, under: root))
        #expect(MediaFilter.accepts(url, under: root))
    }
}
