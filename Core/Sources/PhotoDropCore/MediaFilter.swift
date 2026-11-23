import Foundation

public enum MediaKind: Sendable {
    case renderedPhoto
    case rawPhoto
    case video
}

public enum MediaFilter {
    public static let jpegExtensions: Set<String> = ["jpg", "jpeg"]
    public static let renderedPhotoExtensions: Set<String> = jpegExtensions.union(["heic", "heif", "png", "tif", "tiff"])
    public static let rawExtensions: Set<String> = ["dng", "arw", "cr2", "cr3", "nef", "raf", "orf", "rw2"]
    public static let videoExtensions: Set<String> = ["mov", "mp4"]
    public static let allowedExtensions = renderedPhotoExtensions.union(rawExtensions).union(videoExtensions)

    public static func kind(of url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if renderedPhotoExtensions.contains(ext) { return .renderedPhoto }
        if rawExtensions.contains(ext) { return .rawPhoto }
        if videoExtensions.contains(ext) { return .video }
        return nil
    }

    public static func isJPEG(_ url: URL) -> Bool {
        jpegExtensions.contains(url.pathExtension.lowercased())
    }

    public static func isHidden(_ url: URL, under root: URL) -> Bool {
        let file = url.standardizedFileURL.pathComponents
        let base = root.standardizedFileURL.pathComponents
        // A file outside the root is judged by its own name only.
        let belowRoot = file.starts(with: base) ? file.dropFirst(base.count) : file.suffix(1)
        return belowRoot.contains { $0.hasPrefix(".") }
    }

    public static func accepts(_ url: URL, under root: URL) -> Bool {
        kind(of: url) != nil && !isHidden(url, under: root)
    }
}
