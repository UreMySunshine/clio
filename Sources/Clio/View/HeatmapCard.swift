import SwiftUI

/// 22 weeks of daily totals, one column per week and one row per weekday.
struct HeatmapCard: View {
    @Environment(\.theme) private var theme
    @Environment(\.panelIsOpen) private var panelIsOpen
    var dailyTokens: [Date: Int]

    @State private var hovered: Date?
    @State private var gridWidth: CGFloat = 0
    @State private var tipWidth: CGFloat = 0

    private let weeks = 22
    private let cell: CGFloat = 10
    private let gap: CGFloat = 3
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.firstWeekday = 2 // Monday, matching the weekly period used elsewhere
        return c
    }

    /// Column 0 is the Monday 21 weeks back; every column holds seven days.
    private var columns: [[Date]] {
        let today = calendar.startOfDay(for: Date())
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: today),
              let firstMonday = calendar.date(byAdding: .weekOfYear, value: -(weeks - 1), to: thisWeek.start)
        else { return [] }
        return (0..<weeks).map { week in
            (0..<7).compactMap { day in
                calendar.date(byAdding: .day, value: week * 7 + day, to: firstMonday)
            }
        }
    }

    private var peak: Int { max(1, dailyTokens.values.max() ?? 1) }
    private var activeDays: Int { dailyTokens.values.filter { $0 > 0 }.count }

    var body: some View {
        Card(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                CardTitle(text: "每日活跃")
                Spacer()
                Text("近 \(weeks) 周 · \(activeDays) 天有记录")
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textSecondary)
            }
            .frame(height: 15)

            // Labels are placed at their column's offset instead of inside a
            // cell-wide box, which would squeeze a two-character month name
            // into a vertical stack.
            ZStack(alignment: .topLeading) {
                ForEach(monthMarkers, id: \.column) { marker in
                    Text(marker.name)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                        .fixedSize()
                        .offset(x: CGFloat(marker.column) * (cell + gap))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: 10)

            HStack(spacing: gap) {
                ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                    VStack(spacing: gap) {
                        ForEach(column, id: \.self) { day in
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(color(for: day))
                                .frame(width: cell, height: cell)
                                .opacity(panelIsOpen || (dailyTokens[day] ?? 0) == 0 ? 1 : 0)
                                .overlay {
                                    if day == hovered {
                                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                                            .strokeBorder(theme.textPrimary.opacity(0.45), lineWidth: 1)
                                    }
                                }
                        }
                    }
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear.onChange(of: geo.size.width, initial: true) { _, width in
                        gridWidth = width
                    }
                }
            )
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point): hovered = day(at: point)
                case .ended: hovered = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let hovered {
                    HoverTip(text: HoverTip.pair(Self.dayLabel.string(from: hovered),
                                                (dailyTokens[hovered] ?? 0) > 0
                                                    ? Format.compact(dailyTokens[hovered] ?? 0)
                                                    : "无记录"))
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

            HStack(spacing: gap) {
                Spacer()
                Text("少").font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                ForEach(0..<theme.heatmap.count, id: \.self) { level in
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(theme.heatmap[level])
                        .frame(width: 8, height: 8)
                }
                Text("多").font(.system(size: 10)).foregroundStyle(theme.textSecondary)
            }
            .frame(height: 14)
        }
    }

    private static let dayLabel: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "M月d日"
        return f
    }()

    /// Cell under the pointer. Days after today are left without a readout —
    /// the current week's column is drawn in full but only partly recorded.
    private func day(at point: CGPoint) -> Date? {
        let pitch = cell + gap
        let column = Int(point.x / pitch)
        let row = Int(point.y / pitch)
        guard point.x >= 0, point.y >= 0, row < 7, columns.indices.contains(column) else { return nil }
        let day = columns[column][row]
        return day <= calendar.startOfDay(for: Date()) ? day : nil
    }

    private func tipOffset(for day: Date) -> CGFloat {
        guard let column = columns.firstIndex(where: { $0.contains(day) }) else { return 0 }
        let centre = CGFloat(column) * (cell + gap) + cell / 2
        return min(max(0, centre - tipWidth / 2), max(0, gridWidth - tipWidth))
    }

    private func color(for day: Date) -> Color {
        let tokens = dailyTokens[day] ?? 0
        guard tokens > 0 else { return theme.heatmap[0] }
        let ratio = Double(tokens) / Double(peak)
        switch ratio {
        case ..<0.25: return theme.heatmap[1]
        case ..<0.5: return theme.heatmap[2]
        case ..<0.75: return theme.heatmap[3]
        default: return theme.heatmap[4]
        }
    }

    /// A column is marked only when its month differs from the column before,
    /// so the strip reads as month boundaries rather than a repeated name.
    private var monthMarkers: [(column: Int, name: String)] {
        let names = ["一月", "二月", "三月", "四月", "五月", "六月",
                     "七月", "八月", "九月", "十月", "十一月", "十二月"]
        var markers: [(column: Int, name: String)] = []
        var previousMonth = 0
        for (index, column) in columns.enumerated() {
            guard let first = column.first else { continue }
            let month = calendar.component(.month, from: first)
            if month != previousMonth {
                // A name that the next one would overlap is dropped; at 10pt a
                // character is narrower than one column.
                if let last = markers.last, index - last.column < last.name.count {
                    markers.removeLast()
                }
                markers.append((index, names[max(0, min(11, month - 1))]))
                previousMonth = month
            }
        }
        return markers
    }
}
