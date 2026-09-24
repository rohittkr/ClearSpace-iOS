import SwiftUI
import Photos
import PhotosUI
import LocalAuthentication
import ImageIO

// MARK: - Item

struct VaultItem: Codable, Identifiable, Hashable {
    let id: String
    let added: Date
    let created: Date?
    let bytes: Int64
}

// MARK: - Store

/// Photos moved into the vault are copied into the app's own protected storage.
/// Files use complete file protection, so they are unreadable while the device is locked,
/// and the vault UI additionally requires Face ID / passcode every time it opens.
@MainActor
final class VaultStore: ObservableObject {
    @Published private(set) var items: [VaultItem] = []
    @Published var isUnlocked = false
    @Published var authMessage: String? = nil
    @Published var isWorking = false

    private var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("ClearSpaceVault", isDirectory: true)
    }

    private var indexURL: URL { directory.appendingPathComponent("index.json") }

    init() {
        loadIndex()
    }

    // MARK: Authentication

    func unlock() async {
        authMessage = nil
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            authMessage = "Set a device passcode (and optionally Face ID) in Settings to use the Private Vault."
            return
        }
        do {
            let ok = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: "Unlock your Private Vault"
            )
            isUnlocked = ok
        } catch {
            isUnlocked = false
            let code = (error as? LAError)?.code
            if code != .userCancel && code != .appCancel && code != .systemCancel {
                authMessage = "Authentication failed. Please try again."
            }
        }
    }

    func lock() {
        isUnlocked = false
    }

    // MARK: Index

    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private func loadIndex() {
        guard let data = try? Data(contentsOf: indexURL),
              let decoded = try? JSONDecoder().decode([VaultItem].self, from: data) else {
            items = []
            return
        }
        // Drop entries whose file has disappeared.
        items = decoded.filter { FileManager.default.fileExists(atPath: fileURL(for: $0).path) }
    }

    private func saveIndex() throws {
        try ensureDirectory()
        let data = try JSONEncoder().encode(items)
        try data.write(to: indexURL, options: [.atomic, .completeFileProtection])
    }

    func fileURL(for item: VaultItem) -> URL {
        directory.appendingPathComponent(item.id + ".bin")
    }

    var totalBytes: Int64 { items.reduce(Int64(0)) { $0 + $1.bytes } }

    // MARK: Adding

    /// Copies the given library photos into the vault. Returns the assets that were safely copied.
    func add(assets: [PHAsset]) async -> [PHAsset] {
        isWorking = true
        defer { isWorking = false }
        var copied: [PHAsset] = []
        do { try ensureDirectory() } catch { return [] }

        for asset in assets {
            guard let data = await VaultIO.imageData(for: asset) else { continue }
            let item = VaultItem(
                id: UUID().uuidString,
                added: Date(),
                created: asset.creationDate,
                bytes: Int64(data.count)
            )
            do {
                try data.write(to: fileURL(for: item), options: [.atomic, .completeFileProtection])
                items.insert(item, at: 0)
                copied.append(asset)
            } catch {
                continue
            }
        }
        try? saveIndex()
        return copied
    }

    // MARK: Restoring / removing

    /// Saves vault photos back into the Photos library, then removes them from the vault.
    func restore(_ list: [VaultItem]) async throws -> Int {
        isWorking = true
        defer { isWorking = false }
        var restored: [VaultItem] = []
        for item in list {
            guard let data = try? Data(contentsOf: fileURL(for: item)) else { continue }
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: data, options: nil)
                request.creationDate = item.created
            }
            restored.append(item)
        }
        remove(restored)
        return restored.count
    }

    /// Permanently deletes vault copies.
    func deleteForever(_ list: [VaultItem]) -> CleanupResult {
        let bytes = list.reduce(Int64(0)) { $0 + $1.bytes }
        remove(list)
        return CleanupResult(removed: list.count, bytes: bytes, note: "Deleted from the vault permanently.")
    }

    private func remove(_ list: [VaultItem]) {
        let ids = Set(list.map { $0.id })
        for item in list {
            try? FileManager.default.removeItem(at: fileURL(for: item))
        }
        items.removeAll { ids.contains($0.id) }
        try? saveIndex()
    }
}

// MARK: - IO helpers

enum VaultIO {
    static func imageData(for asset: PHAsset) async -> Data? {
        await withCheckedContinuation { (continuation: CheckedContinuation<Data?, Never>) in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.version = .current
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                continuation.resume(returning: data)
            }
        }
    }

    static func thumbnail(at url: URL, maxPixel: Int) -> UIImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions) else { return nil }
        let thumbOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbOptions) else { return nil }
        return UIImage(cgImage: cg)
    }
}

// MARK: - Thumbnail

private struct VaultThumb: View {
    let url: URL
    var maxPixel: Int = 300
    @State private var image: UIImage?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.gray.opacity(0.15)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: proxy.size.width, height: proxy.size.height)
                        .clipped()
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .task(id: url) {
            let target = url
            let size = maxPixel
            image = await Task.detached(priority: .userInitiated) {
                VaultIO.thumbnail(at: target, maxPixel: size)
            }.value
        }
    }
}

// MARK: - Screen

struct VaultView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vault = VaultStore()

    @State private var pickerPresented = false
    @State private var pickerSelection: [PhotosPickerItem] = []
    @State private var selected: Set<String> = []
    @State private var viewing: VaultItem?

    @State private var addReviewAssets: [PHAsset] = []
    @State private var showAddReview = false
    @State private var deleteSnapshot: [VaultItem] = []
    @State private var showDeleteReview = false
    @State private var alertMessage: String?

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        Group {
            if vault.isUnlocked {
                unlockedContent
            } else {
                lockedContent
            }
        }
        .navigationTitle("Private Vault")
        .navigationBarTitleDisplayMode(.large)
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase != .active { vault.lock(); selected.removeAll() }
        }
        .alert("Private Vault", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(alertMessage ?? "")
        }
    }

    // MARK: Locked

    private var lockedContent: some View {
        VStack(spacing: 16) {
            Image(systemName: "lock.fill")
                .font(.system(size: 56))
                .foregroundStyle(Theme.brandGradient)
            Text("Vault is Locked")
                .font(.title3.weight(.bold))
            Text("Unlock with Face ID or your device passcode to see your protected photos.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let message = vault.authMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button("Unlock Vault") { Task { await vault.unlock() } }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(28)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            if !vault.isUnlocked { await vault.unlock() }
        }
    }

    // MARK: Unlocked

    @ViewBuilder
    private var unlockedContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Photos you add are copied into ClearSpace's protected storage and can then be removed from your Photos library. Vault contents are lost if you delete the app.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .card()

                Button {
                    pickerSelection = []
                    pickerPresented = true
                } label: {
                    Label("Add Photos to Vault", systemImage: "plus.circle.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(!model.photoAccess.canRead || vault.isWorking)

                if !model.photoAccess.canRead {
                    Text("Allow Photos access from the Home screen to add photos.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                if vault.isWorking {
                    ProgressView("Working…")
                        .frame(maxWidth: .infinity)
                }

                if vault.items.isEmpty {
                    EmptyStateView(
                        symbol: "lock.open",
                        title: "Vault is Empty",
                        message: "Add photos to keep them out of your main library."
                    )
                    .frame(height: 260)
                } else {
                    SelectionHeader(
                        summary: "\(vault.items.count) photos · \(Fmt.bytes(vault.totalBytes))",
                        onSelectAll: { selected = Set(vault.items.map { $0.id }) },
                        onDeselectAll: { selected.removeAll() }
                    )
                    LazyVGrid(columns: columns, spacing: 4) {
                        ForEach(vault.items) { item in
                            cell(item)
                        }
                    }
                }
            }
            .padding(12)
        }
        .safeAreaInset(edge: .bottom) {
            if !selected.isEmpty {
                VStack(spacing: 8) {
                    Text("\(selected.count) selected")
                        .font(.subheadline.weight(.semibold))
                    HStack(spacing: 10) {
                        Button("Restore to Photos") { restoreSelected() }
                            .buttonStyle(SecondaryButtonStyle())
                        Button("Delete Forever") { startDeleteReview() }
                            .buttonStyle(PrimaryButtonStyle(destructive: true))
                    }
                }
                .padding(.horizontal)
                .padding(.top, 12)
                .padding(.bottom, 8)
                .background(.regularMaterial)
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Lock") { vault.lock(); selected.removeAll() }
            }
        }
        .photosPicker(
            isPresented: $pickerPresented,
            selection: $pickerSelection,
            matching: .images,
            photoLibrary: .shared()
        )
        .onChange(of: pickerSelection) { _, newValue in
            let ids = newValue.compactMap { $0.itemIdentifier }
            guard !ids.isEmpty else { return }
            Task { await addPicked(identifiers: ids) }
        }
        .sheet(item: $viewing) { item in
            NavigationStack {
                VaultThumb(url: vault.fileURL(for: item), maxPixel: 2000)
                    .padding()
                    .navigationTitle(Fmt.date(item.created))
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { viewing = nil }
                        }
                    }
            }
        }
        .sheet(isPresented: $showAddReview) {
            NavigationStack {
                ReviewView(
                    title: "Remove From Photos",
                    items: addReviewAssets.map { asset in
                        ReviewItem(
                            id: asset.localIdentifier,
                            title: "Photo (copy saved in Vault)",
                            subtitle: Fmt.date(asset.creationDate),
                            typeLabel: "Photo",
                            bytes: AssetSize.bytes(for: asset),
                            asset: asset
                        )
                    },
                    perform: { try await removeOriginals(addReviewAssets) }
                )
            }
            .environmentObject(model)
        }
        .sheet(isPresented: $showDeleteReview) {
            NavigationStack {
                ReviewView(
                    title: "Delete From Vault",
                    items: deleteSnapshot.map { item in
                        ReviewItem(
                            id: item.id,
                            title: "Vault photo",
                            subtitle: Fmt.date(item.created),
                            typeLabel: "Vault photo",
                            bytes: item.bytes,
                            asset: nil,
                            symbol: "lock.fill"
                        )
                    },
                    perform: { await deleteVaultItems(deleteSnapshot) }
                )
            }
            .environmentObject(model)
        }
    }

    private func cell(_ item: VaultItem) -> some View {
        let isSelected = selected.contains(item.id)
        return VaultThumb(url: vault.fileURL(for: item))
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Theme.brand, lineWidth: isSelected ? 3 : 0)
            }
            .overlay(alignment: .topTrailing) {
                SelectionBadge(selected: isSelected).padding(5)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if selected.isEmpty {
                    viewing = item
                } else if isSelected {
                    selected.remove(item.id)
                } else {
                    selected.insert(item.id)
                }
            }
            .onLongPressGesture {
                if isSelected { selected.remove(item.id) } else { selected.insert(item.id) }
            }
            .accessibilityLabel("Vault photo from \(Fmt.date(item.created))")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Actions

    private func addPicked(identifiers: [String]) async {
        pickerSelection = []
        let fetched = PHAsset.fetchAssets(withLocalIdentifiers: identifiers, options: nil)
        var assets: [PHAsset] = []
        fetched.enumerateObjects { asset, _, _ in assets.append(asset) }
        guard !assets.isEmpty else { return }

        let copied = await vault.add(assets: assets)
        if copied.isEmpty {
            alertMessage = "The selected photos could not be copied into the vault."
            return
        }
        if copied.count < assets.count {
            alertMessage = "\(assets.count - copied.count) photo(s) could not be copied and will stay in your library."
        }
        addReviewAssets = copied
        showAddReview = true
    }

    @MainActor
    private func removeOriginals(_ list: [PHAsset]) async throws -> CleanupResult {
        let bytes = list.reduce(Int64(0)) { $0 + AssetSize.bytes(for: $1) }
        try await PhotoDeleter.delete(list)
        return CleanupResult(removed: list.count, bytes: bytes, note: PhotoDeleter.recentlyDeletedNote)
    }

    private func restoreSelected() {
        let list = vault.items.filter { selected.contains($0.id) }
        guard !list.isEmpty else { return }
        Task {
            do {
                let count = try await vault.restore(list)
                selected.removeAll()
                model.libraryVersion += 1
                alertMessage = "Restored \(count) photo(s) to your Photos library."
            } catch {
                alertMessage = "Could not restore photos: \(error.localizedDescription)"
            }
        }
    }

    private func startDeleteReview() {
        deleteSnapshot = vault.items.filter { selected.contains($0.id) }
        guard !deleteSnapshot.isEmpty else { return }
        showDeleteReview = true
    }

    @MainActor
    private func deleteVaultItems(_ list: [VaultItem]) -> CleanupResult {
        let result = vault.deleteForever(list)
        selected.subtract(list.map { $0.id })
        return result
    }
}
