import Foundation

/// The second source of quota state: what Claude Code hands its status line.
///
/// Running this binary as that command (or in front of an existing one) writes
/// the `rate_limits` payload where the panel can read it, and forwards stdin to
/// the wrapped command untouched so an existing status line keeps rendering.
/// It arrives on every status-line render, which is far more often than the
/// panel would poll on its own — but it has never carried the model-scoped
/// window, so it complements the CLI rather than replacing it.
enum RateLimitBridge {
    static var snapshotPath: URL { AppPaths.support.appending(path: "rate-limits.json") }

    /// `--statusline [-- command args...]`
    static func run(passthrough: [String]) -> Int32 {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        capture(input)
        guard let command = passthrough.first else { return 0 }
        return forward(input, to: command, arguments: Array(passthrough.dropFirst()))
    }

    static func capture(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let limits = root["rate_limits"] as? [String: Any]
        else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let encoded = try? encoder.encode(snapshot(from: limits)) else { return }
        try? encoded.write(to: snapshotPath, options: .atomic)
    }

    static func load() -> RateLimitSnapshot? {
        guard let data = try? Data(contentsOf: snapshotPath) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(RateLimitSnapshot.self, from: data)
    }

    /// Shared with `UsageProbe`: the two sources report the same windows, under
    /// slightly different key names and time formats.
    static func snapshot(from limits: [String: Any]) -> RateLimitSnapshot {
        RateLimitSnapshot(updatedAt: Date(),
                          fiveHour: window(limits["five_hour"]),
                          sevenDay: window(limits["seven_day"]),
                          modelScoped: scoped(limits["model_scoped"]))
    }

    private static func window(_ value: Any?) -> RateLimitWindow? {
        guard let object = value as? [String: Any] else { return nil }
        // The status line calls it `used_percentage`; the CLI's own answer to a
        // `get_usage` request calls the same number `utilization`.
        return RateLimitWindow(usedPercentage: number(object["used_percentage"]) ?? number(object["utilization"]),
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

    private static func number(_ value: Any?) -> Double? {
        if let d = value as? Double { return d }
        if let i = value as? Int { return Double(i) }
        return nil
    }

    /// The status line sends Unix seconds, the CLI an ISO string.
    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String { return ISO8601.date(from: text) }
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: Double(seconds)) }
        return nil
    }

    /// Run the wrapped status-line command with the same stdin and hand its
    /// output straight through, so wrapping is invisible to the terminal.
    private static func forward(_ input: Data, to command: String, arguments: [String]) -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [command] + arguments
        let stdin = Pipe()
        process.standardInput = stdin
        do {
            try process.run()
        } catch {
            return 0
        }
        stdin.fileHandleForWriting.write(input)
        try? stdin.fileHandleForWriting.close()
        process.waitUntilExit()
        return process.terminationStatus
    }
}
