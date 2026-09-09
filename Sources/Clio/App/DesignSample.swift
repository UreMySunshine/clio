import Foundation

/// The numbers printed on the design canvas, so a render can be compared with
/// the artboard one-to-one instead of against live data that never matches.
@MainActor
enum DesignSample {
    static func dashboard(now: Date = Date()) -> Dashboard {
        Dashboard(snapshots: [claudeCode(now: now), codex(now: now)], updatedAt: now)
    }

    /// The Codex artboard, so the tool switch and the card header are covered
    /// by the comparison too.
    private static func codex(now: Date) -> ToolSnapshot {
        let weekReset = nextWeekday(7, hour: 22, from: now)
        return ToolSnapshot(
            tool: .codex,
            plan: "ChatGPT Plus",
            fiveHour: QuotaWindow(title: "5 小时", used: 91_000_000, fraction: 0.91,
                                  resetsAt: now.addingTimeInterval(47 * 60),
                                  length: 5 * 3600),
            week: QuotaWindow(title: "本周", used: 54_000_000, fraction: 0.54, resetsAt: weekReset,
                              length: 7 * 24 * 3600),
            modelQuota: nil,
            counter: QuotaCounter(title: "剩余重置卡", value: "2", suffix: "张"),
            totals: [.day: TokenCounts(input: 301_000, output: 88_000, cacheRead: 473_000)],
            costs: [.day: 2.13],
            tokenTrend: [.day: -0.22],
            buckets: [.day: (0..<24).map { Bucket(id: $0, label: String(format: "%02d", $0), tokens: 0) }],
            models: [.day: [
                ModelUsage(model: "gpt-5-codex", displayName: "gpt-5-codex", tokens: 612_000, cost: 1.71),
                ModelUsage(model: "gpt-5", displayName: "gpt-5", tokens: 206_000, cost: 0.38),
                ModelUsage(model: "o4-mini", displayName: "o4-mini", tokens: 44_000, cost: 0.04),
            ]],
            dailyTokens: heatmap(now: now),
            activity: ActivitySummary(activeHours: 2.6, previousActiveHours: 3.4,
                                      requests: 1_204, sessions: 7,
                                      activeTrend: [1.8, 2.4, 3.1, 2.2, 3.6, 2.9, 3.4, 2.6],
                                      requestTrend: [820, 960, 1_310, 880, 1_450, 1_120, 1_380, 1_204]),
            updatedAt: now
        )
    }

    private static func claudeCode(now: Date) -> ToolSnapshot {
        let counts = TokenCounts(input: 184_000,
                                 output: 61_000,
                                 cacheRead: 942_000,
                                 cacheWrite5m: 56_000,
                                 cacheWrite1h: 0)
        // The artboard's bar heights, in the 48pt plot.
        let heights = [0, 0, 0, 0, 0, 0, 0, 0, 0, 2, 7, 48, 10, 21, 30, 3, 43, 0, 0, 0, 0, 0, 0, 0]
        let buckets = heights.enumerated().map {
            Bucket(id: $0.offset, label: String(format: "%02d", $0.offset), tokens: $0.element * 10_000)
        }

        let weekReset = nextWeekday(5, hour: 9, from: now)   // 周四 09:00
        let fiveHourReset = now.addingTimeInterval(2 * 3600 + 14 * 60)

        return ToolSnapshot(
            tool: .claudeCode,
            plan: "Max 5×",
            fiveHour: QuotaWindow(title: "5 小时", used: 62_000_000, fraction: 0.62,
                                  resetsAt: fiveHourReset, length: 5 * 3600),
            week: QuotaWindow(title: "本周", used: 38_000_000, fraction: 0.38, resetsAt: weekReset,
                              length: 7 * 24 * 3600),
            modelQuota: QuotaWindow(title: "Fable 额度", used: 71_000_000, fraction: 0.71,
                                    resetsAt: weekReset, length: 7 * 24 * 3600),
            counter: QuotaCounter(title: "剩余重置次数", value: "1", suffix: "/ 1"),
            totals: [.day: TokenCounts(input: counts.input,
                                       output: counts.output,
                                       cacheRead: counts.cacheRead,
                                       cacheWrite5m: 1_243_610 - counts.input - counts.output - counts.cacheRead,
                                       cacheWrite1h: 0)],
            costs: [.day: 4.86],
            tokenTrend: [.day: 0.18],
            buckets: [.day: buckets],
            models: [.day: [
                ModelUsage(model: "opus-4-1", displayName: "Opus 4.1", tokens: 680_000, cost: 3.92),
                ModelUsage(model: "sonnet-4", displayName: "Sonnet 4", tokens: 521_000, cost: 0.88),
                ModelUsage(model: "haiku-3-5", displayName: "Haiku 3.5", tokens: 42_000, cost: 0.06),
            ]],
            dailyTokens: heatmap(now: now),
            activity: ActivitySummary(activeHours: 4.2, previousActiveHours: 3.1,
                                      requests: 2_847, sessions: 12,
                                      activeTrend: [2.1, 3.0, 2.4, 3.6, 2.8, 3.1, 3.9, 4.2],
                                      requestTrend: [1_640, 2_010, 1_780, 2_460, 2_150, 2_320, 2_690, 2_847]),
            updatedAt: now
        )
    }

    /// 38 active days spread over the last five weeks, matching the artboard's
    /// density. Deterministic so repeat renders are comparable.
    private static func heatmap(now: Date) -> [Date: Int] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let today = calendar.startOfDay(for: now)
        var totals: [Date: Int] = [:]
        var seed: UInt64 = 20_260_908
        func next() -> Double {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double((seed >> 33) % 1000) / 1000
        }
        for offset in 0..<45 {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            let r = next()
            if r < 0.16 { continue }
            totals[day] = Int(r * 4_000_000)
        }
        return totals
    }

    private static func nextWeekday(_ weekday: Int, hour: Int, from date: Date) -> Date {
        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0
        return Calendar.current.nextDate(after: date,
                                         matching: components,
                                         matchingPolicy: .nextTime) ?? date
    }
}
