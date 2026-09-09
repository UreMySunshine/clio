import Foundation

/// Reads `~/.codex/sessions/**/*.jsonl`.
///
/// Codex records a `token_count` event per turn; `last_token_usage` is that
/// turn's delta while `total_token_usage` is the session running total, so only
/// the delta is accumulated. `input_tokens` there already includes the cached
/// portion reported separately as `cached_input_tokens`.
///
/// The shape below is the Codex CLI rollout format. Fields are read defensively
/// and a line that doesn't match is skipped rather than failing the scan.
final class CodexReader {
    private let scanner = LogScanner(root: Tool.codex.logDirectory)
    private var events: [String: UsageEvent] = [:]
    private var currentModel = "codex"

    var isAvailable: Bool { scanner.rootExists }

    private static let marker = Array("token_count".utf8)

    func refresh() -> [UsageEvent] {
        scanner.scan { line in
            guard ByteSearch.contains(line, Self.marker) else { return }
            guard let base = line.baseAddress else { return }
            let data = Data(bytes: base, count: line.count)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            ingest(object)
        }
        let cutoff = Date().addingTimeInterval(-LogScanner.retention)
        events = events.filter { $0.value.timestamp > cutoff }
        return Array(events.values)
    }

    private func ingest(_ object: [String: Any]) {
        let payload = object["payload"] as? [String: Any] ?? [:]

        // Any line that names a model updates what later turns are attributed to.
        if let model = payload["model"] as? String, !model.isEmpty {
            currentModel = model
        }

        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any]
        else { return }

        if let model = info["model"] as? String, !model.isEmpty {
            currentModel = model
        }

        let stamp = (object["timestamp"] as? String) ?? ""
        guard let timestamp = ISO8601.date(from: stamp) else { return }

        let input = last["input_tokens"] as? Int ?? 0
        let cached = last["cached_input_tokens"] as? Int ?? 0
        var counts = TokenCounts()
        counts.input = max(0, input - cached)
        counts.cacheRead = cached
        counts.output = last["output_tokens"] as? Int ?? 0

        guard counts.total > 0 else { return }
        let key = "\(stamp)|\(currentModel)|\(counts.input)|\(counts.output)|\(counts.cacheRead)"
        guard events[key] == nil else { return }
        events[key] = UsageEvent(timestamp: timestamp, model: currentModel, counts: counts, dedupeKey: key)
    }
}
