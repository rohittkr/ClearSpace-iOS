import SwiftUI
import Contacts

// MARK: - Permission

enum ContactsAccess: Equatable {
    case notDetermined, authorized, limited, denied, restricted

    var canRead: Bool { self == .authorized || self == .limited }

    static func current() -> ContactsAccess {
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .notDetermined:
            return .notDetermined
        case .restricted:
            return .restricted
        case .denied:
            return .denied
        case .authorized:
            return .authorized
        default:
            // `.limited` only exists on iOS 18+, so it needs an availability check.
            if #available(iOS 18.0, *), status == .limited {
                return .limited
            }
            return .authorized
        }
    }
}

// MARK: - Model types

struct ContactEntry: Identifiable {
    let id: String
    let name: String
    let givenName: String
    let familyName: String
    let organization: String
    let phones: [String]
    let emails: [String]
    let contact: CNContact

    var detailScore: Int {
        phones.count + emails.count + (organization.isEmpty ? 0 : 1)
    }

    var detailLine: String {
        var parts = [String]()
        if let phone = phones.first { parts.append(phone) }
        if let email = emails.first { parts.append(email) }
        if parts.isEmpty && !organization.isEmpty { parts.append(organization) }
        return parts.isEmpty ? "No phone or email" : parts.joined(separator: " · ")
    }
}

struct ContactGroup: Identifiable {
    let id: String
    var members: [ContactEntry]
    var keepID: String
    let reasons: [String]
}

struct ContactDeleteOutcome {
    var deletedIDs: [String]
    var failed: Int
}

// MARK: - Worker (background)

enum ContactsWorker {
    static func fetchAll() throws -> [ContactEntry] {
        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName)
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.sortOrder = .userDefault

        var entries = [ContactEntry]()
        try store.enumerateContacts(with: request) { contact, _ in
            let display = CNContactFormatter.string(from: contact, style: .fullName)
            let fallback = contact.organizationName.isEmpty ? "No Name" : contact.organizationName
            entries.append(
                ContactEntry(
                    id: contact.identifier,
                    name: display ?? fallback,
                    givenName: contact.givenName,
                    familyName: contact.familyName,
                    organization: contact.organizationName,
                    phones: contact.phoneNumbers.map { $0.value.stringValue },
                    emails: contact.emailAddresses.map { String($0.value) },
                    contact: contact
                )
            )
        }
        return entries
    }

    // Normalisation helpers

    static func fold(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func phoneKey(_ raw: String) -> String? {
        let digits = raw.filter { $0.isASCII && $0.isNumber }
        guard digits.count >= 7 else { return nil }
        return "p:" + String(digits.suffix(10))
    }

    static func emailKey(_ raw: String) -> String? {
        let email = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return email.isEmpty ? nil : "e:" + email
    }

    static func nameKey(given: String, family: String) -> String? {
        let first = fold(given)
        let last = fold(family)
        guard !first.isEmpty, !last.isEmpty else { return nil }
        return "n:\(first) \(last)"
    }

    static func keys(for entry: ContactEntry) -> Set<String> {
        var keys = Set<String>()
        for phone in entry.phones {
            if let key = phoneKey(phone) { keys.insert(key) }
        }
        for email in entry.emails {
            if let key = emailKey(email) { keys.insert(key) }
        }
        if let key = nameKey(given: entry.givenName, family: entry.familyName) {
            keys.insert(key)
        }
        return keys
    }

    /// Groups contacts that share a normalised phone number, email or full name.
    static func group(_ entries: [ContactEntry]) -> [ContactGroup] {
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

        var owners = [String: [Int]]()
        for (index, entry) in entries.enumerated() {
            for key in keys(for: entry) {
                owners[key, default: []].append(index)
            }
        }
        for (_, indices) in owners where indices.count > 1 {
            let root = find(indices[0])
            for other in indices.dropFirst() {
                let otherRoot = find(other)
                if otherRoot != root { parent[otherRoot] = find(root) }
            }
        }

        var reasonSets = [Int: Set<String>]()
        for (key, indices) in owners where indices.count > 1 {
            let root = find(indices[0])
            let reason: String
            if key.hasPrefix("p:") {
                reason = "Same phone number"
            } else if key.hasPrefix("e:") {
                reason = "Same email"
            } else {
                reason = "Same name"
            }
            reasonSets[root, default: []].insert(reason)
        }

        var buckets = [Int: [Int]]()
        for index in 0..<count {
            buckets[find(index), default: []].append(index)
        }

        var groups = [ContactGroup]()
        for (root, members) in buckets where members.count > 1 {
            let list = members.map { entries[$0] }
            var keeper = list[0]
            for candidate in list where candidate.detailScore > keeper.detailScore {
                keeper = candidate
            }
            let reasons = (reasonSets[root] ?? []).sorted()
            groups.append(ContactGroup(id: keeper.id + "-group", members: list, keepID: keeper.id, reasons: reasons))
        }
        groups.sort { ($0.members.first?.name ?? "") < ($1.members.first?.name ?? "") }
        return groups
    }

    static func delete(_ contacts: [CNContact]) -> ContactDeleteOutcome {
        let store = CNContactStore()
        var deleted = [String]()
        var failed = 0
        for contact in contacts {
            guard let mutable = contact.mutableCopy() as? CNMutableContact else {
                failed += 1
                continue
            }
            let request = CNSaveRequest()
            request.delete(mutable)
            do {
                try store.execute(request)
                deleted.append(contact.identifier)
            } catch {
                failed += 1
            }
        }
        return ContactDeleteOutcome(deletedIDs: deleted, failed: failed)
    }
}

// MARK: - Store

@MainActor
final class ContactsStore: ObservableObject {
    @Published private(set) var access: ContactsAccess = ContactsAccess.current()
    @Published private(set) var groups: [ContactGroup] = []
    @Published var selected: Set<String> = []
    @Published private(set) var isScanning = false
    @Published private(set) var hasScanned = false
    @Published private(set) var errorMessage: String? = nil

    /// Number of extra contacts (everything except one per group).
    var duplicateCount: Int {
        groups.reduce(0) { $0 + max($1.members.count - 1, 0) }
    }

    func refreshAccess() {
        access = ContactsAccess.current()
    }

    /// Used at launch: never prompts, only scans if the user already allowed access.
    func scanIfAuthorized() {
        refreshAccess()
        if access.canRead && !hasScanned {
            scan()
        }
    }

    func requestAccess() async {
        let store = CNContactStore()
        do {
            _ = try await store.requestAccess(for: .contacts)
        } catch {
            errorMessage = "Contacts access couldn't be requested: \(error.localizedDescription)"
        }
        refreshAccess()
        if access.canRead { scan() }
    }

    func scan() {
        guard access.canRead, !isScanning else { return }
        isScanning = true
        errorMessage = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) { () -> Result<[ContactGroup], Error> in
                do {
                    let entries = try ContactsWorker.fetchAll()
                    return .success(ContactsWorker.group(entries))
                } catch {
                    return .failure(error)
                }
            }.value
            switch outcome {
            case .success(let found):
                self.groups = found
                let removable = Set(found.flatMap { group in
                    group.members.map { $0.id }.filter { $0 != group.keepID }
                })
                self.selected = self.selected.intersection(removable)
            case .failure(let error):
                self.errorMessage = "Contacts couldn't be read: \(error.localizedDescription)"
            }
            self.hasScanned = true
            self.isScanning = false
        }
    }

    // MARK: Selection

    func toggle(_ id: String) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    func setKeep(contactID: String, groupID: String) {
        guard let index = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[index].keepID = contactID
        selected.remove(contactID)
    }

    func selectDuplicates(in groupID: String) {
        guard let group = groups.first(where: { $0.id == groupID }) else { return }
        for member in group.members where member.id != group.keepID {
            selected.insert(member.id)
        }
    }

    func selectAllDuplicates() {
        var ids = Set<String>()
        for group in groups {
            for member in group.members where member.id != group.keepID {
                ids.insert(member.id)
            }
        }
        selected = ids
    }

    func deselectAll() {
        selected.removeAll()
    }

    var selectedEntries: [ContactEntry] {
        var list = [ContactEntry]()
        for group in groups {
            for member in group.members where selected.contains(member.id) && member.id != group.keepID {
                list.append(member)
            }
        }
        return list
    }

    // MARK: Deletion (only called after the Review screen is confirmed)

    func delete(_ entries: [ContactEntry]) async -> CleanupResult {
        let contacts = entries.map { $0.contact }
        let outcome = await Task.detached(priority: .userInitiated) {
            ContactsWorker.delete(contacts)
        }.value

        let removed = Set(outcome.deletedIDs)
        var updated = [ContactGroup]()
        for var group in groups {
            group.members.removeAll { removed.contains($0.id) }
            if group.members.count > 1 { updated.append(group) }
        }
        groups = updated
        selected.subtract(removed)

        var note: String? = nil
        if outcome.failed > 0 {
            note = "\(outcome.failed) contact\(outcome.failed == 1 ? "" : "s") couldn't be deleted. They may belong to an account that doesn't allow changes."
        }
        return CleanupResult(removed: outcome.deletedIDs.count, bytes: 0, failed: outcome.failed, note: note)
    }
}

// MARK: - Screen

struct ContactsScreen: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ContactsContent(store: model.contacts)
    }
}

private struct ContactsContent: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: ContactsStore
    @State private var showReview = false
    @State private var reviewSnapshot: [ContactEntry] = []

    var body: some View {
        Group {
            switch store.access {
            case .notDetermined:
                PermissionMessageView(
                    symbol: "person.crop.circle.badge.questionmark",
                    title: "Allow Contacts Access",
                    message: "ClearSpace needs to read your contacts to find duplicates. Contacts stay on your iPhone and are only deleted after you review and confirm.",
                    buttonTitle: "Allow Access",
                    action: {
                        Task { await store.requestAccess() }
                    }
                )
            case .denied:
                PermissionMessageView(
                    symbol: "lock.shield",
                    title: "Contacts Access Is Off",
                    message: "ClearSpace can't read your contacts because access was denied. Turn on Contacts access for ClearSpace in Settings to find duplicates."
                )
            case .restricted:
                PermissionMessageView(
                    symbol: "hand.raised.slash",
                    title: "Contacts Access Is Restricted",
                    message: "Contacts access is restricted on this iPhone, so ClearSpace can't scan for duplicates.",
                    buttonTitle: nil
                )
            case .authorized, .limited:
                results
            }
        }
        .navigationTitle("Duplicate Contacts")
        .navigationBarTitleDisplayMode(.large)
        .task {
            store.refreshAccess()
            if store.access.canRead && !store.hasScanned { store.scan() }
        }
        .toolbar {
            if store.access.canRead && !store.isScanning {
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
                    title: "Review Contacts",
                    items: reviewItems(for: reviewSnapshot),
                    perform: { try await performDelete(reviewSnapshot) }
                )
            }
            .environmentObject(model)
        }
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        if store.isScanning && !store.hasScanned {
            ProgressView("Checking contacts…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let message = store.errorMessage {
            PermissionMessageView(
                symbol: "exclamationmark.triangle",
                title: "Something Went Wrong",
                message: message,
                buttonTitle: "Try Again",
                action: { store.scan() }
            )
        } else if store.groups.isEmpty {
            EmptyStateView(
                symbol: "person.crop.circle.badge.checkmark",
                title: "No Duplicates Found",
                message: "None of your contacts share a phone number, email or full name."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if store.access == .limited {
                        limitedBanner
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("\(store.groups.count) groups · \(store.selected.count) selected")
                            .font(.subheadline.weight(.semibold))
                        Text("In each group one contact is suggested to keep. Select the duplicates you want to remove, or touch and hold a contact to keep it instead.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 10) {
                            Button("Select All Duplicates") { store.selectAllDuplicates() }
                                .buttonStyle(SecondaryButtonStyle())
                            Button("Deselect All") { store.deselectAll() }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                    }

                    ForEach(store.groups) { group in
                        groupCard(group)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .safeAreaInset(edge: .bottom) {
                SelectionBar(
                    count: store.selected.count,
                    bytes: 0,
                    title: "Review Selected (\(store.selected.count))",
                    action: startReview
                )
            }
        }
    }

    private var limitedBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Limited access: only the contacts you shared with ClearSpace are checked.")
                .font(.footnote)
            Spacer(minLength: 4)
            Button("Settings") { SystemSettings.open() }
                .font(.footnote.weight(.semibold))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
    }

    private func groupCard(_ group: ContactGroup) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(group.reasons.isEmpty ? "Possible duplicates" : group.reasons.joined(separator: " · "))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Select duplicates") { store.selectDuplicates(in: group.id) }
                    .font(.caption.weight(.semibold))
            }
            ForEach(group.members) { member in
                memberRow(member, in: group)
                if member.id != group.members.last?.id {
                    Divider()
                }
            }
        }
        .card()
    }

    private func memberRow(_ member: ContactEntry, in group: ContactGroup) -> some View {
        let isKeep = member.id == group.keepID
        let isSelected = store.selected.contains(member.id)
        return Button {
            if !isKeep { store.toggle(member.id) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.title)
                    .foregroundStyle(isKeep ? Color.green : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.name)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(member.detailLine)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if isKeep {
                    Label("Keep", systemImage: "star.fill")
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.green))
                        .foregroundStyle(.white)
                } else {
                    PlainSelectionBadge(selected: isSelected)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                store.setKeep(contactID: member.id, groupID: group.id)
            } label: {
                Label("Keep This Contact", systemImage: "star")
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: Review

    private func startReview() {
        reviewSnapshot = store.selectedEntries
        guard !reviewSnapshot.isEmpty else { return }
        showReview = true
    }

    private func reviewItems(for list: [ContactEntry]) -> [ReviewItem] {
        list.map { entry in
            ReviewItem(
                id: entry.id,
                title: entry.name,
                subtitle: entry.detailLine,
                typeLabel: "Contact",
                bytes: 0,
                asset: nil,
                symbol: "person.crop.circle"
            )
        }
    }

    @MainActor
    private func performDelete(_ list: [ContactEntry]) async throws -> CleanupResult {
        await store.delete(list)
    }
}
