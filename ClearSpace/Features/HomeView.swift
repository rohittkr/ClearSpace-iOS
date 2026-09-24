import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    storageCard
                    permissionBanner
                    LibraryCards(similar: model.similar, contacts: model.contacts)
                    summaryCard
                    toolsSection
                    Text("All scanning happens on this iPhone. Nothing is uploaded.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(.bottom, 8)
                }
                .padding(.horizontal)
                .padding(.top, 8)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("ClearSpace")
            .refreshable { model.refresh() }
            .navigationDestination(for: Route.self) { route in
                destination(for: route)
            }
        }
        .task { model.start() }
        .onChange(of: scenePhase) { _, newPhase in
            if newPhase == .active { model.refresh() }
        }
    }

    // MARK: Storage

    private var storageCard: some View {
        VStack(spacing: 18) {
            HStack(spacing: 20) {
                ZStack {
                    StorageRing(fraction: model.storage.usedFraction)
                    VStack(spacing: 0) {
                        Text(Fmt.percent(model.storage.usedFraction))
                            .font(.title.weight(.bold))
                        Text("used")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 120, height: 120)

                VStack(alignment: .leading, spacing: 6) {
                    Text("Device Storage")
                        .font(.headline)
                    Text("\(Fmt.bytes(model.storage.free)) free")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Theme.brand)
                        .minimumScaleFactor(0.7)
                        .lineLimit(1)
                    Text("of \(Fmt.bytes(model.storage.total))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }

            Divider()

            HStack {
                storageFigure(title: "Total", value: Fmt.bytes(model.storage.total))
                Spacer()
                storageFigure(title: "Used", value: Fmt.bytes(model.storage.used))
                Spacer()
                storageFigure(title: "Free", value: Fmt.bytes(model.storage.free))
            }
        }
        .card()
        .accessibilityElement(children: .combine)
    }

    private func storageFigure(title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold))
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Permission banner

    @ViewBuilder
    private var permissionBanner: some View {
        switch model.photoAccess {
        case .notDetermined:
            VStack(alignment: .leading, spacing: 10) {
                Label("Find clutter in your photos", systemImage: "sparkles")
                    .font(.headline)
                Text("Allow photo access so ClearSpace can look for similar photos, screenshots and large videos. You review everything before it is removed.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Allow Photo Access") {
                    Task { await model.requestPhotoAccess() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }
            .card()
        case .denied:
            VStack(alignment: .leading, spacing: 10) {
                Label("Photo access is off", systemImage: "lock.shield")
                    .font(.headline)
                Text("Turn on Photos access for ClearSpace in Settings to scan your library.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Open Settings") { SystemSettings.open() }
                    .buttonStyle(PrimaryButtonStyle())
            }
            .card()
        case .restricted:
            Label("Photo access is restricted on this iPhone.", systemImage: "hand.raised.slash")
                .font(.subheadline)
                .card()
        case .limited:
            Label("Limited photo access: only selected photos are scanned.", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.orange)
                .card()
        case .authorized:
            EmptyView()
        }
    }

    // MARK: Summary

    private var summaryCard: some View {
        NavigationLink(value: Route.summary) {
            HStack(spacing: 14) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.brandGradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cleanup Summary")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(model.ledger.totalItems > 0
                         ? "\(Fmt.bytes(model.ledger.totalBytes)) freed · \(model.ledger.totalItems) items removed"
                         : "Nothing cleaned yet")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .card()
        }
        .buttonStyle(.plain)
    }

    // MARK: Tools

    private var toolsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("More Tools")
                .font(.title3.weight(.bold))
            VStack(spacing: 0) {
                toolLink(.blurry, "camera.filters", Theme.blurTint, "Blurry Photos", "Find out-of-focus shots")
                Divider()
                toolLink(.swipe, "hand.draw.fill", Theme.swipeTint, "Swipe Cleanup", "Right to keep, left to mark")
                Divider()
                toolLink(.calendar, "calendar.badge.minus", Theme.calendarTint, "Calendar Cleanup", "Remove old calendar events")
                Divider()
                toolLink(.vault, "lock.fill", Theme.vaultTint, "Private Vault", "Protect photos with Face ID")
            }
            .card()
        }
    }

    private func toolLink(_ route: Route, _ symbol: String, _ tint: Color, _ title: String, _ subtitle: String) -> some View {
        NavigationLink(value: route) {
            ToolRow(symbol: symbol, tint: tint, title: title, subtitle: subtitle)
        }
        .buttonStyle(.plain)
    }

    // MARK: Routing

    @ViewBuilder
    private func destination(for route: Route) -> some View {
        switch route {
        case .similar: SimilarPhotosScreen()
        case .screenshots: ScreenshotsView()
        case .videos: VideosView()
        case .contacts: ContactsScreen()
        case .blurry: BlurryPhotosView()
        case .swipe: SwipeCleanupView()
        case .calendar: CalendarCleanupView()
        case .vault: VaultView()
        case .summary: SummaryView()
        }
    }
}

// MARK: - Category cards

/// Separate view so it can observe the similar-photo and contact stores directly.
private struct LibraryCards: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var similar: SimilarStore
    @ObservedObject var contacts: ContactsStore

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Your Library")
                .font(.title3.weight(.bold))
            LazyVGrid(columns: columns, spacing: 12) {
                StatCard(
                    symbol: "photo.fill",
                    tint: Theme.photosTint,
                    title: "Photos",
                    value: model.photoAccess.canRead ? "\(model.photoCount)" : "–",
                    subtitle: "photos in your library"
                )

                NavigationLink(value: Route.videos) {
                    StatCard(
                        symbol: "video.fill",
                        tint: Theme.videosTint,
                        title: "Videos",
                        value: model.photoAccess.canRead ? "\(model.videoCount)" : "–",
                        subtitle: model.videoBytes.map { "\(Fmt.bytes($0)) in videos" } ?? "Calculating size…",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)

                NavigationLink(value: Route.screenshots) {
                    StatCard(
                        symbol: "camera.viewfinder",
                        tint: Theme.screenshotsTint,
                        title: "Screenshots",
                        value: model.photoAccess.canRead ? "\(model.screenshotCount)" : "–",
                        subtitle: model.screenshotBytes.map { "Up to \(Fmt.bytes($0)) can be freed" } ?? "Calculating size…",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)

                NavigationLink(value: Route.similar) {
                    StatCard(
                        symbol: "square.on.square",
                        tint: Theme.similarTint,
                        title: "Similar Photos",
                        value: similar.hasScanned ? "\(similar.groups.count) groups" : "Scan",
                        subtitle: similar.hasScanned
                            ? "Up to \(Fmt.bytes(similar.reclaimableBytes)) can be freed"
                            : "Tap to find near-duplicates",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)

                NavigationLink(value: Route.contacts) {
                    StatCard(
                        symbol: "person.2.fill",
                        tint: Theme.contactsTint,
                        title: "Duplicate Contacts",
                        value: contacts.hasScanned ? "\(contacts.groups.count) groups" : "Scan",
                        subtitle: contacts.hasScanned
                            ? "\(contacts.duplicateCount) extra contacts found"
                            : "Tap to check your contacts",
                        showsChevron: true
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}
