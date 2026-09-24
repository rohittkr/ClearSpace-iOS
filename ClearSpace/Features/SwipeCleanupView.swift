import SwiftUI
import Photos

struct SwipeCleanupView: View {
    @EnvironmentObject private var model: AppModel

    private struct Decision {
        let id: String
        let marked: Bool
    }

    @State private var assets: [PHAsset] = []
    @State private var index = 0
    @State private var history: [Decision] = []
    @State private var marked: [String] = []
    @State private var offset: CGSize = .zero
    @State private var isBusy = false
    @State private var isLoading = true
    @State private var showReview = false
    @State private var reviewSnapshot: [PHAsset] = []

    private var current: PHAsset? {
        index < assets.count ? assets[index] : nil
    }

    var body: some View {
        PhotoAccessGate {
            content
        }
        .navigationTitle("Swipe Cleanup")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: model.libraryVersion) { await load() }
        .sheet(isPresented: $showReview, onDismiss: { pruneMarked() }) {
            NavigationStack {
                ReviewView(
                    title: "Review Marked Photos",
                    items: reviewItems(for: reviewSnapshot),
                    perform: { try await performDelete(reviewSnapshot) }
                )
            }
            .environmentObject(model)
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading && assets.isEmpty {
            ProgressView("Loading photos…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if assets.isEmpty {
            EmptyStateView(symbol: "photo", title: "No Photos", message: "There are no photos to go through.")
        } else {
            VStack(spacing: 16) {
                HStack {
                    Label("Keep: \(history.filter { !$0.marked }.count)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                    Spacer()
                    Text("\(min(index + 1, assets.count)) of \(assets.count)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Label("Marked: \(marked.count)", systemImage: "trash.circle.fill")
                        .foregroundStyle(.red)
                }
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal)

                if let asset = current {
                    card(for: asset)
                    controls
                } else {
                    Spacer()
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 60))
                        .foregroundStyle(Theme.brandGradient)
                    Text("You're all caught up")
                        .font(.title3.weight(.bold))
                    Text("You marked \(marked.count) photo\(marked.count == 1 ? "" : "s") for deletion. Nothing is deleted until you review and confirm.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                    Spacer()
                }

                VStack(spacing: 10) {
                    Button("Review Marked (\(marked.count))", action: startReview)
                        .buttonStyle(PrimaryButtonStyle())
                        .disabled(marked.isEmpty)
                    if !history.isEmpty {
                        Button("Undo Last") { undo() }
                            .buttonStyle(SecondaryButtonStyle())
                            .disabled(isBusy)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
            }
            .padding(.top, 8)
        }
    }

    private func card(for asset: PHAsset) -> some View {
        let progress = max(min(offset.width / 120, 1), -1)
        return ZStack {
            AssetThumbnail(asset: asset, pixels: 1200, fit: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

            stamp(text: "KEEP", color: .green, opacity: max(progress, 0))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(24)
            stamp(text: "DELETE", color: .red, opacity: max(-progress, 0))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(24)
        }
        .padding(.horizontal)
        .id(asset.localIdentifier)
        .rotationEffect(.degrees(Double(offset.width) / 25))
        .offset(x: offset.width, y: offset.height * 0.15)
        .gesture(
            DragGesture()
                .onChanged { value in
                    if !isBusy { offset = value.translation }
                }
                .onEnded { value in
                    if value.translation.width > 120 {
                        decide(mark: false)
                    } else if value.translation.width < -120 {
                        decide(mark: true)
                    } else {
                        withAnimation(.spring()) { offset = .zero }
                    }
                }
        )
        .accessibilityLabel("Photo from \(Fmt.date(asset.creationDate))")
        .accessibilityAction(named: "Keep") { decide(mark: false) }
        .accessibilityAction(named: "Mark for deletion") { decide(mark: true) }
    }

    private func stamp(text: String, color: Color, opacity: Double) -> some View {
        Text(text)
            .font(.title.weight(.heavy))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(color, lineWidth: 4))
            .rotationEffect(.degrees(color == .green ? -12 : 12))
            .opacity(opacity)
    }

    private var controls: some View {
        HStack(spacing: 40) {
            Button {
                decide(mark: true)
            } label: {
                Image(systemName: "xmark")
                    .font(.title.weight(.bold))
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.red.opacity(0.15)))
                    .foregroundStyle(.red)
            }
            .accessibilityLabel("Mark for deletion")
            Button {
                decide(mark: false)
            } label: {
                Image(systemName: "checkmark")
                    .font(.title.weight(.bold))
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.green.opacity(0.15)))
                    .foregroundStyle(.green)
            }
            .accessibilityLabel("Keep")
        }
        .disabled(isBusy)
    }

    // MARK: Actions

    private func decide(mark: Bool) {
        guard !isBusy, let asset = current else { return }
        isBusy = true
        withAnimation(.easeOut(duration: 0.2)) {
            offset = CGSize(width: mark ? -700 : 700, height: 0)
        }
        Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            history.append(Decision(id: asset.localIdentifier, marked: mark))
            if mark { marked.append(asset.localIdentifier) }
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                offset = .zero
                index += 1
            }
            isBusy = false
        }
    }

    private func undo() {
        guard let last = history.popLast() else { return }
        if last.marked { marked.removeAll { $0 == last.id } }
        index = max(index - 1, 0)
    }

    private func load() async {
        guard model.photoAccess.canRead else {
            isLoading = false
            return
        }
        isLoading = true
        let found = await Task.detached(priority: .userInitiated) {
            LibraryScanner.images(limit: 300, includeScreenshots: true)
        }.value
        if assets.isEmpty {
            assets = found
        } else {
            let alive = Set(found.map { $0.localIdentifier })
            assets = assets.filter { alive.contains($0.localIdentifier) }
            index = min(index, assets.count)
        }
        isLoading = false
    }

    private func pruneMarked() {
        let alive = Set(assets.map { $0.localIdentifier })
        marked = marked.filter { alive.contains($0) }
        history = history.filter { alive.contains($0.id) }
        index = min(index, assets.count)
    }

    // MARK: Review

    private func startReview() {
        let markedSet = Set(marked)
        reviewSnapshot = assets.filter { markedSet.contains($0.localIdentifier) }
        guard !reviewSnapshot.isEmpty else { return }
        showReview = true
    }

    private func reviewItems(for list: [PHAsset]) -> [ReviewItem] {
        list.map { asset in
            ReviewItem(
                id: asset.localIdentifier,
                title: "Marked photo",
                subtitle: Fmt.date(asset.creationDate),
                typeLabel: "Photo",
                bytes: AssetSize.bytes(for: asset),
                asset: asset
            )
        }
    }

    @MainActor
    private func performDelete(_ list: [PHAsset]) async throws -> CleanupResult {
        let bytes = list.reduce(Int64(0)) { $0 + AssetSize.bytes(for: $1) }
        try await PhotoDeleter.delete(list)
        let removed = Set(list.map { $0.localIdentifier })
        // Drop deleted photos but keep the card position consistent.
        let before = assets.prefix(index).filter { removed.contains($0.localIdentifier) }.count
        assets.removeAll { removed.contains($0.localIdentifier) }
        index = max(index - before, 0)
        marked.removeAll { removed.contains($0) }
        history.removeAll { removed.contains($0.id) }
        return CleanupResult(removed: list.count, bytes: bytes, note: PhotoDeleter.recentlyDeletedNote)
    }
}
