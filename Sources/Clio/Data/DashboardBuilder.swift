import Foundation

/// Turns raw usage events into the numbers each screen shows.
enum DashboardBuilder {

    struct QuotaConfig {
        var planName: String?
        /// Real utilisation captured from the status-line feed, when connected.
        var rateLimits: RateLimitSnapshot?
    }

    static let fiveHours: TimeInterval = 5 * 3600

    /// Monday-first, matching the week the periods are cut on.
    static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    static func snapshot(tool: Tool,
                         events: [UsageEvent],
                         rejections: [QuotaRejection],
                         prices: PriceTable,
                         quota: QuotaConfig,
                         history: [Date: Int] = [:],
                         now: Date = Date(),
                         calendar: Calendar = .current) -> ToolSnapshot {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        let live = quota.rateLimits

        var totals: [Granularity: TokenCounts] = [:]
        var costs: [Granularity: Double] = [:]
        var tokenTrend: [Granularity: Double] = [:]
        var buckets: [Granularity: [Bucket]] = [:]
        var models: [Granularity: [ModelUsage]] = [:]

        for granularity in Granularity.allCases {
            let current = range(for: granularity, containing: now, calendar: calendar)
            let previous = previousRange(current, granularity: granularity, calendar: calendar)
            let inCurrent = sorted.filter { current.contains($0.timestamp) }
            let inPrevious = sorted.filter { previous.contains($0.timestamp) }

            let currentCounts = inCurrent.reduce(into: TokenCounts()) { $0 += $1.counts }
            let previousCounts = inPrevious.reduce(into: TokenCounts()) { $0 += $1.counts }
            totals[granularity] = currentCounts

            costs[granularity] = cost(of: inCurrent, prices: prices)
            tokenTrend[granularity] = change(from: previousCounts.total, to: currentCounts.total)
            buckets[granularity] = bucket(inCurrent, granularity: granularity, range: current, calendar: calendar)
            models[granularity] = breakdown(inCurrent, prices: prices)
        }

        return ToolSnapshot(
            tool: tool,
            plan: quota.planName,
            fiveHour: fiveHourWindow(sorted, rejections: rejections, live: live?.fiveHour, now: now),
            week: weekWindow(sorted, live: live?.sevenDay, now: now, calendar: calendar),
            modelQuota: modelQuotaWindow(sorted, live: live, now: now, calendar: calendar),
            // The design's remaining-resets line has no local source.
            counter: nil,
            totals: totals,
            costs: costs,
            tokenTrend: tokenTrend,
            buckets: buckets,
            models: models,
            dailyTokens: dailyTokens(sorted, history: history, now: now, calendar: calendar),
            activity: activity(sorted, now: now, calendar: calendar),
            updatedAt: now
        )
    }

    // MARK: - Periods

    static func range(for granularity: Granularity, containing date: Date, calendar: Calendar) -> Range<Date> {
        let component: Calendar.Component
        switch granularity {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        guard let interval = calendar.dateInterval(of: component, for: date) else {
            return date..<date
        }
        return interval.start..<interval.end
    }

    private static func previousRange(_ current: Range<Date>, granularity: Granularity, calendar: Calendar) -> Range<Date> {
        let component: Calendar.Component
        switch granularity {
        case .day: component = .day
        case .week: component = .weekOfYear
        case .month: component = .month
        }
        guard let start = calendar.date(byAdding: component, value: -1, to: current.lowerBound),
              let end = calendar.date(byAdding: component, value: -1, to: current.upperBound)
        else { return current.lowerBound..<current.lowerBound }
        return start..<end
    }

    private static func change(from old: Int, to new: Int) -> Double {
        change(from: Double(old), to: Double(new))
    }

    private static func change(from old: Double, to new: Double) -> Double {
        guard old > 0 else { return 0 }
        return (new - old) / old
    }

    // MARK: - Aggregations

    private static func cost(of events: [UsageEvent], prices: PriceTable) -> Double {
        events.reduce(0) { $0 + (prices.cost($1.counts, model: $1.model) ?? 0) }
    }

    private static func bucket(_ events: [UsageEvent],
                               granularity: Granularity,
                               range: Range<Date>,
                               calendar: Calendar) -> [Bucket] {
        switch granularity {
        case .day:
            var totals = Array(repeating: 0, count: 24)
            for event in events {
                let hour = calendar.component(.hour, from: event.timestamp)
                totals[hour] += event.counts.total
            }
            return totals.enumerated().map {
                Bucket(id: $0.offset, label: String(format: "%02d", $0.offset), tokens: $0.element)
            }
        case .week, .month:
            let days = calendar.dateComponents([.day], from: range.lowerBound, to: range.upperBound).day ?? 7
            var totals = Array(repeating: 0, count: max(1, days))
            for event in events {
                let index = calendar.dateComponents([.day], from: range.lowerBound, to: event.timestamp).day ?? 0
                if totals.indices.contains(index) { totals[index] += event.counts.total }
            }
            return totals.enumerated().map { offset, tokens in
                let date = calendar.date(byAdding: .day, value: offset, to: range.lowerBound) ?? range.lowerBound
                let label = granularity == .week
                    ? Self.weekdayNames[(calendar.component(.weekday, from: date) + 5) % 7]
                    : String(calendar.component(.day, from: date))
                return Bucket(id: offset, label: label, tokens: tokens)
            }
        }
    }

    private static func breakdown(_ events: [UsageEvent], prices: PriceTable) -> [ModelUsage] {
        var tokens: [String: Int] = [:]
        var spend: [String: Double] = [:]
        for event in events {
            tokens[event.model, default: 0] += event.counts.total
            spend[event.model, default: 0] += prices.cost(event.counts, model: event.model) ?? 0
        }
        return tokens
            .map { ModelUsage(model: $0.key,
                              displayName: ModelNaming.displayName(for: $0.key),
                              tokens: $0.value,
                              cost: spend[$0.key] ?? 0) }
            .sorted { $0.tokens > $1.tokens }
    }

    /// Tokens per calendar day for the last 22 weeks — the heatmap's span.
    /// The scan covers whatever transcripts still exist; `history` reaches
    /// further back and only fills the days the scan has nothing for.
    private static func dailyTokens(_ events: [UsageEvent],
                                    history: [Date: Int],
                                    now: Date,
                                    calendar: Calendar) -> [Date: Int] {
        let earliest = calendar.date(byAdding: .day, value: -22 * 7, to: calendar.startOfDay(for: now)) ?? now
        var totals: [Date: Int] = [:]
        for event in events where event.timestamp >= earliest {
            let day = calendar.startOfDay(for: event.timestamp)
            totals[day, default: 0] += event.counts.total
        }
        for (day, tokens) in history where day >= earliest && totals[day] == nil {
            totals[day] = tokens
        }
        return totals
    }

    /// Gaps longer than this are treated as time away rather than time worked.
    private static let activeGap: TimeInterval = 5 * 60
    private static let trendDays = 14

    /// Active time is the sum of the gaps between consecutive responses, each
    /// capped at `activeGap`; the logs record no other notion of a session's
    /// span.
    static func activity(_ events: [UsageEvent], now: Date, calendar: Calendar) -> ActivitySummary {
        let today = calendar.startOfDay(for: now)
        var stamps: [Date: [Date]] = [:]
        var requests: [Date: Int] = [:]
        var sessionsToday: Set<String> = []
        for event in events {
            let day = calendar.startOfDay(for: event.timestamp)
            stamps[day, default: []].append(event.timestamp)
            requests[day, default: 0] += 1
            if day == today { sessionsToday.insert(event.sessionID) }
        }

        func hours(_ day: Date) -> Double {
            guard let times = stamps[day], times.count > 1 else { return 0 }
            let sorted = times.sorted()
            let worked = zip(sorted, sorted.dropFirst())
                .reduce(0.0) { $0 + min($1.1.timeIntervalSince($1.0), activeGap) }
            return worked / 3600
        }

        let days = (0..<trendDays)
            .compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
            .reversed()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        return ActivitySummary(activeHours: hours(today),
                               previousActiveHours: hours(yesterday),
                               requests: requests[today] ?? 0,
                               sessions: sessionsToday.count,
                               activeTrend: days.map(hours),
                               requestTrend: days.map { Double(requests[$0] ?? 0) })
    }

    // MARK: - Quota windows

    /// The current 5-hour window. A logged rate-limit rejection carries a real
    /// `resetsAt`, which is the only authoritative boundary available locally;
    /// without one the window is reconstructed by walking the request history —
    /// a window opens on the first request after the previous one expired.
    static func fiveHourWindow(_ events: [UsageEvent],
                               rejections: [QuotaRejection],
                               live: RateLimitWindow?,
                               now: Date) -> QuotaWindow {
        var start: Date?
        // A boundary is only ever taken from something that reported one: the
        // status-line feed, or a rate-limit rejection recorded in the log.
        var reported: Date?
        if let feed = live?.resetsAt, feed > now {
            start = feed.addingTimeInterval(-fiveHours)
            reported = feed
        } else if let latest = rejections.filter({ $0.resetsAt > now }).max(by: { $0.resetsAt < $1.resetsAt }) {
            start = latest.resetsAt.addingTimeInterval(-fiveHours)
            reported = latest.resetsAt
        } else {
            for event in events where event.timestamp > now.addingTimeInterval(-fiveHours * 40) {
                guard let current = start else { start = event.timestamp; continue }
                if event.timestamp >= current.addingTimeInterval(fiveHours) { start = event.timestamp }
            }
            if let current = start, now >= current.addingTimeInterval(fiveHours) { start = nil }
        }

        guard let start else {
            return QuotaWindow(title: "5 小时", used: 0, fraction: live?.fraction,
                               resetsAt: live?.resetsAt, length: fiveHours)
        }
        let end = start.addingTimeInterval(fiveHours)
        let used = events
            .filter { $0.timestamp >= start && $0.timestamp < end }
            .reduce(0) { $0 + $1.counts.total }
        // Only a reported boundary is shown. Reconstructing one from request
        // history assumes a window opens on the first request after the last
        // one closed, which continuous use makes meaningless.
        return QuotaWindow(title: "5 小时",
                           used: used,
                           fraction: live?.fraction,
                           resetsAt: live?.resetsAt ?? reported,
                           length: fiveHours)
    }

    /// A model-scoped weekly allowance, reported alongside the two windows.
    static func modelQuotaWindow(_ events: [UsageEvent],
                                 live: RateLimitSnapshot?,
                                 now: Date,
                                 calendar: Calendar) -> QuotaWindow? {
        guard let scoped = live?.modelScoped.first else { return nil }
        let week = range(for: .week, containing: now, calendar: calendar)
        let used = events
            .filter { week.contains($0.timestamp) && matches(scoped.displayName, $0.model) }
            .reduce(0) { $0 + $1.counts.total }
        return QuotaWindow(title: "\(scoped.displayName) 额度",
                           used: used,
                           fraction: scoped.fraction,
                           resetsAt: scoped.resetsAt,
                           length: 7 * 24 * 3600)
    }

    /// "Fable" matches `claude-fable-5-1`, so the row's token figure covers the
    /// same family the reported percentage does.
    private static func matches(_ displayName: String, _ model: String) -> Bool {
        let key = displayName.lowercased().replacingOccurrences(of: " ", with: "-")
        return model.lowercased().contains(key)
    }

    /// The weekly window. Its real boundary is anchored to the account, not the
    /// calendar; the reported reset time is used when available and the
    /// calendar week stands in otherwise.
    static func weekWindow(_ events: [UsageEvent], live: RateLimitWindow?, now: Date, calendar: Calendar) -> QuotaWindow {
        let week = range(for: .week, containing: now, calendar: calendar)
        let used = events
            .filter { week.contains($0.timestamp) }
            .reduce(0) { $0 + $1.counts.total }
        // The account's weekly boundary is not the calendar week and is not
        // recorded locally, so nothing is claimed without the feed.
        return QuotaWindow(title: "本周",
                           used: used,
                           fraction: live?.fraction,
                           resetsAt: live?.resetsAt,
                           length: 7 * 24 * 3600)
    }
}
