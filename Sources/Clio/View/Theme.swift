import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Colors and metrics taken from the design canvas. Light and dark are two
/// separate sets rather than one set with opacity tweaks, matching the source.
struct Theme {
    var textPrimary: Color
    var textSecondary: Color
    var textTertiary: Color
    var cardFill: Color
    var cardStroke: Color
    var cardInnerStroke: Color
    var panelFill: Color
    var panelStroke: Color
    var panelInnerStroke: Color
    var separator: Color
    var chartGuide: Color
    var shareTrack: Color
    var track: Color
    var segmentedFill: Color
    var segmentedSelected: Color
    var segmentedSelectedText: Color
    var badgeFill: Color
    var badgeText: Color
    var cost: Color
    var pillFill: Color
    var menuFill: Color
    var accent: Color
    var warning: Color
    var danger: Color
    var positive: Color
    var heatmap: [Color]

    static let light = Theme(
        textPrimary: Color(hex: 0x1D1D1F),
        textSecondary: Color(hex: 0x6E6E73),
        textTertiary: Color(hex: 0xAEAEB2),
        cardFill: Color.white.opacity(0.55),
        cardStroke: Color.black.opacity(0.06),
        cardInnerStroke: Color.white.opacity(0.8),
        panelFill: Color(hex: 0xF6F6F8).opacity(0.62),
        panelStroke: Color.black.opacity(0.14),
        panelInnerStroke: Color.white.opacity(0.7),
        separator: Color(hex: 0xE5E5EA),
        chartGuide: Color(hex: 0xEEEEF2),
        shareTrack: Color(hex: 0xE0E0E6),
        track: Color(hex: 0xE5E5EA),
        segmentedFill: Color.black.opacity(0.07),
        segmentedSelected: .white,
        segmentedSelectedText: Color(hex: 0x1D1D1F),
        badgeFill: Color(hex: 0xF2E9E4),
        badgeText: Color(hex: 0xB8572F),
        cost: Color(hex: 0x1F8552),
        pillFill: Color(hex: 0xE3E3E8),
        menuFill: Color(hex: 0xF6F6F8),
        accent: Color(hex: 0x0A84FF),
        warning: Color(hex: 0xFF9F0A),
        danger: Color(hex: 0xFF3B30),
        positive: Color(hex: 0x34C759),
        heatmap: [Color(hex: 0xEBEBF0), Color(hex: 0xB9E3CD), Color(hex: 0x7DCBA3),
                  Color(hex: 0x3FAA73), Color(hex: 0x1F8552)]
    )

    static let dark = Theme(
        textPrimary: Color(hex: 0xF5F5F7),
        textSecondary: Color(hex: 0x98989D),
        textTertiary: Color(hex: 0x8A8A8F),
        cardFill: Color.white.opacity(0.07),
        cardStroke: Color.white.opacity(0.08),
        cardInnerStroke: Color.white.opacity(0.06),
        panelFill: Color(hex: 0x28282C).opacity(0.6),
        panelStroke: Color.black.opacity(0.5),
        panelInnerStroke: Color.white.opacity(0.14),
        separator: Color.white.opacity(0.1),
        chartGuide: Color.white.opacity(0.08),
        shareTrack: Color.white.opacity(0.12),
        track: Color(hex: 0x48484A),
        segmentedFill: Color.black.opacity(0.35),
        segmentedSelected: Color.white.opacity(0.18),
        segmentedSelectedText: Color(hex: 0xF5F5F7),
        badgeFill: Color(hex: 0x4A4A4F),
        badgeText: Color(hex: 0xF5F5F7),
        cost: Color(hex: 0x6FD09B),
        pillFill: Color(hex: 0x1F1F21),
        menuFill: Color(hex: 0x2C2C2E),
        accent: Color(hex: 0x0A84FF),
        warning: Color(hex: 0xFF9F0A),
        danger: Color(hex: 0xFF453A),
        positive: Color(hex: 0x30D158),
        heatmap: [Color.white.opacity(0.08), Color(hex: 0x1F5C3E), Color(hex: 0x2F8557),
                  Color(hex: 0x3FAA73), Color(hex: 0x6FD09B)]
    )

    static func resolve(_ scheme: ColorScheme) -> Theme {
        scheme == .dark ? .dark : .light
    }

    /// Ring and bar color for a quota window: monochrome below half, orange
    /// from 50%, red from 80%.
    func quotaColor(_ fraction: Double?, base: Color? = nil) -> Color {
        guard let fraction else { return base ?? accent }
        if fraction >= 0.8 { return danger }
        if fraction >= 0.5 { return warning }
        return base ?? accent
    }
}

/// Set while rendering to an image. `ImageRenderer` draws an AppKit-backed
/// view as a placeholder box, so those are left out of an off-screen pass.
private struct SnapshotKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var isSnapshot: Bool {
        get { self[SnapshotKey.self] }
        set { self[SnapshotKey.self] = newValue }
    }
}

private struct ThemeKey: EnvironmentKey {
    static let defaultValue = Theme.light
}

extension EnvironmentValues {
    var theme: Theme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

/// Measured off the design canvas. The panel's 320pt is its *content* width —
/// the artboard's card is 320 wide plus 12pt of padding on each side, so the
/// window itself is 344.
enum Metrics {
    static let panelContentWidth: CGFloat = 320
    static let panelPadding: CGFloat = 12
    static let panelWidth: CGFloat = panelContentWidth + panelPadding * 2
    static let cardRadius: CGFloat = 10
    static let panelRadius: CGFloat = 14
    /// Content width inside a card: 320 minus the card's own 12pt padding.
    static let cardContentWidth: CGFloat = panelContentWidth - 24
}
