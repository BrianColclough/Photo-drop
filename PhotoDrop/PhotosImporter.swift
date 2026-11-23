import Photos
import Synchronization

struct ImportRequest: Sendable, Hashable {
    let primary: URL
    let isVideo: Bool
    let alternateRAW: URL?

    init(primary: URL, isVideo: Bool, alternateRAW: URL? = nil) {
        self.primary = primary
        self.isVideo = isVideo
        self.alternateRAW = alternateRAW
    }
}

struct ImportResult: Sendable {
    enum Outcome: Sendable {
        case imported(assetID: String)
        case failed(String)
    }

    let request: ImportRequest
    let outcome: Outcome
}

struct PhotoAlbum: Sendable, Hashable, Identifiable {
    let id: String
    let title: String
}

struct PhotosImportError: LocalizedError {
    let errorDescription: String?

    init(_ text: String) {
        errorDescription = text
    }
}

struct PhotosImporter: Sendable {
    static var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func albums() -> [PhotoAlbum] {
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
        var albums: [PhotoAlbum] = []
        collections.enumerateObjects { collection, _, _ in
            albums.append(PhotoAlbum(id: collection.localIdentifier, title: collection.localizedTitle ?? ""))
        }
        return albums.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    func findOrCreateAlbum(titled title: String) async throws -> PhotoAlbum {
        if let existing = albums().first(where: { $0.title == title }) {
            return existing
        }
        let createdID = Mutex<String?>(nil)
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            createdID.withLock { $0 = request.placeholderForCreatedAssetCollection.localIdentifier }
        }
        guard let id = createdID.withLock({ $0 }) else {
            throw PhotosImportError("Photos did not create the album “\(title)”.")
        }
        return PhotoAlbum(id: id, title: title)
    }

    func importFiles(_ requests: [ImportRequest], intoAlbumWithID albumID: String) async -> [ImportResult] {
        var results: [ImportResult] = []
        for request in requests {
            let outcome: ImportResult.Outcome
            do {
                outcome = .imported(assetID: try await importOne(request, albumID: albumID))
            } catch {
                outcome = .failed(Self.text(for: error))
            }
            results.append(ImportResult(request: request, outcome: outcome))
        }
        return results
    }

    private func importOne(_ request: ImportRequest, albumID: String) async throws -> String {
        guard Self.album(withID: albumID) != nil else {
            throw PhotosImportError("The album no longer exists in Photos.")
        }
        let assetID = Mutex<String?>(nil)
        try await PHPhotoLibrary.shared().performChanges {
            let creation = PHAssetCreationRequest.forAsset()
            creation.addResource(
                with: request.isVideo ? .video : .photo,
                fileURL: request.primary,
                options: Self.copyOptions(for: request.primary)
            )
            if let raw = request.alternateRAW {
                creation.addResource(with: .alternatePhoto, fileURL: raw, options: Self.copyOptions(for: raw))
            }
            guard let placeholder = creation.placeholderForCreatedAsset else { return }
            assetID.withLock { $0 = placeholder.localIdentifier }

            if let album = Self.album(withID: albumID) {
                PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
            }
        }
        guard let id = assetID.withLock({ $0 }) else {
            throw PhotosImportError("Photos did not return an item for \(request.primary.lastPathComponent).")
        }
        return id
    }

    private static func album(withID id: String) -> PHAssetCollection? {
        PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil).firstObject
    }

    private static func copyOptions(for url: URL) -> PHAssetResourceCreationOptions {
        let options = PHAssetResourceCreationOptions()
        options.originalFilename = url.lastPathComponent
        options.shouldMoveFile = false
        return options
    }

    private static func text(for error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.localizedDescription) [\(nsError.domain) \(nsError.code)]"
    }
}
