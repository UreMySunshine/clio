import Foundation

@main
enum UsageTests {
    private static var failures = 0
    private static let now = Date()
    private static let root = FileManager.default.temporaryDirectory.appending(path: "clio-usage-\(UUID())")
    private static let prices = PriceTable(prices: ["gpt-priced": .make(input: 2, output: 10, cacheRead: 0.2)])

    static func main() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        try testArchives()
        try testArchiveMove()
        try testArchiveOnly()
        try testUpgrade()
        try testCacheWrites()
        try testLegacyUsage()
        testQuotaVisibility()
        testUnknownPrices()
        testZeroPrice()
        testAutoReviewPrice()
        testCombinedUsage()
        testCombinedActivity()
        testCombinedMilestones()
        try testMilestonePersistence()
        testMilestonePeriods()
        testPerToolMilestones()
        guard failures == 0 else {
            print("\(failures) assertions failed")
            exit(1)
        }
        print("16 usage regression scenarios passed")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        if !condition() { failures += 1; print("FAIL: \(message)") }
    }

    private static func directories(_ name: String) throws -> URL {
        let base = root.appending(path: name)
        for directory in ["sessions", "archived_sessions"] {
            try FileManager.default.createDirectory(at: base.appending(path: directory), withIntermediateDirectories: true)
        }
        return base
    }

    private static func usage(_ seconds: TimeInterval, input: Int = 1000, cached: Int = 600,
                              write: Int? = 0, output: Int = 100, total: Int = 1100,
                              plan: String = "prolite", fiveHour: Bool = false) throws -> String {
        var last = ["input_tokens": input, "cached_input_tokens": cached,
                    "output_tokens": output, "reasoning_output_tokens": 50, "total_tokens": input + output]
        last["cache_write_input_tokens"] = write
        let reset = now.addingTimeInterval(86400).timeIntervalSince1970
        let limits: [String: Any] = [
            "plan_type": plan,
            "primary": ["used_percent": 10, "window_minutes": 10080, "resets_at": reset],
            "secondary": fiveHour
                ? ["used_percent": 20, "window_minutes": 300, "resets_at": now.addingTimeInterval(3600).timeIntervalSince1970]
                : NSNull()
        ]
        let object: [String: Any] = [
            "type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds)),
            "payload": ["type": "token_count", "info": ["last_token_usage": last, "total_token_usage": ["total_tokens": total]],
                        "rate_limits": limits]
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func log(_ base: URL, _ name: String, archived: Bool = false, lines: [String]) throws -> URL {
        let file = base.appending(path: archived ? "archived_sessions" : "sessions").appending(path: "\(name).jsonl")
        let context = #"{"type":"turn_context","payload":{"model":"gpt-priced"}}"#
        try Data(([context] + lines).joined(separator: "\n").appending("\n").utf8).write(to: file)
        return file
    }

    private static func append(_ line: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private static func snapshot(_ events: [UsageEvent], tool: Tool = .codex,
                                 limits: RateLimitSnapshot? = nil, prices: PriceTable? = nil) -> ToolSnapshot {
        DashboardBuilder.snapshot(tool: tool, events: events, rejections: [], prices: prices ?? self.prices,
                                  quota: .init(rateLimits: limits), now: now)
    }

    private static func testArchives() throws {
        let base = try directories("archives")
        let first = try usage(-60)
        _ = try log(base, "active", lines: [first])
        _ = try log(base, "archive", archived: true, lines: [first, try usage(-50, total: 2200)])
        let reader = CodexReader(root: base.appending(path: "sessions"))
        let events = reader.refresh(now: now).events
        expect(events.count == 2, "active and archived copies must be deduplicated")
        expect(reader.refresh(now: now).events.count == 2, "refresh must not repeat archived usage")
        let result = DashboardBuilder.snapshot(tool: .codex, events: events, rejections: [], prices: prices,
                                              quota: .init(), now: now)
        for period in [Granularity.day, .week, .month, .recentWeek, .recentMonth] {
            expect(result.usage.totals[period]?.total == 2200, "\(period) total must include archived usage")
            expect(result.usage.buckets[period]?.reduce(0, { $0 + $1.tokens }) == 2200, "\(period) chart must include archived usage")
        }
        expect(result.usage.dailyTokens.values.reduce(0, +) == 2200, "daily ledger must include archived usage")
    }

    private static func testArchiveMove() throws {
        let base = try directories("move")
        let file = try log(base, "moving", lines: [try usage(-60)])
        let reader = CodexReader(root: base.appending(path: "sessions"))
        expect(reader.refresh(now: now).events.count == 1, "initial active usage")
        let archived = base.appending(path: "archived_sessions/moving.jsonl")
        try FileManager.default.moveItem(at: file, to: archived)
        expect(reader.refresh(now: now).events.count == 1, "moving a log must not double its usage")
        try append(usage(-50, total: 2200), to: archived)
        expect(reader.refresh(now: now).events.count == 2, "new archived content must be read incrementally")
        let restarted = CodexReader(root: base.appending(path: "sessions"))
        expect(restarted.refresh(now: now).events.count == 2, "restart must retain archived usage")
    }

    private static func testArchiveOnly() throws {
        let base = try directories("archive-only")
        try FileManager.default.removeItem(at: base.appending(path: "sessions"))
        _ = try log(base, "only", archived: true, lines: [try usage(-60)])
        let reader = CodexReader(root: base.appending(path: "sessions"))
        expect(reader.isAvailable, "archived logs alone must make Codex available")
        expect(reader.refresh(now: now).events.count == 1, "archived logs alone must be counted")
    }

    private static func testUpgrade() throws {
        let base = try directories("upgrade")
        let file = try log(base, "upgrade", lines: [try usage(-60, plan: "plus", fiveHour: true)])
        let reader = CodexReader(root: base.appending(path: "sessions"))
        expect(reader.refresh(now: now).quota?.fiveHour != nil, "reported five-hour window must be retained")
        try append(usage(-50, total: 2200), to: file)
        let result = reader.refresh(now: now)
        expect(result.plan == "Pro 5×", "prolite must display as Pro 5×")
        expect(result.events.reduce(0, { $0 + $1.counts.total }) == 2200, "upgrade must retain earlier usage")
        expect(result.quota?.fiveHour == nil, "new subscription without five-hour quota must clear the old window")
    }

    private static func testCacheWrites() throws {
        let base = try directories("writes")
        _ = try log(base, "writes", lines: [try usage(-60, write: 200)])
        let result = CodexReader(root: base.appending(path: "sessions")).refresh(now: now)
        let counts = result.events.first?.counts ?? TokenCounts()
        expect(counts.input == 200 && counts.cacheRead == 600 && counts.cacheWrite == 200,
               "input must separate cache reads and writes")
        expect(counts.output == 100 && counts.total == 1100, "cache writes and reasoning must not double the total")
        expect(snapshot(result.events).usage.totals[.day]?.cacheWrite == 200,
               "reported cache writes must reach the dashboard")
        expect(abs((prices.cost(counts, model: "gpt-priced") ?? 0) - 0.00202) < 1e-12,
               "cache writes must use their price")
    }

    private static func testLegacyUsage() throws {
        let base = try directories("legacy")
        _ = try log(base, "legacy", lines: [try usage(-60, write: nil)])
        let counts = CodexReader(root: base.appending(path: "sessions")).refresh(now: now).events.first?.counts
        expect(counts?.input == 400 && counts?.cacheWrite == 0 && counts?.total == 1100,
               "older usage without a cache-write field must retain its total")
    }

    private static func testQuotaVisibility() {
        let absent: Any? = snapshot([]).fiveHour
        expect(absent == nil, "Codex without a reported five-hour quota must hide the row")
        let limits = RateLimitSnapshot(updatedAt: now, fiveHour: .init(usedPercentage: 20), modelScoped: [])
        let present: Any? = snapshot([], limits: limits).fiveHour
        expect(present != nil, "Codex with a reported five-hour quota must show the row")
        let claude: Any? = snapshot([], tool: .claudeCode).fiveHour
        expect(claude != nil, "Claude Code must retain its five-hour row")
    }

    private static func testUnknownPrices() {
        let counts = TokenCounts(input: 1000)
        let events = ["gpt-priced", "codex-auto-review"].map {
            UsageEvent(timestamp: now, model: $0, counts: counts, dedupeKey: $0)
        }
        let result = snapshot(events).usage
        let unknown: Double? = result.models[.day]?.first { $0.model == "codex-auto-review" }?.cost
        expect(unknown == nil, "missing model prices must remain unknown")
        expect(result.costs[.day] == nil, "an incomplete total cost must remain unknown")
        expect(result.totals[.day]?.total == 2000, "unpriced model tokens must still be counted")
        expect(result.models[.day]?.first { $0.model == "gpt-priced" }?.cost == 0.002,
               "known model costs must remain visible")
    }

    private static func testZeroPrice() {
        let free = PriceTable(prices: ["free-model": .make(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)])
        let event = UsageEvent(timestamp: now, model: "free-model", counts: .init(input: 1000), dedupeKey: "free")
        let result = snapshot([event], prices: free).usage
        expect(result.costs[.day] == 0 && result.models[.day]?.first?.cost == 0,
               "a known zero price must remain zero")
    }

    private static func testAutoReviewPrice() {
        let counts = TokenCounts(input: 1000, output: 100, cacheRead: 600)
        expect(PriceTable.builtin.cost(counts, model: "codex-auto-review") == 0,
               "Codex automatic review must be priced at zero")
    }

    private static func event(_ tool: Tool, _ seconds: TimeInterval, tokens: Int, model: String = "gpt-priced") -> UsageEvent {
        UsageEvent(timestamp: now.addingTimeInterval(seconds), model: model, counts: .init(input: tokens),
                   dedupeKey: "\(tool.rawValue)\(seconds)", sessionID: tool.rawValue)
    }

    /// Calendar-day periods, so the fixtures land inside today wherever the test runs.
    private static var noon: Date { Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now)! }

    private static func testCombinedUsage() {
        let shift = noon.timeIntervalSince(now)
        let claudeEvents = [event(.claudeCode, shift, tokens: 3000, model: "claude-opus-5-5"),
                            event(.claudeCode, shift - 86400, tokens: 1000, model: "claude-opus-5-5")]
        let codexEvents = [event(.codex, shift + 60, tokens: 1000), event(.codex, shift + 120, tokens: 500, model: "unpriced")]
        let prices = PriceTable(prices: ["gpt-priced": .make(input: 2, output: 10),
                                         "claude-opus-5-5": .make(input: 4, output: 20)])
        let claude = DashboardBuilder.snapshot(tool: .claudeCode, events: claudeEvents, rejections: [], prices: prices,
                                               quota: .init(), now: noon).usage
        let codex = DashboardBuilder.snapshot(tool: .codex, events: codexEvents, rejections: [], prices: prices,
                                              quota: .init(), now: noon).usage
        let combined = DashboardBuilder.combined([claude, codex], events: claudeEvents + codexEvents, now: noon)

        expect(combined.totals[.day]?.total == 4500, "combined day total must add both tools")
        expect(combined.totals[.day]?.input == 4500, "combined token kinds must add both tools")
        expect(combined.previousTotals[.day] == 1000, "combined previous day must add both tools")
        expect(abs(combined.tokenTrend(.day) - 3.5) < 1e-9, "combined trend must compare combined totals")
        expect(combined.costs[.day] == nil, "an unpriced model in either tool must leave the combined cost unknown")
        let hour = Calendar.current.component(.hour, from: noon)
        let bar = combined.buckets[.day]?[hour]
        expect(bar?.byTool[.claudeCode] == 3000 && bar?.byTool[.codex] == 1500 && bar?.tokens == 4500,
               "a combined bar must keep each tool's share")
        expect(combined.buckets[.day]?.count == 24, "combined day chart must keep one bar per hour")
        expect(combined.models[.day]?.map(\.model) == ["claude-opus-5-5", "gpt-priced", "unpriced"],
               "combined models must be listed together by tokens")
        let today = Calendar.current.startOfDay(for: noon)
        expect(combined.dailyTokens[today] == 4500, "combined heat map must add both tools per day")

        let priced = DashboardBuilder.combined([claude], events: claudeEvents, now: noon)
        expect(priced.costs[.day] == claude.costs[.day], "a single tool's combined cost must equal its own")
    }

    private static func testCombinedActivity() {
        let shift = noon.timeIntervalSince(now)
        // Both tools answer through the same minutes, then Codex carries on alone.
        let claudeEvents = (0...4).map { event(.claudeCode, shift + Double($0) * 60, tokens: 10) }
        let codexEvents = (0...8).map { event(.codex, shift + Double($0) * 60 + 30, tokens: 10) }
        let activity = DashboardBuilder.combined([], events: claudeEvents + codexEvents, now: noon).activity
        expect(abs(activity.activeHours - (8 * 60 + 30) / 3600.0) < 1e-9,
               "time spent in both tools at once must count once")
        expect(activity.requests == 14, "combined requests must add both tools")
        expect(activity.sessions == 2, "combined sessions must add both tools")
    }

    private static func milestoneState(claude: Int = 0, codex: Int = 0, at date: Date? = nil) -> MilestoneState {
        let parts = [(Tool.claudeCode, claude), (.codex, codex)].map { tool, tokens in
            snapshot([UsageEvent(timestamp: now, model: "gpt-priced", counts: .init(input: tokens), dedupeKey: tool.rawValue)],
                     tool: tool).usage
        }
        let totals = DashboardBuilder.combined(parts, events: [], now: now).totals
        return Milestones.state(dayTokens: totals[.day]?.total ?? 0,
                                weekTokens: totals[.week]?.total ?? 0,
                                monthTokens: totals[.month]?.total ?? 0,
                                at: date ?? now)
    }

    private static func testCombinedMilestones() {
        let initial = milestoneState(claude: 60_000_000, codex: 30_000_000)
        expect(!Milestones.shouldCelebrate(previous: nil, current: initial), "first scan must establish a baseline")
        let combined100 = milestoneState(claude: 60_000_000, codex: 40_000_000)
        expect(Milestones.shouldCelebrate(previous: initial, current: combined100),
               "Claude Code 60M and Codex 40M must celebrate the combined 100M")
        let still100 = milestoneState(claude: 100_000_000, codex: 40_000_000)
        expect(!Milestones.shouldCelebrate(previous: combined100, current: still100),
               "a tool reaching 100M on its own must not celebrate a combined floor already reached")
    }

    private static func testMilestonePersistence() throws {
        let original = milestoneState(claude: 200_000_000, codex: 100_000_000)
        let restored = try JSONDecoder().decode(MilestoneState.self, from: JSONEncoder().encode(original))
        expect(!Milestones.shouldCelebrate(previous: restored, current: original),
               "a restart must not replay completed milestones")
        let partial = Milestones.merged(previous: restored, current: milestoneState(claude: 100_000_000))
        expect(!Milestones.shouldCelebrate(previous: partial, current: original),
               "partial reads must retain completed milestones")
    }

    private static func testMilestonePeriods() {
        let previous = milestoneState(claude: 100_000_000, codex: 100_000_000)
        for (period, floor) in [("day", \MilestoneState.dayFloor),
                                ("week", \MilestoneState.weekFloor),
                                ("month", \MilestoneState.monthFloor)] {
            var current = previous
            current[keyPath: floor] += 1
            expect(Milestones.shouldCelebrate(previous: previous, current: current),
                   "a \(period) crossing must trigger a celebration")
        }
        let nextYear = Calendar.current.date(byAdding: .year, value: 1, to: now)!
        let reset = milestoneState(claude: 200_000_000, codex: 200_000_000, at: nextYear)
        expect(!Milestones.shouldCelebrate(previous: previous, current: reset),
               "new calendar periods must establish new baselines")
        expect(Milestones.merged(previous: previous, current: reset) == reset,
               "completed floors must reset with their calendar periods")
    }

    private static func testPerToolMilestones() {
        let perTool = Data(#"{"tools":{"claudeCode":{"dayID":"2026-10-09","dayFloor":1,"weekID":"2026-W41","weekFloor":2,"monthID":"2026-10","monthFloor":3}}}"#.utf8)
        let restored = try? JSONDecoder().decode(MilestoneState.self, from: perTool)
        expect(restored == nil, "per-tool milestones must give way to a combined baseline")
        expect(!Milestones.shouldCelebrate(previous: restored,
                                           current: milestoneState(claude: 200_000_000, codex: 100_000_000)),
               "migration from per-tool milestones must not celebrate existing usage")
    }
}
