import SwiftUI

/// Spring responses from the design's Fluid prototype. Every spring there is
/// critically damped, so values settle without overshoot.
enum Motion {
    static let panel = 0.32
    static let tool = 0.35
    static let period = 0.3
    static let figures = 0.5
    static let bars = 0.4
    static let share = 0.45

    /// Nil under Reduce Motion, so the change lands at once.
    static func spring(_ response: Double, reduce: Bool) -> Animation? {
        reduce ? nil : .spring(response: response, dampingFraction: 1)
    }
}

private struct PanelOpenKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    /// False while the panel is closed or closing. Quota bars grow from empty
    /// and heat-map cells fade in as it turns true.
    var panelIsOpen: Bool {
        get { self[PanelOpenKey.self] }
        set { self[PanelOpenKey.self] = newValue }
    }
}

/// A figure that counts through the amounts between its old and new values
/// when the change is animated.
struct RollingNumber: View, Animatable {
    var value: Double
    var format: (Double) -> String

    var animatableData: Double {
        get { value }
        set { value = newValue }
    }

    var body: some View {
        Text(format(value))
    }
}

/// Hover fill and press shrink for the panel's small text buttons.
struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        QuietButton(configuration: configuration)
    }
}

private struct QuietButton: View {
    @Environment(\.theme) private var theme
    let configuration: ButtonStyleConfiguration
    @State private var isHovered = false

    var body: some View {
        configuration.label
            .foregroundStyle(isHovered ? theme.textPrimary : theme.textTertiary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isHovered ? theme.segmentedFill : .clear,
                        in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
            .animation(.easeOut(duration: 0.08), value: isHovered)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
            // The fill reaches past the label without moving it.
            .padding(.horizontal, -6)
            .padding(.vertical, -2)
            .onHover { isHovered = $0 }
    }
}
