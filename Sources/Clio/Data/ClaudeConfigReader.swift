import Foundation

/// Reads the quota state Claude Code caches in `~/.claude.json`.
///
/// `cachedUsageUtilization` holds the same payload the CLI answers a
/// `get_usage` request with, plus the time it was fetched, and Claude Code
/// refreshes it while it runs. Reading the file costs nothing, so it is the
/// first source tried; the CLI is asked only on the slower schedule.
///
/// The block under `juniper_tide` is the weekly session-limit reset that the
/// terminal offers as `/limit-reset`. It is null unless the account is in that
/// experiment.
enum ClaudeConfigReader {
    private static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude.json")
    }

    static func read() -> (limits: RateLimitSnapshot, counter: QuotaCounter?)? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return parse(data)
    }

    /// Split from the file read so a payload can be checked on its own.
    static func parse(_ data: Data) -> (limits: RateLimitSnapshot, counter: QuotaCounter?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cached = root["cachedUsageUtilization"] as? [String: Any],
              let utilization = cached["utilization"] as? [String: Any]
        else { return nil }

        var snapshot = RateLimitBridge.snapshot(from: utilization)
        if let fetched = cached["fetchedAtMs"] as? Double {
            snapshot.updatedAt = Date(timeIntervalSince1970: fetched / 1000)
        }
        // The scoped window is reported through `limits` here rather than
        // `model_scoped`, which this payload leaves null.
        if snapshot.modelScoped.isEmpty {
            snapshot.modelScoped = scopedFromLimits(utilization["limits"])
        }
        return (snapshot, resetCounter(utilization["juniper_tide"]))
    }

    private static func scopedFromLimits(_ value: Any?) -> [ScopedRateLimitWindow] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard entry["kind"] as? String == "weekly_scoped",
                  let scope = entry["scope"] as? [String: Any],
                  let model = scope["model"] as? [String: Any],
                  let name = model["display_name"] as? String, !name.isEmpty
            else { return nil }
            return ScopedRateLimitWindow(displayName: name,
                                         utilization: entry["percent"] as? Double
                                             ?? (entry["percent"] as? Int).map(Double.init),
                                         resetsAt: (entry["resets_at"] as? String).flatMap(ISO8601.date(from:)))
        }
    }

    /// "剩余重置次数 1 / 1" — how many session-limit resets this week are still
    /// unspent. The block carries one boolean and a weekly allowance.
    private static func resetCounter(_ value: Any?) -> QuotaCounter? {
        guard let block = value as? [String: Any] else { return nil }
        let perWeek = (block["resets_per_week"] as? Int) ?? 1
        guard perWeek > 0 else { return nil }
        let available = block["available"] as? Bool ?? false
        return QuotaCounter(title: "剩余重置次数",
                            value: "\(available ? perWeek : 0)",
                            suffix: "/ \(perWeek)")
    }
}
