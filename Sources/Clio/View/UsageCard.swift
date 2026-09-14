import SwiftUI

/// Token total, spend, the input/output/cache split, the period chart, and the
/// per-model breakdown — the design keeps all of it in one card.
///
/// Row heights are pinned to the values measured off the design canvas.
/// SwiftUI's default line heights run 1–5pt tighter than the browser's
/// `line-height: normal`, and left free the difference accumulates down the
/// panel.
struct UsageCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var snapshot: ToolSnapshot
    @Binding var granularity: Granularity
    @Binding var basis: ShareBasis
    /// The trend badge sits against the headline, whose width steps as the
    /// count passes a digit; the badge stays hidden until that width is final.
    @State private var isTrendShown = true
    @State private var trendReveal: Task<Void, Never>?

    private var counts: TokenCounts { snapshot.totals[granularity] ?? TokenCounts() }

    /// Of the input that could have been served from cache, the share that was.
    private var cacheHitRate: String {
        let considered = counts.cacheRead + counts.input
        guard considered > 0 else { return "—" }
        return Format.percent(Double(counts.cacheRead) / Double(considered))
    }

    var body: some View {
        Card {
            HStack {
                CardTitle(text: "Token 用量")
                Spacer()
                Segmented(options: Granularity.allCases.map { ($0, $0.title, nil) },
                          selection: $granularity,
                          compact: true)
            }
            .frame(height: 19)

            // Last baseline, not first: the spend column has a caption line
            // above its figure, and it is the figure that lines up.
            HStack(alignment: .lastTextBaseline, spacing: 8) {
                RollingNumber(value: Double(counts.total)) { Format.compact(Int($0.rounded())) }
                    .animation(Motion.spring(Motion.figures, reduce: reduceMotion), value: granularity)
                    .font(.system(size: 28, weight: .semibold))
                    .kerning(-0.6)
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.55)
                    // Takes its full size before the row's spacer does; without
                    // this the headline is scaled down and its baseline drifts
                    // off the trend badge beside it.
                    .layoutPriority(1)
                TrendBadge(change: snapshot.tokenTrend[granularity] ?? 0)
                    .opacity(isTrendShown ? 1 : 0)
                // The spend group sits against the right edge, as drawn. The
                // caption keeps to that edge too, so a counting figure beneath
                // it doesn't carry it sideways.
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("Est.cost")
                        .font(.system(size: 9))
                        .foregroundStyle(theme.textTertiary)
                        .frame(height: 11)
                    let cost = snapshot.costs[granularity]
                    RollingNumber(value: cost ?? 0) { cost == nil ? Format.money(nil) : Format.money($0) }
                        .animation(Motion.spring(Motion.figures, reduce: reduceMotion), value: granularity)
                        .font(.system(size: 14, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.cost)
                        .lineLimit(1)
                }
                .fixedSize()
            }
            .frame(height: 29)
            // The caption above the spend figure reaches higher than the row
            // was drawn for; without this it touches the period switch.
            .padding(.top, 4)
            .onChange(of: granularity) { old, new in
                trendReveal?.cancel()
                guard !reduceMotion else { return }
                let delay = Self.countSettleTime(from: snapshot.totals[old]?.total ?? 0,
                                                 to: snapshot.totals[new]?.total ?? 0)
                // A count that never changes width leaves the badge in place.
                guard delay > 0 else {
                    isTrendShown = true
                    return
                }
                isTrendShown = false
                trendReveal = Task { @MainActor in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled else { return }
                    withAnimation(.easeOut(duration: 0.2)) { isTrendShown = true }
                }
            }

            HStack(spacing: 6) {
                StatColumn(title: "输入", value: Format.compactNarrow(counts.input))
                StatColumn(title: "输出", value: Format.compactNarrow(counts.output))
                StatColumn(title: "缓存读", value: Format.compactNarrow(counts.cacheRead))
                StatColumn(title: "缓存写", value: Format.compactNarrow(counts.cacheWrite))
                // Right-aligned so the row ends on the card's edge, level with
                // the spend figure above it.
                StatColumn(title: "缓存命中", value: cacheHitRate, tint: theme.cost,
                           alignment: .trailing)
            }
            .frame(height: 33)

            UsageChart(buckets: snapshot.buckets[granularity] ?? [], granularity: granularity)

            // A hairline that takes up a whole point: the panel's height has to
            // land on one, or the window rounds up past its own content.
            Rectangle()
                .fill(theme.separator)
                .frame(height: 0.5)
                .frame(height: 1)

            ModelBreakdown(models: snapshot.models[granularity] ?? [], basis: $basis)
        }
    }

    /// When the counting headline last changes width: the latest moment, on
    /// the count's own critically damped curve, that the figure's shape with
    /// its digits set aside still differs from where it ends.
    private static func countSettleTime(from start: Int, to end: Int) -> Double {
        func shape(_ value: Double) -> String {
            String(Format.compact(Int(value.rounded())).map { $0.isNumber ? "0" : $0 })
        }
        let final = shape(Double(end))
        let omega = 2 * Double.pi / Motion.figures
        var settled = 0.0
        for step in 1...240 {
            let t = Double(step) / 120
            let progress = 1 - (1 + omega * t) * exp(-omega * t)
            if shape(Double(start) + Double(end - start) * progress) != final { settled = t }
        }
        // One frame more, for the change to reach the screen.
        return settled > 0 ? settled + 1.0 / 60 : 0
    }
}

/// What the model share bar and the model ordering are measured in.
enum ShareBasis { case tokens, cost }

/// Bars over the selected period, with ticks on the same geometry so a label
/// always sits on its bar — one per day in the week view.
private struct UsageChart: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var buckets: [Bucket]
    var granularity: Granularity

    @State private var hovered: Int?
    @State private var plotWidth: CGFloat = 0
    @State private var tipWidth: CGFloat = 0

    private var peak: Int { max(1, buckets.map(\.tokens).max() ?? 1) }
    private let spacing: CGFloat = 3

    /// Label every k-th bar, keeping the tick count at eight or fewer.
    private var stride: Int {
        guard buckets.count > 8 else { return 1 }
        return Int(ceil(Double(buckets.count) / 6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ZStack(alignment: .topLeading) {
                // Guides sit at fixed offsets in the 48pt plot, as drawn.
                ForEach([12.0, 24.0, 36.0], id: \.self) { offset in
                    Rectangle()
                        .fill(theme.chartGuide)
                        .frame(height: 0.5)
                        .offset(y: offset)
                }
                // Keyed by position, so switching period grows or shrinks each
                // bar from the height it had.
                HStack(alignment: .bottom, spacing: spacing) {
                    ForEach(Array(buckets.enumerated()), id: \.offset) { index, bucket in
                        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                            .fill(theme.accent.opacity(hovered == nil || hovered == index ? 1 : 0.4))
                            .frame(height: max(0, 48 * CGFloat(bucket.tokens) / CGFloat(peak)))
                            .frame(maxWidth: .infinity)
                    }
                }
                .animation(Motion.spring(Motion.bars, reduce: reduceMotion), value: granularity)
                .frame(height: 49, alignment: .bottom)
            }
            .frame(height: 49)
            .background(
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size.width, initial: true) { _, width in
                        plotWidth = width
                    }
                }
            )
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = barIndex(at: point.x)
                case .ended: hovered = nil
                }
            }

            GeometryReader { geo in
                let count = max(1, buckets.count)
                let barWidth = (geo.size.width - spacing * CGFloat(count - 1)) / CGFloat(count)
                ZStack(alignment: .topLeading) {
                    ForEach(Swift.stride(from: 0, to: buckets.count, by: stride).map { ($0, buckets[$0].label) },
                            id: \.0) { index, label in
                        Text(label)
                            .font(.system(size: 9))
                            .monospacedDigit()
                            .foregroundStyle(theme.textTertiary)
                            .fixedSize()
                            // Centred on its bar rather than on the bar's left
                            // edge, so a weekday name sits under its column.
                            .frame(width: barWidth)
                            .offset(x: CGFloat(index) * (barWidth + spacing))
                    }
                }
            }
            .frame(height: 13)
        }
        .overlay(alignment: .topLeading) {
            if let hovered, buckets.indices.contains(hovered) {
                HoverTip(text: HoverTip.pair(tipTitle(buckets[hovered]),
                                            Format.compact(buckets[hovered].tokens)))
                    .background(
                        GeometryReader { geo in
                            Color.clear.onChange(of: geo.size.width, initial: true) { _, width in
                                tipWidth = width
                            }
                        }
                    )
                    .offset(x: tipOffset(for: hovered), y: -25)
            }
        }
    }

    /// The axis is terse by design; the readout spells the period out.
    private func tipTitle(_ bucket: Bucket) -> String {
        switch granularity {
        case .day: return "\(bucket.label):00"
        case .week: return bucket.label
        case .month: return "\(bucket.label)日"
        }
    }

    private var barPitch: CGFloat {
        let count = CGFloat(max(1, buckets.count))
        return (plotWidth - spacing * (count - 1)) / count + spacing
    }

    private func barIndex(at x: CGFloat) -> Int? {
        guard plotWidth > 0, !buckets.isEmpty, x >= 0 else { return nil }
        let index = min(buckets.count - 1, max(0, Int(x / barPitch)))
        // An empty slot draws no bar; a readout there would point at nothing.
        return buckets[index].tokens > 0 ? index : nil
    }

    /// Centres the readout on its bar, kept inside the plot at either end.
    private func tipOffset(for index: Int) -> CGFloat {
        let centre = CGFloat(index) * barPitch + (barPitch - spacing) / 2
        return min(max(0, centre - tipWidth / 2), max(0, plotWidth - tipWidth))
    }
}

/// Share bar plus one row per model, measured in whichever of tokens or
/// spend the header's switch selects.
private struct ModelBreakdown: View {
    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var models: [ModelUsage]
    @Binding var basis: ShareBasis

    /// Dots and share-bar segments use different ramps in the design: the dots
    /// are the lighter brand tints, the bar the saturated ones.
    private static let dotPalette = [
        Color(hex: 0xD97757), Color(hex: 0xE8A98E), Color(hex: 0xF3D3C5),
        Color(hex: 0xB8572F), Color(hex: 0xE7C4B4),
    ]

    private static let barPalette = [
        Color(hex: 0xC2410C), Color(hex: 0xF59E6B), Color(hex: 0x8A5A44),
        Color(hex: 0xD97757), Color(hex: 0xE8A98E),
    ]

    private func weight(_ model: ModelUsage) -> Double {
        basis == .tokens ? Double(model.tokens) : model.cost
    }

    private var ordered: [ModelUsage] { models.sorted { weight($0) > weight($1) } }
    private var total: Double { max(0.01, ordered.reduce(0) { $0 + weight($1) }) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("按模型")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button {
                    basis = basis == .tokens ? .cost : .tokens
                } label: {
                    HStack(spacing: 3) {
                        Text(basis == .tokens ? "Token" : "花费")
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 8, weight: .semibold))
                    }
                    .font(.system(size: 10))
                }
                .buttonStyle(QuietButtonStyle())
            }
            .frame(height: 14)

            GeometryReader { geo in
                // Square-ended segments inside a rounded track: only the track's
                // own ends are round, and the 2pt gaps show the track through.
                let shown = ordered.prefix(5)
                let usable = max(0, geo.size.width - 2 * CGFloat(max(0, shown.count - 1)))
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.shareTrack)
                    HStack(spacing: 2) {
                        ForEach(Array(shown.enumerated()), id: \.element.id) { index, model in
                            Rectangle()
                                .fill(Self.barPalette[index % Self.barPalette.count])
                                .frame(width: max(1, usable * weight(model) / total))
                        }
                    }
                }
                .clipShape(Capsule())
                .animation(Motion.spring(Motion.share, reduce: reduceMotion), value: basis)
            }
            .frame(height: 5)

            ForEach(Array(ordered.prefix(5).enumerated()), id: \.element.id) { index, model in
                HStack(spacing: 8) {
                    HStack(spacing: 7) {
                        Circle()
                            .fill(Self.dotPalette[index % Self.dotPalette.count])
                            .frame(width: 6, height: 6)
                        Text(model.displayName)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.textPrimary)
                    }
                    Spacer(minLength: 0)
                    // Fixed columns as measured: 160 / 64 / 56 with 8pt gaps,
                    // the last two right-aligned.
                    Text(Format.compact(model.tokens))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(basis == .tokens ? theme.textPrimary : theme.textSecondary)
                        .frame(width: 64, alignment: .trailing)
                    Text(Format.money(model.cost))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(basis == .cost ? theme.textPrimary : theme.textSecondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .frame(height: 17)
            }
        }
    }
}
