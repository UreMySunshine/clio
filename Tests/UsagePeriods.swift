import Foundation

@main
enum UsagePeriodsTests {
    static func main() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        calendar.firstWeekday = 2
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 15))!
        let day: TimeInterval = 24 * 3600
        let weekStart = calendar.date(from: DateComponents(year: 2026, month: 10, day: 4))!
        let monthStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 11))!
        let recentTime = now.addingTimeInterval(-3 * day - 3600)
        let events = [
            event(monthStart.addingTimeInterval(-1), tokens: 1_000),
            event(monthStart, tokens: 100),
            event(weekStart.addingTimeInterval(-1), tokens: 200),
            event(weekStart, tokens: 300),
            event(calendar.startOfDay(for: weekStart).addingTimeInterval(day), tokens: 350),
            event(recentTime.addingTimeInterval(-1), tokens: 400),
            event(recentTime, tokens: 500),
            event(now.addingTimeInterval(-1), tokens: 600),
            event(calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!, tokens: 10_000),
        ]
        let prices = PriceTable(prices: ["test": .make(input: 1, output: 1)])
        let snapshot = DashboardBuilder.snapshot(
            tool: .codex, events: events, rejections: [],
            prices: prices, quota: .init(),
            now: now, calendar: calendar)
        expect(snapshot.usage.totals[.recentWeek]?.total == 2_150, "7-day boundaries and future events")
        expect(snapshot.usage.totals[.recentMonth]?.total == 2_450, "30-day boundaries across months")
        expect(abs(snapshot.usage.costs[.recentWeek]! - 0.00215) < 1e-10, "cost follows selected period")
        for period in [Granularity.recentWeek, .recentMonth] {
            let total = snapshot.usage.totals[period]!.total
            expect(snapshot.usage.buckets[period]!.reduce(0) { $0 + $1.tokens } == total, "chart agrees with total")
            expect(snapshot.usage.models[period]!.reduce(0) { $0 + $1.tokens } == total, "models agree with total")
        }
        let bars = snapshot.usage.buckets[.recentWeek]!
        expect(
            bars.count == 7 && bars.first?.label == "10/4" && bars.last?.label == "10/10",
            "exactly seven local calendar days")
        expect(bars[0].tokens == 300 && bars[1].tokens == 350, "midnight starts the next chart bar")
        expect(snapshot.usage.buckets[.recentMonth]?.first?.label == "9/11", "cross-month labels")

        let previousEvent = event(recentTime.addingTimeInterval(-7 * day + 1), tokens: 550)
        let previousWeek = event(weekStart.addingTimeInterval(-4 * day), tokens: 550)
        let trend = DashboardBuilder.snapshot(
            tool: .codex,
            events: [previousEvent, previousWeek, event(recentTime, tokens: 1_100)],
            rejections: [], prices: prices, quota: .init(),
            now: now, calendar: calendar)
        expect(trend.usage.tokenTrend(.recentWeek) == 0, "trend uses adjacent seven calendar days")

        let claudeStart = now.addingTimeInterval(-day - 3600)
        let claudeEvents = [
            event(recentTime, tokens: 10_000), event(claudeStart, tokens: 700),
            event(now.addingTimeInterval(-1), tokens: 800),
        ]
        let claude = DashboardBuilder.snapshot(
            tool: .claudeCode, events: claudeEvents, rejections: [],
            prices: prices, quota: .init(),
            now: now, calendar: calendar)
        let combined = DashboardBuilder.combined(
            [snapshot.usage, claude.usage], events: events + claudeEvents,
            now: now, calendar: calendar)
        for period in [Granularity.recentWeek, .recentMonth] {
            let total = combined.totals[period]!.total
            expect(
                total == snapshot.usage.totals[period]!.total + claude.usage.totals[period]!.total,
                "combined total matches tool breakdown")
            expect(combined.buckets[period]!.reduce(0) { $0 + $1.tokens } == total, "combined chart matches total")
            expect(combined.models[period]!.reduce(0) { $0 + $1.tokens } == total, "combined models match total")
        }
        let single = DashboardBuilder.combined([snapshot.usage], events: events, now: now, calendar: calendar)
        expect(single.totals[.recentWeek] == snapshot.usage.totals[.recentWeek], "one tool also combines")
        expect(
            Granularity.allCases.map(\.title) == ["今日", "本周", "本月", "近7天", "近30天", "自定义"],
            "preset periods retain their identifiers alongside custom")

        expect(snapshot.usage.buckets[.day]?.count == 24, "calendar day unchanged")
        expect(snapshot.usage.buckets[.week]?.count == 7, "calendar week unchanged")
        expect(snapshot.usage.buckets[.month]?.count == 31, "calendar month unchanged")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstNow = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 15))!
        let dstRange = DashboardBuilder.range(for: .recentWeek, containing: dstNow, calendar: calendar)
        expect(dstRange.upperBound.timeIntervalSince(dstRange.lowerBound) == 7 * day - 3600, "seven natural days across DST")
        customRanges()
        print("Usage period checks passed (presets, custom selection, inclusive boundaries, ledger and DST)")
    }

    private static func customRanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0) -> Date {
            calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
        }
        let now = date(2026, 10, 14, 15)
        let first = date(2026, 9, 30)
        let last = date(2026, 10, 2)
        let range = UsageDateRange(start: last, end: first, today: now, calendar: calendar)
        expect(range.start == first && range.end == last && range.dayCount(calendar: calendar) == 3,
               "reverse cross-month range is normalized and includes both endpoints")
        let interval = range.interval(calendar: calendar)
        expect(interval.contains(first) && interval.contains(date(2026, 10, 2, 23)), "first and last dates included")
        expect(!interval.contains(first.addingTimeInterval(-1)) && !interval.contains(date(2026, 10, 3)),
               "outside midnights excluded")
        var selection = UsageDateSelection()
        selection.select(last, today: now, calendar: calendar)
        expect(selection.range(today: now, calendar: calendar)?.isSingleDay == true, "first click permits single day")
        selection.select(first, today: now, calendar: calendar)
        expect(selection.range(today: now, calendar: calendar) == range, "second click selects reversed endpoint")
        selection.select(last, today: now, calendar: calendar)
        expect(selection.start == last && selection.end == nil, "click after completed range begins again")
        selection.select(last, today: now, calendar: calendar)
        expect(selection.range(today: now, calendar: calendar)?.isSingleDay == true && selection.end == last,
               "same day can complete single-day range")
        selection.select(date(2026, 10, 15), today: now, calendar: calendar)
        expect(selection.end == last, "future click leaves draft unchanged")
        let saved = range.storedDays(calendar: calendar)
        expect(UsageDateRange(storedDays: saved, today: now, calendar: calendar) == range, "saved local dates restored")
        expect(UsageDateRange(storedDays: ["2026-02-30", "2026-03-01"], today: now, calendar: calendar) == nil,
               "invalid saved civil date rejected")
        let bounded = UsageDateRange(start: last, end: date(2026, 10, 20), today: now, calendar: calendar)
        expect(bounded.end == calendar.startOfDay(for: now), "restored future end limited to today")
        let crossYear = UsageDateRange(start: date(2025, 12, 31), end: date(2026, 1, 2), today: now, calendar: calendar)
        expect(crossYear.dayCount(calendar: calendar) == 3, "range crosses year boundary")
        for days in [7, 30] {
            let recent = UsageDateRange.recent(days, today: now, calendar: calendar)
            expect(recent.end == calendar.startOfDay(for: now) && recent.dayCount(calendar: calendar) == days,
                   "shortcut includes today and exactly the requested number of days")
        }
        let prices = PriceTable(prices: ["test": .make(input: 1, output: 1)])
        let events = [event(first.addingTimeInterval(-1), tokens: 9000), event(first, tokens: 100),
                      event(date(2026, 10, 1, 14), tokens: 200), event(date(2026, 10, 2, 23), tokens: 300),
                      event(date(2026, 10, 3), tokens: 9000), event(date(2026, 10, 14, 10), tokens: 500)]
        let source = DashboardBuilder.snapshot(tool: .codex, events: events, rejections: [], prices: prices,
                                               quota: .init(), now: now, calendar: calendar).usage
        let custom = DashboardBuilder.selecting(source, range: range, calendar: calendar)
        expect(custom.totals[.custom]?.total == 600, "custom totals include only selected dates")
        expect(abs(custom.costs[.custom]! - 0.0006) < 1e-10, "custom cost follows range")
        expect(custom.buckets[.custom]?.map(\.tokens) == [100, 200, 300], "range chart uses local daily buckets")
        expect(custom.models[.custom]?.reduce(0, { $0 + $1.tokens }) == 600, "custom models follow range")
        expect(custom.activity.requests == source.activity.requests && custom.dailyTokens == source.dailyTokens,
               "custom range preserves today activity and history heatmap")
        let singleRange = UsageDateRange(start: first, end: first, today: now, calendar: calendar)
        let single = DashboardBuilder.selecting(source, range: singleRange, calendar: calendar)
        expect(single.buckets[.custom]?.count == 24 && single.buckets[.custom]?[0].tokens == 100,
               "custom single day uses hourly buckets")
        let ledger = UsageLedger(days: ["2026-09-30": 1000, "2026-10-01": 200, "2026-10-02": 300])
        let historical = DashboardBuilder.snapshot(tool: .codex, events: events, rejections: [], prices: prices,
                                                   quota: .init(), ledger: ledger, now: now, calendar: calendar).usage
        let incomplete = DashboardBuilder.selecting(historical, range: range, calendar: calendar)
        expect(incomplete.totals[.custom]?.total == 1500, "ledger recovers missing daily total without double counting")
        expect(incomplete.unavailableDetails.contains(.custom) && incomplete.partialCosts.contains(.custom)
               && abs((incomplete.costs[.custom] ?? -1) - 0.0006) < 1e-10
               && incomplete.models[.custom]?.isEmpty == true, "missing log details retain a marked known subtotal without model zeros")
        expect(incomplete.buckets[.custom]?.map(\.tokens) == [1000, 200, 300], "ledger supports daily chart")
        let incompleteSingle = DashboardBuilder.selecting(historical, range: singleRange, calendar: calendar)
        expect(incompleteSingle.totals[.custom]?.total == 1000 && incompleteSingle.buckets[.custom]?.isEmpty == true,
               "ledger-only single day has total and no fabricated hourly chart")
        let combined = DashboardBuilder.combined([single, incompleteSingle], events: [], now: now, calendar: calendar)
        expect(combined.totals[.custom]?.total == 1100 && combined.buckets[.custom]?.isEmpty == true
               && combined.models[.custom]?.isEmpty == true && combined.partialCosts.contains(.custom)
               && abs((combined.costs[.custom] ?? -1) - 0.0002) < 1e-10,
               "mixed detail availability retains the subtotal without exposing partial hourly data")
        let zeroRange = UsageDateRange(start: date(2026, 8, 1), end: date(2026, 8, 2), today: now, calendar: calendar)
        let zero = DashboardBuilder.selecting(source, range: zeroRange, calendar: calendar)
        expect(zero.totals[.custom]?.total == 0 && !zero.unavailableDetails.contains(.custom), "known empty range remains zero")

        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        for (month, day, hours) in [(3, 8, 23), (11, 1, 25)] {
            let dstDay = date(2026, month, day)
            let dstRange = UsageDateRange(start: dstDay, end: dstDay, today: date(2026, 12, 1), calendar: calendar)
            expect(dstRange.interval(calendar: calendar).upperBound.timeIntervalSince(dstDay) == Double(hours * 3600),
                   "single day follows local midnight across DST")
            expect(dstRange.dayCount(calendar: calendar) == 1, "DST day counts as one day")
            let before = calendar.date(byAdding: .day, value: -1, to: dstDay)!
            let after = calendar.date(byAdding: .day, value: 1, to: dstDay)!
            let spanning = UsageDateRange(start: before, end: after, today: date(2026, 12, 1), calendar: calendar)
            let dstEvents = [before, dstDay, after].map { event($0, tokens: 100) }
            let dstSource = DashboardBuilder.snapshot(tool: .codex, events: dstEvents, rejections: [], prices: prices,
                                                      quota: .init(), now: date(2026, 12, 1), calendar: calendar).usage
            let dstCustom = DashboardBuilder.selecting(dstSource, range: spanning, calendar: calendar)
            expect(spanning.dayCount(calendar: calendar) == 3 && dstCustom.buckets[.custom]?.map(\.tokens) == [100, 100, 100],
                   "multi-day DST range preserves all daily buckets")
        }
    }

    private static func event(_ timestamp: Date, tokens: Int) -> UsageEvent {
        UsageEvent(
            timestamp: timestamp, model: "test", counts: TokenCounts(input: tokens),
            dedupeKey: UUID().uuidString)
    }

    private static func expect(_ condition: Bool, _ message: String) {
        precondition(condition, message)
    }
}
