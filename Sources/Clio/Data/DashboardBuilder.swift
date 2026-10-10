import Foundation

/// Turns raw usage events into the numbers each screen shows.
enum DashboardBuilder {

    struct QuotaConfig {
        var planName: String?
        /// Real utilisation, from whichever source reported it most recently.
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
                         now: Date = Date(),
                         calendar: Calendar = .current) -> ToolSnapshot {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        let live = quota.rateLimits

        return ToolSnapshot(
            tool: tool,
            plan: quota.planName,
            fiveHour: tool == .claudeCode || live?.fiveHour != nil
                ? fiveHourWindow(sorted, rejections: rejections, live: live?.fiveHour, now: now) : nil,
            week: weekWindow(sorted, live: live?.sevenDay, now: now, calendar: calendar),
            modelQuota: modelQuotaWindow(sorted, live: live, now: now, calendar: calendar),
            usage: usage(tool: tool, sorted, prices: prices, now: now, calendar: calendar),
            updatedAt: now
        )
    }

    private static func usage(tool: Tool,
                              _ sorted: [UsageEvent],
                              prices: PriceTable,
                              now: Date,
                              calendar: Calendar) -> UsageSummary {
        var totals: [Granularity: TokenCounts] = [:]
        var previousTotals: [Granularity: Int] = [:]
        var costs: [Granularity: Double] = [:]
        var buckets: [Granularity: [Bucket]] = [:]
        var models: [Granularity: [ModelUsage]] = [:]

        for granularity in Granularity.allCases {
            let current = range(for: granularity, containing: now, calendar: calendar)
            let previous = previousRange(current, granularity: granularity, calendar: calendar)
            let inCurrent = sorted.filter { current.contains($0.timestamp) }

            totals[granularity] = inCurrent.reduce(into: TokenCounts()) { $0 += $1.counts }
            costs[granularity] = cost(of: inCurrent, prices: prices)
            previousTotals[granularity] = sorted
                .filter { previous.contains($0.timestamp) }
                .reduce(0) { $0 + $1.counts.total }
            buckets[granularity] = bucket(inCurrent, tool: tool, granularity: granularity, range: current,
                                          calendar: calendar)
            models[granularity] = breakdown(inCurrent, prices: prices)
        }

        return UsageSummary(totals: totals,
                            previousTotals: previousTotals,
                            costs: costs,
                            buckets: buckets,
                            models: models,
                            dailyTokens: dailyTokens(sorted, now: now, calendar: calendar),
                            activity: activity(sorted, now: now, calendar: calendar))
    }

    /// The tools' usage added together. Active time is worked out again from
    /// every tool's responses, so time spent in two tools at once counts once.
    static func combined(_ parts: [UsageSummary],
                         events: [UsageEvent],
                         now: Date = Date(),
                         calendar: Calendar = .current) -> UsageSummary {
        var totals: [Granularity: TokenCounts] = [:]
        var previousTotals: [Granularity: Int] = [:]
        var costs: [Granularity: Double] = [:]
        var buckets: [Granularity: [Bucket]] = [:]
        var models: [Granularity: [ModelUsage]] = [:]

        for granularity in Granularity.allCases {
            totals[granularity] = parts.reduce(into: TokenCounts()) { $0 += $1.totals[granularity] ?? TokenCounts() }
            previousTotals[granularity] = parts.reduce(0) { $0 + ($1.previousTotals[granularity] ?? 0) }
            costs[granularity] = parts.reduce(Optional(0.0)) { sum, part in
                sum.flatMap { total in part.costs[granularity].map { total + $0 } }
            }

            // Every tool's chart covers the same period, so bars line up by position.
            let charts = parts.compactMap { $0.buckets[granularity] }
            buckets[granularity] = charts.first.map { first in
                first.indices.map { index in
                    Bucket(id: first[index].id,
                           label: first[index].label,
                           byTool: charts.reduce(into: [:]) { $0.merge($1[index].byTool, uniquingKeysWith: +) })
                }
            }

            var merged: [String: ModelUsage] = [:]
            for model in parts.flatMap({ $0.models[granularity] ?? [] }) {
                guard let existing = merged[model.model] else {
                    merged[model.model] = model
                    continue
                }
                merged[model.model] = ModelUsage(model: model.model,
                                                 displayName: model.displayName,
                                                 tokens: existing.tokens + model.tokens,
                                                 cost: existing.cost.flatMap { cost in model.cost.map { cost + $0 } })
            }
            models[granularity] = merged.values.sorted { $0.tokens > $1.tokens }
        }

        return UsageSummary(totals: totals,
                            previousTotals: previousTotals,
                            costs: costs,
                            buckets: buckets,
                            models: models,
                            dailyTokens: parts.reduce(into: [:]) { $0.merge($1.dailyTokens, uniquingKeysWith: +) },
                            activity: activity(events, now: now, calendar: calendar))
    }

    // MARK: - Periods

    static func range(for granularity: Granularity, containing date: Date, calendar: Calendar) -> Range<Date> {
        let component: Calendar.Component
        var periodCalendar = calendar
        switch granularity {
        case .day: component = .day
        case .week:
            component = .weekOfYear
            periodCalendar.firstWeekday = 2
        case .month: component = .month
        case .recentWeek, .recentMonth:
            let today = calendar.startOfDay(for: date)
            let days = granularity == .recentWeek ? 7 : 30
            let start = calendar.date(byAdding: .day, value: 1 - days, to: today)!
            let end = calendar.date(byAdding: .day, value: 1, to: today)!
            return start..<end
        }
        guard let interval = periodCalendar.dateInterval(of: component, for: date) else {
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
        case .recentWeek, .recentMonth:
            let days = granularity == .recentWeek ? 7 : 30
            let start = calendar.date(byAdding: .day, value: -days, to: current.lowerBound)!
            return start..<current.lowerBound
        }
        guard let start = calendar.date(byAdding: component, value: -1, to: current.lowerBound),
              let end = calendar.date(byAdding: component, value: -1, to: current.upperBound)
        else { return current.lowerBound..<current.lowerBound }
        return start..<end
    }

    // MARK: - Aggregations

    private static func cost(of events: [UsageEvent], prices: PriceTable) -> Double? {
        var total = 0.0
        for event in events {
            guard let cost = prices.cost(event.counts, model: event.model) else { return nil }
            total += cost
        }
        return total
    }

    private static func bucket(_ events: [UsageEvent],
                               tool: Tool,
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
                Bucket(id: $0.offset, label: String(format: "%02d", $0.offset), byTool: [tool: $0.element])
            }
        case .week, .month, .recentWeek, .recentMonth:
            let start = calendar.startOfDay(for: range.lowerBound)
            let end = calendar.startOfDay(for: range.upperBound)
            let days = (calendar.dateComponents([.day], from: start, to: end).day ?? 0)
                + (range.upperBound > end ? 1 : 0)
            var totals = Array(repeating: 0, count: max(1, days))
            for event in events {
                let index = calendar.dateComponents([.day], from: start,
                                                    to: calendar.startOfDay(for: event.timestamp)).day ?? 0
                if totals.indices.contains(index) { totals[index] += event.counts.total }
            }
            return totals.enumerated().map { offset, tokens in
                let date = calendar.date(byAdding: .day, value: offset, to: start) ?? start
                let label: String
                switch granularity {
                case .week:
                    label = Self.weekdayNames[(calendar.component(.weekday, from: date) + 5) % 7]
                case .month:
                    label = String(calendar.component(.day, from: date))
                default:
                    label = "\(calendar.component(.month, from: date))/\(calendar.component(.day, from: date))"
                }
                return Bucket(id: offset, label: label, byTool: [tool: tokens])
            }
        }
    }

    private static func breakdown(_ events: [UsageEvent], prices: PriceTable) -> [ModelUsage] {
        var tokens: [String: Int] = [:]
        var spend: [String: Double] = [:]
        for event in events {
            tokens[event.model, default: 0] += event.counts.total
            if let cost = prices.cost(event.counts, model: event.model) {
                spend[event.model, default: 0] += cost
            }
        }
        return tokens
            .map { ModelUsage(model: $0.key,
                              displayName: ModelNaming.displayName(for: $0.key),
                              tokens: $0.value,
                              cost: spend[$0.key]) }
            .sorted { $0.tokens > $1.tokens }
    }

    /// Tokens per calendar day for the last 22 weeks — the heatmap's span.
    private static func dailyTokens(_ events: [UsageEvent],
                                    now: Date,
                                    calendar: Calendar) -> [Date: Int] {
        let earliest = calendar.date(byAdding: .day, value: -22 * 7, to: calendar.startOfDay(for: now)) ?? now
        var totals: [Date: Int] = [:]
        for event in events where event.timestamp >= earliest {
            let day = calendar.startOfDay(for: event.timestamp)
            totals[day, default: 0] += event.counts.total
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
        // A reported window that has ended keeps only its reset time: its
        // percentage is stale, and the history walk starts there.
        let ended = live?.resetsAt.flatMap { $0 > now ? nil : $0 }
        let running = ended == nil ? live : nil
        var start: Date?
        // A boundary is only ever taken from something that reported one: the
        // status-line feed, or a rate-limit rejection recorded in the log.
        var reported: Date?
        if let feed = running?.resetsAt {
            start = feed.addingTimeInterval(-fiveHours)
            reported = feed
        } else if let latest = rejections.filter({ $0.resetsAt > now }).max(by: { $0.resetsAt < $1.resetsAt }) {
            start = latest.resetsAt.addingTimeInterval(-fiveHours)
            reported = latest.resetsAt
        } else {
            let earliest = ended ?? now.addingTimeInterval(-fiveHours * 40)
            for event in events where event.timestamp >= earliest {
                guard let current = start else { start = event.timestamp; continue }
                if event.timestamp >= current.addingTimeInterval(fiveHours) { start = event.timestamp }
            }
            if let current = start, now >= current.addingTimeInterval(fiveHours) { start = nil }
        }

        guard let start else {
            // No window has opened since the reported reset, so nothing is used.
            return QuotaWindow(title: "5 小时", used: 0, fraction: ended == nil ? running?.fraction : 0,
                               resetsAt: running?.resetsAt ?? ended, length: fiveHours)
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
                           fraction: running?.fraction,
                           resetsAt: running?.resetsAt ?? reported ?? ended,
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
