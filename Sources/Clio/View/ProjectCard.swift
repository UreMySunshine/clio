import SwiftUI

/// Where the period's tokens went, by working directory. The bar behind each
/// row carries the share, so the list needs no separate share bar.
struct ProjectCard: View {
    @Environment(\.theme) private var theme
    var projects: [ProjectUsage]
    var granularity: Granularity

    /// Anything under a percent is noise in a list meant to answer where the
    /// period's tokens went; the largest project is kept whatever its share, so
    /// a quiet period still shows something.
    private var shown: [ProjectUsage] {
        let significant = projects.filter { Double($0.tokens) / Double(total) >= 0.01 }
        return Array((significant.isEmpty ? projects : significant).prefix(5))
    }
    private var total: Int { max(1, projects.reduce(0) { $0 + $1.tokens }) }

    private var periodTitle: String {
        switch granularity {
        case .day: return "今日"
        case .week: return "本周"
        case .month: return "本月"
        }
    }

    var body: some View {
        Card(spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                CardTitle(text: "按项目")
                Spacer()
                Text(periodTitle)
                    .font(.system(size: 10))
                    .foregroundStyle(theme.textTertiary)
            }
            .frame(height: 15)

            VStack(spacing: 6) {
                ForEach(shown) { project in
                    row(project)
                }
            }
        }
    }

    private func row(_ project: ProjectUsage) -> some View {
        let share = Double(project.tokens) / Double(total)
        return VStack(spacing: 3) {
            HStack(spacing: 8) {
                Text(project.displayName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(Format.compactNarrow(project.tokens))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(theme.textPrimary)
                    .frame(width: 56, alignment: .trailing)
                Text(Format.percent(share))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(theme.textSecondary)
                    .frame(width: 32, alignment: .trailing)
            }
            .frame(height: 16)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(theme.track)
                    Capsule()
                        .fill(theme.accent.opacity(0.55))
                        .frame(width: max(2, geo.size.width * share))
                }
            }
            .frame(height: 3)
        }
    }
}
