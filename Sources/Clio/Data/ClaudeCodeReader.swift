import Foundation

/// Reads `~/.claude/projects/**/*.jsonl`.
///
/// Usage lives on `type: "assistant"` lines under `message.usage`; the cache
/// write is split by TTL under `usage.cache_creation`. Resumed sessions write
/// the same response into more than one file, so responses are keyed by
/// `requestId` (falling back to `uuid`).
final class ClaudeCodeReader {
    private let scanner = LogScanner(root: Tool.claudeCode.logDirectory)
    private var events: [String: UsageEvent] = [:]
    private var rejections: [QuotaRejection] = []

    var isAvailable: Bool { scanner.rootExists }

    /// Byte markers used to skip lines that cannot carry usage before paying
    /// for a JSON parse. Most lines in a session log are prompts, tool results
    /// and attachments.
    private static let usageMarker = Array("\"usage\"".utf8)
    private static let quotaMarker = Array("\"quotaLimits\"".utf8)

    func refresh() -> (events: [UsageEvent], rejections: [QuotaRejection]) {
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
        events = events.filter { $0.value.timestamp > cutoff }
        rejections = rejections.filter { $0.timestamp > cutoff }
        return (Array(events.values), rejections)
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
              let model = message["model"] as? String,
              // Locally generated placeholder responses carry no real usage.
              model != "<synthetic>"
        else { return }

        let key = (object["requestId"] as? String) ?? (object["uuid"] as? String) ?? UUID().uuidString
        guard events[key] == nil else { return }

        let creation = usage["cache_creation"] as? [String: Any]
        let write5m = creation?["ephemeral_5m_input_tokens"] as? Int
        let write1h = creation?["ephemeral_1h_input_tokens"] as? Int
        let writeTotal = usage["cache_creation_input_tokens"] as? Int ?? 0

        var counts = TokenCounts()
        counts.input = usage["input_tokens"] as? Int ?? 0
        counts.output = usage["output_tokens"] as? Int ?? 0
        counts.cacheRead = usage["cache_read_input_tokens"] as? Int ?? 0
        if write5m != nil || write1h != nil {
            counts.cacheWrite5m = write5m ?? 0
            counts.cacheWrite1h = write1h ?? 0
        } else {
            // Older logs report only the total; the 5-minute tier is the default.
            counts.cacheWrite5m = writeTotal
        }

        events[key] = UsageEvent(timestamp: timestamp,
                                 model: model,
                                 counts: counts,
                                 dedupeKey: key,
                                 sessionID: object["sessionId"] as? String ?? "")
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
