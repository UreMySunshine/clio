import Foundation

/// Reads active and archived `.jsonl` sessions in `~/.codex`.
///
/// Codex records a `token_count` event per turn; `last_token_usage` is that
/// turn's delta while `total_token_usage` is the session running total, so only
/// the delta is accumulated (or derived from cumulative snapshots when absent).
/// `input_tokens` includes both `cached_input_tokens`
/// and `cache_write_input_tokens`.
///
/// Each rollout file is one thread. `session_meta.session_id` is the
/// conversation it belongs to, and subagent threads repeat their parent's id,
/// so the activity card can count conversations instead of files. The file
/// path is the fallback when a log has no meta line.
///
/// The shape below is the Codex CLI rollout format. Fields are read defensively
/// and a line that doesn't match is skipped rather than failing the scan.
final class CodexReader {
    struct Reading {
        var events: [UsageEvent]
        var quota: RateLimitSnapshot?
    }

    private(set) var revision = 0

    private let scanners: [LogScanner]
    private var events: [String: UsageEvent] = [:]
    /// Latest model named in each session file. Subagent sessions log a
    /// different model alongside their parent, so it is not shared across files.
    private var models: [String: String] = [:]
    /// Conversation id from `session_meta`, keyed by file path.
    private var sessionIDs: [String: String] = [:]
    /// Latest `total_token_usage` seen in each session file.
    private var totals: [String: [String: Int]] = [:]
    private var timers: [String: RequestTimer] = [:]
    private var timingQualities: [String: TimingQuality] = [:]
    private let sleepHistory: () -> SleepTimeline
    private var sleeps = SleepTimeline()

    /// Standard response items put their timing fields before the body. Read
    /// that prefix without decoding tool output; other layouts use the full parser.
    private struct ResponseHeader {
        enum Reading {
            case response(ResponseHeader)
            case ignored
        }
        let timestamp: String
        let kind: String
        let role: String?

        private static let bodyFields: Set<String> = [
            "content", "output", "arguments", "input", "summary", "encrypted_content",
        ]

        static func read(_ line: UnsafeRawBufferPointer) -> Reading? {
            guard line.count >= 1024, !ByteSearch.contains(line, modelMarker) else { return nil }
            var end = line.count
            while end > 0, [0x20, 0x09, 0x0D].contains(line[end - 1]) { end -= 1 }
            guard end > 0, line[end - 1] == 0x7D else { return nil }
            var cursor = Cursor(bytes: UnsafeRawBufferPointer(rebasing: line.prefix(1024)))
            guard cursor.consume(0x7B) else { return nil }
            var timestamp: String?
            var type: String?
            while let key = cursor.string(), cursor.consume(0x3A) {
                if key == "payload" {
                    guard cursor.consume(0x7B) else { return nil }
                    if type == "event_msg" {
                        while let field = cursor.string(), cursor.consume(0x3A) {
                            if field == "type", let kind = cursor.string() {
                                return ["token_count", "task_started", "turn_aborted"].contains(kind) ? nil : .ignored
                            }
                            guard cursor.skipScalar(), cursor.consume(0x2C) else { return nil }
                        }
                        return nil
                    }
                    guard type == "response_item", let timestamp,
                        let response = payload(&cursor, timestamp: timestamp)
                    else { return nil }
                    return .response(response)
                }
                switch key {
                case "timestamp":
                    guard let value = cursor.string() else { return nil }
                    timestamp = value
                case "type":
                    guard let value = cursor.string() else { return nil }
                    type = value
                default: guard cursor.skipScalar() else { return nil }
                }
                guard cursor.consume(0x2C) else { return nil }
            }
            return nil
        }

        private static func payload(_ cursor: inout Cursor, timestamp: String) -> ResponseHeader? {
            var kind: String?
            var role: String?
            func header() -> ResponseHeader? {
                guard let kind, kind != "message" || role != nil else { return nil }
                return ResponseHeader(timestamp: timestamp, kind: kind, role: role)
            }
            while let key = cursor.string(), cursor.consume(0x3A) {
                if bodyFields.contains(key) { return header() }
                switch key {
                case "type":
                    guard let value = cursor.string() else { return nil }
                    kind = value
                case "role":
                    guard let value = cursor.string() else { return nil }
                    role = value
                default: guard cursor.skipScalar() else { return nil }
                }
                if cursor.consume(0x7D) { return header() }
                guard cursor.consume(0x2C) else { return nil }
            }
            return nil
        }

        private struct Cursor {
            let bytes: UnsafeRawBufferPointer
            var offset = 0

            mutating func consume(_ byte: UInt8) -> Bool {
                whitespace()
                guard offset < bytes.count, bytes[offset] == byte else { return false }
                offset += 1
                return true
            }

            mutating func string() -> String? {
                guard consume(0x22) else { return nil }
                let start = offset
                while offset < bytes.count {
                    let byte = bytes[offset]
                    if byte == 0x5C || byte < 0x20 { return nil }
                    if byte == 0x22 {
                        let value = String(bytes: bytes[start..<offset], encoding: .utf8)
                        offset += 1
                        return value
                    }
                    offset += 1
                }
                return nil
            }

            mutating func skipScalar() -> Bool {
                whitespace()
                if offset < bytes.count, bytes[offset] == 0x22 { return string() != nil }
                let start = offset
                while offset < bytes.count, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x7D].contains(bytes[offset]) {
                    offset += 1
                }
                guard offset > start else { return false }
                let scalar = String(decoding: bytes[start..<offset], as: UTF8.self)
                return scalar == "null" || scalar == "true" || scalar == "false" || Double(scalar)?.isFinite == true
            }

            private mutating func whitespace() {
                while offset < bytes.count, [0x20, 0x09, 0x0D, 0x0A].contains(bytes[offset]) { offset += 1 }
            }
        }
    }

    private enum TimingQuality: Int {
        case notification, response, usageRecord
    }

    /// Keep request timing per rollout; tool results mark the next request's start.
    private struct RequestTimer {
        var boundary: Date?
        var start: Date?
        var output: Date?
        var toolOutput: Date?
        var usageRecord: (timestamp: Date, counts: [String: Int])?
        var lastFinish: Date?

        mutating func observe(_ object: [String: Any], payload: [String: Any], at date: Date) {
            switch object["type"] as? String {
            case "turn_context": boundary = date
            case "token_usage_record":
                if let counts = payload["usage"] as? [String: Int] { usageRecord = (date, counts) }
            case "response_item":
                observeResponse(payload["type"] as? String ?? "", role: payload["role"] as? String, at: date)
            case "event_msg":
                if ["task_started", "turn_aborted"].contains(payload["type"] as? String ?? "") {
                    self = RequestTimer(boundary: date, lastFinish: lastFinish)
                }
            default: break
            }
        }

        mutating func observeResponse(_ kind: String, role: String?, at date: Date) {
            if kind.hasSuffix("_output") {
                boundary = date
                if output != nil { toolOutput = date }
            } else if kind == "message", role != "assistant" {
                boundary = date
            } else if kind == "message" || kind == "reasoning" || kind.hasSuffix("_call") {
                // Some clients flush response items just after their token event.
                if start == nil, let lastFinish, date.timeIntervalSince(lastFinish) <= 0.1 { return }
                if start == nil { start = boundary }
                output = date
                toolOutput = nil
            }
        }

        mutating func finish(at date: Date, counts: [String: Int], sleeps: SleepTimeline)
            -> (duration: TimeInterval, quality: TimingQuality)? {
            var end = date
            var quality = TimingQuality.notification
            if let toolOutput, date.timeIntervalSince(toolOutput) <= 0.1, let output {
                end = output
                quality = .response
            }
            if let record = usageRecord,
                ["input_tokens", "cached_input_tokens", "output_tokens"].allSatisfy({
                    (record.counts[$0] ?? 0) == (counts[$0] ?? 0)
                })
            {
                end = record.timestamp
                quality = .usageRecord
            }
            let seconds = sleeps.estimatedDuration(from: start ?? boundary, to: end)
            // A delayed usage notification must not displace a newer tool result
            // or the response's actual end as the next request's boundary.
            self = RequestTimer(boundary: max(boundary ?? end, end), lastFinish: date)
            return seconds.map { (duration: $0, quality: quality) }
        }
    }

    private var quota: RateLimitSnapshot?

    init(root: URL = Tool.codex.logDirectory,
         sleepHistory: @escaping () -> SleepTimeline = { SleepHistory.shared.snapshot() }) {
        scanners = [LogScanner(root: root),
                    LogScanner(root: root.deletingLastPathComponent().appending(path: "archived_sessions"))]
        self.sleepHistory = sleepHistory
    }

    var isAvailable: Bool {
        scanners.contains { $0.rootExists }
    }

    /// `token_count` lines carry usage but no model; the model is named by the
    /// `turn_context` line that opens each turn. `session_meta` is the first
    /// line of a rollout and names the conversation.
    private static let usageMarker = Array("token_count".utf8)
    private static let contextMarker = Array("turn_context".utf8)
    private static let sessionMarker = Array("session_meta".utf8)
    private static let responseMarker = Array("response_item".utf8)
    private static let modelMarker = Array("\"model\"".utf8)
    private static let timingMarkers = ["token_usage_record", "task_started", "turn_aborted"]
        .map { Array($0.utf8) }

    func refresh(now: Date = Date()) -> Reading {
        let currentSleeps = sleepHistory()
        let scans = scanners.map { $0.prepare() }
        if scans.contains(where: { $0.needsRebuild }) || currentSleeps != sleeps {
            revision += 1
            scanners.forEach { $0.reset() }
            events.removeAll()
            models.removeAll()
            sessionIDs.removeAll()
            totals.removeAll()
            timers.removeAll()
            timingQualities.removeAll()
            quota = nil
        }
        sleeps = currentSleeps
        for (scanner, scan) in zip(scanners, scans) {
            scanner.scan(scan) { file, line in
                if let reading = ResponseHeader.read(line) {
                    switch reading {
                    case .ignored: return
                    case .response(let header):
                        if let date = ISO8601.date(from: header.timestamp) {
                            timers[file, default: RequestTimer()].observeResponse(header.kind, role: header.role, at: date)
                            return
                        }
                    }
                }
                guard ByteSearch.contains(line, Self.responseMarker)
                        || ByteSearch.contains(line, Self.usageMarker)
                        || ByteSearch.contains(line, Self.contextMarker)
                        || ByteSearch.contains(line, Self.sessionMarker)
                        || Self.timingMarkers.contains(where: { ByteSearch.contains(line, $0) })
                else { return }
                guard let base = line.baseAddress else { return }
                let data = Data(bytes: base, count: line.count)
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                ingest(object, file: file)
            }
        }
        let previousCount = events.count
        let cutoff = now.addingTimeInterval(-LogScanner.retention)
        events = events.filter { $0.value.timestamp > cutoff }
        if events.count != previousCount {
            revision += 1
            timingQualities = timingQualities.filter { events[$0.key] != nil }
        }
        return Reading(events: Array(events.values), quota: quota)
    }

    private func ingest(_ object: [String: Any], file: String) {
        let payload = object["payload"] as? [String: Any] ?? [:]
        if let stamp = object["timestamp"] as? String, let date = ISO8601.date(from: stamp) {
            timers[file, default: RequestTimer()].observe(object, payload: payload, at: date)
        }

        if object["type"] as? String == "session_meta" {
            let id = (payload["session_id"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? (payload["id"] as? String)
            if let id, !id.isEmpty { sessionIDs[file] = id }
            return
        }

        // Any line that names a model updates what later turns are attributed to.
        if let model = payload["model"] as? String, !model.isEmpty {
            models[file] = model
        }

        guard payload["type"] as? String == "token_count" else { return }

        let stamp = (object["timestamp"] as? String) ?? ""
        let timestamp = ISO8601.date(from: stamp)
        if let timestamp { noteQuota(payload["rate_limits"], at: timestamp) }
        guard let info = payload["info"] as? [String: Any] else { return }

        if let model = info["model"] as? String, !model.isEmpty {
            models[file] = model
        }
        let currentModel = models[file] ?? "codex"
        guard let timestamp else { return }

        let total = info["total_token_usage"] as? [String: Int]
        let previous = totals[file]
        let last: [String: Int]
        if let total, total == previous { return }
        if let reported = info["last_token_usage"] as? [String: Int] {
            last = reported
        } else if let total {
            // ccusage prefers the latest delta, falling back to nonnegative
            // differences between cumulative snapshots when the delta is absent.
            last = total.reduce(into: [:]) { result, item in
                result[item.key] = max(0, item.value - (previous?[item.key] ?? 0))
            }
        } else {
            return
        }
        if let total { totals[file] = total }

        let input = last["input_tokens"] ?? 0
        let cached = min(input, last["cached_input_tokens"] ?? 0)
        let written = min(input - cached, last["cache_write_input_tokens"] ?? 0)
        var counts = TokenCounts()
        counts.input = max(0, input - cached - written)
        counts.cacheRead = cached
        counts.cacheWrite5m = written
        counts.output = last["output_tokens"] ?? 0
        if let reported = last["total_tokens"], reported != counts.total {
            counts.reportedTotal = reported
        }

        guard counts.total > 0 else { return }
        let timing = timers[file, default: RequestTimer()].finish(at: timestamp, counts: last, sleeps: sleeps)
        let key = [
            String(Int64(timestamp.timeIntervalSince1970 * 1000)), currentModel,
            String(counts.input), String(counts.output), String(counts.cacheRead),
            String(counts.cacheWrite), String(last["reasoning_output_tokens"] ?? 0), String(counts.total),
        ].joined(separator: "|")
        if var existing = events[key] {
            guard let timing, existing.estimatedDuration == nil
                || timing.quality.rawValue > (timingQualities[key]?.rawValue ?? -1) else { return }
            timingQualities[key] = timing.quality
            guard existing.estimatedDuration != timing.duration else { return }
            existing.estimatedDuration = timing.duration
            events[key] = existing
            revision += 1
            return
        }
        revision += 1
        timingQualities[key] = timing?.quality
        events[key] = UsageEvent(timestamp: timestamp,
                                 model: currentModel,
                                 counts: counts,
                                 dedupeKey: key,
                                 sessionID: sessionIDs[file] ?? file,
                                 estimatedDuration: timing?.duration)
    }

    /// A day or longer is weekly; shorter reported windows are five-hour quotas.
    private func noteQuota(_ value: Any?, at timestamp: Date) {
        guard let limits = value as? [String: Any] else { return }
        if let existing = quota?.updatedAt, timestamp <= existing { return }

        var fiveHour: RateLimitWindow?
        var week: RateLimitWindow?
        for key in ["primary", "secondary"] {
            guard let entry = limits[key] as? [String: Any],
                  let window = Self.quotaWindow(entry)
            else { continue }
            let minutes = Self.number(entry["window_minutes"]) ?? 0
            if minutes >= 24 * 60 {
                week = window
            } else if minutes > 0 {
                fiveHour = window
            }
        }
        guard fiveHour != nil || week != nil else { return }
        quota = RateLimitSnapshot(updatedAt: timestamp,
                                  fiveHour: fiveHour,
                                  sevenDay: week,
                                  modelScoped: [])
    }

    private static func quotaWindow(_ entry: [String: Any]) -> RateLimitWindow? {
        guard let percent = number(entry["used_percent"]) else { return nil }
        return RateLimitWindow(usedPercentage: percent, resetsAt: date(entry["resets_at"]))
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: Double(seconds)) }
        if let text = value as? String { return ISO8601.date(from: text) }
        return nil
    }
}
