import SwiftUI
import VPNWidgetCore

/// A small square with the client's symbol.
struct ClientKindBadge: View {
    var kind: ProviderKind
    var size: CGFloat = 24

    var body: some View {
        Image(systemName: StateStyle.symbol(kind))
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: size, height: size)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityLabel(kind.displayName)
    }
}
