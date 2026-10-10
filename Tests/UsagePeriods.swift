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
            Granularity.allCases.map(\.title) == ["今日", "本周", "本月", "近7天", "近30天"],
            "exactly five periods in requested order")

        expect(snapshot.usage.buckets[.day]?.count == 24, "calendar day unchanged")
        expect(snapshot.usage.buckets[.week]?.count == 7, "calendar week unchanged")
        expect(snapshot.usage.buckets[.month]?.count == 31, "calendar month unchanged")
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let dstNow = calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 15))!
        let dstRange = DashboardBuilder.range(for: .recentWeek, containing: dstNow, calendar: calendar)
        expect(dstRange.upperBound.timeIntervalSince(dstRange.lowerBound) == 7 * day - 3600, "seven natural days across DST")
        print("Usage period checks passed")
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
