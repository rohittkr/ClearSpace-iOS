import SwiftUI
import Photos

@MainActor
final class AppModel: ObservableObject {
    @Published var photoAccess: PhotoAccess = PhotoAccess.current()
    @Published var storage: DeviceStorage = DeviceStorage.read()
    @Published var photoCount: Int = 0
    @Published var videoCount: Int = 0
    @Published var screenshotCount: Int = 0
    @Published var videoBytes: Int64? = nil
    @Published var screenshotBytes: Int64? = nil
    /// Bumped whenever the library changed (cleanup, new permission) so screens reload.
    @Published var libraryVersion: Int = 0
    @Published var ledger: CleanupLedger = CleanupLedger.load()

    let similar = SimilarStore()
    let contacts = ContactsStore()

    private var statsTask: Task<Void, Never>?

    /// Called when the app opens.
    func start() {
        refresh()
        contacts.scanIfAuthorized()
    }

    /// Refreshes storage numbers and library counts.
    func refresh() {
        storage = DeviceStorage.read()
        photoAccess = PhotoAccess.current()
        contacts.refreshAccess()
        if photoAccess.canRead {
            loadLibraryStats()
        } else {
            statsTask?.cancel()
            photoCount = 0
            videoCount = 0
            screenshotCount = 0
            videoBytes = nil
            screenshotBytes = nil
        }
    }

    func requestPhotoAccess() async {
        photoAccess = await PhotoAccess.request()
        libraryVersion += 1
        refresh()
    }

    func recordCleanup(_ result: CleanupResult) {
        ledger.record(result)
        ledger.save()
        libraryVersion += 1
        refresh()
    }

    func resetLedger() {
        CleanupLedger.reset()
        ledger = CleanupLedger()
    }

    private func loadLibraryStats() {
        statsTask?.cancel()
        statsTask = Task {
            let counts = await Task.detached(priority: .utility) {
                LibraryScanner.counts()
            }.value
            if Task.isCancelled { return }
            photoCount = counts.photos
            videoCount = counts.videos
            screenshotCount = counts.screenshots

            let sizes = await Task.detached(priority: .utility) { () -> (Int64, Int64) in
                let shots = LibraryScanner.totalBytes(of: LibraryScanner.screenshots())
                let vids = LibraryScanner.totalBytes(of: LibraryScanner.videos())
                return (shots, vids)
            }.value
            if Task.isCancelled { return }
            screenshotBytes = sizes.0
            videoBytes = sizes.1
        }
    }
}
