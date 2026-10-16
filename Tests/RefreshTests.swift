import Foundation

enum AppPaths {
    static let support = FileManager.default.temporaryDirectory.appending(path: "clio-refresh-\(UUID())")
}

enum StatsCacheReader {
    static var history: [Date: Int] = [:]
    static func dailyTokens() -> [Date: Int] { history }
}

@main
enum RefreshTests {
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    static func main() async throws {
        let root = AppPaths.support
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var requests = RefreshRequests()
        expect(requests.request(scanLogs: false), "first request starts worker")
        expect(requests.next() == false, "quota update skips logs")
        for _ in 0..<100 { expect(!requests.request(scanLogs: false), "burst shares worker") }
        expect(!requests.request(scanLogs: true), "scan joins pending batch")
        expect(!requests.request(scanLogs: false), "quota request retains scan")
        expect(requests.next() == true, "one pending scan")
        expect(requests.next() == nil, "burst drained")
        expect(requests.request(scanLogs: false), "worker restarts")
        expect(requests.next() == false && requests.next() == nil, "next batch drains")
        try await dashboard(root)
        try await codexQuota(root)
        try await codexTimingEnrichment(root)
        print("Refresh regression checks passed")
    }

    static func line(_ date: Date, id: String, tokens: Int) throws -> Data {
        let object: [String: Any] = [
            "type": "assistant", "timestamp": ISO8601DateFormatter().string(from: date),
            "uuid": id, "sessionId": "fixture", "requestId": id,
            "message": ["id": id, "model": "test", "usage": ["input_tokens": tokens, "output_tokens": 0]]
        ]
        return try JSONSerialization.data(withJSONObject: object) + Data([10])
    }

    static func codexQuota(_ root: URL) async throws {
        let now = Date()
        let logs = root.appending(path: "codex/sessions")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appending(path: "session.jsonl")
        let record: [String: Any] = [
            "type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-60)),
            "payload": ["type": "token_count", "info": ["last_token_usage": ["input_tokens": 100, "output_tokens": 20]]]
        ]
        try (JSONSerialization.data(withJSONObject: record) + Data([10])).write(to: file)
        let reader = CodexReader(root: logs, sleepHistory: { SleepTimeline() })
        let readers = LogReaders(claude: ClaudeCodeReader(root: root.appending(path: "absent"), sleepHistory: { SleepTimeline() }), codex: reader)
        func config(_ percentage: Double, resets: Int) -> [Tool: DashboardBuilder.QuotaConfig] {
            [.codex: .init(rateLimits: .init(updatedAt: now, fiveHour: .init(usedPercentage: percentage,
                           resetsAt: now.addingTimeInterval(3600)), sevenDay: nil, modelScoped: []), remainingResets: resets)]
        }
        let first = await readers.dashboard(prices: .builtin, quota: config(60, resets: 1), quotaMaxAge: 600, now: now)
        let revision = reader.revision
        let reset = await readers.dashboard(prices: .builtin, quota: config(10, resets: 0), quotaMaxAge: 600, scanLogs: false, now: now)
        expect(reset.snapshot(for: .codex)?.fiveHour?.fraction == 0.1, "manual reset lowers quota despite cached usage")
        expect(reset.snapshot(for: .codex)?.remainingResets == 0, "manual reset count updates")
        expect(reset.snapshot(for: .codex)?.usage.totals[.day]?.total == first.snapshot(for: .codex)?.usage.totals[.day]?.total,
               "manual reset preserves usage")
        expect(reader.revision == revision, "quota update does not read Codex logs")
        _ = reader.refresh()
        expect(reader.revision == revision, "unchanged Codex logs preserve revision")
        try FileManager.default.removeItem(at: file)
        _ = await readers.dashboard(prices: .builtin, quota: [:], quotaMaxAge: 600, now: now)
        expect(reader.revision > revision, "Codex deletion invalidates cache")
    }

    static func codexTimingEnrichment(_ root: URL) async throws {
        var sleeps = SleepTimeline()
        StatsCacheReader.history = [:]
        for name in ["daily-tokens.json", "codex-daily-tokens.json"] {
            try FileManager.default.removeItem(at: root.appending(path: name))
        }
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let base = root.appending(path: "codex-timing")
        let logs = base.appending(path: "sessions")
        let archived = base.appending(path: "archived_sessions")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: archived, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        let usage: [String: Any] = [
            "type": "event_msg", "timestamp": stamp,
            "payload": [
                "type": "token_count", "info": ["last_token_usage": ["input_tokens": 1000, "output_tokens": 600]],
            ],
        ]
        let response = try JSONSerialization.data(withJSONObject: usage) + Data([10])
        let model = Data("{\"type\":\"turn_context\",\"payload\":{\"model\":\"test\"}}\n".utf8)
        try (model + response).write(to: logs.appending(path: "partial.jsonl"))
        let reader = CodexReader(root: logs, sleepHistory: { sleeps })
        let readers = LogReaders(
            claude: ClaudeCodeReader(root: base.appending(path: "absent"), sleepHistory: { SleepTimeline() }),
            codex: reader)
        let first = await readers.dashboard(prices: .builtin, quota: [:], quotaMaxAge: 600, now: now)
        expect(first.combined.models[.day]?.first?.outputSpeed.tokensPerSecond == nil, "initial model has no timing")
        let context: [String: Any] = [
            "type": "turn_context",
            "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-70)), "payload": ["model": "test"],
        ]
        try (JSONSerialization.data(withJSONObject: context) + Data([10]) + response)
            .write(to: archived.appending(path: "complete.jsonl"))
        let cached = await readers.dashboard(prices: .builtin, quota: [:], quotaMaxAge: 600, scanLogs: false, now: now)
        expect(
            cached.combined.models[.day]?.first?.outputSpeed.tokensPerSecond == nil,
            "quota-only updates retain cached timing until the next log scan")
        let updated = await readers.dashboard(prices: .builtin, quota: [:], quotaMaxAge: 600, now: now)
        expect(
            updated.combined.models[.day]?.first?.outputSpeed.tokensPerSecond == 60,
            "timing-only enrichment rebuilds cached model speeds")
        expect(
            updated.combined.totals == first.combined.totals,
            "timing-only enrichment never increases cached token totals")
        expect(
            updated.snapshot(for: .codex)?.usage.models[.day]?.first?.outputSpeed.samples == 1,
            "per-tool and combined model speeds share the enriched request")
        sleeps = SleepTimeline([DateInterval(start: now.addingTimeInterval(-68), end: now.addingTimeInterval(-63))])
        let asleepCache = await readers.dashboard(
            prices: .builtin, quota: [:], quotaMaxAge: 600, scanLogs: false, now: now)
        expect(
            asleepCache.combined.models[.day]?.first?.outputSpeed.tokensPerSecond == 60,
            "quota-only updates keep cached timing until power history is scanned")
        let awake = await readers.dashboard(prices: .builtin, quota: [:], quotaMaxAge: 600, now: now)
        expect(
            awake.combined.models[.day]?.first?.outputSpeed.tokensPerSecond == 120,
            "power-history changes invalidate cached model speed even with unchanged log files")
        expect(awake.combined.totals == updated.combined.totals, "sleep correction never changes token totals")
    }

    static func dashboard(_ root: URL) async throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let now = calendar.startOfDay(for: Date()).addingTimeInterval(12 * 3600)
        let logs = root.appending(path: "claude")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let file = logs.appending(path: "session.jsonl")
        var data = Data()
        for index in 0..<3000 {
            data.append(try line(now.addingTimeInterval(Double(-index - 1)), id: "event-\(index)", tokens: 100))
        }
        try data.write(to: file)
        let claude = ClaudeCodeReader(root: logs, sleepHistory: { SleepTimeline() })
        let readers = LogReaders(claude: claude, codex: CodexReader(root: root.appending(path: "sessions"), sleepHistory: { SleepTimeline() }))
        let prices = PriceTable(prices: ["test": .make(input: 1, output: 1)])
        let start = Date()
        let first = await readers.dashboard(prices: prices, quota: [:], quotaMaxAge: 600, now: now, calendar: calendar)
        let cold = Date().timeIntervalSince(start)
        let originalTotal = first.combined.totals[.day]!.total
        expect(originalTotal > 0, "initial totals")
        let revision = claude.revision
        _ = claude.refresh()
        expect(claude.revision == revision, "unchanged logs preserve revision")
        let unrelated = try FileHandle(forWritingTo: file)
        try unrelated.seekToEnd()
        try unrelated.write(contentsOf: Data("{\"type\":\"user\"}\n".utf8))
        try unrelated.close()
        _ = claude.refresh()
        expect(claude.revision == revision, "unrelated log lines do not invalidate usage")
        let limits = RateLimitSnapshot(updatedAt: now, fiveHour: .init(usedPercentage: 40, resetsAt: now.addingTimeInterval(3600)),
                                       sevenDay: nil, modelScoped: [])
        let quota: [Tool: DashboardBuilder.QuotaConfig] = [.claudeCode: .init(rateLimits: limits)]
        let warmStart = Date()
        let warm = await readers.dashboard(prices: prices, quota: quota, quotaMaxAge: 600, scanLogs: false, now: now, calendar: calendar)
        let cached = Date().timeIntervalSince(warmStart)
        expect(warm.combined.totals[.day]?.total == originalTotal, "quota preserves usage")
        expect(warm.snapshot(for: .claudeCode)?.fiveHour?.fraction == 0.4, "quota updates percentage")
        let uncachedStart = Date()
        let uncached = DashboardBuilder.snapshot(tool: .claudeCode, events: warm.snapshot(for: .claudeCode)!.usage.rangeSource!.events,
                                                rejections: [], prices: prices, quota: quota[.claudeCode]!, now: now, calendar: calendar)
        _ = DashboardBuilder.combined([uncached.usage], events: uncached.usage.rangeSource!.events, now: now, calendar: calendar)
        let uncachedTime = Date().timeIntervalSince(uncachedStart)
        expect(uncached.usage.totals == warm.snapshot(for: .claudeCode)?.usage.totals, "cached totals equal full aggregation")
        expect(uncached.usage.costs == warm.snapshot(for: .claudeCode)?.usage.costs, "cached costs equal full aggregation")
        print(String(format: "3,000 events: uncached aggregation %.4fs, cached quota %.4fs", uncachedTime, cached))
        let ledgerPath = root.appending(path: "daily-tokens.json")
        let ledgerDate = try FileManager.default.attributesOfItem(atPath: ledgerPath.path)[.modificationDate] as! Date
        _ = await readers.dashboard(prices: prices, quota: quota, quotaMaxAge: 600, scanLogs: false, now: now, calendar: calendar)
        let currentDate = try FileManager.default.attributesOfItem(atPath: ledgerPath.path)[.modificationDate] as! Date
        expect(currentDate == ledgerDate, "quota does not rewrite ledger")
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: line(now, id: "new", tokens: 200))
        try handle.close()
        let quotaOnly = await readers.dashboard(prices: prices, quota: quota, quotaMaxAge: 600, scanLogs: false, now: now, calendar: calendar)
        expect(quotaOnly.combined.totals[.day]?.total == originalTotal, "quota update does not scan new logs")
        let changed = await readers.dashboard(prices: prices, quota: quota, quotaMaxAge: 600, now: now, calendar: calendar)
        expect(changed.combined.totals[.day]?.total == originalTotal + 200, "scheduled scan includes appended usage")
        expect(claude.revision > revision, "append invalidates cache")
        let repriced = await readers.dashboard(prices: .init(prices: ["test": .make(input: 2, output: 1)]), quota: quota,
                                                quotaMaxAge: 600, scanLogs: false, now: now, calendar: calendar)
        expect(abs(repriced.combined.costs[.day]! - Double(originalTotal + 200) * 2 / 1_000_000) < 1e-8, "price invalidates cache")
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!
        let nextDay = await readers.dashboard(prices: prices, quota: quota, quotaMaxAge: 600, scanLogs: false, now: tomorrow, calendar: calendar)
        expect(nextDay.combined.totals[.day]?.total == 0, "day boundary invalidates cache")
        expect(nextDay.snapshot(for: .claudeCode)?.fiveHour?.fraction == 0, "expired window resets")
        var shifted = calendar
        shifted.timeZone = TimeZone(secondsFromGMT: -12 * 3600)!
        let shiftedResult = await readers.dashboard(prices: prices, quota: [:], quotaMaxAge: 600, scanLogs: false, now: now, calendar: shifted)
        let expected = DashboardBuilder.snapshot(tool: .claudeCode, events: changed.snapshot(for: .claudeCode)!.usage.rangeSource!.events,
                                                 rejections: [], prices: prices, quota: .init(), now: now, calendar: shifted)
        expect(shiftedResult.combined.totals[.day]?.total == expected.usage.totals[.day]?.total, "time zone invalidates cache")
        StatsCacheReader.history = [calendar.startOfDay(for: now.addingTimeInterval(-100 * 86400)): 1234]
        let history = await readers.dashboard(prices: prices, quota: [:], quotaMaxAge: 600, scanLogs: false, now: now, calendar: calendar)
        expect(history.combined.dailyTokens.values.contains(1234), "external history invalidates cache")
        let beforeDelete = claude.revision
        try FileManager.default.removeItem(at: logs)
        let deleted = await readers.dashboard(prices: prices, quota: [:], quotaMaxAge: 600, now: now, calendar: calendar)
        expect(claude.revision > beforeDelete, "removed root invalidates cache")
        expect(deleted.snapshot(for: .claudeCode)?.usage.rangeSource?.events.isEmpty == true, "removed logs clear cached events")
        print(String(format: "3,000 events: initial %.4fs, cached quota %.4fs", cold, cached))
    }
}
