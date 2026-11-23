import Foundation

public struct ImportGroup: Hashable, Sendable {
    public enum Kind: Sendable {
        case photo
        case video
    }

    public let primary: URL
    public let kind: Kind
    public let alternateRAW: URL?

    public init(primary: URL, kind: Kind, alternateRAW: URL? = nil) {
        self.primary = primary
        self.kind = kind
        self.alternateRAW = alternateRAW
    }

    public var files: [URL] {
        if let alternateRAW { [primary, alternateRAW] } else { [primary] }
    }
}

struct PairKey: Hashable {
    let folder: String
    let baseName: String

    init(_ url: URL) {
        folder = url.deletingLastPathComponent().path
        baseName = url.deletingPathExtension().lastPathComponent.lowercased()
    }
}

public enum AssetPairing {
    public static func groups(for urls: [URL]) -> [ImportGroup] {
        var seenPaths = Set<String>()
        let sorted = urls
            .filter { seenPaths.insert($0.path).inserted }
            .sorted { $0.path < $1.path }

        var firstJPEG: [PairKey: URL] = [:]
        var firstRAW: [PairKey: URL] = [:]
        for url in sorted {
            let key = PairKey(url)
            if MediaFilter.isJPEG(url), firstJPEG[key] == nil {
                firstJPEG[key] = url
            } else if MediaFilter.kind(of: url) == .rawPhoto, firstRAW[key] == nil {
                firstRAW[key] = url
            }
        }

        return sorted.compactMap { url in
            let key = PairKey(url)
            switch MediaFilter.kind(of: url) {
            case .video:
                return ImportGroup(primary: url, kind: .video)
            case .rawPhoto:
                let isAlternate = firstRAW[key] == url && firstJPEG[key] != nil
                return isAlternate ? nil : ImportGroup(primary: url, kind: .photo)
            case .renderedPhoto:
                let raw = firstJPEG[key] == url ? firstRAW[key] : nil
                return ImportGroup(primary: url, kind: .photo, alternateRAW: raw)
            case nil:
                return nil
            }
        }
    }
}
