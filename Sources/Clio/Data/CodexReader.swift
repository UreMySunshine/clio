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
    /// Latest model named in each session file. Subagent sessions log a
    /// different model alongside their parent, so it is not shared across files.
    private var models: [String: String] = [:]
    /// Latest `total_token_usage` seen in each session file.
    private var totals: [String: Int] = [:]

    var isAvailable: Bool { scanner.rootExists }

    /// `token_count` lines carry usage but no model; the model is named by the
    /// `turn_context` line that opens each turn.
    private static let usageMarker = Array("token_count".utf8)
    private static let contextMarker = Array("turn_context".utf8)

    func refresh() -> [UsageEvent] {
        scanner.scan { file, line in
            guard ByteSearch.contains(line, Self.usageMarker)
                    || ByteSearch.contains(line, Self.contextMarker) else { return }
            guard let base = line.baseAddress else { return }
            let data = Data(bytes: base, count: line.count)
            guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }
            ingest(object, file: file)
        }
        let cutoff = Date().addingTimeInterval(-LogScanner.retention)
        events = events.filter { $0.value.timestamp > cutoff }
        return Array(events.values)
    }

    private func ingest(_ object: [String: Any], file: String) {
        let payload = object["payload"] as? [String: Any] ?? [:]

        // Any line that names a model updates what later turns are attributed to.
        if let model = payload["model"] as? String, !model.isEmpty {
            models[file] = model
        }

        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let last = info["last_token_usage"] as? [String: Any]
        else { return }

        if let model = info["model"] as? String, !model.isEmpty {
            models[file] = model
        }
        let currentModel = models[file] ?? "codex"

        // An event that leaves the session total unchanged is not a request:
        // Codex repeats the last one, and reports the context size after compaction.
        if let total = (info["total_token_usage"] as? [String: Any])?["total_tokens"] as? Int {
            guard total != totals[file] else { return }
            totals[file] = total
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
