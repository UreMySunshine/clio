import SwiftUI

/// The menu-bar item: the usage ring, and — depending on the setting — the
/// window percentage or today's token count beside it. Rendered to a colored
/// (non-template) image so the ring can turn orange and red.
///
/// The open-state background is drawn here rather than left to the button's own
/// highlight, which AppKit clears again when the click's mouse-up lands. The
/// padding it needs is reserved in every state, so selecting never changes the
/// image's size and the content never shifts.
struct MenuBarLabel: View {
    var fraction: Double?
    var text: String?
    var isDark: Bool
    var isSelected = false

    private var foreground: Color {
        isDark ? Color(hex: 0xF5F5F7) : Color(hex: 0x1D1D1F)
    }

    private var ringColor: Color {
        guard let fraction else { return foreground }
        if fraction >= 0.8 { return isDark ? Color(hex: 0xFF453A) : Color(hex: 0xFF3B30) }
        if fraction >= 0.5 { return Color(hex: 0xFF9F0A) }
        return foreground
    }

    var body: some View {
        HStack(spacing: 5) {
            UsageRing(fraction: fraction, color: ringColor, trackColor: foreground, size: 14)
            if let text {
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(foreground)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(foreground.opacity(0.16))
            }
        }
    }
}
