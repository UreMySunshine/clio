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
        try testCodexQuotaSources()
        testQuotaConflicts()
        try testUsageHistory()
        try testCacheWrites()
        try testLegacyUsage()
        try testCompressedLogs()
        testQuotaVisibility()
        testUnknownPrices()
        testMonthlyUnknownModel()
        testZeroPrice()
        testAutoReviewPrice()
        testCombinedUsage()
        testCombinedActivity()
        testCombinedMilestones()
        try testMilestonePersistence()
        testMilestonePeriods()
        testPerToolMilestones()
        try testCodexSpeed()
        try testCodexDelayedUsageBoundary()
        try testCodexDuplicateTiming()
        try testCodexDuplicateTimingQuality()
        try testCodexSameTimestamp()
        try testClaudeSpeed()
        try testClaudeTimingMetadata()
        try testClaudeSidechainTiming()
        try testCodexZeroUsageTiming()
        testSleepTimeline()
        testSleepHistoryCache()
        try testReaderSleepTiming()
        testSpeedAggregation()
        testModelOutputSpeed()
        testOutputSpeedFormatting()
        try testCodexLargeResponseHeaders()
        try testPreparedLogScans()
        try testBufferedLogLines()
        guard failures == 0 else {
            print("\(failures) assertions failed")
            exit(1)
        }
        print("39 usage regression scenarios passed")
    }

    private static func record(_ type: String, at seconds: Double, payload: [String: Any]) throws -> String {
        let object: [String: Any] = [
            "type": type,
            "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds)), "payload": payload,
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private static func testCodexSpeed() throws {
        let base = try directories("speed-codex")
        let file = try log(
            base, "timed",
            lines: [
                try record("turn_context", at: -100, payload: ["model": "gpt-priced"]),
                try record("response_item", at: -95, payload: ["type": "reasoning"]),
                try record("response_item", at: -90, payload: ["type": "function_call"]),
                try record(
                    "token_usage_record", at: -90,
                    payload: [
                        "usage": [
                            "input_tokens": 1000,
                            "cached_input_tokens": 600, "output_tokens": 600,
                        ]
                    ]),
                try record("response_item", at: -70, payload: ["type": "function_call_output"]),
            ])
        let reader = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() })
        expect(reader.refresh(now: now).events.isEmpty, "timing lines alone cannot create usage")
        try append(usage(-70, output: 600, total: 1600), to: file)
        let first = reader.refresh(now: now).events
        expect(
            first.count == 1 && first[0].estimatedDuration == 10,
            "Codex uses the matching response usage record and excludes tool execution across refreshes")
        try append(usage(-69, output: 600, total: 1600), to: file)
        try append(record("response_item", at: -60, payload: ["type": "message", "role": "assistant"]), to: file)
        try append(usage(-50, output: 200, total: 2800), to: file)
        let second = reader.refresh(now: now).events.sorted { $0.timestamp < $1.timestamp }
        expect(
            second.count == 2 && second[1].estimatedDuration == 20,
            "duplicate quota snapshots cannot reset the request clock")
        try append(record("event_msg", at: -40, payload: ["type": "turn_aborted"]), to: file)
        try append(record("event_msg", at: -20, payload: ["type": "task_started"]), to: file)
        try append(usage(-10, output: 400, total: 4200), to: file)
        let third = reader.refresh(now: now).events.max { $0.timestamp < $1.timestamp }
        expect(third?.estimatedDuration == 10, "an aborted request cannot carry its start into a new turn")
        _ = try log(base, "untimed", lines: [try usage(-5, output: 999, total: 1999)])
        let untimed = reader.refresh(now: now).events.first { $0.counts.output == 999 }
        expect(untimed?.estimatedDuration == nil, "Codex files cannot borrow another file's timing")
    }

    private static func testCodexDelayedUsageBoundary() throws {
        let base = try directories("speed-delayed-usage")
        let file = try log(
            base, "delayed",
            lines: [
                try record("turn_context", at: -100, payload: ["model": "gpt-priced"]),
                try record("response_item", at: -90, payload: ["type": "function_call"]),
                try record(
                    "token_usage_record", at: -90,
                    payload: [
                        "usage": [
                            "input_tokens": 1000, "cached_input_tokens": 600, "output_tokens": 600,
                        ]
                    ]),
                try record("response_item", at: -85, payload: ["type": "function_call_output"]),
                try usage(-80, output: 600, total: 1600),
            ])
        let reader = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() })
        expect(
            reader.refresh(now: now).events.first?.estimatedDuration == 10,
            "delayed usage still ends the first request at its matching usage record")
        try append(record("response_item", at: -75, payload: ["type": "message", "role": "assistant"]), to: file)
        try append(usage(-70, output: 200, total: 2800), to: file)
        let events = reader.refresh(now: now).events.sorted { $0.timestamp < $1.timestamp }
        expect(
            events.count == 2 && events[1].estimatedDuration == 15,
            "delayed token_count cannot replace the next request's earlier tool-result boundary")
        let speed = events.reduce(into: OutputSpeed()) { $0.include($1) }
        expect(speed.tokensPerSecond == 32, "delayed usage preserves the duration-weighted output speed")

        _ = try log(
            base, "mismatched",
            lines: [
                try record("turn_context", at: -60, payload: ["model": "gpt-priced"]),
                try record("response_item", at: -50, payload: ["type": "function_call"]),
                try record(
                    "token_usage_record", at: -50,
                    payload: [
                        "usage": [
                            "input_tokens": 999, "cached_input_tokens": 0, "output_tokens": 999,
                        ]
                    ]),
                try usage(-40, output: 600, total: 1600),
                try record("response_item", at: -30, payload: ["type": "message", "role": "assistant"]),
                try usage(-20, output: 200, total: 2800),
            ])
        let fallback = reader.refresh(now: now).events.filter { $0.timestamp > now.addingTimeInterval(-60) }
        expect(
            fallback.count == 2 && fallback.allSatisfy { $0.estimatedDuration == 20 },
            "unmatched usage records retain token_count as the fallback boundary")
    }

    private static func testCodexDuplicateTiming() throws {
        let base = try directories("speed-duplicate-timing")
        let response = try usage(-60, output: 600, total: 1600)
        _ = try log(
            base, "partial",
            lines: [
                #"{"type":"session_meta","payload":{"id":"original-session"}}"#, response,
            ])
        let reader = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() })
        let initial = reader.refresh(now: now).events
        expect(initial.count == 1 && initial[0].estimatedDuration == nil, "partial copy initially has no timing")
        let revision = reader.revision
        _ = try log(
            base, "complete", archived: true,
            lines: [
                #"{"type":"session_meta","payload":{"id":"archived-copy"}}"#,
                try record("turn_context", at: -70, payload: ["model": "gpt-priced"]), response,
            ])
        let completed = reader.refresh(now: now).events
        expect(
            completed.count == 1 && completed[0].estimatedDuration == 10,
            "a complete archived copy fills missing request timing without adding another event")
        expect(
            completed.first?.counts == initial.first?.counts
                && completed.first?.sessionID == "original-session"
                && completed.first?.dedupeKey == initial.first?.dedupeKey,
            "timing enrichment preserves existing tokens and request identity")
        expect(reader.revision > revision, "timing enrichment invalidates cached usage even with unchanged event count")
        let completedRevision = reader.revision
        _ = try log(base, "another-partial", lines: [response])
        let repeated = reader.refresh(now: now).events
        expect(
            repeated.count == 1 && repeated[0].estimatedDuration == 10 && reader.revision == completedRevision,
            "an incomplete duplicate cannot erase timing or invalidate the cache")
        _ = try log(
            base, "another-complete", archived: true,
            lines: [
                try record("turn_context", at: -70, payload: ["model": "gpt-priced"]), response,
            ])
        _ = reader.refresh(now: now)
        expect(reader.revision == completedRevision, "equivalent timed copies do not invalidate cached usage")
    }

    private static func testCodexDuplicateTimingQuality() throws {
        func lines(_ quality: Int, session: String) throws -> [String] {
            var result = [
                "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(session)\"}}",
                try record("turn_context", at: -100, payload: ["model": "gpt-priced"]),
                try record("response_item", at: quality == 2 ? -90 : -80, payload: ["type": "function_call"]),
            ]
            if quality == 2 {
                result.append(try record("token_usage_record", at: -90, payload: [
                    "usage": ["input_tokens": 1000, "cached_input_tokens": 600, "output_tokens": 600],
                ]))
            }
            if quality == 1 {
                result.append(try record("response_item", at: -60, payload: ["type": "function_call_output"]))
            }
            result.append(try usage(-60, output: 600, total: 1600))
            return result
        }
        for (first, second) in [(0, 2), (2, 0), (0, 1), (1, 2), (2, 1)] {
            for incremental in [false, true] {
                let base = try directories("timing-quality-\(first)-\(second)-\(incremental)")
                _ = try log(base, "active", lines: lines(first, session: "original"))
                let reader = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() })
                let initial = incremental ? reader.refresh(now: now).events.first : nil
                let initialRevision = reader.revision
                _ = try log(base, "archive", archived: true, lines: lines(second, session: "duplicate"))
                let events = reader.refresh(now: now).events
                let expected: TimeInterval = max(first, second) == 2 ? 10 : 20
                expect(events.count == 1 && events.first?.estimatedDuration == expected,
                    "duplicate timing chooses the strongest source in either scan order or incremental refresh")
                expect(events.first?.counts.output == 600 && events.first?.counts.total == 1600
                    && events.first?.sessionID == "original",
                    "timing quality does not change counts or original session identity")
                if incremental {
                    expect(events.first?.timestamp == initial?.timestamp && events.first?.dedupeKey == initial?.dedupeKey,
                        "timing quality preserves the original event identity")
                    expect(second > first ? reader.revision > initialRevision : reader.revision == initialRevision,
                        "only improved timing invalidates an incremental result")
                }
                let revision = reader.revision
                _ = try log(base, "repeated", archived: true, lines: lines(0, session: "repeated"))
                expect(reader.refresh(now: now).events.first?.estimatedDuration == expected && reader.revision == revision,
                    "a repeated fallback cannot replace precise timing or invalidate cached usage")
            }
        }
    }

    private static func testCodexSameTimestamp() throws {
        let base = try directories("codex-same-timestamp")
        for (index, output) in [600, 800].enumerated() {
            _ = try log(base, "request-\(index)", lines: [
                try record("turn_context", at: -100 + Double(index * 20), payload: ["model": "gpt-priced"]),
                try usage(-60, output: output, total: 1000 + output),
            ])
        }
        let reader = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() })
        let events = reader.refresh(now: now).events
        let speed = events.reduce(into: OutputSpeed()) { $0.include($1) }
        expect(events.count == 2 && speed.outputTokens == 1400 && speed.duration == 60 && speed.samples == 2,
            "different usage records with one timestamp keep separate counts and file-specific timing")
    }

    private static func testClaudeSpeed() throws {
        let base = root.appending(path: "speed-claude")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let file = base.appending(path: "session.jsonl")
        func line(
            _ kind: String, id: String, parent: String?, at seconds: Double,
            output: Int? = nil, complete: Bool = false, block: Int = 0
        ) throws -> String {
            var object: [String: Any] = [
                "type": kind, "uuid": id, "sessionId": "s",
                "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds)),
            ]
            object["parentUuid"] = parent
            if let output {
                var message: [String: Any] = [
                    "id": "m", "model": "claude", "usage": ["input_tokens": 10, "output_tokens": output],
                ]
                if complete { message["stop_reason"] = "end_turn" }
                object["message"] = message
                object["apiBlockIndex"] = block
            }
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let initial = [
            try line("user", id: "u", parent: nil, at: -100),
            try line("attachment", id: "a", parent: "u", at: -98),
            try line("assistant", id: "b0", parent: "a", at: -95, output: 600),
        ]
        try Data((initial.joined(separator: "\n") + "\n").utf8).write(to: file)
        let reader = ClaudeCodeReader(root: base, sleepHistory: { SleepTimeline() })
        expect(reader.refresh().events.first?.estimatedDuration == nil, "unfinished Claude output has no speed")
        let revision = reader.revision
        try append(line("assistant", id: "b1", parent: "b0", at: -90, output: 600, complete: true, block: 1), to: file)
        let completed = reader.refresh().events
        expect(
            completed.count == 1 && completed[0].estimatedDuration == 10,
            "Claude follows the first block's parent across attachments and refreshes")
        expect(reader.revision > revision, "completion with unchanged token counts invalidates cached speed")
        try append(line("assistant", id: "b2", parent: "b1", at: -88, output: 600, complete: true, block: 2), to: file)
        expect(
            reader.refresh().events.first?.estimatedDuration == 12,
            "later blocks extend duration without duplicating tokens")
        let orphan = base.appending(path: "orphan.jsonl")
        try Data(
            (try line(
                "assistant", id: "orphan", parent: "u", at: -80, output: 600,
                complete: true, block: 1) + "\n").utf8
        ).write(to: orphan)
        expect(reader.refresh().events.count == 1, "replayed blocks cannot duplicate Claude usage")
    }

    private static func testClaudeTimingMetadata() throws {
        let base = root.appending(path: "claude-timing-metadata")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        let midnight = calendar.startOfDay(for: now)
        let formatter = ISO8601DateFormatter()
        func block(at date: Date, complete: Bool) throws -> String {
            var message: [String: Any] = [
                "id": "same-message", "model": complete ? "later-model" : "original-model",
                "usage": ["input_tokens": 10, "output_tokens": 600],
            ]
            if complete { message["stop_reason"] = "end_turn" }
            let object: [String: Any] = [
                "type": "assistant", "timestamp": formatter.string(from: date),
                "uuid": complete ? "final" : "first", "parentUuid": complete ? "first" : "user",
                "requestId": "request", "sessionId": complete ? "later-session" : "original-session",
                "apiBlockIndex": complete ? 1 : 0, "message": message,
            ]
            return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        }
        let user: [String: Any] = [
            "type": "user", "uuid": "user", "timestamp": formatter.string(from: midnight.addingTimeInterval(-10)),
        ]
        let file = base.appending(path: "session.jsonl")
        let initial =
            try String(decoding: JSONSerialization.data(withJSONObject: user), as: UTF8.self)
            + "\n" + block(at: midnight.addingTimeInterval(-5), complete: false) + "\n"
        try Data(initial.utf8).write(to: file)
        let reader = ClaudeCodeReader(root: base, sleepHistory: { SleepTimeline() })
        let first = reader.refresh().events
        let ledger = UsageLedger.updated(
            nil, events: first, history: [:], now: now, retentionDays: nil, calendar: calendar)
        let revision = reader.revision
        try append(block(at: midnight.addingTimeInterval(5), complete: true), to: file)
        let enriched = reader.refresh().events
        expect(enriched.count == 1 && enriched[0].estimatedDuration == 15, "Claude timing is enriched across midnight")
        expect(
            enriched.first?.timestamp == first.first?.timestamp && enriched.first?.model == first.first?.model
                && enriched.first?.sessionID == first.first?.sessionID && enriched.first?.counts == first.first?.counts
                && enriched.first?.dedupeKey == first.first?.dedupeKey,
            "equal-count timing enrichment preserves every existing Claude event field")
        let updated = UsageLedger.updated(
            ledger, events: enriched, history: [:], now: now, retentionDays: nil, calendar: calendar)
        expect(updated == ledger, "cross-midnight enrichment cannot add the same tokens to a second ledger day")
        expect(reader.revision > revision, "preserving Claude metadata still invalidates cached speed")
    }

    private static func testClaudeSidechainTiming() throws {
        for sidechainFirst in [false, true] {
            for mismatched in [false, true] {
                let base = root.appending(path: "claude-sidechain-\(sidechainFirst)-\(mismatched)")
                try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                let formatter = ISO8601DateFormatter()
                func block(sidechain: Bool, at seconds: Double, index: Int) throws -> String {
                    let object: [String: Any] = [
                        "type": "assistant", "uuid": "block-\(sidechain)-\(index)", "parentUuid": "user",
                        "timestamp": formatter.string(from: now.addingTimeInterval(seconds)),
                        "sessionId": "session", "requestId": "request", "isSidechain": sidechain,
                        "apiBlockIndex": index,
                        "message": ["id": "message", "model": sidechain ? "side-model" : "main-model",
                            "stop_reason": "end_turn",
                            "usage": ["input_tokens": 10, "output_tokens": sidechain && mismatched ? 700 : 600]],
                    ]
                    return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
                }
                let user: [String: Any] = ["type": "user", "uuid": "user",
                    "timestamp": formatter.string(from: now.addingTimeInterval(-100))]
                let sideLines = try String(decoding: JSONSerialization.data(withJSONObject: user), as: UTF8.self)
                    + "\n" + block(sidechain: true, at: -90, index: 0) + "\n"
                let mainLines = try block(sidechain: false, at: -80, index: 1) + "\n"
                let firstFile = base.appending(path: sidechainFirst ? "side.jsonl" : "main.jsonl")
                let secondFile = base.appending(path: sidechainFirst ? "main.jsonl" : "side.jsonl")
                try Data((sidechainFirst ? sideLines : mainLines).utf8).write(to: firstFile)
                let reader = ClaudeCodeReader(root: base, sleepHistory: { SleepTimeline() })
                _ = reader.refresh()
                let initialRevision = reader.revision
                try Data((sidechainFirst ? mainLines : sideLines).utf8).write(to: secondFile)
                let events = reader.refresh().events
                let expected: TimeInterval? = mismatched ? nil : 10
                expect(events.count == 1 && events.first?.estimatedDuration == expected,
                    "matching sidechain timing survives either arrival order; different counts cannot supply timing")
                expect(events.first?.model == "main-model" && events.first?.counts.output == 600
                    && events.first?.sessionID == "session"
                    && events.first?.timestamp == ISO8601.date(from: formatter.string(from: now.addingTimeInterval(-80))),
                    "the non-sidechain copy supplies event metadata and counts")
                expect(sidechainFirst || !mismatched ? reader.revision > initialRevision : reader.revision == initialRevision,
                    "only a preferred copy or valid timing enrichment invalidates cached usage")
                let fresh = ClaudeCodeReader(root: base, sleepHistory: { SleepTimeline() }).refresh().events
                expect(fresh.count == 1 && fresh.first?.estimatedDuration == expected && fresh.first?.model == "main-model",
                    "a complete scan preserves main metadata and matching sidechain timing")
                let sideFile = base.appending(path: "side.jsonl")
                try append(block(sidechain: true, at: -85, index: 1), to: sideFile)
                let extended = reader.refresh().events
                expect(extended.first?.estimatedDuration == (mismatched ? nil : 15)
                    && extended.first?.timestamp == events.first?.timestamp && extended.first?.counts == events.first?.counts,
                    "later sidechain blocks extend matching timing without moving or duplicating the main event")
                let revision = reader.revision
                _ = reader.refresh()
                expect(reader.revision == revision, "unchanged sidechain copies retain cached usage")
            }
        }
    }

    private static func testCodexZeroUsageTiming() throws {
        let base = try directories("codex-zero-timing")
        let zero: [String: Any] = [
            "type": "token_count",
            "info": [
                "last_token_usage": ["input_tokens": 0, "output_tokens": 0],
                "total_token_usage": ["input_tokens": 0, "output_tokens": 0],
            ],
            "rate_limits": ["primary": ["used_percent": 20, "window_minutes": 300]],
        ]
        let file = try log(
            base, "request",
            lines: [
                try record("turn_context", at: -100, payload: ["model": "gpt-priced"]),
                try record("response_item", at: -95, payload: ["type": "reasoning"]),
                try record("event_msg", at: -90, payload: zero),
            ])
        let reader = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() })
        let empty = reader.refresh(now: now)
        expect(empty.events.isEmpty && empty.quota?.fiveHour?.usedPercentage == 20, "zero snapshots still update quota")
        try append(usage(-80, output: 600, total: 1600), to: file)
        let result = reader.refresh(now: now).events
        expect(
            result.count == 1 && result[0].estimatedDuration == 20,
            "zero usage cannot consume an observed request timer")
        try append(record("event_msg", at: -75, payload: zero), to: file)
        try append(record("response_item", at: -70, payload: ["type": "message", "role": "assistant"]), to: file)
        try append(usage(-60, output: 600, total: 3200), to: file)
        let next = reader.refresh(now: now).events.sorted { $0.timestamp < $1.timestamp }
        expect(
            next.count == 2 && next[1].estimatedDuration == 20,
            "zero usage before output cannot shift the next boundary")
    }

    private static func testSleepTimeline() {
        func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
        let timeline = SleepTimeline([
            DateInterval(start: date(60), end: date(80)),
            DateInterval(start: date(10), end: date(30)),
            DateInterval(start: date(20), end: date(40)),
            DateInterval(start: date(10), end: date(30)),
        ])
        expect(timeline.intervals.count == 2, "duplicate and overlapping sleeps are merged")
        expect(timeline.estimatedDuration(from: date(0), to: date(100)) == 50, "only overlapping sleep is subtracted")
        expect(
            timeline.estimatedDuration(from: date(25), to: date(70)) == 20, "partial sleeps at both edges are clipped")
        expect(
            timeline.estimatedDuration(from: date(40), to: date(60)) == 20,
            "touching interval edges do not remove awake time")
        expect(
            timeline.estimatedDuration(from: date(12), to: date(20)) == nil,
            "an entirely sleeping request has no timing")
        expect(
            timeline.estimatedDuration(from: nil, to: date(100)) == nil, "sleep history cannot invent a missing start")
        expect(timeline.estimatedDuration(from: date(100), to: date(0)) == nil, "backwards requests remain invalid")
        expect(timeline.estimatedDuration(from: date(100), to: date(100)) == nil, "equal timestamps have no duration")
        expect(
            timeline.estimatedDuration(from: date(100), to: date(1000)) == 900,
            "real slow requests without sleep remain eligible")
        let longSleep = SleepTimeline([DateInterval(start: date(10), end: date(7200))])
        expect(
            longSleep.estimatedDuration(from: date(0), to: date(7210)) == 20,
            "sleep is removed before the one-hour limit")
        let parsed = SleepTimeline.parse(
            """
            2026-10-16 03:52:33 +0800 Sleep  Entering Sleep state due to 'Maintenance Sleep':TCPKeepAlive=active Using AC (Charge:100%) 972 secs
            2026-10-16 04:08:45 +0800 DarkWake  DarkWake from Deep Idle Using AC 45 secs
            2026-10-15 19:52:33 +0000 Sleep  Entering Sleep state due to 'Maintenance Sleep' Using AC 972 secs
            2026-10-16 04:09:30 +0800 Sleep  Entering Sleep state due to 'Maintenance Sleep' Using AC
            2026-10-16 04:09:30 +0800 Assertions  Entering Sleep state 999 secs
            invalid timestamp Sleep Entering Sleep state 999 secs
            """)
        expect(
            parsed.intervals.count == 1 && parsed.intervals[0].duration == 972,
            "pmset parsing ignores wake, incomplete and unrelated records")
        expect(
            parsed.intervals.first?.start == ISO8601.date(from: "2026-10-15T19:52:33Z"),
            "power timestamps preserve timezone and date boundaries")
    }

    private static func testSleepHistoryCache() {
        var wall = now
        var uptime: TimeInterval = 100
        var reads = 0
        let history = SleepHistory(
            load: {
                reads += 1
                return ""
            }, clock: { (wall, uptime) })
        _ = history.snapshot()
        wall.addTimeInterval(20)
        uptime += 20
        _ = history.snapshot()
        expect(reads == 1, "awake refreshes reuse power history without starting another process")
        wall.addTimeInterval(1000)
        _ = history.snapshot()
        expect(reads == 2, "sleep between scans reloads power history")
        _ = history.snapshot()
        expect(reads == 2, "readers share the refreshed power-history cache")
        wall.addTimeInterval(-10)
        uptime += 1
        _ = history.snapshot()
        expect(reads == 3, "wall-clock corrections invalidate the power-history cache")
        var failures = 0
        let unavailable = SleepHistory(
            load: {
                failures += 1
                return nil
            }, clock: { (wall, uptime) })
        expect(unavailable.snapshot().intervals.isEmpty, "unavailable power history does not interrupt usage scanning")
        _ = unavailable.snapshot()
        expect(failures == 1, "unavailable power history does not spawn a command on every refresh")
    }

    private static func testReaderSleepTiming() throws {
        let anchor = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970))
        var sleeps = SleepTimeline()
        let corrected = SleepTimeline([
            DateInterval(start: anchor.addingTimeInterval(-90), end: anchor.addingTimeInterval(-20))
        ])
        let base = try directories("sleep-timing")
        let lines = try [
            record("turn_context", at: -100, payload: ["model": "gpt-priced"]),
            record("response_item", at: -10, payload: ["type": "message", "role": "assistant"]),
            usage(-10, output: 600, total: 1600),
        ]
        _ = try log(base, "request", lines: lines)
        _ = try log(base, "copy", archived: true, lines: lines)
        let codex = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { sleeps })
        let initial = codex.refresh(now: now).events
        expect(
            initial.count == 1 && initial[0].estimatedDuration == 90,
            "initial Codex timing can precede power-history completion")
        let revision = codex.revision
        sleeps = corrected
        let updated = codex.refresh(now: now).events
        expect(
            updated.count == 1 && updated[0].estimatedDuration == 20,
            "changed sleep history replays active and archived files without duplicates")
        expect(
            updated.first?.counts == initial.first?.counts && updated.first?.dedupeKey == initial.first?.dedupeKey,
            "sleep correction preserves Codex tokens and identity")
        expect(codex.revision > revision, "sleep-only corrections invalidate cached usage")
        let stableRevision = codex.revision
        _ = codex.refresh(now: now)
        expect(codex.revision == stableRevision, "unchanged sleep history preserves incremental scanning")

        let claudeRoot = base.appending(path: "claude")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        let formatter = ISO8601DateFormatter()
        let user: [String: Any] = [
            "type": "user", "uuid": "u", "timestamp": formatter.string(from: anchor.addingTimeInterval(-100)),
        ]
        let response: [String: Any] = [
            "type": "assistant", "uuid": "a", "parentUuid": "u",
            "timestamp": formatter.string(from: anchor.addingTimeInterval(-10)),
            "message": [
                "id": "m", "model": "claude", "stop_reason": "end_turn",
                "usage": ["input_tokens": 10, "output_tokens": 600],
            ],
        ]
        try
            (JSONSerialization.data(withJSONObject: user) + Data([10])
            + JSONSerialization.data(withJSONObject: response) + Data([10]))
            .write(to: claudeRoot.appending(path: "request.jsonl"))
        sleeps = SleepTimeline()
        let claude = ClaudeCodeReader(root: claudeRoot, sleepHistory: { sleeps })
        let before = claude.refresh().events
        expect(before.first?.estimatedDuration == 90, "Claude retains its original parent-chain timing")
        sleeps = corrected
        let after = claude.refresh().events
        expect(
            after.first?.estimatedDuration == 20 && after.first?.timestamp == before.first?.timestamp,
            "Claude subtracts the same sleep history without moving the event")
    }

    private static func testSpeedAggregation() {
        expect(
            ISO8601.date(from: "2026-10-15T12:34:56.789Z") == ISO8601.date(from: "2026-10-15T20:34:56.789+08:00"),
            "timestamp parsing preserves timezone offsets")
        expect(
            ISO8601.date(from: "2026-10-15T12:34:56Z") != nil
                && ISO8601.date(from: "2026-10-15T12:34:56.123456Z") != nil
                && ISO8601.date(from: "invalid") == nil,
            "timestamp parsing handles whole seconds, fractions and invalid records")
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        func event(_ tokens: Int, _ seconds: Double?, at date: Date? = nil) -> UsageEvent {
            UsageEvent(
                timestamp: date ?? noon, model: "gpt-priced", counts: TokenCounts(output: tokens),
                dedupeKey: UUID().uuidString, estimatedDuration: seconds)
        }
        let today = [
            event(1000, 10), event(200, 20), event(199, 1), event(500, 0.5),
            event(500, nil), event(500, 3601), event(500, -1), event(500, .nan),
            event(500, 0), event(500, .infinity),
        ]
        let yesterday = calendar.date(byAdding: .day, value: -1, to: noon)!
        let events = today + [event(600, 10, at: yesterday)]
        let summary = DashboardBuilder.snapshot(
            tool: .codex, events: events, rejections: [], prices: prices,
            quota: .init(), now: noon, calendar: calendar
        ).usage
        expect(
            summary.outputSpeeds[.day]?.tokensPerSecond == 40 && summary.outputSpeeds[.day]?.samples == 2,
            "speed uses summed output / summed duration, excluding tiny, missing and implausible samples")
        expect(summary.outputSpeeds[.recentWeek]?.tokensPerSecond == 45, "speed follows the selected period")
        let custom = DashboardBuilder.selecting(
            summary,
            range: UsageDateRange(
                start: yesterday, end: yesterday,
                today: noon, calendar: calendar), calendar: calendar)
        expect(
            custom.outputSpeeds[.custom]?.tokensPerSecond == 60, "custom dates recalculate speed from their own events")
        var other = UsageSummary.empty
        other.outputSpeeds[.day] = OutputSpeed(outputTokens: 600, duration: 10, samples: 1)
        let combined = DashboardBuilder.combined([summary, other], events: events, now: noon, calendar: calendar)
        expect(combined.outputSpeeds[.day]?.tokensPerSecond == 45, "combined speed weights each tool by timed duration")
        expect(
            UsageSummary.empty.outputSpeeds[.day]?.tokensPerSecond == nil, "missing samples cannot display zero speed")
        var limit = OutputSpeed()
        limit.include(event(200, 1))
        limit.include(event(200, 3600))
        expect(limit.samples == 2, "output and duration thresholds are inclusive")
        let components = calendar.dateComponents([.year, .month, .day], from: noon)
        let dayKey = String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
        let ledger = UsageLedger(days: [dayKey: 1_000_000])
        let partial = DashboardBuilder.snapshot(
            tool: .codex, events: events, rejections: [], prices: prices,
            quota: .init(), ledger: ledger, now: noon, calendar: calendar
        ).usage
        expect(
            partial.outputSpeeds[.day]?.tokensPerSecond == nil, "daily totals without raw details cannot invent speed")
        let incomplete = DashboardBuilder.combined([summary, partial], events: events, now: noon, calendar: calendar)
        expect(
            incomplete.models[.day]?.isEmpty == true && incomplete.outputSpeeds[.day]?.tokensPerSecond == nil,
            "combined usage with missing history cannot report another tool's speed as its overall speed")
    }

    private static func testOutputSpeedFormatting() {
        func speed(_ tokens: Int, _ seconds: Double) -> OutputSpeed {
            var result = OutputSpeed()
            result.include(UsageEvent(
                timestamp: now, model: "slow", counts: TokenCounts(output: tokens),
                dedupeKey: UUID().uuidString, estimatedDuration: seconds))
            return result
        }
        expect(Format.outputSpeed(speed(200, 500)) == "≈ 0.4 tok/s", "slow valid output does not round to zero")
        expect(Format.outputSpeed(speed(200, 3600)) == "≈ 0.056 tok/s", "minimum eligible rate retains precision")
        expect(Format.outputSpeed(speed(200, 250)) == "≈ 0.8 tok/s", "sub-token rates retain their fractional value")
        expect(Format.outputSpeed(speed(200, 200)) == "≈ 1 tok/s", "one-token rate keeps integer formatting")
        expect(Format.outputSpeed(speed(604, 10)) == "≈ 60 tok/s", "ordinary output retains integer formatting")
        expect(Format.outputSpeed(OutputSpeed()) == "—", "missing samples remain unavailable")
    }

    private static func testModelOutputSpeed() {
        let calendar = Calendar.current
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: now)!
        let yesterday = calendar.date(byAdding: .day, value: -1, to: noon)!
        func event(_ model: String, _ tokens: Int, _ duration: Double?, at date: Date? = nil) -> UsageEvent {
            UsageEvent(
                timestamp: date ?? noon, model: model, counts: TokenCounts(output: tokens),
                dedupeKey: UUID().uuidString, estimatedDuration: duration)
        }
        let events = [
            event("gpt-priced", 1000, 10), event("gpt-priced", 200, 20),
            event("gpt-priced", 199, 1), event("slow", 900, 30), event("slow", 1000, nil),
            event("untimed", 600, nil), event("gpt-priced", 600, 10, at: yesterday),
        ]
        let codex = DashboardBuilder.snapshot(
            tool: .codex, events: events, rejections: [], prices: prices,
            quota: .init(), now: noon, calendar: calendar
        ).usage
        let models = codex.models[.day] ?? []
        expect(
            models.first { $0.model == "gpt-priced" }?.outputSpeed.tokensPerSecond == 40,
            "each model uses only its eligible output and duration")
        expect(
            models.first { $0.model == "slow" }?.outputSpeed.tokensPerSecond == 30,
            "other models and untimed responses do not dilute a model's speed")
        expect(
            models.first { $0.model == "untimed" }?.outputSpeed.tokensPerSecond == nil,
            "a model without timing remains visible with unavailable speed")
        let otherEvents = [event("gpt-priced", 600, 10)]
        let claude = DashboardBuilder.snapshot(
            tool: .claudeCode, events: otherEvents, rejections: [], prices: prices,
            quota: .init(), now: noon, calendar: calendar
        ).usage
        let combined = DashboardBuilder.combined(
            [codex, claude], events: events + otherEvents, now: noon, calendar: calendar)
        let merged = combined.models[.day]?.first { $0.model == "gpt-priced" }
        expect(
            merged?.outputSpeed.tokensPerSecond == 45 && merged?.outputSpeed.samples == 3,
            "the same model across tools merges sample totals rather than averaging speeds")
        let custom = DashboardBuilder.selecting(
            codex,
            range: UsageDateRange(
                start: yesterday, end: yesterday,
                today: noon, calendar: calendar), calendar: calendar)
        expect(
            custom.models[.custom]?.count == 1 && custom.models[.custom]?.first?.outputSpeed.tokensPerSecond == 60,
            "custom dates recompute model speeds from the selected requests")
        expect(
            claude.models[.day]?.first?.outputSpeed.tokensPerSecond == 60,
            "a single tool keeps its own model speed after combined aggregation")
    }

    private static func testCodexLargeResponseHeaders() throws {
        let body = try String(
            decoding: JSONEncoder().encode(
                String(
                    repeating:
                        "工具输出 🧪 \\\"type\\\":\\\"token_count\\\" response_item model text\n", count: 200)),
            as: UTF8.self)
        let variants = [
            "{\"type\":\"function_call\",\"id\":null,\"arguments\":\(body)}",
            "{\"type\":\"custom_tool_call\",\"id\":null,\"input\":\(body)}",
            "{\"type\":\"reasoning\",\"id\":null,\"summary\":[{\"text\":\(body)}]}",
            "{\"type\":\"message\",\"id\":null,\"role\":\"assistant\",\"content\":[{\"text\":\(body)}]}",
            "{\"type\":\"message\",\"content\":[{\"text\":\(body)}],\"role\":\"assistant\"}",
            "{\"content\":[{\"text\":\(body)}],\"type\":\"message\",\"role\":\"assistant\"}",
            "{\"type\":\"message\",\"role\":\"assis\\u0074ant\",\"content\":[{\"text\":\(body)}]}",
            "{\"type\":\"function_call\",\"arguments\":\(body),\"model\":\"gpt-other\"}",
            "{\"metadata\":{\"values\":[1,2,3]},\"type\":\"function_call\",\"arguments\":\(body)}",
        ]
        func envelope(_ payload: String, at seconds: Double, reordered: Bool, type: String = "response_item") throws
            -> String
        {
            let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(seconds))
            if reordered {
                return "{\"payload\":\(payload),\"type\":\"\(type)\",\"timestamp\":\"\(stamp)\"}"
            }
            return
                "{ \"timestamp\" : \"\(stamp)\", \"ordinal\": 7, \"type\" : \"\(type)\", \"payload\":\(payload)}"
        }
        for (index, payload) in variants.enumerated() {
            var readings: [[UsageEvent]] = []
            for reordered in [false, true] {
                let base = try directories("large-header-\(index)-\(reordered)")
                let tool = "{\"type\":\"custom_tool_call_output\",\"id\":null,\"call_id\":\"tool\",\"output\":\(body)}"
                let extraModel = index == 0 ? ",\"model\":\"gpt-event\"" : ""
                let ignored = "{\"type\":\"agent_message\",\"message\":\(body)\(extraModel)}"
                let started = "{\"type\":\"task_started\",\"message\":\(body)}"
                _ = try log(
                    base, "response",
                    lines: [
                        #"{"type":"session_meta","payload":{"id":"header-fixture"}}"#,
                        try record("turn_context", at: -110, payload: ["model": "gpt-priced"]),
                        try envelope(started, at: -100, reordered: reordered, type: "event_msg"),
                        try envelope(ignored, at: -96, reordered: reordered, type: "event_msg"),
                        try envelope(payload, at: -90, reordered: reordered),
                        try usage(-90, output: 600, total: 1600),
                        try envelope(tool, at: -80, reordered: reordered),
                        try record("response_item", at: -70, payload: ["type": "message", "role": "assistant"]),
                        try usage(-70, output: 200, total: 2800),
                    ])
                readings.append(
                    CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() }).refresh(now: now)
                        .events.sorted { $0.timestamp < $1.timestamp })
            }
            expect(readings.allSatisfy { $0.count == 2 }, "large response variant \(index) retains both requests")
            for (fast, fallback) in zip(readings[0], readings[1]) {
                expect(
                    fast.counts == fallback.counts && fast.model == fallback.model
                        && fast.timestamp == fallback.timestamp && fast.sessionID == fallback.sessionID
                        && fast.dedupeKey == fallback.dedupeKey && fast.estimatedDuration == fallback.estimatedDuration,
                    "large response variant \(index) agrees across envelope layouts")
                expect(fast.estimatedDuration == 10, "large response bodies cannot override timing metadata")
            }
            if index == 7 {
                expect(
                    readings[0].allSatisfy { $0.model == "gpt-other" },
                    "model changes after a large body remain visible")
            }
            if index == 0 {
                expect(
                    readings[0].allSatisfy { $0.model == "gpt-event" },
                    "event models after a large message retain the original attribution")
            }
        }
    }

    private static func testPreparedLogScans() throws {
        let base = try directories("prepared-scans").appending(path: "sessions")
        let file = base.appending(path: "events.jsonl")
        try Data("first\npar".utf8).write(to: file)
        let scanner = LogScanner(root: base)
        var lines: [String] = []
        let first = scanner.prepare()
        expect(!first.needsRebuild, "a new scanner needs no rebuild")
        expect(
            scanner.scan(first) { _, line in lines.append(String(decoding: line, as: UTF8.self)) } == 1
                && lines == ["first"], "prepared scans consume only complete lines")
        let unchanged = scanner.prepare()
        expect(
            !unchanged.needsRebuild && scanner.scan(unchanged) { _, _ in } == 0,
            "unchanged files skip content reads")
        try append("tial", to: file)
        lines.removeAll()
        let appended = scanner.prepare()
        expect(!appended.needsRebuild, "appending to a file preserves incremental state")
        scanner.scan(appended) { _, line in lines.append(String(decoding: line, as: UTF8.self)) }
        expect(lines == ["partial"], "incremental reads retain a previously incomplete suffix")
        try Data("replacement\nextra\n".utf8).write(to: file, options: .atomic)
        let replaced = scanner.prepare()
        expect(replaced.needsRebuild, "atomic replacement invalidates a prepared scan")
        scanner.reset()
        lines.removeAll()
        scanner.scan(replaced) { _, line in lines.append(String(decoding: line, as: UTF8.self)) }
        expect(lines == ["replacement", "extra"], "the same metadata snapshot replays a replacement after reset")
        try FileManager.default.removeItem(at: file)
        let deleted = scanner.prepare()
        expect(deleted.needsRebuild, "deleted files remain detectable in the single metadata walk")
        scanner.reset()
        expect(scanner.scan(deleted) { _, _ in } == 0, "deleted files cannot replay stale content")
    }

    private static func testBufferedLogLines() throws {
        let base = try directories("buffered-lines")
        let logs = base.appending(path: "sessions")
        let file = logs.appending(path: "chunks.jsonl")
        let first = Data(repeating: 0x61, count: 256 * 1024 - 1)
        let second = Data(String(repeating: "中🧪", count: 150_000).utf8)
        let tail = Data(repeating: 0x62, count: 256 * 1024 + 11)
        try (first + Data([10, 10]) + second + Data([10]) + tail).write(to: file)
        let scanner = LogScanner(root: logs)
        let prepared = scanner.prepare()
        let hidden = base.appending(path: "temporarily-unavailable")
        try FileManager.default.moveItem(at: file, to: hidden)
        var lines: [Data] = []
        scanner.scan(prepared) { _, line in lines.append(Data(line)) }
        expect(lines.isEmpty, "a temporarily unavailable file emits no partial records")
        try FileManager.default.moveItem(at: hidden, to: file)
        let restored = scanner.prepare()
        expect(!restored.needsRebuild, "restoring the same file retains metadata and incremental state")
        scanner.scan(restored) { _, line in lines.append(Data(line)) }
        expect(lines == [first, second], "reads retry and preserve UTF-8 lines across several buffer boundaries")
        try append("尾", to: file)
        lines.removeAll()
        scanner.scan { _, line in lines.append(Data(line)) }
        expect(lines == [tail + Data("尾".utf8)], "a large incomplete trailing line is resumed exactly once")
        expect(scanner.scan { _, _ in } == 0, "unchanged buffered logs do not read file contents again")
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
        let reader = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() })
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

    private static func testCompressedLogs() throws {
        // Zstandard 1.5.7 frames with checksums and no declared content size.
        // The first contains session metadata, a model, and 110 tokens; the
        // second adds a 220-token request with a different timestamp.
        let first = Data(
            base64Encoded:
                "KLUv/QRYLQYAEo0mHXCn1QHWIzURPyhNwhDaEOo1wPQzRM0PZl/ph78mQ4wxpolpjtTbL2ka7ksCoKUEldRLpjln+JwaiSFqTseT8yVw7OXt4CrktGAHMk/mKYxAGiINEVBk8fPXUrM21i83uKF2aqCqGPKIfsbPD13b+kDbrUIOgT3E+JUUITSxlFmR11b9fLEn5yvtUUjv5am1IbeMWfnn+gr9JA8AIACOgRVv4OYMAW/HJmf0lBXHOeUTT5+BPRKLmSfrXMkAJG1AC3uUi89g"
        )!
        let second = Data(
            base64Encoded:
                "KLUv/QRYnQQAYokdHWA1bgOw/BA7Kr+pBapgkTKmKLg0sFExFCiCDIMcgffey6LQt5dI2V59TNRuHXOQDj4Yaxwzkb45ppI3eka2udRtlTf6ZVDJ8a3cMpJigNX6Y5fCLDu+cFIzFR1CHiIPIUCJrmfLduMl6eORtqRWHMDXM2P6TQkAOAZWvIGbMwS8HZuc0VPWON3fB4+AKHAUMg4Ipw=="
        )!
        let base = try directories("compressed")
        let file = base.appending(path: "sessions/events.jsonl.zst")
        try first.write(to: file)
        let fixtureNow = ISO8601.date(from: "2026-10-10T12:01:00Z")!
        let reader = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() })
        let initial = reader.refresh(now: fixtureNow).events
        expect(initial.count == 1 && initial[0].counts.total == 110, "compressed session usage is counted")
        expect(
            initial.first?.model == "gpt-priced" && initial.first?.counts.cacheRead == 40,
            "compressed logs retain model and cache breakdown")
        expect(initial.first?.sessionID == "compressed-thread", "compressed session metadata is read")
        expect(reader.refresh(now: fixtureNow).events.count == 1, "unchanged archives are not counted twice")
        let scanner = LogScanner(root: base.appending(path: "sessions"))
        expect(
            scanner.scan { _, _ in } == 1 && scanner.scan { _, _ in } == 0,
            "unchanged compressed files are not decompressed again")

        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: second)
        try handle.close()
        expect(
            reader.refresh(now: fixtureNow).events.reduce(0) { $0 + $1.counts.total } == 330,
            "concatenated Zstandard frames are read after an archive changes")

        let duplicate = try log(
            base, "duplicate",
            lines: [
                #"{"timestamp":"2026-10-10T12:00:00Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":100,"cached_input_tokens":40,"output_tokens":10,"total_tokens":110},"total_token_usage":{"total_tokens":110}}}}"#,
                #"{"timestamp":"2026-10-10T12:00:01Z","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":200,"cached_input_tokens":80,"output_tokens":20,"total_tokens":220},"total_token_usage":{"total_tokens":330}}}}"#,
            ])
        expect(
            reader.refresh(now: fixtureNow).events.count == 2, "plain and compressed copies are deduplicated")
        try FileManager.default.removeItem(at: duplicate)
        expect(
            reader.refresh(now: fixtureNow).events.count == 2,
            "compression preserves usage after the plain copy is removed")
        let archived = base.appending(path: "archived_sessions/events.jsonl.zst")
        try FileManager.default.moveItem(at: file, to: archived)
        expect(
            reader.refresh(now: fixtureNow).events.count == 2,
            "moving compressed logs to archives preserves usage")
        expect(
            CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() }).refresh(now: fixtureNow).events.count == 2,
            "a fresh reader imports compressed archived logs")

        var corrupt = first + second
        corrupt[corrupt.count - 1] ^= 1
        try corrupt.write(to: archived, options: .atomic)
        expect(reader.refresh(now: fixtureNow).events.isEmpty, "a checksum failure rejects the whole archive")
        try (first + second.dropLast(2)).write(to: archived, options: .atomic)
        expect(
            reader.refresh(now: fixtureNow).events.isEmpty,
            "an incomplete final frame does not import earlier frames")
        try first.write(to: archived, options: .atomic)
        expect(
            reader.refresh(now: fixtureNow).events.count == 1, "repaired compressed archives are rescanned")
        try FileManager.default.removeItem(at: archived)
        expect(reader.refresh(now: fixtureNow).events.isEmpty, "deleted compressed logs disappear from usage")
    }

    private static func testArchiveMove() throws {
        let base = try directories("move")
        let file = try log(base, "moving", lines: [try usage(-60)])
        let reader = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() })
        expect(reader.refresh(now: now).events.count == 1, "initial active usage")
        let archived = base.appending(path: "archived_sessions/moving.jsonl")
        try FileManager.default.moveItem(at: file, to: archived)
        expect(reader.refresh(now: now).events.count == 1, "moving a log must not double its usage")
        try append(usage(-50, total: 2200), to: archived)
        expect(reader.refresh(now: now).events.count == 2, "new archived content must be read incrementally")
        let restarted = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() })
        expect(restarted.refresh(now: now).events.count == 2, "restart must retain archived usage")
    }

    private static func testArchiveOnly() throws {
        let base = try directories("archive-only")
        try FileManager.default.removeItem(at: base.appending(path: "sessions"))
        _ = try log(base, "only", archived: true, lines: [try usage(-60)])
        let reader = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() })
        expect(reader.isAvailable, "archived logs alone must make Codex available")
        expect(reader.refresh(now: now).events.count == 1, "archived logs alone must be counted")
    }

    private static func testUpgrade() throws {
        let base = try directories("upgrade")
        let file = try log(base, "upgrade", lines: [try usage(-60, plan: "plus", fiveHour: true)])
        let reader = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() })
        expect(reader.refresh(now: now).events.count == 1, "usage before a plan upgrade must be counted")
        try append(usage(-50, total: 2200), to: file)
        let result = reader.refresh(now: now)
        expect(PlanReader.codexDisplayName(for: "prolite") == "Pro 5×", "prolite must display as Pro 5×")
        expect(result.events.reduce(0, { $0 + $1.counts.total }) == 2200, "upgrade must retain earlier usage")
        try append(usage(-40, total: 3300, plan: "pro"), to: file)
        expect(reader.refresh(now: now).events.reduce(0, { $0 + $1.counts.total }) == 3300,
               "a further plan change must retain all usage")
        expect(PlanReader.codexDisplayName(for: "pro") == "Pro 20×", "Codex pro must display as Pro 20×")
        let claudeConfig = Data(#"{"oauthAccount":{"organizationType":"claude_pro"}}"#.utf8)
        expect(PlanReader.parse(claudeConfig) == "Pro", "Claude Pro must keep its own plan label")
    }

    private static func testCodexQuotaSources() throws {
        let base = try directories("quota-sources")
        let file = try log(base, "live", lines: [try usage(-60, fiveHour: true)])
        let reader = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() })
        let initial = reader.refresh(now: now)
        expect(initial.quota?.fiveHour?.usedPercentage == 20, "local short-window quota is read")
        expect(initial.quota?.sevenDay?.usedPercentage == 10, "local weekly quota is read")
        let api = RateLimitSnapshot(updatedAt: now.addingTimeInterval(-55),
                                   sevenDay: .init(usedPercentage: 40, resetsAt: now.addingTimeInterval(86400)), modelScoped: [])
        let selected = RateLimitSnapshot.latest([initial.quota!, api], now: now, maxAge: 3600)
        expect(selected?.sevenDay?.usedPercentage == 40, "newer API quota replaces local quota")
        expect(selected?.fiveHour == nil, "a newer complete response removes an absent short window")
        try append(usage(-50, total: 2200), to: file)
        let fresh = reader.refresh(now: now)
        let logged = RateLimitSnapshot.latest([api, fresh.quota!], now: now, maxAge: 3600)
        expect(logged?.updatedAt == fresh.quota?.updatedAt, "newer log quota wins over older API data")
        expect(RateLimitSnapshot.latest([fresh.quota!], now: now, maxAge: 3600) != nil,
               "fresh local quota remains available when the API fails")
        expect(RateLimitSnapshot.latest([fresh.quota!], now: now.addingTimeInterval(4000), maxAge: 3600) == nil,
               "old log quota must not remain available indefinitely")
        let payload: [String: Any] = ["type": "event_msg", "timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(-40)),
            "payload": ["type": "token_count", "info": NSNull(), "rate_limits": [
                "primary": ["used_percent": 70, "window_minutes": 10080, "resets_at": now.addingTimeInterval(86400).timeIntervalSince1970]]]]
        try append(String(decoding: JSONSerialization.data(withJSONObject: payload), as: UTF8.self), to: file)
        let quotaOnly = reader.refresh(now: now)
        expect(quotaOnly.quota?.sevenDay?.usedPercentage == 70 && quotaOnly.events.count == 2,
               "quota-only log updates must not create token usage")
        let newer = snapshot(quotaOnly.events, limits: quotaOnly.quota)
        expect(newer.week.fraction == 0.7, "log quota reaches the dashboard used by the menu bar")
        try append(usage(-80, total: 2200, fiveHour: true), to: file)
        expect(reader.refresh(now: now).quota?.sevenDay?.usedPercentage == 70,
               "out-of-order log lines cannot replace newer quota")
        try append(usage(-30, total: 2200), to: file)
        let duplicate = reader.refresh(now: now)
        expect(duplicate.quota?.sevenDay?.usedPercentage == 10 && duplicate.events.count == 2,
               "repeated token totals can still carry a new quota snapshot")
    }

    private static func testQuotaConflicts() {
        let reset = now.addingTimeInterval(3600)
        let high = RateLimitSnapshot(updatedAt: now.addingTimeInterval(-10),
            fiveHour: .init(usedPercentage: 60, resetsAt: reset),
            sevenDay: .init(usedPercentage: 50, resetsAt: now.addingTimeInterval(86400)),
            modelScoped: [.init(displayName: "Fable", utilization: 40, resetsAt: now.addingTimeInterval(86400))])
        var delayed = high
        delayed.updatedAt = now
        delayed.fiveHour?.usedPercentage = 20
        delayed.sevenDay?.usedPercentage = 30
        delayed.modelScoped[0].utilization = 10
        let stable = delayed.stabilized(against: high, now: now)
        expect(stable.fiveHour?.usedPercentage == 60 && stable.sevenDay?.usedPercentage == 50,
               "delayed same-window reports cannot make either tool's usage decrease")
        expect(stable.modelScoped[0].utilization == 40, "scoped Claude quotas cannot decrease within the same window")
        delayed.fiveHour?.resetsAt = reset.addingTimeInterval(-0.007526)
        expect(delayed.stabilized(against: high, now: now).fiveHour?.usedPercentage == 60,
               "second and fractional-second reset timestamps identify the same window")
        var partial = delayed
        partial.fiveHour?.usedPercentage = nil
        expect(partial.stabilized(against: high, now: now).fiveHour?.usedPercentage == 60,
               "a partial report cannot erase a known value within the same window")
        partial.fiveHour?.resetsAt = nil
        expect(partial.stabilized(against: high, now: now).fiveHour?.usedPercentage == 60,
               "an undated window cannot replace a known active window")
        var growing = high
        growing.updatedAt = now
        growing.fiveHour?.usedPercentage = 65
        expect(growing.stabilized(against: high, now: now).fiveHour?.usedPercentage == 65,
               "new usage within the same window continues to increase")
        var restarted = delayed
        restarted.fiveHour?.resetsAt = reset.addingTimeInterval(5 * 3600)
        restarted.fiveHour?.usedPercentage = 0
        expect(restarted.stabilized(against: high, now: now).fiveHour?.usedPercentage == 0,
               "a new reset window allows usage to return to zero")
        var oldWindow = delayed
        oldWindow.fiveHour?.resetsAt = reset.addingTimeInterval(-600)
        oldWindow.fiveHour?.usedPercentage = 99
        expect(oldWindow.stabilized(against: restarted, now: now).fiveHour?.usedPercentage == 0,
               "a delayed previous-window report cannot undo a reset")
        expect(delayed.stabilized(against: high, now: now, allowsDecrease: true).fiveHour?.usedPercentage == 20,
               "confirmed manual resets allow API usage to decrease")
        expect(delayed.stabilized(against: high, now: reset.addingTimeInterval(1)).fiveHour?.usedPercentage == 20,
               "ended windows cannot preserve their old usage")
        let absent = RateLimitSnapshot(updatedAt: now, sevenDay: delayed.sevenDay, modelScoped: [])
        expect(absent.stabilized(against: high, now: now).fiveHour == nil,
               "complete Codex snapshots do not restore a removed short window")
        let old = RateLimitSnapshot(updatedAt: now.addingTimeInterval(-60), fiveHour: high.fiveHour,
                                    sevenDay: high.sevenDay, modelScoped: high.modelScoped)
        let feed = RateLimitSnapshot(updatedAt: now, fiveHour: growing.fiveHour, sevenDay: delayed.sevenDay, modelScoped: [])
        let merged = RateLimitSnapshot.merged([old, feed, high], now: now, maxAge: 3600)!.stabilized(against: high, now: now)
        expect(merged.fiveHour?.usedPercentage == 65 && merged.sevenDay?.usedPercentage == 50,
               "Claude cache and status-line conflicts resolve without usage oscillation")
        expect(merged.modelScoped.first?.utilization == 40, "status-line updates retain cache-only scoped quotas")
        let expired = RateLimitSnapshot(updatedAt: now, fiveHour: .init(usedPercentage: 99, resetsAt: now.addingTimeInterval(-1)), modelScoped: [])
        expect(RateLimitSnapshot.latest([expired], now: now, maxAge: 3600) == nil,
               "expired Codex windows are unavailable")
        let boundary = RateLimitSnapshot.merged([expired], now: now, maxAge: 3600)
        expect(snapshot([], tool: .claudeCode, limits: boundary).fiveHour?.fraction == 0,
               "Claude's ended short window still establishes a zero-usage boundary")
        let undated = Data(#"{"cachedUsageUtilization":{"utilization":{"five_hour":{"utilization":20}}}}"#.utf8)
        expect(ClaudeConfigReader.parse(undated) == nil, "undated Claude caches cannot appear newly fetched")
        let dated = Data(#"{"cachedUsageUtilization":{"fetchedAtMs":1000000,"utilization":{"five_hour":{"utilization":20}}}}"#.utf8)
        expect(ClaudeConfigReader.parse(dated)?.updatedAt == Date(timeIntervalSince1970: 1000),
               "Claude caches retain their actual fetch timestamp")
    }

    private static func testUsageHistory() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        func date(_ month: Int, _ day: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12))!
        }
        func usageEvent(_ date: Date, _ tokens: Int) -> UsageEvent {
            UsageEvent(timestamp: date, model: "gpt-priced", counts: TokenCounts(input: tokens),
                       dedupeKey: "\(date)-\(tokens)", sessionID: "history")
        }
        let fixtureNow = date(10, 13)
        let legacy = try JSONDecoder().decode(UsageLedger.self, from: Data(#"{"days":{"2026-07-08":4000000,"2026-08-10":1200000,"2026-09-20":800,"2026-10-11":300,"2026-10-12":999}}"#.utf8))
        let events = [usageEvent(date(7, 8), 10), usageEvent(date(10, 12), 200), usageEvent(date(10, 12), 300)]
        let ledger = UsageLedger.updated(legacy, events: events,
            history: [calendar.startOfDay(for: date(6, 25)): 600, calendar.startOfDay(for: date(8, 10)): 20],
            now: fixtureNow, retentionDays: 30, calendar: calendar)
        expect(ledger.days["2026-07-08"] == 4_000_000 && ledger.days["2026-08-10"] == 1_200_000,
               "partial or deleted old logs cannot erase saved historical daily totals")
        expect(ledger.days["2026-10-12"] == 500, "recent available logs are recalculated without adding the old cache")
        expect(ledger.days["2026-10-11"] == 300, "missing recent logs do not erase a previously saved day")
        expect(ledger.days["2026-06-25"] == 600, "Claude's statistics cache fills an otherwise missing historical day")
        let repeated = UsageLedger.updated(ledger, events: events, history: [:], now: fixtureNow,
                                          retentionDays: 30, calendar: calendar)
        expect(repeated == ledger, "repeated scans do not accumulate cached totals again")
        expect(UsageLedger.updated(ledger, events: [], history: [:], now: fixtureNow,
                                   retentionDays: 30, calendar: calendar) == ledger,
               "deleting every source log preserves saved daily history")
        let snapshot = DashboardBuilder.snapshot(tool: .claudeCode, events: events, rejections: [], prices: prices,
            quota: .init(), ledger: ledger, now: fixtureNow, calendar: calendar)
        expect(snapshot.usage.dailyTokens[calendar.startOfDay(for: date(7, 8))] == 4_000_000,
               "saved July totals are restored to the heatmap")
        expect(snapshot.usage.dailyTokens[calendar.startOfDay(for: date(10, 12))] == 500,
               "the heatmap does not count recent usage twice")
        expect(snapshot.usage.previousTotals[.month] == 800, "previous-month comparisons include retained history")
        expect(snapshot.usage.totals[.month]?.total == 800 && snapshot.usage.models[.month]?.isEmpty == true
               && snapshot.usage.costs[.month] == nil && snapshot.usage.unavailableDetails.contains(.month),
               "selected-period total includes saved history while incomplete model and cost details stay unavailable")
        let empty = DashboardBuilder.snapshot(tool: .claudeCode, events: [], rejections: [], prices: prices,
            quota: .init(), ledger: ledger, now: fixtureNow, calendar: calendar)
        expect(empty.usage.dailyTokens == snapshot.usage.dailyTokens,
               "historical heatmap data remains available with no source events")
    }

    private static func testCacheWrites() throws {
        let base = try directories("writes")
        _ = try log(base, "writes", lines: [try usage(-60, write: 200)])
        let result = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() }).refresh(now: now)
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
        let counts = CodexReader(root: base.appending(path: "sessions"), sleepHistory: { SleepTimeline() }).refresh(now: now).events.first?.counts
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

        for tool in Tool.allCases {
            let weekly = RateLimitWindow(usedPercentage: 42)
            let both = RateLimitSnapshot(updatedAt: now, fiveHour: .init(usedPercentage: 20),
                                         sevenDay: weekly, modelScoped: [])
            let selected = snapshot([], tool: tool, limits: both)
            expect(selected.menuBarQuota.fraction == 0.2 && selected.menuBarQuota.title == selected.fiveHour?.title,
                   "\(tool) menu bar must prefer the five-hour quota")
            let weekOnly = RateLimitSnapshot(updatedAt: now, sevenDay: weekly, modelScoped: [])
            let fallback = snapshot([], tool: tool, limits: weekOnly)
            expect(fallback.menuBarQuota.fraction == 0.42 && fallback.menuBarQuota.title == fallback.week.title,
                   "\(tool) menu bar must fall back to weekly quota when five-hour percentage is absent")
            let unused = RateLimitSnapshot(updatedAt: now, fiveHour: .init(usedPercentage: 0),
                                           sevenDay: weekly, modelScoped: [])
            expect(snapshot([], tool: tool, limits: unused).menuBarQuota.fraction == 0,
                   "\(tool) zero usage is an available five-hour quota")
            expect(snapshot([], tool: tool).menuBarQuota.fraction == nil,
                   "\(tool) missing quota must remain unavailable")
        }
    }

    private static func testUnknownPrices() {
        let counts = TokenCounts(input: 1000)
        let events = ["gpt-priced", "codex-auto-review"].map {
            UsageEvent(timestamp: now, model: $0, counts: counts, dedupeKey: $0)
        }
        let result = snapshot(events).usage
        let unknown: Double? = result.models[.day]?.first { $0.model == "codex-auto-review" }?.cost
        expect(unknown == 0, "models without prices must contribute zero cost")
        expect(result.costs[.day] == 0.002, "unknown models must not hide known costs")
        expect(result.totals[.day]?.total == 2000, "unpriced model tokens must still be counted")
        expect(result.models[.day]?.first { $0.model == "gpt-priced" }?.cost == 0.002,
               "known model costs must remain visible")
    }

    private static func testMonthlyUnknownModel() {
        let monthStart = DashboardBuilder.range(for: .month, containing: now, calendar: .current).lowerBound
        let unknown = UsageEvent(timestamp: monthStart, model: "codex",
                                 counts: .init(reportedTotal: 7_212_919), dedupeKey: "monthly-unknown")
        let known = UsageEvent(timestamp: now, model: "gpt-priced",
                               counts: .init(input: 1000), dedupeKey: "monthly-known")
        let result = snapshot([unknown, known]).usage
        expect(result.costs[.month] == 0.002, "monthly costs must include priced models despite historical unknown models")
        expect(result.totals[.month]?.total == 7_213_919, "unknown model totals must remain counted")
        expect(result.models[.month]?.first { $0.model == "codex" }?.cost == 0,
               "unknown historical model rows must show zero cost")
        expect(snapshot([unknown]).usage.costs[.month] == 0, "periods with only unknown prices must show zero")
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
        expect(combined.costs[.day] == (claude.costs[.day] ?? 0) + (codex.costs[.day] ?? 0),
               "unpriced models must not hide the combined cost")
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
        let below200 = milestoneState(claude: 159_999_999, codex: 40_000_000)
        expect(!Milestones.shouldCelebrate(previous: combined100, current: below200),
               "daily usage below 200M must not celebrate the next milestone")
        let combined200 = milestoneState(claude: 160_000_000, codex: 40_000_000)
        expect(Milestones.shouldCelebrate(previous: below200, current: combined200),
               "daily usage reaching exactly 200M must celebrate again")
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
            expect(Milestones.shouldCelebrate(previous: previous, current: current) == (period == "day"),
                   "only a daily crossing must trigger a celebration; checked \(period)")
        }
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let reset = milestoneState(at: nextDay)
        expect(!Milestones.shouldCelebrate(previous: previous, current: reset),
               "a new day without usage must not celebrate")
        expect(Milestones.merged(previous: previous, current: reset).dayFloor == 0,
               "completed daily floors must reset on a new day")
        let next100 = milestoneState(claude: 100_000_000, at: nextDay)
        expect(Milestones.shouldCelebrate(previous: reset, current: next100),
               "the next day must celebrate its own first 100M")
        expect(Milestones.shouldCelebrate(previous: previous, current: next100),
               "a new day's first scan reaching 100M must celebrate even after yesterday reached 200M")
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
