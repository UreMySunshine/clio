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
    private let scanner: LogScanner
    private var events: [String: Entry] = [:]
    private var exactKeys: [String: String] = [:]
    private var replayRoutes: [String: [String]] = [:]
    private var sidechainRoutes: [String: [String]] = [:]
    private var rejections: [QuotaRejection] = []

    init(root: URL = Tool.claudeCode.logDirectory) {
        scanner = LogScanner(root: root)
    }

    var isAvailable: Bool { scanner.rootExists }

    /// Byte markers used to skip lines that cannot carry usage before paying
    /// for a JSON parse. Most lines in a session log are prompts, tool results
    /// and attachments.
    private static let usageMarker = Array("\"usage\"".utf8)
    private static let quotaMarker = Array("\"quotaLimits\"".utf8)

    func refresh() -> (events: [UsageEvent], rejections: [QuotaRejection]) {
        if scanner.needsRebuild() {
            scanner.reset()
            events.removeAll()
            exactKeys.removeAll()
            replayRoutes.removeAll()
            sidechainRoutes.removeAll()
            rejections.removeAll()
        }
        scanner.scan { _, line in
            guard ByteSearch.contains(line, Self.usageMarker)
                    || ByteSearch.contains(line, Self.quotaMarker) else { return }
            guard let base = line.baseAddress else { return }
            let data = Data(bytes: base, count: line.count)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            ingest(object)
        }
        let cutoff = Date().addingTimeInterval(-LogScanner.retention)
        events = events.filter { $0.value.event.timestamp > cutoff }
        rejections = rejections.filter { $0.timestamp > cutoff }
        return (events.values.map(\.event), rejections)
    }

    private func ingest(_ object: [String: Any]) {
        guard let stamp = object["timestamp"] as? String,
              let timestamp = ISO8601.date(from: stamp)
        else { return }

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
                ?? "\(messageID)|\(sessionID)|\(Int64(timestamp.timeIntervalSince1970 * 1000))"
        } else {
            rawKey = UUID().uuidString
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
            if existing.isSidechain != isSidechain {
                if isSidechain { return }
            } else if existing.event.counts.total >= counts.total {
                return
            }
        }
        events[key] = Entry(event: UsageEvent(timestamp: timestamp, model: model, counts: counts,
                                              dedupeKey: key, sessionID: sessionID),
                            isSidechain: isSidechain)
    }
}

enum ISO8601 {
    private static let withFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let plain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(from string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}
