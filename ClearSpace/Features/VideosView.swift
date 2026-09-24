import SwiftUI
import Photos
import AVFoundation
import AVKit

struct VideoItem: Identifiable {
    let asset: PHAsset
    let bytes: Int64
    var id: String { asset.localIdentifier }
}

struct VideosView: View {
    @EnvironmentObject private var model: AppModel
    @State private var videos: [VideoItem] = []
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var showReview = false
    @State private var reviewSnapshot: [VideoItem] = []
    @State private var previewTarget: PreviewTarget?
    @State private var confirmCompress = false
    @State private var isCompressing = false
    @State private var compressStatus = ""
    @State private var compressMessage: String?

    var body: some View {
        PhotoAccessGate {
            content
        }
        .navigationTitle("Large Videos")
        .navigationBarTitleDisplayMode(.large)
        .task(id: model.libraryVersion) { await load() }
        .sheet(isPresented: $showReview) {
            NavigationStack {
                ReviewView(
                    title: "Review Videos",
                    items: reviewItems(for: reviewSnapshot),
                    perform: { try await performDelete(reviewSnapshot) }
                )
            }
            .environmentObject(model)
        }
        .sheet(item: $previewTarget) { target in
            VideoPreviewView(asset: target.asset)
        }
        .confirmationDialog(
            "Create compressed copies?",
            isPresented: $confirmCompress,
            titleVisibility: .visible
        ) {
            Button("Compress \(selected.count) Video\(selected.count == 1 ? "" : "s")") {
                compressSelected()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("ClearSpace saves a smaller copy of each selected video to your library. Your originals are not deleted. You can remove them later through Review.")
        }
        .alert("Compression", isPresented: Binding(
            get: { compressMessage != nil },
            set: { if !$0 { compressMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(compressMessage ?? "")
        }
        .overlay {
            if isCompressing {
                ZStack {
                    Color.black.opacity(0.35).ignoresSafeArea()
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text(compressStatus).font(.subheadline.weight(.semibold))
                    }
                    .padding(24)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isLoading && videos.isEmpty {
            ProgressView("Finding videos…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if videos.isEmpty {
            EmptyStateView(
                symbol: "video.slash",
                title: "No Videos",
                message: "There are no videos in your photo library."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    SelectionHeader(
                        summary: "\(videos.count) videos · \(Fmt.bytes(videos.reduce(Int64(0)) { $0 + $1.bytes })) · largest first",
                        onSelectAll: { selected = Set(videos.map { $0.id }) },
                        onDeselectAll: { selected.removeAll() }
                    )
                    LazyVStack(spacing: 10) {
                        ForEach(videos) { item in
                            row(item)
                        }
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
        }
    }

    private func row(_ item: VideoItem) -> some View {
        let isSelected = selected.contains(item.id)
        return HStack(spacing: 12) {
            Button {
                previewTarget = PreviewTarget(asset: item.asset)
            } label: {
                ZStack {
                    AssetThumbnail(asset: item.asset, pixels: 240)
                    Image(systemName: "play.circle.fill")
                        .font(.title)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                }
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Preview video")

            Button {
                if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Fmt.bytes(item.bytes))
                            .font(.headline)
                        Text(Fmt.date(item.asset.creationDate))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Label(Fmt.duration(item.asset.duration), systemImage: "clock")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    PlainSelectionBadge(selected: isSelected)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Theme.brand, lineWidth: isSelected ? 2 : 0)
        }
    }

    private var bottomBar: some View {
        let selectedItems = videos.filter { selected.contains($0.id) }
        let bytes = selectedItems.reduce(Int64(0)) { $0 + $1.bytes }
        return VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(selectedItems.count) selected")
                        .font(.subheadline.weight(.semibold))
                    if bytes > 0 {
                        Text("About \(Fmt.bytes(bytes)) can be freed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            HStack(spacing: 10) {
                Button {
                    confirmCompress = true
                } label: {
                    Label("Compress Copy", systemImage: "arrow.down.right.and.arrow.up.left")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.brand.opacity(0.14)))
                        .foregroundStyle(Theme.brand)
                }
                .disabled(selectedItems.isEmpty)
                .opacity(selectedItems.isEmpty ? 0.4 : 1)

                Button("Review (\(selectedItems.count))", action: startReview)
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(selectedItems.isEmpty)
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.regularMaterial)
    }

    // MARK: Data

    private func load() async {
        guard model.photoAccess.canRead else {
            isLoading = false
            return
        }
        isLoading = true
        let items = await Task.detached(priority: .userInitiated) { () -> [VideoItem] in
            let assets = LibraryScanner.videos()
            var list = assets.map { VideoItem(asset: $0, bytes: AssetSize.bytes(for: $0)) }
            list.sort { $0.bytes > $1.bytes }
            return list
        }.value
        videos = items
        selected = selected.intersection(Set(items.map { $0.id }))
        isLoading = false
    }

    // MARK: Review

    private func startReview() {
        reviewSnapshot = videos.filter { selected.contains($0.id) }
        guard !reviewSnapshot.isEmpty else { return }
        showReview = true
    }

    private func reviewItems(for list: [VideoItem]) -> [ReviewItem] {
        list.map { item in
            ReviewItem(
                id: item.id,
                title: "Video · \(Fmt.duration(item.asset.duration))",
                subtitle: Fmt.date(item.asset.creationDate),
                typeLabel: "Video",
                bytes: item.bytes,
                asset: item.asset
            )
        }
    }

    @MainActor
    private func performDelete(_ list: [VideoItem]) async throws -> CleanupResult {
        let bytes = list.reduce(Int64(0)) { $0 + $1.bytes }
        try await PhotoDeleter.delete(list.map { $0.asset })
        return CleanupResult(removed: list.count, bytes: bytes, note: PhotoDeleter.recentlyDeletedNote)
    }

    // MARK: Compression

    private func compressSelected() {
        let targets = videos.filter { selected.contains($0.id) }
        guard !targets.isEmpty else { return }
        isCompressing = true
        Task {
            var succeeded = 0
            var savedBytes: Int64 = 0
            var failures: [String] = []
            for (index, item) in targets.enumerated() {
                compressStatus = "Compressing \(index + 1) of \(targets.count)…"
                do {
                    let newSize = try await VideoCompressor.compress(item.asset)
                    succeeded += 1
                    savedBytes += max(item.bytes - newSize, 0)
                } catch {
                    failures.append(error.localizedDescription)
                }
            }
            isCompressing = false
            var message = ""
            if succeeded > 0 {
                message += "Saved \(succeeded) compressed cop\(succeeded == 1 ? "y" : "ies") to your library. Deleting the originals would free about \(Fmt.bytes(savedBytes)) more than the copies use. Originals were not touched."
            }
            if let first = failures.first {
                if !message.isEmpty { message += "\n\n" }
                message += "\(failures.count) video\(failures.count == 1 ? "" : "s") could not be compressed: \(first)"
            }
            compressMessage = message
            model.refresh()
            model.libraryVersion += 1
        }
    }
}

// MARK: - Preview

struct PreviewTarget: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

struct VideoPreviewView: View {
    let asset: PHAsset
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?
    @State private var failed = false

    var body: some View {
        NavigationStack {
            Group {
                if let player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .bottom)
                } else if failed {
                    PermissionMessageView(
                        symbol: "icloud.slash",
                        title: "Video Unavailable",
                        message: "This video couldn't be loaded. It may be stored in iCloud and couldn't be downloaded right now.",
                        buttonTitle: nil
                    )
                } else {
                    ProgressView("Loading video…")
                }
            }
            .navigationTitle(Fmt.date(asset.creationDate))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadPlayer() }
        .onDisappear { player?.pause() }
    }

    private func loadPlayer() async {
        let item: AVPlayerItem? = await withCheckedContinuation { continuation in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .automatic
            PHImageManager.default().requestPlayerItem(forVideo: asset, options: options) { playerItem, _ in
                continuation.resume(returning: playerItem)
            }
        }
        if let item {
            let newPlayer = AVPlayer(playerItem: item)
            player = newPlayer
            newPlayer.play()
        } else {
            failed = true
        }
    }
}

// MARK: - Compression service

enum VideoCompressor {
    enum CompressError: LocalizedError {
        case unavailable
        case exportFailed(String)
        case saveFailed

        var errorDescription: String? {
            switch self {
            case .unavailable:
                return "The video isn't available on this device (it may still be in iCloud)."
            case .exportFailed(let reason):
                return "Export failed: \(reason)"
            case .saveFailed:
                return "The compressed copy couldn't be saved to your library."
            }
        }
    }

    /// Creates a compressed copy in the photo library. The original is never modified or deleted.
    /// Returns the size in bytes of the new file.
    static func compress(_ asset: PHAsset) async throws -> Int64 {
        guard let avAsset = await loadAVAsset(asset) else { throw CompressError.unavailable }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mov")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let maybeSession: AVAssetExportSession? = AVAssetExportSession(
            asset: avAsset,
            presetName: AVAssetExportPresetMediumQuality
        )
        guard let session = maybeSession else {
            throw CompressError.exportFailed("This video can't be exported at reduced quality.")
        }

        if #available(iOS 18.0, *) {
            do {
                try await session.export(to: outputURL, as: .mov)
            } catch {
                throw CompressError.exportFailed(error.localizedDescription)
            }
        } else {
            session.outputURL = outputURL
            session.outputFileType = .mov
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                session.exportAsynchronously {
                    continuation.resume()
                }
            }
            if session.status != .completed {
                throw CompressError.exportFailed(session.error?.localizedDescription ?? "Unknown error")
            }
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path)
        let newSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0

        let created = Box<Bool>(false)
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: outputURL)
                created.value = (request != nil)
            }
        } catch {
            throw CompressError.saveFailed
        }
        if !created.value { throw CompressError.saveFailed }
        return newSize
    }

    private static func loadAVAsset(_ asset: PHAsset) async -> AVAsset? {
        await withCheckedContinuation { (continuation: CheckedContinuation<AVAsset?, Never>) in
            let options = PHVideoRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { avAsset, _, _ in
                continuation.resume(returning: avAsset)
            }
        }
    }
}
