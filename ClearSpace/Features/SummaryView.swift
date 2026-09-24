import SwiftUI

struct SummaryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var confirmReset = false

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(Theme.brandGradient)
                    .padding(.top, 16)
                Text(model.ledger.totalBytes > 0 ? Fmt.bytes(model.ledger.totalBytes) : "0 KB")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                Text("total space freed with ClearSpace")
                    .foregroundStyle(.secondary)

                VStack(spacing: 0) {
                    row("Items removed", "\(model.ledger.totalItems)")
                    Divider()
                    row("Cleanups completed", "\(model.ledger.sessions)")
                    Divider()
                    row("Last cleanup", model.ledger.lastDate.map { Fmt.date($0) } ?? "Never")
                    Divider()
                    row("Free storage now", Fmt.bytes(model.storage.free))
                }
                .card()

                Text("Photos keeps deleted items in Recently Deleted for 30 days, so free storage may not change until that album is emptied.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if model.ledger.sessions > 0 {
                    Button("Reset History", role: .destructive) { confirmReset = true }
                        .padding(.top, 4)
                }
            }
            .padding()
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Cleanup Summary")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Reset cleanup history?", isPresented: $confirmReset, titleVisibility: .visible) {
            Button("Reset History", role: .destructive) { model.resetLedger() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This only clears ClearSpace's own totals. Your photos and contacts are not affected.")
        }
        .onAppear { model.refresh() }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).fontWeight(.semibold)
        }
        .font(.subheadline)
        .padding(.vertical, 10)
    }
}
