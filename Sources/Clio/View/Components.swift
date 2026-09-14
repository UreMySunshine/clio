import SwiftUI

/// The menu-bar glyph: a track ring with a progress arc that starts at 12
/// o'clock. Geometry matches the design's 16-unit artboard (r 5.5, stroke 2).
struct UsageRing: View {
    var fraction: Double?
    var color: Color
    var trackColor: Color
    var size: CGFloat = 16

    var body: some View {
        let scale = size / 16
        ZStack {
            Circle()
                .stroke(trackColor.opacity(0.28), lineWidth: 2 * scale)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, fraction ?? 0)))
                .stroke(color, style: StrokeStyle(lineWidth: 2 * scale, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .padding(2.5 * scale)
        .frame(width: size, height: size)
    }
}

/// Rounded card used for every block inside the panel.
struct Card<Content: View>: View {
    @Environment(\.theme) private var theme
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.cardFill, in: RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous))
        // Two hairlines, as drawn: a light one inside the edge and a dark one
        // on it. One stroke alone loses the glass edge.
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .inset(by: 0.25)
                .strokeBorder(theme.cardInnerStroke, lineWidth: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 0.5)
        )
    }
}

/// Section caption in the card header row.
struct CardTitle: View {
    @Environment(\.theme) private var theme
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .kerning(0.2)
            .foregroundStyle(theme.textSecondary)
            .frame(height: 15)
    }
}

/// Plan badge — "Max 5×", "ChatGPT Plus".
struct PlanBadge: View {
    @Environment(\.theme) private var theme
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(theme.badgeText)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(theme.badgeFill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
    }
}

/// Period switch inside the usage card, and the tool switch at the top.
struct Segmented<Value: Hashable>: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var options: [(value: Value, title: String, symbol: String?)]
    @Binding var selection: Value
    var compact = false

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options, id: \.value) { option in
                let isSelected = option.value == selection
                Button {
                    selection = option.value
                } label: {
                    HStack(spacing: 6) {
                        if let symbol = option.symbol {
                            Image(systemName: symbol).font(.system(size: 10, weight: .semibold))
                        }
                        Text(option.title)
                    }
                    .font(.system(size: compact ? 10 : 12, weight: .medium))
                    .foregroundStyle(isSelected ? theme.segmentedSelectedText : theme.textSecondary)
                    .frame(height: compact ? 16 : 24.5)
                    .frame(maxWidth: compact ? nil : .infinity)
                    .padding(.horizontal, compact ? 8 : 0)
                    .selectedSegment(isSelected)
                    // An unselected segment draws nothing but its label, so
                    // without this only the glyphs answer a click.
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .segmentThumb(cornerRadius: compact ? 4 : 5)
        .animation(Motion.spring(Motion.period, reduce: reduceMotion), value: selection)
        .padding(compact ? 1.5 : 2)
        .background(theme.segmentedFill, in: RoundedRectangle(cornerRadius: compact ? 5 : 8, style: .continuous))
    }
}

/// The tool switch: brand mark plus name, one segment per detected tool.
struct ToolSwitch: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var tools: [Tool]
    @Binding var selection: Tool

    var body: some View {
        HStack(spacing: 0) {
            ForEach(tools) { tool in
                let isSelected = tool == selection
                Button {
                    selection = tool
                } label: {
                    HStack(spacing: 6) {
                        BrandIcon(tool: tool,
                                  size: 12,
                                  color: isSelected
                                      ? (tool.brandColor ?? theme.segmentedSelectedText)
                                      : theme.textSecondary)
                        Text(tool.displayName)
                    }
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(isSelected ? theme.segmentedSelectedText : theme.textSecondary)
                    .frame(height: 25)
                    .frame(maxWidth: .infinity)
                    .selectedSegment(isSelected)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .segmentThumb(cornerRadius: 5)
        .animation(Motion.spring(Motion.tool, reduce: reduceMotion), value: selection)
        .padding(2)
        .background(theme.segmentedFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Bounds of the selected segment in a switch.
private struct SelectedSegmentKey: PreferenceKey {
    static var defaultValue: Anchor<CGRect>?

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

private extension View {
    func selectedSegment(_ isSelected: Bool) -> some View {
        anchorPreference(key: SelectedSegmentKey.self, value: .bounds) { isSelected ? $0 : nil }
    }

    /// One thumb for the whole switch, behind every label, placed on the
    /// selected segment. Drawn per segment instead, a thumb sliding across
    /// would pass over the labels of the segments before it.
    func segmentThumb(cornerRadius: CGFloat) -> some View {
        backgroundPreferenceValue(SelectedSegmentKey.self) { anchor in
            GeometryReader { proxy in
                if let anchor {
                    let rect = proxy[anchor]
                    SegmentThumb(cornerRadius: cornerRadius)
                        .frame(width: rect.width, height: rect.height)
                        .offset(x: rect.minX, y: rect.minY)
                }
            }
        }
    }
}

private struct SegmentThumb: View {
    @Environment(\.theme) private var theme
    var cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(theme.segmentedSelected)
            .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
    }
}

/// Percentage change against the preceding period. Rising spend reads as a
/// warning, falling spend as a gain — the arrow direction carries the sign.
struct TrendBadge: View {
    @Environment(\.theme) private var theme
    var change: Double

    var body: some View {
        let rising = change >= 0
        let tint = rising ? theme.danger : theme.positive
        // Judged on the rounded figure: a change under half a percent prints as
        // "0%", and an arrow beside it claims a direction the number doesn't show.
        let shown = Int((abs(change) * 100).rounded()) > 0
        HStack(spacing: 1) {
            Image(systemName: rising ? "arrow.up" : "arrow.down")
                .font(.system(size: 7, weight: .bold))
            Text(Format.signedPercent(change))
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(tint)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        .fixedSize()
        .opacity(shown ? 1 : 0)
    }
}

/// One labelled number in the input/output/cache row.
struct StatColumn: View {
    @Environment(\.theme) private var theme
    var title: String
    var value: String
    var tint: Color?
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(theme.textSecondary)
                .frame(height: 14, alignment: .top)
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(tint ?? theme.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(height: 17, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .trailing ? .trailing : .leading)
    }
}

/// Readout shown while the pointer is over a bar or a heatmap cell. Dark in
/// both themes, as drawn.
struct HoverTip: View {
    var text: Text
    var arrowEdge: Edge?

    private let fill = Color(hex: 0x1E1E20, opacity: 0.92)

    var body: some View {
        text
            .font(.system(size: 11))
            .monospacedDigit()
            .foregroundStyle(Color(hex: 0xF5F5F7))
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .overlay(alignment: arrowEdge == .top ? .top : .bottom) {
                if arrowEdge != nil {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(fill)
                        .frame(width: 8, height: 8)
                        .rotationEffect(.degrees(45))
                        .offset(y: arrowEdge == .top ? -4 : 4)
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 7, y: 4)
            .fixedSize()
            .allowsHitTesting(false)
    }

    /// A label and its figure, the shape both the chart and the heat map use.
    static func pair(_ label: String, _ value: String) -> Text {
        Text(label).foregroundColor(Color(hex: 0xA0A0A5)) + Text("  ") + Text(value).fontWeight(.semibold)
    }
}
