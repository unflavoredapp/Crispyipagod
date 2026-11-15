import SwiftUI

// MARK: - iOS 16 compatibility helpers

extension View {
    /// iOS 16-friendly `onChange` that accepts the new value (mirrors the iOS 17 two-parameter form's `newValue`).
    @ViewBuilder
    func onChangeCompat<V: Equatable>(of value: V, perform action: @escaping (V) -> Void) -> some View {
        onChange(of: value, perform: action)
    }

    /// `presentationBackground` / `presentationBackgroundInteraction` need iOS 16.4+.
    @ViewBuilder
    func presentationMaterialChrome(upThrough fraction: CGFloat? = nil) -> some View {
        if #available(iOS 16.4, *) {
            if let fraction {
                self
                    .presentationBackgroundInteraction(.enabled(upThrough: .fraction(fraction)))
                    .presentationBackground(.ultraThinMaterial)
            } else {
                self.presentationBackground(.ultraThinMaterial)
            }
        } else {
            self
        }
    }

    @ViewBuilder
    func symbolEffectListening(_ active: Bool) -> some View {
        if #available(iOS 17.0, *) {
            self.symbolEffect(.variableColor.iterative, isActive: active)
        } else {
            self.opacity(active ? 1 : 0.85)
        }
    }
}
