import SwiftUI

enum Theme {
    static let brand = Color(red: 0.16, green: 0.42, blue: 0.98)
    static let brandDeep = Color(red: 0.36, green: 0.28, blue: 0.92)

    static let photosTint = Color.pink
    static let videosTint = Color.purple
    static let screenshotsTint = Color.teal
    static let similarTint = Color.orange
    static let contactsTint = Color.green
    static let calendarTint = Color.red
    static let vaultTint = Color.indigo
    static let blurTint = Color.cyan
    static let swipeTint = Color.mint

    static var brandGradient: LinearGradient {
        LinearGradient(colors: [brand, brandDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

struct CardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(.secondarySystemGroupedBackground))
            )
    }
}

extension View {
    func card() -> some View {
        modifier(CardModifier())
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var destructive: Bool
    @Environment(\.isEnabled) private var isEnabled

    init(destructive: Bool = false) {
        self.destructive = destructive
    }

    func makeBody(configuration: Configuration) -> some View {
        let fill: AnyShapeStyle = destructive
            ? AnyShapeStyle(Color.red)
            : AnyShapeStyle(Theme.brandGradient)
        return configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(fill)
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1.0) : 0.4)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .padding(.vertical, 8)
            .padding(.horizontal, 14)
            .foregroundStyle(Theme.brand)
            .background(
                Capsule().fill(Theme.brand.opacity(0.12))
            )
            .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1.0) : 0.4)
    }
}
