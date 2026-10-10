import Foundation

/// Reads active and archived `.jsonl` sessions in `~/.codex`.
///
/// Codex records a `token_count` event per turn; `last_token_usage` is that
/// turn's delta while `total_token_usage` is the session running total, so only
/// the delta is accumulated (or derived from cumulative snapshots when absent).
/// `input_tokens` includes both `cached_input_tokens`
/// and `cache_write_input_tokens`.
///
/// A `token_count` line also carries `rate_limits`: `used_percent` and
/// `resets_at` for each window. A window of a day or longer is the weekly
/// allowance (10080 minutes). Shorter ones, when Codex sends them, are the
/// 5-hour allowance. The newest reading with windows replaces the previous
/// snapshot. Nothing is asked of the network.
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
        var plan: String?
    }

    private let scanners: [LogScanner]
    private var events: [String: UsageEvent] = [:]
    /// Latest model named in each session file. Subagent sessions log a
    /// different model alongside their parent, so it is not shared across files.
    private var models: [String: String] = [:]
    /// Conversation id from `session_meta`, keyed by file path.
    private var sessionIDs: [String: String] = [:]
    /// Latest `total_token_usage` seen in each session file.
    private var totals: [String: [String: Int]] = [:]
    /// Newest quota snapshot seen in any session file.
    private var quota: RateLimitSnapshot?
    private var planName: String?

    init(root: URL = Tool.codex.logDirectory) {
        scanners = [LogScanner(root: root),
                    LogScanner(root: root.deletingLastPathComponent().appending(path: "archived_sessions"))]
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

    func refresh(now: Date = Date()) -> Reading {
        if scanners.contains(where: { $0.needsRebuild() }) {
            scanners.forEach { $0.reset() }
            events.removeAll()
            models.removeAll()
            sessionIDs.removeAll()
            totals.removeAll()
            quota = nil
            planName = nil
        }
        for scanner in scanners {
            scanner.scan { file, line in
                guard ByteSearch.contains(line, Self.usageMarker)
                        || ByteSearch.contains(line, Self.contextMarker)
                        || ByteSearch.contains(line, Self.sessionMarker) else { return }
                guard let base = line.baseAddress else { return }
                let data = Data(bytes: base, count: line.count)
                guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { return }
                ingest(object, file: file)
            }
        }
        let cutoff = now.addingTimeInterval(-LogScanner.retention)
        events = events.filter { $0.value.timestamp > cutoff }
        return Reading(events: Array(events.values), quota: currentQuota(at: now), plan: planName)
    }

    private func ingest(_ object: [String: Any], file: String) {
        let payload = object["payload"] as? [String: Any] ?? [:]

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

        guard payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any]
        else { return }

        let stamp = (object["timestamp"] as? String) ?? ""
        let timestamp = ISO8601.date(from: stamp)
        if let timestamp { noteQuota(payload["rate_limits"], at: timestamp) }

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
        let key = [
            String(Int64(timestamp.timeIntervalSince1970 * 1000)), currentModel,
            String(counts.input), String(counts.output), String(counts.cacheRead),
            String(counts.cacheWrite), String(last["reasoning_output_tokens"] ?? 0), String(counts.total),
        ].joined(separator: "|")
        guard events[key] == nil else { return }
        events[key] = UsageEvent(timestamp: timestamp,
                                 model: currentModel,
                                 counts: counts,
                                 dedupeKey: key,
                                 sessionID: sessionIDs[file] ?? file)
    }

    /// A day or longer is the weekly allowance. Anything shorter is the 5-hour
    /// one. Codex currently sends only the 7-day window (`10080` minutes) on
    /// `primary` and leaves `secondary` empty.
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
        if let plan = limits["plan_type"] as? String {
            planName = PlanReader.displayName(for: plan)
        }
    }

    /// Drop a window whose reset time has passed. The next `token_count` is
    /// what replaces it; until then the old percentage belongs to a closed week.
    private func currentQuota(at now: Date) -> RateLimitSnapshot? {
        guard var snap = quota else { return nil }
        if let week = snap.sevenDay, !week.isCurrent(at: now) { snap.sevenDay = nil }
        if let five = snap.fiveHour, !five.isCurrent(at: now) { snap.fiveHour = nil }
        guard snap.fiveHour != nil || snap.sevenDay != nil else { return nil }
        return snap
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
