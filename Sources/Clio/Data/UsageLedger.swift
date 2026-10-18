import Foundation

/// Daily token totals, kept after the session logs they were read from are gone.
///
/// A day is taken from the scan while its source logs are still expected to be
/// available, and keeps that total afterwards.
struct UsageLedger: Codable, Equatable {
    /// Keyed `yyyy-MM-dd` in the local calendar.
    var days: [String: Int]

    private static func path(for tool: Tool) -> URL {
        let name = tool == .claudeCode ? "daily-tokens.json" : "codex-daily-tokens.json"
        return AppPaths.support.appending(path: name)
    }

    static func load(for tool: Tool) -> UsageLedger? {
        guard let data = try? Data(contentsOf: path(for: tool)) else { return nil }
        return try? JSONDecoder().decode(UsageLedger.self, from: data)
    }

    func save(for tool: Tool) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? data.write(to: Self.path(for: tool), options: .atomic)
    }

    /// Claude Code's `cleanupPeriodDays`; nil when it is 0, which turns deletion off.
    static func retentionDays() -> Int? {
        guard let data = try? Data(contentsOf: StatusLineInstaller.settingsPath),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let days = root["cleanupPeriodDays"] as? Int
        else { return 30 }
        return days == 0 ? nil : days
    }

    /// `previous` brought up to date with a scan made at `now` and with the
    /// stats cache's `history`.
    static func updated(_ previous: UsageLedger?,
                        events: [UsageEvent],
                        history: [Date: Int],
                        now: Date,
                        retentionDays: Int?,
                        calendar: Calendar = .current) -> UsageLedger {
        var firstComplete = Date.distantPast
        if let retentionDays, let cutoff = calendar.date(byAdding: .day, value: -retentionDays, to: now) {
            // Recent days are recalculated using the configured cleanup period.
            firstComplete = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: cutoff)) ?? now
        }
        let first = key(firstComplete, calendar)

        var days = previous?.days ?? [:]
        var scanned: [String: Int] = [:]
        for event in events {
            scanned[key(event.timestamp, calendar), default: 0] += event.counts.total
        }
        for (day, tokens) in scanned where day >= first || days[day] == nil {
            days[day] = tokens
        }
        for (date, tokens) in history where tokens > 0 {
            let day = key(date, calendar)
            if day < first && days[day] == nil { days[day] = tokens }
        }
        return UsageLedger(days: days)
    }

    func tokens(in range: Range<Date>, calendar: Calendar = .current) -> Int {
        let start = Self.key(range.lowerBound, calendar)
        let end = Self.key(range.upperBound, calendar)
        return days.filter { $0.key >= start && $0.key < end }.values.reduce(0, +)
    }

    /// Tokens per day from `start` on, keyed by the day's start.
    func daily(from start: Date, calendar: Calendar = .current) -> [Date: Int] {
        let first = Self.key(start, calendar)
        var totals: [Date: Int] = [:]
        for (day, tokens) in days where day >= first {
            let parts = day.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            else { continue }
            totals[date] = tokens
        }
        return totals
    }

    static func key(_ date: Date, _ calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

/// Verified model totals for closed days, keyed in their recorded time zone.
struct CategoryLedger: Codable, Equatable {
    var timeZone: String
    var days: [String: [String: Int]]

    static var path: URL { AppPaths.support.appending(path: "model-category-days.json") }

    static func load() -> Self? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
}
