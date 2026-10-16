import Foundation

/// Reads `~/.claude/projects/**/*.jsonl`.
///
/// Usage lives on `type: "assistant"` lines under `message.usage`; the cache
/// write is split by TTL under `usage.cache_creation`. Resumed sessions write
/// the same response into more than one file. Like ccusage, deduplication uses
/// message + request identity and prefers the complete, non-sidechain record.
final class ClaudeCodeReader {
    private struct Entry {
        let event: UsageEvent
        let isSidechain: Bool
    }
    private(set) var revision = 0

    private let scanner: LogScanner
    private var events: [String: Entry] = [:]
    private var exactKeys: [String: String] = [:]
    private var replayRoutes: [String: [String]] = [:]
    private var sidechainRoutes: [String: [String]] = [:]
    private var rejections: [QuotaRejection] = []
    private var timings: [String: FileTiming] = [:]
    private let sleepHistory: () -> SleepTimeline
    private var sleeps = SleepTimeline()

    private func timing(for file: String) -> FileTiming {
        if let timing = timings[file] { return timing }
        let timing = FileTiming()
        timings[file] = timing
        return timing
    }

    private final class FileTiming {
        struct Node {
            let parent: String?
            let timestamp: Date
            let isAttachment: Bool
        }
        struct Message {
            let start: Date?
            let hasFirstBlock: Bool
        }
        var nodes: [String: Node] = [:]
        var messages: [String: Message] = [:]

        func duration(_ object: [String: Any], at date: Date, sleeps: SleepTimeline) -> TimeInterval? {
            let parent = object["parentUuid"] as? String
            if let id = object["uuid"] as? String {
                nodes[id] = Node(
                    parent: parent, timestamp: date,
                    isAttachment: object["type"] as? String == "attachment")
            }
            guard object["type"] as? String == "assistant",
                let message = object["message"] as? [String: Any],
                let id = message["id"] as? String
            else { return nil }
            if messages[id] == nil {
                var cursor = parent
                var start: Date?
                for _ in 0..<32 {
                    guard let key = cursor, let node = nodes[key] else { break }
                    if !node.isAttachment { start = node.timestamp; break }
                    cursor = node.parent
                }
                messages[id] = Message(start: start, hasFirstBlock: (object["apiBlockIndex"] as? Int ?? 0) == 0)
            }
            guard let timing = messages[id], timing.hasFirstBlock,
                message["stop_reason"] as? String != nil
            else { return nil }
            return sleeps.estimatedDuration(from: timing.start, to: date)
        }
    }

    init(root: URL = Tool.claudeCode.logDirectory,
         sleepHistory: @escaping () -> SleepTimeline = { SleepHistory.shared.snapshot() }) {
        scanner = LogScanner(root: root)
        self.sleepHistory = sleepHistory
    }

    var isAvailable: Bool { scanner.rootExists }

    /// Keep usage, quota and parent-chain records; unrelated metadata is skipped.
    private static let usageMarker = Array("\"usage\"".utf8)
    private static let quotaMarker = Array("\"quotaLimits\"".utf8)
    private static let chainMarker = Array("\"uuid\"".utf8)

    func refresh() -> (events: [UsageEvent], rejections: [QuotaRejection]) {
        let currentSleeps = sleepHistory()
        let scan = scanner.prepare()
        if scan.needsRebuild || currentSleeps != sleeps {
            revision += 1
            scanner.reset()
            events.removeAll()
            exactKeys.removeAll()
            replayRoutes.removeAll()
            sidechainRoutes.removeAll()
            rejections.removeAll()
            timings.removeAll()
        }
        sleeps = currentSleeps
        scanner.scan(scan) { file, line in
            guard
                ByteSearch.contains(line, Self.usageMarker)
                    || ByteSearch.contains(line, Self.quotaMarker)
                    || ByteSearch.contains(line, Self.chainMarker)
            else { return }
            guard let base = line.baseAddress else { return }
            let data = Data(bytes: base, count: line.count)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            ingest(object, file: file)
        }
        let previousCount = events.count + rejections.count
        let cutoff = Date().addingTimeInterval(-LogScanner.retention)
        events = events.filter { $0.value.event.timestamp > cutoff }
        rejections = rejections.filter { $0.timestamp > cutoff }
        if events.count + rejections.count != previousCount { revision += 1 }
        return (events.values.map(\.event), rejections)
    }

    private func ingest(_ object: [String: Any], file: String) {
        guard let stamp = object["timestamp"] as? String,
              let timestamp = ISO8601.date(from: stamp)
        else { return }
        var duration = timing(for: file).duration(object, at: timestamp, sleeps: sleeps)

        if let quota = object["quotaLimits"] as? [String: Any],
           let resets = quota["resetsAt"] as? Double {
            rejections.append(QuotaRejection(timestamp: timestamp,
                                             resetsAt: Date(timeIntervalSince1970: resets),
                                             kind: quota["rateLimitType"] as? String ?? "unknown"))
        }

        guard object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let input = usage["input_tokens"] as? Int,
              let output = usage["output_tokens"] as? Int
        else { return }
        let model = message["model"] as? String ?? "claude"
        let messageID = message["id"] as? String
        let requestID = object["requestId"] as? String
        let sessionID = object["sessionId"] as? String ?? ""
        let isSidechain = object["isSidechain"] as? Bool ?? false
        let rawKey: String
        if let messageID {
            rawKey = requestID.map { "\(messageID)|\($0)" }
                ?? "message|\(messageID)"
        } else {
            rawKey = requestID.map { "request|\($0)" }
                ?? (object["uuid"] as? String).map { "uuid|\($0)" }
                ?? UUID().uuidString
        }
        let route = messageID.map { "\($0)|\(sessionID)" }
        let replayKey = route.flatMap { (isSidechain ? replayRoutes[$0] : sidechainRoutes[$0])?.first { key in
            events[key].map { isSidechain || $0.isSidechain } ?? false
        } }
        let key = exactKeys[rawKey] ?? replayKey ?? rawKey

        let creation = usage["cache_creation"] as? [String: Any]
        let write5m = creation?["ephemeral_5m_input_tokens"] as? Int
        let write1h = creation?["ephemeral_1h_input_tokens"] as? Int
        let writeTotal = usage["cache_creation_input_tokens"] as? Int ?? 0

        var counts = TokenCounts()
        counts.input = input
        counts.output = output
        counts.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        if creation != nil {
            counts.cacheWrite5m = write5m ?? 0
            counts.cacheWrite1h = write1h ?? 0
        } else {
            // Older logs report only the total; the 5-minute tier is the default.
            counts.cacheWrite5m = writeTotal
        }

        guard counts.total > 0 else { return }

        exactKeys[rawKey] = key
        if let route, !(replayRoutes[route] ?? []).contains(key) {
            replayRoutes[route, default: []].append(key)
        }
        if let route, (isSidechain || events[key]?.isSidechain == true),
           !(sidechainRoutes[route] ?? []).contains(key) {
            sidechainRoutes[route, default: []].append(key)
        }
        if let existing = events[key] {
            if existing.isSidechain && !isSidechain {
                if existing.event.counts == counts {
                    duration = [duration, existing.event.estimatedDuration].compactMap { $0 }.max()
                }
            } else {
                if existing.isSidechain != isSidechain, existing.event.counts != counts { return }
                if existing.event.counts.total > counts.total { return }
                if existing.event.counts.total == counts.total {
                    guard (duration ?? 0) > (existing.event.estimatedDuration ?? 0) else { return }
                    var event = existing.event
                    event.estimatedDuration = duration
                    events[key] = Entry(event: event, isSidechain: existing.isSidechain)
                    revision += 1
                    return
                }
            }
        }
        revision += 1
        events[key] = Entry(
            event: UsageEvent(timestamp: timestamp, model: model, counts: counts,
                              dedupeKey: key, sessionID: sessionID, estimatedDuration: duration),
            isSidechain: isSidechain)
    }
}

enum ISO8601 {
    // FormatStyle avoids DateFormatter's per-line overhead during full log scans.
    private static let withFraction = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plain = Date.ISO8601FormatStyle()

    static func date(from string: String) -> Date? {
        (try? withFraction.parse(string)) ?? (try? plain.parse(string))
    }
}
