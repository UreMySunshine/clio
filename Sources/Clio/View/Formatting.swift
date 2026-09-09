import Foundation

enum Format {
    private static let grouped: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.groupingSeparator = ","
        return f
    }()

    /// Full count with thousands separators, as on the headline number.
    static func grouped(_ value: Int) -> String {
        grouped.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// Compact form used in the menu bar and the per-model rows.
    static func compact(_ value: Int) -> String {
        switch value {
        case 1_000_000...:
            return String(format: "%.2fM", Double(value) / 1_000_000)
        case 1_000...:
            return String(format: "%.0fK", Double(value) / 1_000)
        default:
            return String(value)
        }
    }

    /// Compact form with fewer decimals the larger the figure gets, so a
    /// value stays inside the five-column split instead of being elided.
    static func compactNarrow(_ value: Int) -> String {
        switch value {
        case 1_000_000_000...:
            return String(format: "%.0fM", Double(value) / 1_000_000)
        case 100_000_000...:
            return String(format: "%.1fM", Double(value) / 1_000_000)
        default:
            return compact(value)
        }
    }

    /// "1 小时 40 分" — a span, coarse enough to read at a glance.
    static func duration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total >= 86400 {
            let days = total / 86400, hours = (total % 86400) / 3600
            return hours > 0 ? "\(days) 天 \(hours) 小时" : "\(days) 天"
        }
        if total >= 3600 {
            let hours = total / 3600, minutes = (total % 3600) / 60
            return minutes > 0 ? "\(hours) 小时 \(minutes) 分" : "\(hours) 小时"
        }
        return "\(max(1, total / 60)) 分"
    }

    /// "9月8日 23:41" — a date the reader can compare against today at a glance.
    static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_Hans_CN")
        f.dateFormat = "M月d日 HH:mm"
        return f
    }()

    static func money(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value >= 100
            ? String(format: "$%.0f", value)
            : String(format: "$%.2f", value)
    }

    static func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    static func signedPercent(_ change: Double) -> String {
        "\(Int((abs(change) * 100).rounded()))%"
    }

    /// "2 天 3 小时后" / "2 小时 14 分后" / "47 分后" — the quota row names the
    /// window, so the word 重置 would only repeat what the column already is.
    /// Empty when no boundary was reported — the row then carries the token
    /// figure alone rather than a made-up time.
    static func reset(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "" }
        let seconds = date.timeIntervalSince(now)
        guard seconds > 0 else { return "已重置" }
        return "\(duration(seconds))后"
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}
