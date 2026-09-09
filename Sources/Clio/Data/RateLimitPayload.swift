import Foundation

/// Parses the quota payload Claude Code reports.
///
/// The same shape reaches this app two ways — cached in `~/.claude.json` and
/// answered to a `get_usage` request — under slightly different key names and
/// time formats.
enum RateLimitPayload {
    static func snapshot(from limits: [String: Any]) -> RateLimitSnapshot {
        RateLimitSnapshot(updatedAt: Date(),
                          fiveHour: window(limits["five_hour"]),
                          sevenDay: window(limits["seven_day"]),
                          modelScoped: scoped(limits["model_scoped"]))
    }

    private static func window(_ value: Any?) -> RateLimitWindow? {
        guard let object = value as? [String: Any] else { return nil }
        return RateLimitWindow(usedPercentage: number(object["utilization"]),
                               resetsAt: date(object["resets_at"]))
    }

    private static func scoped(_ value: Any?) -> [ScopedRateLimitWindow] {
        guard let entries = value as? [[String: Any]] else { return [] }
        return entries.compactMap { entry in
            guard let name = entry["display_name"] as? String, !name.isEmpty else { return nil }
            return ScopedRateLimitWindow(displayName: name,
                                         utilization: number(entry["utilization"]),
                                         resetsAt: date(entry["resets_at"]))
        }
    }

    static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    /// An ISO string in both sources today; Unix seconds are accepted because
    /// the CLI calls the request experimental and may change the shape.
    static func date(_ value: Any?) -> Date? {
        if let text = value as? String { return ISO8601.date(from: text) }
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: Double(seconds)) }
        return nil
    }
}
