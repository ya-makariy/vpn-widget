import SwiftUI

/// Liquid Glass for the panel rows, with plain surfaces when the user asked
/// for less transparency or more contrast.
struct RowGlass: ViewModifier {
    var tint: Color?
    var id: String
    var namespace: Namespace.ID
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous)
        if reduceTransparency {
            content
                .background(tint ?? Color.clear, in: shape)
                .background(.background.secondary, in: shape)
                .overlay(shape.strokeBorder(.separator))
        } else {
            content
                .glassEffect(.regular.tint(tint).interactive(), in: shape)
                .glassEffectID(id, in: namespace)
                .overlay(contrast == .increased ? shape.strokeBorder(.separator) : nil)
        }
    }
}

extension View {
    func rowGlass(tint: Color?, id: String, in namespace: Namespace.ID) -> some View {
        modifier(RowGlass(tint: tint, id: id, namespace: namespace))
    }
}
