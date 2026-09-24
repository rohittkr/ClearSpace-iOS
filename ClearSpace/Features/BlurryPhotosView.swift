import SwiftUI
import Photos

struct BlurItem: Identifiable {
    let asset: PHAsset
    /// Variance of the Laplacian: lower means blurrier.
    let score: Double
    var id: String { asset.localIdentifier }
}

enum BlurWorker {
    static let side = 256

    static func scan(limit: Int, cancel: Box<Bool>, progress: @escaping (Double) -> Void) -> [BlurItem] {
        let assets = LibraryScanner.images(limit: limit, includeScreenshots: false)
        var items = [BlurItem]()
        for (index, asset) in assets.enumerated() {
            if cancel.value { break }
            autoreleasepool {
                if let image = ImageLoader.cgImage(for: asset, side: CGFloat(side)),
                   let score = sharpness(of: image) {
                    items.append(BlurItem(asset: asset, score: score))
                }
            }
            if index % 8 == 0 {
                progress(Double(index) / Double(max(assets.count, 1)))
            }
        }
        items.sort { $0.score < $1.score }
        return items
    }

    /// Simple sharpness heuristic: variance of a 4-neighbour Laplacian on a small grayscale copy.
    static func sharpness(of image: CGImage) -> Double? {
        let side = BlurWorker.side
        var pixels = [UInt8](repeating: 0, count: side * side)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return nil }

        var sum = 0.0
        var sumSquares = 0.0
        var n = 0.0
        for y in 1..<(side - 1) {
            for x in 1..<(side - 1) {
                let center = Int(pixels[y * side + x])
                let up = Int(pixels[(y - 1) * side + x])
                let down = Int(pixels[(y + 1) * side + x])
                let left = Int(pixels[y * side + x - 1])
                let right = Int(pixels[y * side + x + 1])
                let laplacian = Double(4 * center - up - down - left - right)
                sum += laplacian
                sumSquares += laplacian * laplacian
                n += 1
            }
        }
        guard n > 0 else { return nil }
        let mean = sum / n
        return sumSquares / n - mean * mean
    }
}

struct BlurryPhotosView: View {
    @EnvironmentObject private var model: AppModel
    @State private var items: [BlurItem] = []
    @State private var selected: Set<String> = []
    @State private var isScanning = false
    @State private var hasScanned = false
    @State private var progress = 0.0
    @State private var threshold = 80.0
    @State private var cancelFlag = Box<Bool>(false)
    @State private var showReview = false
    @State private var reviewSnapshot: [BlurItem] = []

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    private var blurry: [BlurItem] {
        items.filter { $0.score < threshold }
    }

    var body: some View {
        PhotoAccessGate {
            content
        }
        .navigationTitle("Blurry Photos")
        .navigationBarTitleDisplayMode(.large)
        .sheet(isPresented: $showReview) {
            NavigationStack {
                ReviewView(
                    title: "Review Blurry Photos",
                    items: reviewItems(for: reviewSnapshot),
                    perform: { try await performDelete(reviewSnapshot) }
                )
            }
            .environmentObject(model)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isScanning {
            VStack(spacing: 18) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(Theme.brand)
                    .frame(maxWidth: 280)
                Text("Checking sharpness… \(Fmt.percent(progress))")
                    .font(.headline)
                Button("Stop") { cancelFlag.value = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
            .padding(32)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !hasScanned {
            VStack(spacing: 18) {
                Image(systemName: "camera.filters")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.brandGradient)
                Text("Find Blurry Photos")
                    .font(.title2.weight(.bold))
                Text("ClearSpace measures how sharp each of your 1,500 most recent photos is, on this iPhone. The result is a heuristic, so you always review before anything is removed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Scan Photos") { startScan() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Blur sensitivity")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Slider(value: $threshold, in: 20...200, step: 5)
                        Text("Move right to flag more photos as blurry.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .card()

                    if blurry.isEmpty {
                        EmptyStateView(
                            symbol: "checkmark.circle",
                            title: "No Blurry Photos",
                            message: "No photos fall below the current sensitivity. Try moving the slider right."
                        )
                        .frame(height: 220)
                    } else {
                        SelectionHeader(
                            summary: "\(blurry.count) blurry photos · \(selected.count) selected",
                            onSelectAll: { selected = Set(blurry.map { $0.id }) },
                            onDeselectAll: { selected.removeAll() }
                        )
                        LazyVGrid(columns: columns, spacing: 4) {
                            ForEach(blurry) { item in
                                cell(item)
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .safeAreaInset(edge: .bottom) {
                if !blurry.isEmpty {
                    SelectionBar(
                        count: selectedVisibleCount,
                        bytes: 0,
                        title: "Review Selected (\(selectedVisibleCount))",
                        action: startReview
                    )
                }
            }
        }
    }

    private var selectedVisibleCount: Int {
        blurry.filter { selected.contains($0.id) }.count
    }

    private func cell(_ item: BlurItem) -> some View {
        let isSelected = selected.contains(item.id)
        return Button {
            if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
        } label: {
            SquareThumb(asset: item.asset)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.brand, lineWidth: isSelected ? 3 : 0)
                }
                .overlay(alignment: .topTrailing) {
                    SelectionBadge(selected: isSelected).padding(5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Blurry photo from \(Fmt.date(item.asset.creationDate))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func startScan() {
        isScanning = true
        progress = 0
        selected = []
        let flag = Box<Bool>(false)
        cancelFlag = flag
        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [BlurItem] in
                BlurWorker.scan(limit: 1500, cancel: flag) { value in
                    Task { @MainActor in
                        progress = value
                    }
                }
            }.value
            items = found
            hasScanned = true
            isScanning = false
        }
    }

    private func startReview() {
        reviewSnapshot = blurry.filter { selected.contains($0.id) }
        guard !reviewSnapshot.isEmpty else { return }
        showReview = true
    }

    private func reviewItems(for list: [BlurItem]) -> [ReviewItem] {
        list.map { item in
            ReviewItem(
                id: item.id,
                title: "Blurry photo",
                subtitle: Fmt.date(item.asset.creationDate),
                typeLabel: "Photo",
                bytes: AssetSize.bytes(for: item.asset),
                asset: item.asset
            )
        }
    }

    @MainActor
    private func performDelete(_ list: [BlurItem]) async throws -> CleanupResult {
        let bytes = list.reduce(Int64(0)) { $0 + AssetSize.bytes(for: $1.asset) }
        try await PhotoDeleter.delete(list.map { $0.asset })
        let removed = Set(list.map { $0.id })
        items.removeAll { removed.contains($0.id) }
        selected.subtract(removed)
        return CleanupResult(removed: list.count, bytes: bytes, note: PhotoDeleter.recentlyDeletedNote)
    }
}
