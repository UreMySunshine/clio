import SwiftUI

/// Where a pace readout should appear, in the card's own coordinates.
private struct QuotaTip {
    var text: Text
    /// The filled edge of the bar it belongs to.
    var x: CGFloat
    /// The bar's bottom.
    var y: CGFloat
}

/// The quota block: two rolling windows, an optional per-model allowance, and
/// an optional counter line.
///
/// A window with no reported utilisation shows the tokens it has actually
/// consumed and when it resets. The percentage and its bar appear only once the
/// account reports one — the allowance is not recorded locally, and the
/// rate-limit rejections in the log do not imply a consistent one.
struct SubscriptionCard: View {
    var snapshot: ToolSnapshot
    var showsHeader = true

    /// The readout is drawn on the card rather than inside it: the card's own
    /// hairlines are an overlay, and anything within the content is painted
    /// under them.
    @State private var tip: QuotaTip?
    @State private var tipWidth: CGFloat = 0
    @State private var cardWidth: CGFloat = 0

    fileprivate static let space = "quotaCard"

    var body: some View {
        Card {
            if showsHeader {
                HStack {
                    CardTitle(text: "订阅")
                    Spacer()
                    if let plan = snapshot.plan, !plan.isEmpty {
                        PlanBadge(text: plan)
                    }
                }
                .frame(height: 19)
            }
            QuotaRow(window: snapshot.fiveHour, onTip: { tip = $0 })
            QuotaRow(window: snapshot.week, onTip: { tip = $0 })
            if let modelQuota = snapshot.modelQuota {
                QuotaRow(window: modelQuota, onTip: { tip = $0 })
            }
            if let counter = snapshot.counter {
                CounterRow(counter: counter)
            }
        }
        .coordinateSpace(name: Self.space)
        .background(
            GeometryReader { geo in
                Color.clear.onChange(of: geo.size.width, initial: true) { _, width in cardWidth = width }
            }
        )
        .overlay(alignment: .topLeading) {
            if let tip {
                HoverTip(text: tip.text, arrowEdge: .top)
                    .background(
                        GeometryReader { geo in
                            Color.clear.onChange(of: geo.size.width, initial: true) { _, width in
                                tipWidth = width
                            }
                        }
                    )
                    .offset(x: min(max(0, tip.x - tipWidth / 2), max(0, cardWidth - tipWidth)),
                            y: tip.y + 4)
            }
        }
        // Above the cards that follow, so the last row's readout is not cut off.
        .zIndex(tip == nil ? 0 : 1)
    }
}

private struct QuotaRow: View {
    @Environment(\.theme) private var theme
    var window: QuotaWindow
    var onTip: (QuotaTip?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(window.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                Spacer(minLength: 8)
                HStack(spacing: 4) {
                    Text(window.fraction.map(Format.percent) ?? Format.compact(window.used))
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(theme.quotaColor(window.fraction, base: theme.textPrimary))
                    Text(Format.reset(window.resetsAt))
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                }
                .fixedSize()
            }
            .frame(height: 17)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track)
                    if let fraction = window.fraction {
                        Capsule()
                            .fill(theme.quotaColor(fraction))
                            .frame(width: max(3, geo.size.width * fraction))
                    }
                }
                // A 6pt bar is a small target; the hit area reaches past it
                // without taking any more room in the card.
                .contentShape(Rectangle().inset(by: -4))
                .onContinuousHover { phase in
                    guard case .active = phase, let fraction = window.fraction, let pace else {
                        onTip(nil)
                        return
                    }
                    let frame = geo.frame(in: .named(SubscriptionCard.space))
                    onTip(QuotaTip(text: pace,
                                   x: frame.minX + frame.width * fraction,
                                   y: frame.maxY))
                }
            }
            .frame(height: 6)
            .opacity(window.fraction == nil ? 0 : 1)
            .frame(height: window.fraction == nil ? 0 : 6)
        }
    }

    /// What the pace so far implies, or that the window resets first.
    private var pace: Text? {
        guard let projected = window.timeToExhaustion(), let resetsAt = window.resetsAt else { return nil }
        guard projected < resetsAt.timeIntervalSinceNow else {
            return Text("按当前速率在重置前不会耗尽")
        }
        return Text("按当前速率约 ")
            + Text(Format.duration(projected)).fontWeight(.semibold)
            + Text("后耗尽")
    }
}

private struct CounterRow: View {
    @Environment(\.theme) private var theme
    var counter: QuotaCounter

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(counter.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textPrimary)
            Spacer()
            HStack(spacing: 3) {
                Text(counter.value)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                if let suffix = counter.suffix {
                    Text(suffix)
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
            }
        }
        .frame(height: 17)
        .padding(.top, 10)
    }
}
