import Photos
import UIKit

// MARK: - Permission

enum PhotoAccess: Equatable {
    case notDetermined, authorized, limited, denied, restricted

    var canRead: Bool { self == .authorized || self == .limited }

    static func current() -> PhotoAccess {
        map(PHPhotoLibrary.authorizationStatus(for: .readWrite))
    }

    static func request() async -> PhotoAccess {
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        return map(status)
    }

    private static func map(_ status: PHAuthorizationStatus) -> PhotoAccess {
        switch status {
        case .notDetermined: return .notDetermined
        case .authorized: return .authorized
        case .limited: return .limited
        case .restricted: return .restricted
        case .denied: return .denied
        @unknown default: return .denied
        }
    }
}

// MARK: - Fetching

enum LibraryScanner {
    static func fetchImages() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: PHAssetMediaType.image, options: options)
    }

    static func fetchVideos() -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        return PHAsset.fetchAssets(with: PHAssetMediaType.video, options: options)
    }

    static func array(from result: PHFetchResult<PHAsset>) -> [PHAsset] {
        var assets = [PHAsset]()
        assets.reserveCapacity(result.count)
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }
        return assets
    }

    /// Screenshots are images whose media subtype contains `.photoScreenshot`.
    static func screenshots() -> [PHAsset] {
        var assets = [PHAsset]()
        fetchImages().enumerateObjects { asset, _, _ in
            if asset.mediaSubtypes.contains(.photoScreenshot) {
                assets.append(asset)
            }
        }
        return assets
    }

    static func videos() -> [PHAsset] {
        array(from: fetchVideos())
    }

    static func images(limit: Int, includeScreenshots: Bool) -> [PHAsset] {
        var assets = [PHAsset]()
        fetchImages().enumerateObjects { asset, _, stop in
            if !includeScreenshots && asset.mediaSubtypes.contains(.photoScreenshot) { return }
            assets.append(asset)
            if assets.count >= limit { stop.pointee = true }
        }
        return assets
    }

    static func counts() -> (photos: Int, videos: Int, screenshots: Int) {
        let images = fetchImages()
        var shots = 0
        images.enumerateObjects { asset, _, _ in
            if asset.mediaSubtypes.contains(.photoScreenshot) { shots += 1 }
        }
        return (images.count, fetchVideos().count, shots)
    }

    static func totalBytes(of assets: [PHAsset]) -> Int64 {
        assets.reduce(Int64(0)) { $0 + AssetSize.bytes(for: $1) }
    }
}

// MARK: - Size estimation

final class AssetSizeCache: @unchecked Sendable {
    static let shared = AssetSizeCache()
    private var storage: [String: Int64] = [:]
    private let lock = NSLock()

    func get(_ id: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return storage[id]
    }

    func set(_ id: String, _ value: Int64) {
        lock.lock(); defer { lock.unlock() }
        storage[id] = value
    }
}

enum AssetSize {
    /// Best-effort on-disk size of an asset. Falls back to an estimate when the
    /// system does not expose a size for the asset's resources.
    static func bytes(for asset: PHAsset) -> Int64 {
        let id = asset.localIdentifier
        if let cached = AssetSizeCache.shared.get(id) { return cached }

        var total: Int64 = 0
        let wanted: Set<PHAssetResourceType> = [.photo, .video, .pairedVideo, .fullSizePhoto, .fullSizeVideo]
        for resource in PHAssetResource.assetResources(for: asset) where wanted.contains(resource.type) {
            if resource.responds(to: Selector(("fileSize"))),
               let number = resource.value(forKey: "fileSize") as? NSNumber {
                total += number.int64Value
            }
        }
        if total <= 0 { total = estimate(for: asset) }
        AssetSizeCache.shared.set(id, total)
        return total
    }

    static func cachedOrZero(_ asset: PHAsset) -> Int64 {
        AssetSizeCache.shared.get(asset.localIdentifier) ?? 0
    }

    private static func estimate(for asset: PHAsset) -> Int64 {
        if asset.mediaType == .video {
            return Int64(asset.duration * 2_500_000)
        }
        return Int64(Double(asset.pixelWidth * asset.pixelHeight) * 0.35)
    }
}

// MARK: - Image loading for analysis

enum ImageLoader {
    /// Synchronous load; call from a background task only. Returns nil for iCloud-only assets.
    static func cgImage(for asset: PHAsset, side: CGFloat) -> CGImage? {
        let options = PHImageRequestOptions()
        options.isSynchronous = true
        options.deliveryMode = .highQualityFormat
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        let box = Box<UIImage?>(nil)
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: side, height: side),
            contentMode: .aspectFit,
            options: options
        ) { image, _ in
            box.value = image
        }
        return box.value?.cgImage
    }
}

// MARK: - Deletion

enum PhotoDeleter {
    static let recentlyDeletedNote = "Photos keeps deleted items in Recently Deleted for 30 days. Storage is fully released once they are removed from that album."

    /// Uses PHAssetChangeRequest.deleteAssets. iOS shows its own confirmation alert.
    static func delete(_ assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        let toDelete = assets as NSArray
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(toDelete)
        }
    }

    static func isUserCancelled(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == PHPhotosErrorDomain && ns.code == PHPhotosError.Code.userCancelled.rawValue
    }
}
