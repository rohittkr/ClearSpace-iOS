import SwiftUI
import EventKit

// MARK: - Access

enum CalendarAccess {
    case notDetermined, authorized, writeOnly, denied, restricted

    static func current() -> CalendarAccess {
        map(EKEventStore.authorizationStatus(for: .event))
    }

    static func map(_ status: EKAuthorizationStatus) -> CalendarAccess {
        switch status {
        case .notDetermined: return .notDetermined
        case .fullAccess: return .authorized
        case .writeOnly: return .writeOnly
        case .denied: return .denied
        case .restricted: return .restricted
        default: return .denied
        }
    }
}

// MARK: - Model

struct CalendarEventEntry: Identifiable {
    let id: String
    let event: EKEvent
    let title: String
    let calendarName: String
    let start: Date
    let isRecurring: Bool
}

enum AgeCutoff: Int, CaseIterable, Identifiable {
    case threeMonths = 3
    case sixMonths = 6
    case twelveMonths = 12
    case twentyFourMonths = 24

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .threeMonths: return "3 months"
        case .sixMonths: return "6 months"
        case .twelveMonths: return "1 year"
        case .twentyFourMonths: return "2 years"
        }
    }
}

// MARK: - Store

@MainActor
final class CalendarStore: ObservableObject {
    @Published var access: CalendarAccess = CalendarAccess.current()
    @Published var entries: [CalendarEventEntry] = []
    @Published var selected: Set<String> = []
    @Published var isLoading = false
    @Published var cutoff: AgeCutoff = .twelveMonths

    private let store = EKEventStore()

    func refreshAccess() {
        access = CalendarAccess.current()
    }

    func requestAccess() async {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            // Status is re-read below; a thrown error simply leaves access unchanged.
        }
        refreshAccess()
        if access == .authorized { await scan() }
    }

    func scan() async {
        refreshAccess()
        guard access == .authorized else { return }
        isLoading = true
        defer { isLoading = false }

        let calendar = Calendar.current
        let now = Date()
        guard let cutoffDate = calendar.date(byAdding: .month, value: -cutoff.rawValue, to: now) else { return }

        let editable = store.calendars(for: .event).filter { $0.allowsContentModifications }
        guard !editable.isEmpty else {
            entries = []
            return
        }

        // EventKit limits a single predicate to roughly four years, so scan year by year.
        var found: [EKEvent] = []
        var windowEnd = cutoffDate
        for _ in 0..<8 {
            guard let windowStart = calendar.date(byAdding: .year, value: -1, to: windowEnd) else { break }
            let predicate = store.predicateForEvents(withStart: windowStart, end: windowEnd, calendars: editable)
            found.append(contentsOf: store.events(matching: predicate))
            windowEnd = windowStart
        }

        var result: [CalendarEventEntry] = []
        for event in found where event.endDate < cutoffDate {
            let key = (event.eventIdentifier ?? UUID().uuidString) + "|" + String(event.startDate.timeIntervalSince1970)
            result.append(CalendarEventEntry(
                id: key,
                event: event,
                title: (event.title?.isEmpty == false ? event.title : nil) ?? "Untitled event",
                calendarName: event.calendar?.title ?? "Calendar",
                start: event.startDate,
                isRecurring: event.hasRecurrenceRules
            ))
        }
        result.sort { $0.start < $1.start }
        entries = result
        selected = selected.intersection(Set(result.map { $0.id }))
    }

    func delete(_ list: [CalendarEventEntry]) throws -> CleanupResult {
        var removed = 0
        var failed = 0
        for entry in list {
            do {
                try store.remove(entry.event, span: .thisEvent, commit: false)
                removed += 1
            } catch {
                failed += 1
            }
        }
        do {
            try store.commit()
        } catch {
            store.reset()
            throw error
        }
        let removedIDs = Set(list.map { $0.id })
        entries.removeAll { removedIDs.contains($0.id) }
        selected.subtract(removedIDs)
        return CleanupResult(
            removed: removed,
            bytes: 0,
            failed: failed,
            note: failed > 0 ? "\(failed) event(s) could not be removed." : nil
        )
    }
}

// MARK: - Screen

struct CalendarCleanupView: View {
    @EnvironmentObject private var model: AppModel
    @StateObject private var calendarStore = CalendarStore()
    @State private var showReview = false
    @State private var reviewSnapshot: [CalendarEventEntry] = []

    var body: some View {
        content
            .navigationTitle("Calendar Cleanup")
            .navigationBarTitleDisplayMode(.large)
            .task {
                calendarStore.refreshAccess()
                if calendarStore.access == .authorized { await calendarStore.scan() }
            }
            .sheet(isPresented: $showReview) {
                NavigationStack {
                    ReviewView(
                        title: "Review Events",
                        items: reviewItems(reviewSnapshot),
                        perform: { try await performDelete(reviewSnapshot) }
                    )
                }
                .environmentObject(model)
            }
    }

    @ViewBuilder
    private var content: some View {
        switch calendarStore.access {
        case .notDetermined:
            PermissionMessageView(
                symbol: "calendar",
                title: "Calendar Access Needed",
                message: "ClearSpace reads your calendar on this device to find old events. Nothing leaves your iPhone.",
                buttonTitle: "Allow Calendar Access",
                action: { Task { await calendarStore.requestAccess() } }
            )
        case .denied:
            PermissionMessageView(
                symbol: "calendar.badge.exclamationmark",
                title: "Calendar Access Denied",
                message: "Allow full calendar access in Settings to find old events."
            )
        case .restricted:
            PermissionMessageView(
                symbol: "lock.shield",
                title: "Calendar Access Restricted",
                message: "Calendar access is restricted on this device, for example by Screen Time or a device profile.",
                buttonTitle: nil
            )
        case .writeOnly:
            PermissionMessageView(
                symbol: "calendar.badge.exclamationmark",
                title: "Full Access Required",
                message: "ClearSpace currently has add-only access. Choose Full Access in Settings so it can find old events."
            )
        case .authorized:
            authorizedContent
        }
    }

    @ViewBuilder
    private var authorizedContent: some View {
        if calendarStore.isLoading && calendarStore.entries.isEmpty {
            ProgressView("Looking for old events…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Show events that ended more than")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Picker("Age", selection: $calendarStore.cutoff) {
                            ForEach(AgeCutoff.allCases) { option in
                                Text(option.label).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                        .onChange(of: calendarStore.cutoff) { _, _ in
                            Task { await calendarStore.scan() }
                        }
                        Text("ago. Recurring events remove only the selected occurrence.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .card()

                    if calendarStore.entries.isEmpty {
                        EmptyStateView(
                            symbol: "checkmark.seal",
                            title: "Nothing to Clean",
                            message: "No old events were found for this age range."
                        )
                        .frame(height: 260)
                    } else {
                        SelectionHeader(
                            summary: "\(calendarStore.entries.count) old events",
                            onSelectAll: { calendarStore.selected = Set(calendarStore.entries.map { $0.id }) },
                            onDeselectAll: { calendarStore.selected.removeAll() }
                        )
                        LazyVStack(spacing: 8) {
                            ForEach(calendarStore.entries) { entry in
                                row(entry)
                            }
                        }
                    }
                }
                .padding(12)
            }
            .safeAreaInset(edge: .bottom) {
                if !calendarStore.entries.isEmpty {
                    SelectionBar(
                        count: calendarStore.selected.count,
                        bytes: 0,
                        title: "Review Selected (\(calendarStore.selected.count))",
                        action: startReview
                    )
                }
            }
        }
    }

    private func row(_ entry: CalendarEventEntry) -> some View {
        let isSelected = calendarStore.selected.contains(entry.id)
        return Button {
            if isSelected { calendarStore.selected.remove(entry.id) } else { calendarStore.selected.insert(entry.id) }
        } label: {
            HStack(spacing: 12) {
                PlainSelectionBadge(selected: isSelected)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text("\(Fmt.date(entry.start)) · \(entry.calendarName)\(entry.isRecurring ? " · Repeats" : "")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .card()
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func startReview() {
        reviewSnapshot = calendarStore.entries.filter { calendarStore.selected.contains($0.id) }
        guard !reviewSnapshot.isEmpty else { return }
        showReview = true
    }

    private func reviewItems(_ list: [CalendarEventEntry]) -> [ReviewItem] {
        list.map { entry in
            ReviewItem(
                id: entry.id,
                title: entry.title,
                subtitle: "\(Fmt.date(entry.start)) · \(entry.calendarName)",
                typeLabel: "Event",
                bytes: 0,
                asset: nil,
                symbol: "calendar"
            )
        }
    }

    @MainActor
    private func performDelete(_ list: [CalendarEventEntry]) async throws -> CleanupResult {
        try calendarStore.delete(list)
    }
}
