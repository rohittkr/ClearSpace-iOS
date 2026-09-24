import SwiftUI
import Photos
import Vision

// MARK: - Model types

struct PrintEntry {
    let asset: PHAsset
    let print: VNFeaturePrintObservation
}

struct SimilarGroup: Identifiable {
    let id: String
    var assets: [PHAsset]
    var keepID: String
}

enum Sensitivity: String, CaseIterable, Identifiable {
    case strict = "Strict"
    case balanced = "Balanced"
    case loose = "Loose"

    var id: String { rawValue }

    /// Maximum Vision feature-print distance for two photos to be grouped.
    var threshold: Float {
        switch self {
        case .strict: return 0.25
        case .balanced: return 0.40
        case .loose: return 0.55
        }
    }
}

// MARK: - Analysis (runs off the main thread)

enum SimilarWorker {
    static func computePrints(limit: Int, cancel: Box<Bool>, progress: @escaping (Double) -> Void) -> [PrintEntry] {
        let assets = LibraryScanner.images(limit: limit, includeScreenshots: false)
        var output = [PrintEntry]()
        output.reserveCapacity(assets.count)

        for (index, asset) in assets.enumerated() {
            if cancel.value { break }
            autoreleasepool {
                if let image = ImageLoader.cgImage(for: asset, side: 299),
                   let observation = featurePrint(for: image) {
                    output.append(PrintEntry(asset: asset, print: observation))
                }
            }
            if index % 8 == 0 {
                progress(Double(index) / Double(max(assets.count, 1)))
            }
        }
        return output
    }

    static func featurePrint(for image: CGImage) -> VNFeaturePrintObservation? {
        let request = VNGenerateImageFeaturePrintRequest()
        request.imageCropAndScaleOption = .scaleFill
        if VNGenerateImageFeaturePrintRequest.supportedRevisions.contains(1) {
            request.revision = 1
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        var found: VNFeaturePrintObservation?
        for case let observation as VNFeaturePrintObservation in (request.results ?? []) {
            found = observation
            break
        }
        return found
    }

    /// Groups photos whose feature prints are closer than `threshold`.
    /// Photos are compared with their neighbours in date order (burst shots, retakes).
    static func group(entries: [PrintEntry], threshold: Float, window: Int = 60) -> [SimilarGroup] {
        let count = entries.count
        guard count > 1 else { return [] }

        var parent = Array(0..<count)
        func find(_ node: Int) -> Int {
            var current = node
            while parent[current] != current {
                parent[current] = parent[parent[current]]
                current = parent[current]
            }
            return current
        }

        for i in 0..<count {
            let upper = min(count, i + 1 + window)
            if i + 1 >= upper { continue }
            for j in (i + 1)..<upper {
                var distance: Float = 0
                do {
                    try entries[i].print.computeDistance(&distance, to: entries[j].print)
                } catch {
                    continue
                }
                if distance < threshold {
                    let a = find(i)
                    let b = find(j)
                    if a != b { parent[b] = a }
                }
            }
        }

        var buckets = [Int: [Int]]()
        for i in 0..<count {
            buckets[find(i), default: []].append(i)
        }

        var groups = [SimilarGroup]()
        for (_, members) in buckets where members.count > 1 {
            let assets = members.map { entries[$0].asset }
            let keep = bestAsset(in: assets)
            groups.append(SimilarGroup(id: assets[0].localIdentifier, assets: assets, keepID: keep.localIdentifier))
        }
        groups.sort {
            ($0.assets.first?.creationDate ?? .distantPast) > ($1.assets.first?.creationDate ?? .distantPast)
        }
        return groups
    }

    /// Recommended photo to keep: favourite first, then highest resolution.
    static func bestAsset(in assets: [PHAsset]) -> PHAsset {
        func score(_ asset: PHAsset) -> Double {
            (asset.isFavorite ? 1e12 : 0) + Double(asset.pixelWidth) * Double(asset.pixelHeight)
        }
        return assets.max(by: { score($0) < score($1) }) ?? assets[0]
    }
}

// MARK: - Store

@MainActor
final class SimilarStore: ObservableObject {
    @Published private(set) var groups: [SimilarGroup] = []
    @Published var selected: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var hasScanned = false
    @Published private(set) var scannedCount = 0
    @Published private(set) var reclaimableBytes: Int64 = 0
    @Published var scanLimit: Int = 2000
    @Published var sensitivity: Sensitivity = .balanced {
        didSet {
            if oldValue != sensitivity { regroup() }
        }
    }

    private var entries: [PrintEntry] = []
    private var cancelFlag = Box<Bool>(false)
    private var regroupTask: Task<Void, Never>?

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        progress = 0
        selected = []
        let limit = scanLimit
        let flag = Box<Bool>(false)
        cancelFlag = flag

        Task {
            let found = await Task.detached(priority: .userInitiated) { () -> [PrintEntry] in
                SimilarWorker.computePrints(limit: limit, cancel: flag) { value in
                    Task { @MainActor in
                        self.progress = value
                    }
                }
            }.value
            self.entries = found
            self.scannedCount = found.count
            self.hasScanned = true
            self.isScanning = false
            self.progress = 1
            self.regroup()
        }
    }

    func cancelScan() {
        cancelFlag.value = true
    }

    private func regroup() {
        regroupTask?.cancel()
        let snapshot = entries
        let threshold = sensitivity.threshold
        regroupTask = Task {
            let result = await Task.detached(priority: .userInitiated) { () -> ([SimilarGroup], Int64) in
                let grouped = SimilarWorker.group(entries: snapshot, threshold: threshold)
                var bytes: Int64 = 0
                for group in grouped {
                    for asset in group.assets where asset.localIdentifier != group.keepID {
                        bytes += AssetSize.bytes(for: asset)
                    }
                }
                return (grouped, bytes)
            }.value
            if Task.isCancelled { return }
            self.groups = result.0
            self.reclaimableBytes = result.1
            let removable = Set(result.0.flatMap { group in
                group.assets.map { $0.localIdentifier }.filter { $0 != group.keepID }
            })
            self.selected = self.selected.intersection(removable)
        }
    }

    // MARK: Selection

    func toggle(_ id: String) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
    }

    /// Chooses which photo of a group to keep. The new keeper is un-selected.
    func setKeep(assetID: String, groupID: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].keepID = assetID
        selected.remove(assetID)
        updateReclaimable()
    }

    func selectAllNonKeep() {
        var ids = Set<String>()
        for group in groups {
            for asset in group.assets where asset.localIdentifier != group.keepID {
                ids.insert(asset.localIdentifier)
            }
        }
        selected = ids
    }

    func deselectAll() {
        selected.removeAll()
    }

    var selectedAssets: [PHAsset] {
        var list = [PHAsset]()
        for group in groups {
            for asset in group.assets where selected.contains(asset.localIdentifier) && asset.localIdentifier != group.keepID {
                list.append(asset)
            }
        }
        return list
    }

    func bytes(of assets: [PHAsset]) -> Int64 {
        assets.reduce(Int64(0)) { $0 + AssetSize.cachedOrZero($1) }
    }

    /// Removes deleted photos from the results after a successful cleanup.
    func purge(ids: Set<String>) {
        entries.removeAll { ids.contains($0.asset.localIdentifier) }
        selected.subtract(ids)
        regroup()
    }

    private func updateReclaimable() {
        let current = groups
        Task {
            let bytes = await Task.detached(priority: .utility) { () -> Int64 in
                var total: Int64 = 0
                for group in current {
                    for asset in group.assets where asset.localIdentifier != group.keepID {
                        total += AssetSize.bytes(for: asset)
                    }
                }
                return total
            }.value
            self.reclaimableBytes = bytes
        }
    }
}

// MARK: - Screen

struct SimilarPhotosScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SimilarPhotosContent(store: model.similar)
    }
}

private struct SimilarPhotosContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: SimilarStore
    @State private var showReview = false
    @State private var reviewSnapshot: [PHAsset] = []

    var body: some View {
        PhotoAccessGate {
            content
        }
        .navigationTitle("Similar Photos")
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            if store.hasScanned && !store.isScanning {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.scan()
                    } label: {
                        Label("Rescan", systemImage: "arrow.clockwise")
                    }
                }
            }
        }
        .sheet(isPresented: $showReview) {
            NavigationStack {
                ReviewView(
                    title: "Review Similar Photos",
                    items: reviewItems(for: reviewSnapshot),
                    perform: { try await performDelete(reviewSnapshot) }
                )
            }
            .environmentObject(model)
        }
    }

    @ViewBuilder
    private var content: some View {
        if store.isScanning {
            scanningView
        } else if !store.hasScanned {
            introView
        } else if store.groups.isEmpty {
            VStack(spacing: 16) {
                EmptyStateView(
                    symbol: "checkmark.circle",
                    title: "No Similar Photos",
                    message: "Nothing looked similar among your \(store.scannedCount) most recent photos. Try a looser setting."
                )
                sensitivityPicker.padding(.horizontal)
            }
        } else {
            resultsView
        }
    }

    // MARK: Intro / scanning

    private var introView: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.brandGradient)
                    .padding(.top, 24)
                Text("Find Similar Photos")
                    .font(.title2.weight(.bold))
                Text("ClearSpace uses Apple's Vision framework on your iPhone to compare photos and group near-duplicates. For each group it suggests one photo to keep. Nothing is selected or deleted automatically.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Photos to scan (most recent)")
                        .font(.subheadline.weight(.semibold))
                    Picker("Photos to scan", selection: $store.scanLimit) {
                        Text("1,000").tag(1000)
                        Text("2,000").tag(2000)
                        Text("5,000").tag(5000)
                    }
                    .pickerStyle(.segmented)
                }
                .card()

                Button("Scan Library") { store.scan() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .padding()
        }
    }

    private var scanningView: some View {
        VStack(spacing: 18) {
            ProgressView(value: store.progress)
                .progressViewStyle(.linear)
                .tint(Theme.brand)
                .frame(maxWidth: 280)
            Text("Analysing photos… \(Fmt.percent(store.progress))")
                .font(.headline)
            Text("This can take a minute for large libraries. Photos stored only in iCloud are skipped.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Stop") { store.cancelScan() }
                .buttonStyle(SecondaryButtonStyle())
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Results

    private var sensitivityPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Match sensitivity")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Match sensitivity", selection: $store.sensitivity) {
                ForEach(Sensitivity.allCases) { level in
                    Text(level.rawValue).tag(level)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var resultsView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("\(store.groups.count) groups · \(store.selected.count) selected")
                        .font(.subheadline.weight(.semibold))
                    Text("The photo marked Keep is our suggestion. Tap other photos to select them, or touch and hold a photo to keep it instead.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    sensitivityPicker
                    HStack(spacing: 10) {
                        Button("Select All") { store.selectAllNonKeep() }
                            .buttonStyle(SecondaryButtonStyle())
                        Button("Deselect All") { store.deselectAll() }
                            .buttonStyle(SecondaryButtonStyle())
                        Spacer()
                    }
                }

                ForEach(Array(store.groups.enumerated()), id: \.element.id) { index, group in
                    groupCard(index: index, group: group)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 12)
        }
        .safeAreaInset(edge: .bottom) {
            SelectionBar(
                count: store.selected.count,
                bytes: store.bytes(of: store.selectedAssets),
                title: "Review Selected (\(store.selected.count))",
                action: startReview
            )
        }
    }

    private func groupCard(index: Int, group: SimilarGroup) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Group \(index + 1)")
                    .font(.subheadline.weight(.semibold))
                Text("· \(group.assets.count) photos")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Fmt.date(group.assets.first?.creationDate))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(group.assets, id: \.localIdentifier) { asset in
                        cell(asset: asset, group: group)
                    }
                }
            }
        }
        .card()
    }

    private func cell(asset: PHAsset, group: SimilarGroup) -> some View {
        let id = asset.localIdentifier
        let isKeep = id == group.keepID
        let isSelected = store.selected.contains(id)
        return Button {
            if !isKeep { store.toggle(id) }
        } label: {
            SquareThumb(asset: asset)
                .frame(width: 112, height: 112)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(isKeep ? Color.green : Theme.brand, lineWidth: (isKeep || isSelected) ? 3 : 0)
                }
                .overlay(alignment: .topTrailing) {
                    if !isKeep {
                        SelectionBadge(selected: isSelected).padding(5)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if isKeep {
                        Label("Keep", systemImage: "star.fill")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.green))
                            .foregroundStyle(.white)
                            .padding(5)
                    }
                }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                store.setKeep(assetID: id, groupID: group.id)
            } label: {
                Label("Keep This Photo", systemImage: "star")
            }
        }
        .accessibilityLabel(isKeep ? "Recommended photo to keep" : "Similar photo, \(isSelected ? "selected" : "not selected")")
    }

    // MARK: Review

    private func startReview() {
        reviewSnapshot = store.selectedAssets
        guard !reviewSnapshot.isEmpty else { return }
        showReview = true
    }

    private func reviewItems(for list: [PHAsset]) -> [ReviewItem] {
        list.map { asset in
            ReviewItem(
                id: asset.localIdentifier,
                title: "Similar photo",
                subtitle: Fmt.date(asset.creationDate),
                typeLabel: "Photo",
                bytes: AssetSize.cachedOrZero(asset),
                asset: asset
            )
        }
    }

    @MainActor
    private func performDelete(_ list: [PHAsset]) async throws -> CleanupResult {
        let bytes = list.reduce(Int64(0)) { $0 + AssetSize.cachedOrZero($1) }
        try await PhotoDeleter.delete(list)
        store.purge(ids: Set(list.map { $0.localIdentifier }))
        return CleanupResult(removed: list.count, bytes: bytes, note: PhotoDeleter.recentlyDeletedNote)
    }
}
