import SwiftUI
import Photos

// MARK: - Storage ring

struct StorageRing: View {
    let fraction: Double
    var lineWidth: CGFloat = 14

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: CGFloat(min(max(fraction, 0), 1)))
                .stroke(Theme.brandGradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.8), value: fraction)
        }
    }
}

// MARK: - Stat card

struct StatCard: View {
    let symbol: String
    let tint: Color
    let title: String
    let value: String
    let subtitle: String
    var showsChevron: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: symbol)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(tint.gradient))
                Spacer()
                if showsChevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title2.weight(.bold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Tool row

struct ToolRow: View {
    let symbol: String
    let tint: Color
    let title: String
    let subtitle: String

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.headline)
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.gradient))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold)).foregroundStyle(.primary)
                Text(subtitle).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }
}

// MARK: - Selection badge

struct SelectionBadge: View {
    let selected: Bool

    var body: some View {
        Group {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.white, Theme.brand)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(Color.white)
                    .shadow(color: .black.opacity(0.5), radius: 1.5)
            }
        }
        .font(.title3)
        .accessibilityHidden(true)
    }
}

/// Selection circle that reads well on plain (non-photo) backgrounds.
struct PlainSelectionBadge: View {
    let selected: Bool

    var body: some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3)
            .foregroundStyle(selected ? Theme.brand : Color.secondary)
            .accessibilityHidden(true)
    }
}

// MARK: - Messages / empty states

struct PermissionMessageView: View {
    let symbol: String
    let title: String
    let message: String
    var buttonTitle: String? = "Open Settings"
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: symbol)
                .font(.system(size: 52))
                .foregroundStyle(Theme.brandGradient)
            Text(title)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let buttonTitle {
                Button(buttonTitle) {
                    if let action {
                        action()
                    } else {
                        SystemSettings.open()
                    }
                }
                .buttonStyle(PrimaryButtonStyle())
                .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct EmptyStateView: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Bottom bar

struct SelectionBar: View {
    let count: Int
    let bytes: Int64
    let title: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count) selected")
                        .font(.subheadline.weight(.semibold))
                    if bytes > 0 {
                        Text("About \(Fmt.bytes(bytes)) can be freed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            Button(title, action: action)
                .buttonStyle(PrimaryButtonStyle())
                .disabled(count == 0)
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(.regularMaterial)
    }
}

struct SelectionHeader: View {
    let summary: String
    let onSelectAll: () -> Void
    let onDeselectAll: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(summary)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button("Select All", action: onSelectAll)
                    .buttonStyle(SecondaryButtonStyle())
                Button("Deselect All", action: onDeselectAll)
                    .buttonStyle(SecondaryButtonStyle())
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Thumbnails

struct AssetThumbnail: View {
    let asset: PHAsset
    var pixels: CGFloat = 300
    var fit: Bool = false

    @State private var image: UIImage?
    @State private var requestID: PHImageRequestID = PHInvalidImageRequestID

    var body: some View {
        ZStack {
            Color(.tertiarySystemFill)
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: fit ? .fit : .fill)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .onAppear(perform: load)
        .onDisappear(perform: cancel)
    }

    private func load() {
        guard image == nil else { return }
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = true
        requestID = PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: pixels, height: pixels),
            contentMode: fit ? .aspectFit : .aspectFill,
            options: options
        ) { result, _ in
            if let result {
                image = result
            }
        }
    }

    private func cancel() {
        if requestID != PHInvalidImageRequestID {
            PHImageManager.default().cancelImageRequest(requestID)
            requestID = PHInvalidImageRequestID
        }
    }
}

struct SquareThumb: View {
    let asset: PHAsset
    var pixels: CGFloat = 300

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                AssetThumbnail(asset: asset, pixels: pixels)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Photo permission gate

struct PhotoAccessGate<Content: View>: View {
    @EnvironmentObject private var model: AppModel
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        switch model.photoAccess {
        case .authorized:
            content
        case .limited:
            VStack(spacing: 0) {
                limitedBanner
                content
            }
        case .notDetermined:
            PermissionMessageView(
                symbol: "photo.on.rectangle.angled",
                title: "Allow Photo Access",
                message: "ClearSpace needs access to your photo library to find clutter. Everything is analysed on your iPhone and nothing is uploaded.",
                buttonTitle: "Allow Access",
                action: {
                    Task { await model.requestPhotoAccess() }
                }
            )
        case .denied:
            PermissionMessageView(
                symbol: "lock.shield",
                title: "Photo Access Is Off",
                message: "ClearSpace can't see your photos because access was denied. Turn on Photos access for ClearSpace in Settings to continue."
            )
        case .restricted:
            PermissionMessageView(
                symbol: "hand.raised.slash",
                title: "Photo Access Is Restricted",
                message: "Photo access is restricted on this iPhone, for example by Screen Time or device management, so ClearSpace can't scan your library.",
                buttonTitle: nil
            )
        }
    }

    private var limitedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Limited access: ClearSpace only sees the photos you selected.")
                .font(.footnote)
            Spacer(minLength: 4)
            Button("Manage") {
                if let controller = SystemSettings.topViewController() {
                    PHPhotoLibrary.shared().presentLimitedLibraryPicker(from: controller) { _ in
                        model.refresh()
                        model.libraryVersion += 1
                    }
                }
            }
            .font(.footnote.weight(.semibold))
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.12))
    }
}
