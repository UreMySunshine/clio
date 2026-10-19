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
        // Under the content, so a readout reaching past the card's edge is
        // drawn over the hairlines.
        .background {
            let shape = RoundedRectangle(cornerRadius: Metrics.cardRadius, style: .continuous)
            ZStack {
                shape.fill(theme.cardFill)
                // Two hairlines, as drawn: a light one inside the edge and a dark one
                // on it. One stroke alone loses the glass edge.
                shape.inset(by: 0.25).strokeBorder(theme.cardInnerStroke, lineWidth: 0.5)
                shape.strokeBorder(theme.cardStroke, lineWidth: 0.5)
            }
        }
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
    @State private var target: Value?

    var body: some View {
        SegmentTrack(selection: $selection,
                     target: $target,
                     thumbRadius: compact ? 4 : 5,
                     trackRadius: compact ? 5 : 8,
                     inset: compact ? 1.5 : 2,
                     spring: Motion.spring(Motion.period, reduce: reduceMotion)) {
            HStack(spacing: 0) {
                ForEach(options, id: \.value) { option in
                    let isSelected = option.value == (target ?? selection)
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
                        .scaleEffect(option.value == target ? 1.12 : 1)
                        .frame(height: compact ? 16 : 24.5)
                        .frame(maxWidth: compact ? nil : .infinity)
                        .padding(.horizontal, compact ? 8 : 0)
                        .segmentFrame(option.value)
                        // An unselected segment draws nothing but its label, so
                        // without this only the glyphs answer a click.
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Each segment's frame within its switch, keyed by the segment's value.
private struct SegmentFramesKey: PreferenceKey {
    static let space = "segments"
    static var defaultValue: [AnyHashable: CGRect] = [:]

    static func reduce(value: inout [AnyHashable: CGRect], nextValue: () -> [AnyHashable: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

extension View {
    func segmentFrame(_ value: some Hashable) -> some View {
        background(GeometryReader { proxy in
            Color.clear.preference(key: SegmentFramesKey.self,
                                   value: [AnyHashable(value): proxy.frame(in: .named(SegmentFramesKey.space))])
        })
    }
}

/// One thumb for the whole switch, behind every label, placed on the selected
/// segment. Drawn per segment instead, a thumb sliding across would pass over
/// the labels of the segments before it. Pressing and dragging carries the
/// thumb along; letting go selects the segment it ends nearest to.
struct SegmentTrack<Value: Hashable, Content: View>: View {
    @Environment(\.theme) private var theme
    @Environment(\.liquidGlass) private var glass
    @Binding var selection: Value
    /// The segment under the dragged thumb, for the labels to highlight.
    @Binding var target: Value?
    var thumbRadius: CGFloat
    var trackRadius: CGFloat
    /// Between the track's edge and the segments.
    var inset: CGFloat
    var spring: Animation?
    @ViewBuilder var content: Content

    @State private var frames: [AnyHashable: CGRect] = [:]
    @State private var dragX: CGFloat?

    /// Under Liquid Glass the dragged thumb becomes a clear lens.
    private var lensing: Bool { glass && dragX != nil }

    var body: some View {
        let track = RoundedRectangle(cornerRadius: trackRadius, style: .continuous)
        content
            .coordinateSpace(name: SegmentFramesKey.space)
            .onPreferenceChange(SegmentFramesKey.self) { frames = $0 }
            // Over the track's glass and under the labels: a lens above them
            // refracts the label into a blur.
            .background(alignment: .topLeading) {
                if lensing { lens } else { thumb }
            }
            .animation(spring, value: selection)
            .simultaneousGesture(drag)
            .padding(inset)
            // A layer of its own rather than glass around the labels, which
            // would hold the lens inside it.
            .background(glass ? .clear : theme.segmentedFill, in: track)
            .background { Color.clear.liquidGlass(glass, in: track, tint: theme.segmentedFill) }
    }

    @ViewBuilder
    private var thumb: some View {
        if let rect = thumbRect {
            RoundedRectangle(cornerRadius: thumbRadius, style: .continuous)
                .fill(theme.segmentedSelected)
                .shadow(color: .black.opacity(0.12), radius: 1, y: 1)
                .frame(width: rect.width, height: rect.height)
                .offset(x: rect.minX, y: rect.minY)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var lens: some View {
        if let rect = thumbRect {
            Color.clear
                .liquidGlass(true, in: Capsule(), clear: true, interactive: true)
                .frame(width: rect.width + 2 * inset, height: rect.height + 2 * inset)
                .scaleEffect(1.3)
                .offset(x: rect.minX - inset, y: rect.minY - inset)
                .allowsHitTesting(false)
        }
    }

    private var thumbRect: CGRect? {
        guard let selected = frames[AnyHashable(selection)] else { return nil }
        guard let dragX else { return selected }
        let track = frames.values.reduce(CGRect.null) { $0.union($1) }
        let width = target.flatMap { frames[AnyHashable($0)]?.width } ?? selected.width
        let x = min(max(dragX - width / 2, track.minX), track.maxX - width)
        return CGRect(x: x, y: selected.minY, width: width, height: selected.height)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(SegmentFramesKey.space))
            .onChanged { value in
                if dragX == nil {
                    withAnimation(spring) { dragX = value.location.x }
                } else {
                    dragX = value.location.x
                }
                let next = nearest(to: value.location.x)
                if next != target { withAnimation(spring) { target = next } }
            }
            .onEnded { value in
                let landed = nearest(to: value.location.x)
                withAnimation(spring) {
                    if let landed { selection = landed }
                    dragX = nil
                    target = nil
                }
            }
    }

    private func nearest(to x: CGFloat) -> Value? {
        frames.min { abs($0.value.midX - x) < abs($1.value.midX - x) }?.key.base as? Value
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

/// Readout shown while the pointer is over a bar, a heatmap cell or a figure.
/// Dark in both themes, as drawn.
struct HoverTip<Content: View>: View {
    var arrowEdge: Edge?
    var content: Content

    init(arrowEdge: Edge? = nil, @ViewBuilder content: () -> Content) {
        self.arrowEdge = arrowEdge
        self.content = content()
    }

    private let fill = Color(hex: 0x1E1E20, opacity: 0.92)

    var body: some View {
        content
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
}

extension HoverTip where Content == Text {
    init(text: Text, arrowEdge: Edge? = nil) {
        self.init(arrowEdge: arrowEdge) { text }
    }
}

/// One tool's figure in a readout.
struct TipRow {
    var tool: ModelCategory
    var value: String
}

/// A readout's figures: an optional heading with its total, then one row per
/// tool behind a dot in the tool's chart color, names and figures in aligned
/// columns. The readout is dark in both themes, so the dark set's colors are used.
struct TipTable: View {
    var title: String?
    var total: String?
    var rows: [TipRow] = []

    static let label = Color(hex: 0xA0A0A5)

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
            if let title {
                GridRow {
                    Text(title).foregroundStyle(Self.label)
                    Text(total ?? "").fontWeight(.semibold).gridColumnAlignment(.trailing)
                }
            }
            ForEach(rows, id: \.tool) { row in
                GridRow {
                    HStack(spacing: 5) {
                        Circle()
                            .fill(Theme.dark.categorySeries(row.tool))
                            .frame(width: 6, height: 6)
                        Text(row.tool.displayName).foregroundStyle(Self.label)
                    }
                    Text(row.value).fontWeight(.semibold)
                }
            }
        }
    }
}

struct ModelSourceTipTable: View {
    var sources: [ModelSourceUsage]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(sources.enumerated()), id: \.offset) { _, source in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(source.tool?.displayName ?? "未知来源") · \(source.model)")
                        .foregroundStyle(TipTable.label)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("\(Format.grouped(source.tokens)) Token · \(source.cost.map { Format.money($0) } ?? "-") · \(Format.outputSpeed(source.outputSpeed))")
                        .fontWeight(.semibold)
                }
            }
        }
        .frame(width: Metrics.cardContentWidth - 18, alignment: .leading)
    }
}

/// Shows a readout above the view while the pointer is over it.
private struct HoverTipModifier<TipContent: View>: ViewModifier {
    var tip: TipContent?
    /// The edge the readout keeps to, so it stays inside the panel.
    var alignment: Alignment

    @State private var isHovered = false
    @State private var height: CGFloat = 0

    func body(content: Content) -> some View {
        content
            .onHover { isHovered = $0 }
            .overlay(alignment: alignment) {
                if isHovered, let tip {
                    HoverTip { tip }
                        .background(
                            GeometryReader { geo in
                                Color.clear.onChange(of: geo.size.height, initial: true) { _, value in
                                    height = value
                                }
                            }
                        )
                        .offset(y: -height - 4)
                }
            }
    }
}

extension View {
    func hoverTip(_ rows: [TipRow], alignment: Alignment) -> some View {
        modifier(HoverTipModifier(tip: rows.isEmpty ? nil : TipTable(rows: rows), alignment: alignment))
    }

    func hoverTip<TipContent: View>(isEnabled: Bool, alignment: Alignment,
                                   @ViewBuilder content: () -> TipContent) -> some View {
        modifier(HoverTipModifier(tip: isEnabled ? content() : nil, alignment: alignment))
    }
}

