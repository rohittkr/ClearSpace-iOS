import Foundation
import Photos

/// One row on the Review screen.
struct ReviewItem: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let typeLabel: String
    let bytes: Int64
    var asset: PHAsset? = nil
    var symbol: String = "photo"
}

/// What a cleanup operation reports back.
struct CleanupResult {
    var removed: Int
    var bytes: Int64
    var failed: Int = 0
    var note: String? = nil
}

enum Route: Hashable {
    case similar
    case screenshots
    case videos
    case contacts
    case blurry
    case swipe
    case calendar
    case vault
    case summary
}

struct DeviceStorage: Equatable {
    var total: Int64 = 0
    var free: Int64 = 0

    var used: Int64 { max(total - free, 0) }
    var usedFraction: Double { total > 0 ? Double(used) / Double(total) : 0 }

    static func read() -> DeviceStorage {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        let keys: Set<URLResourceKey> = [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey
        ]
        guard let values = try? url.resourceValues(forKeys: keys) else { return DeviceStorage() }
        let total = Int64(values.volumeTotalCapacity ?? 0)
        let important = values.volumeAvailableCapacityForImportantUsage
        let plain = Int64(values.volumeAvailableCapacity ?? 0)
        return DeviceStorage(total: total, free: important ?? plain)
    }
}

/// Lifetime cleanup totals, stored locally in UserDefaults.
struct CleanupLedger: Codable {
    var totalBytes: Int64 = 0
    var totalItems: Int = 0
    var sessions: Int = 0
    var lastDate: Date? = nil

    private static let key = "clearspace.ledger.v1"

    static func load() -> CleanupLedger {
        guard let data = UserDefaults.standard.data(forKey: key),
              let ledger = try? JSONDecoder().decode(CleanupLedger.self, from: data) else {
            return CleanupLedger()
        }
        return ledger
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    mutating func record(_ result: CleanupResult) {
        guard result.removed > 0 else { return }
        totalBytes += result.bytes
        totalItems += result.removed
        sessions += 1
        lastDate = Date()
    }

    static func reset() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
