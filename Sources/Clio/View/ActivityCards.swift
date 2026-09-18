import SwiftUI

/// The pair of summary cards between the usage card and the heat map: how long
/// today was worked, and how much was asked of the model.
struct ActivityCards: View {
    var activity: ActivitySummary

    var body: some View {
        HStack(spacing: 10) {
            SummaryCard(title: "今日活跃",
                        value: String(format: "%.1f", activity.activeHours),
                        unit: "小时",
                        detail: String(format: "昨日 %.1f 小时", activity.previousActiveHours),
                        series: activity.activeTrend)
            SummaryCard(title: "今日请求",
                        value: Format.grouped(activity.requests),
                        unit: nil,
                        detail: "\(activity.sessions) 个会话",
                        series: activity.requestTrend)
        }
    }
}

private struct SummaryCard: View {
    @Environment(\.theme) private var theme
    var title: String
    var value: String
    var unit: String?
    var detail: String
    var series: [Double]

    var body: some View {
        Card(spacing: 0) {
            // The gap lives on the spacer alone: stack spacing would also be
            // added on both of its sides and take 8pt from the figures.
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 10, weight: .medium))
                        .kerning(0.2)
                        .foregroundStyle(theme.textSecondary)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(value)
                            .font(.system(size: 20, weight: .semibold))
                            .kerning(-0.4)
                            .monospacedDigit()
                            .foregroundStyle(theme.textPrimary)
                        if let unit {
                            Text(unit)
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(theme.textPrimary)
                        }
                    }
                    .lineLimit(1)
                    Text(detail)
                        .font(.system(size: 10))
                        .monospacedDigit()
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Sparkline(values: series)
            }
        }
    }
}

/// The recent days behind a summary figure. Flat when there is nothing to plot.
private struct Sparkline: View {
    @Environment(\.theme) private var theme
    var values: [Double]

    private let size = CGSize(width: 52, height: 28)
    private let inset: CGFloat = 3

    var body: some View {
        let points = points()
        ZStack(alignment: .topLeading) {
            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                // Through the midpoints, which rounds the corners the way the
                // curve is drawn rather than joining raw samples.
                for (a, b) in zip(points, points.dropFirst()) {
                    path.addQuadCurve(to: CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), control: a)
                }
                if let last = points.last { path.addLine(to: last) }
            }
            .stroke(theme.cost, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            if let last = points.last {
                Circle()
                    .fill(theme.cost)
                    .frame(width: 6, height: 6)
                    .offset(x: last.x - 3, y: last.y - 3)
            }
        }
        .frame(width: size.width, height: size.height)
    }

    private func points() -> [CGPoint] {
        guard values.count > 1 else { return [] }
        let low = values.min() ?? 0
        let high = values.max() ?? 0
        let span = high - low
        let usable = size.height - inset * 2
        return values.enumerated().map { index, value in
            let x = inset + (size.width - inset * 2) * CGFloat(index) / CGFloat(values.count - 1)
            let level = span > 0 ? (value - low) / span : 0.5
            return CGPoint(x: x, y: size.height - inset - usable * CGFloat(level))
        }
    }
}
