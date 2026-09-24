import WidgetKit
import SwiftUI

// MARK: - Storage reading (self-contained; the widget measures the same device volume)

struct StorageSnapshot {
    var total: Int64
    var free: Int64

    var used: Int64 { max(total - free, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func read() -> StorageSnapshot {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else {
            return StorageSnapshot(total: 0, free: 0)
        }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let free = values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0)
        return StorageSnapshot(total: total, free: free)
    }

    static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Timeline

struct StorageEntry: TimelineEntry {
    let date: Date
    let snapshot: StorageSnapshot
}

struct StorageProvider: TimelineProvider {
    func placeholder(in context: Context) -> StorageEntry {
        StorageEntry(date: Date(), snapshot: StorageSnapshot(total: 128_000_000_000, free: 42_000_000_000))
    }

    func getSnapshot(in context: Context, completion: @escaping (StorageEntry) -> Void) {
        completion(StorageEntry(date: Date(), snapshot: StorageSnapshot.read()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StorageEntry>) -> Void) {
        let entry = StorageEntry(date: Date(), snapshot: StorageSnapshot.read())
        let next = Calendar.current.date(byAdding: .minute, value: 30, to: Date()) ?? Date().addingTimeInterval(1800)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

// MARK: - View

struct StorageWidgetView: View {
    let entry: StorageEntry
    @Environment(\.widgetFamily) private var family

    private var gradient: LinearGradient {
        LinearGradient(
            colors: [Color(red: 0.16, green: 0.42, blue: 0.98), Color(red: 0.36, green: 0.28, blue: 0.92)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        switch family {
        case .systemMedium:
            HStack(spacing: 18) {
                ring.frame(width: 90, height: 90)
                details
                Spacer(minLength: 0)
            }
        default:
            VStack(spacing: 8) {
                ring.frame(width: 76, height: 76)
                Text("\(StorageSnapshot.format(entry.snapshot.free)) free")
                    .font(.footnote.weight(.semibold))
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
            }
        }
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(Color.gray.opacity(0.25), lineWidth: 9)
            Circle()
                .trim(from: 0, to: entry.snapshot.usedFraction)
                .stroke(gradient, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int((entry.snapshot.usedFraction * 100).rounded()))%")
                    .font(.headline.weight(.bold))
                Text("used")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("ClearSpace")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(StorageSnapshot.format(entry.snapshot.free))
                .font(.title2.weight(.bold))
            Text("free of \(StorageSnapshot.format(entry.snapshot.total))")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Widget

struct ClearSpaceStorageWidget: Widget {
    let kind = "ClearSpaceStorageWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: StorageProvider()) { entry in
            StorageWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Free Storage")
        .description("See how much space is free on your iPhone.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct ClearSpaceWidgetBundle: WidgetBundle {
    var body: some Widget {
        ClearSpaceStorageWidget()
    }
}
