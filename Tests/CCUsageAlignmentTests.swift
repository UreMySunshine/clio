import Foundation

@main
enum CCUsageAlignmentTests {
    static func main() throws {
        if CommandLine.arguments.contains("--live") {
            var result: [String: [String: [String: Int]]] = [:]
            let format = DateFormatter()
            format.dateFormat = "yyyy-MM-dd"
            format.timeZone = TimeZone(identifier: "Asia/Singapore")!
            let sources: [(String, [UsageEvent])] = [
                ("claude", ClaudeCodeReader().refresh().events),
                ("codex", CodexReader().refresh().events),
            ]
            for (tool, events) in sources {
                for event in events {
                    let date = format.string(from: event.timestamp)
                    let counts = event.counts
                    for (field, value) in [
                        "totalTokens": counts.total, "inputTokens": counts.input,
                        "outputTokens": counts.output, "cacheReadTokens": counts.cacheRead,
                        "cacheCreationTokens": counts.cacheWrite,
                    ] {
                        result[tool, default: [:]][date, default: [:]][field, default: 0] += value
                    }
                }
            }
            print(String(data: try JSONEncoder().encode(result), encoding: .utf8)!)
            return
        }
        let root = FileManager.default.temporaryDirectory.appending(path: "clio-ccusage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeRoot = root.appending(path: "claude")
        let codexRoot = root.appending(path: "sessions")
        try FileManager.default.createDirectory(at: claudeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codexRoot, withIntermediateDirectories: true)
        let now = Date()
        let stamp = ISO8601DateFormatter().string(from: now.addingTimeInterval(-60))
        func assistant(
            _ id: String, _ request: String?, _ tokens: Int, sidechain: Bool = false,
            session: String = "main", creation: [String: Int]? = nil
        ) throws -> String {
            var usage: [String: Any] = ["input_tokens": tokens, "output_tokens": 0]
            if let creation {
                usage["cache_creation"] = creation
                usage["cache_creation_input_tokens"] = 500
            }
            var entry: [String: Any] = [
                "type": "assistant", "timestamp": stamp, "sessionId": session,
                "isSidechain": sidechain,
                "message": ["id": id, "model": "claude-opus-5-5", "usage": usage],
            ]
            if let request { entry["requestId"] = request }
            return String(data: try JSONSerialization.data(withJSONObject: entry), encoding: .utf8)!
        }
        let lines = try [
            assistant("stream", "r", 10), assistant("stream", "r", 25),
            assistant("second", "r", 7),
            assistant("copy", "copy-r", 30), assistant("copy", "copy-r", 30, session: "resumed"),
            assistant("copy", "rewritten-r", 50, sidechain: true),
            assistant("parent", "parent-r", 80, sidechain: true), assistant("parent", "new-r", 35),
            assistant("cache", "cache-r", 9, creation: [:]),
        ]
        let file = claudeRoot.appending(path: "events.jsonl")
        try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
        let reader = ClaudeCodeReader(root: claudeRoot)
        let initial = reader.refresh().events
        precondition(
            initial.reduce(0) { $0 + $1.counts.total } == 106,
            "ccusage: latest complete stream, message/request identity, replay and non-sidechain priority")
        precondition(reader.refresh().events.reduce(0) { $0 + $1.counts.total } == 106, "refresh does not duplicate")
        let appended = try assistant("stream", "r", 40) + "\n"
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()
        precondition(
            reader.refresh().events.reduce(0) { $0 + $1.counts.total } == 121,
            "appended complete usage replaces its earlier partial count")

        let survivor = claudeRoot.appending(path: "survivor.jsonl")
        try FileManager.default.copyItem(at: file, to: survivor)
        precondition(reader.refresh().events.reduce(0) { $0 + $1.counts.total } == 121)
        try FileManager.default.removeItem(at: file)
        precondition(
            reader.refresh().events.reduce(0) { $0 + $1.counts.total } == 121,
            "deleting one copy rebuilds deduplication from the surviving file")
        try Data((try assistant("replacement", "replacement-r", 12) + "\n").utf8).write(to: survivor)
        precondition(
            reader.refresh().events.reduce(0) { $0 + $1.counts.total } == 12,
            "truncated Claude logs replace previously accumulated events")
        let atomicReplacement = try assistant("larger-replacement", "replacement-r", 15)
            + "\n" + assistant("extra-replacement", "extra-r", 17) + "\n"
        try Data(atomicReplacement.utf8).write(to: survivor, options: .atomic)
        precondition(
            reader.refresh().events.reduce(0) { $0 + $1.counts.total } == 32,
            "larger atomic replacement rebuilds using file identity")
        try FileManager.default.removeItem(at: survivor)
        precondition(reader.refresh().events.isEmpty, "deleted Claude logs disappear on refresh")

        let context = #"{"type":"turn_context","payload":{"model":"gpt-priced"}}"#
        func tokenCount(_ total: [String: Int], last: [String: Int]? = nil) throws -> String {
            var info: [String: Any] = ["total_token_usage": total]
            if let last { info["last_token_usage"] = last }
            return String(
                data: try JSONSerialization.data(withJSONObject: [
                    "timestamp": stamp,
                    "payload": ["type": "token_count", "info": info],
                ]), encoding: .utf8)!
        }
        let first = ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 10, "total_tokens": 110]
        let second = ["input_tokens": 160, "cached_input_tokens": 60, "output_tokens": 15, "total_tokens": 175]
        let codexLines = try [context, tokenCount(first), tokenCount(first), tokenCount(second)]
        try Data((codexLines.joined(separator: "\n") + "\n").utf8).write(to: codexRoot.appending(path: "delta.jsonl"))
        let codexReader = CodexReader(root: codexRoot)
        let codex = codexReader.refresh()
        precondition(
            codex.events.reduce(0) { $0 + $1.counts.total } == 175,
            "ccusage: derive missing last usage and skip unchanged cumulative snapshots")

        let codexFile = codexRoot.appending(path: "delta.jsonl")
        let reported = ["input_tokens": 100, "cached_input_tokens": 40, "output_tokens": 10, "total_tokens": 150]
        try Data((context + "\n" + tokenCount(reported, last: reported) + "\n").utf8).write(to: codexFile)
        let replacement = codexReader.refresh().events
        precondition(replacement.count == 1 && replacement[0].counts.total == 150,
                     "replaced Codex log retains reported total rather than the 110-token breakdown")
        let counts = replacement[0].counts
        precondition(counts.input == 60 && counts.cacheRead == 40 && counts.output == 10,
                     "reported total does not change available token details")
        precondition((counts + TokenCounts(input: 20)).total == 170,
                     "combining tools preserves the reported total")
        precondition((counts + counts).total == 300, "combining reported totals preserves both")
        let archivedRoot = root.appending(path: "archived_sessions")
        try FileManager.default.createDirectory(at: archivedRoot, withIntermediateDirectories: true)
        let archived = archivedRoot.appending(path: "copy.jsonl")
        try FileManager.default.copyItem(at: codexFile, to: archived)
        precondition(codexReader.refresh().events.reduce(0) { $0 + $1.counts.total } == 150)
        try FileManager.default.removeItem(at: codexFile)
        precondition(codexReader.refresh().events.reduce(0) { $0 + $1.counts.total } == 150,
                     "archived copy survives deletion of its active log")
        try FileManager.default.removeItem(at: archived)
        precondition(codexReader.refresh().events.isEmpty, "deleted Codex logs disappear on refresh")

        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 1
        calendar.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let saturday = calendar.date(from: DateComponents(year: 2026, month: 10, day: 10, hour: 12))!
        let week = DashboardBuilder.range(for: .week, containing: saturday, calendar: calendar)
        precondition(
            calendar.component(.weekday, from: week.lowerBound) == 2,
            "ccusage weeks start Monday regardless of system locale")
        precondition(calendar.component(.day, from: week.lowerBound) == 5)
        print("ccusage alignment checks passed")
    }
}
