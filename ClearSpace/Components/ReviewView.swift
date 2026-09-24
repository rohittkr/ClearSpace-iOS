import SwiftUI
import Photos

/// The single review-and-confirm screen used by every destructive cleanup flow.
/// Nothing is removed until the user taps "Confirm & Delete".
struct ReviewView: View {
    let title: String
    let items: [ReviewItem]
    let perform: () async throws -> CleanupResult

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .review

    enum Phase {
        case review
        case deleting
        case done(CleanupResult)
        case failed(String)
    }

    private var totalBytes: Int64 {
        items.reduce(Int64(0)) { $0 + $1.bytes }
    }

    var body: some View {
        Group {
            switch phase {
            case .review, .failed:
                reviewList
            case .deleting:
                deletingView
            case .done(let result):
                doneView(result)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canCancel {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .interactiveDismissDisabled(!canCancel)
    }

    private var canCancel: Bool {
        switch phase {
        case .review, .failed: return true
        case .deleting, .done: return false
        }
    }

    private var errorMessage: String? {
        if case .failed(let message) = phase { return message }
        return nil
    }

    // MARK: Review

    private var reviewList: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Will be removed")
                        .font(.title2.weight(.bold))
                    HStack {
                        summaryTile(title: "Items", value: "\(items.count)")
                        summaryTile(
                            title: "Estimated space to free",
                            value: totalBytes > 0 ? Fmt.bytes(totalBytes) : "Negligible"
                        )
                    }
                    Text("Review the list below. Nothing is deleted until you tap Confirm & Delete.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))
            }

            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .font(.subheadline)
                }
            }

            Section("Items (\(items.count))") {
                ForEach(items) { item in
                    row(item)
                }
            }
        }
        .listStyle(.insetGrouped)
        .safeAreaInset(edge: .bottom) {
            VStack {
                Button(action: confirm) {
                    Text("Confirm & Delete")
                }
                .buttonStyle(PrimaryButtonStyle(destructive: true))
                .disabled(items.isEmpty)
            }
            .padding(.horizontal)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(.regularMaterial)
        }
    }

    private func summaryTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.bold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
    }

    private func row(_ item: ReviewItem) -> some View {
        HStack(spacing: 12) {
            Group {
                if let asset = item.asset {
                    AssetThumbnail(asset: asset, pixels: 160)
                } else {
                    ZStack {
                        Color(.tertiarySystemFill)
                        Image(systemName: item.symbol)
                            .font(.title3)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(item.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.typeLabel)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.brand.opacity(0.12)))
                    .foregroundStyle(Theme.brand)
                if item.bytes > 0 {
                    Text(Fmt.bytes(item.bytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Deleting

    private var deletingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Deleting…")
                .font(.headline)
            Text("If iOS asks you to confirm, choose Delete to finish.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Done

    private func doneView(_ result: CleanupResult) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(Theme.brandGradient)
                    .padding(.top, 24)
                Text("Space Freed")
                    .font(.largeTitle.weight(.bold))
                Text(result.bytes > 0 ? Fmt.bytes(result.bytes) : "Cleanup completed")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(Theme.brand)

                VStack(spacing: 0) {
                    resultRow("Items removed", "\(result.removed)")
                    Divider()
                    resultRow("Estimated space freed", result.bytes > 0 ? Fmt.bytes(result.bytes) : "Negligible")
                    Divider()
                    resultRow("Total freed with ClearSpace", Fmt.bytes(model.ledger.totalBytes))
                    if result.failed > 0 {
                        Divider()
                        resultRow("Could not be removed", "\(result.failed)")
                    }
                }
                .card()

                Label("Cleanup completed", systemImage: "checkmark.circle.fill")
                    .font(.headline)
                    .foregroundStyle(.green)

                if let note = result.note {
                    Text(note)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("Done") { dismiss() }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, 8)
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
    }

    private func resultRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
    }

    // MARK: Actions

    private func confirm() {
        phase = .deleting
        Task {
            do {
                let result = try await perform()
                model.recordCleanup(result)
                phase = .done(result)
            } catch {
                if PhotoDeleter.isUserCancelled(error) {
                    phase = .review
                } else {
                    phase = .failed("The cleanup could not be completed: \(error.localizedDescription)")
                }
            }
        }
    }
}
