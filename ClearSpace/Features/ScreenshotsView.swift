import SwiftUI
import Photos

struct ScreenshotsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var assets: [PHAsset] = []
    @State private var sizes: [String: Int64] = [:]
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var showReview = false
    @State private var reviewSnapshot: [PHAsset] = []

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        PhotoAccessGate {
            content
        }
        .navigationTitle("Screenshots")
        .navigationBarTitleDisplayMode(.large)
        .task(id: model.libraryVersion) { await load() }
        .sheet(isPresented: $showReview) {
            NavigationStack {
                ReviewView(
                    title: "Review Screenshots",
                    items: reviewItems(for: reviewSnapshot),
                    perform: { try await performDelete(reviewSnapshot) }
                )
            }
            .environmentObject(model)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isLoading && assets.isEmpty {
            ProgressView("Finding screenshots…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if assets.isEmpty {
            EmptyStateView(
                symbol: "camera.viewfinder",
                title: "No Screenshots",
                message: "There are no screenshots to clean up."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SelectionHeader(
                        summary: "\(assets.count) screenshots · \(Fmt.bytes(totalBytes)) total",
                        onSelectAll: { selected = Set(assets.map { $0.localIdentifier }) },
                        onDeselectAll: { selected.removeAll() }
                    )
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(assets, id: \.localIdentifier) { asset in
                            cell(asset)
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
            .safeAreaInset(edge: .bottom) {
                SelectionBar(
                    count: selected.count,
                    bytes: selectedBytes,
                    title: "Review Selected (\(selected.count))",
                    action: startReview
                )
            }
        }
    }

    private func cell(_ asset: PHAsset) -> some View {
        let id = asset.localIdentifier
        let isSelected = selected.contains(id)
        return Button {
            if isSelected { selected.remove(id) } else { selected.insert(id) }
        } label: {
            SquareThumb(asset: asset)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Theme.brand, lineWidth: isSelected ? 3 : 0)
                }
                .overlay(alignment: .topTrailing) {
                    SelectionBadge(selected: isSelected).padding(5)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Screenshot from \(Fmt.date(asset.creationDate))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Data

    private var totalBytes: Int64 {
        assets.reduce(Int64(0)) { $0 + (sizes[$1.localIdentifier] ?? 0) }
    }

    private var selectedBytes: Int64 {
        selected.reduce(Int64(0)) { $0 + (sizes[$1] ?? 0) }
    }

    private func load() async {
        guard model.photoAccess.canRead else {
            isLoading = false
            return
        }
        isLoading = true
        let found = await Task.detached(priority: .userInitiated) {
            LibraryScanner.screenshots()
        }.value
        assets = found
        selected = selected.intersection(Set(found.map { $0.localIdentifier }))
        isLoading = false

        let computed = await Task.detached(priority: .utility) { () -> [String: Int64] in
            var map = [String: Int64]()
            for asset in found {
                map[asset.localIdentifier] = AssetSize.bytes(for: asset)
            }
            return map
        }.value
        sizes = computed
    }

    // MARK: Review

    private func startReview() {
        reviewSnapshot = assets.filter { selected.contains($0.localIdentifier) }
        guard !reviewSnapshot.isEmpty else { return }
        showReview = true
    }

    private func reviewItems(for list: [PHAsset]) -> [ReviewItem] {
        list.map { asset in
            ReviewItem(
                id: asset.localIdentifier,
                title: "Screenshot",
                subtitle: Fmt.date(asset.creationDate),
                typeLabel: "Screenshot",
                bytes: sizes[asset.localIdentifier] ?? AssetSize.cachedOrZero(asset),
                asset: asset
            )
        }
    }

    @MainActor
    private func performDelete(_ list: [PHAsset]) async throws -> CleanupResult {
        let bytes = list.reduce(Int64(0)) { $0 + (sizes[$1.localIdentifier] ?? AssetSize.cachedOrZero($1)) }
        try await PhotoDeleter.delete(list)
        return CleanupResult(removed: list.count, bytes: bytes, note: PhotoDeleter.recentlyDeletedNote)
    }
}
