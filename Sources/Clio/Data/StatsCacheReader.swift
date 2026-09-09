import Foundation

/// Reads the daily totals Claude Code keeps in `~/.claude/stats-cache.json`.
///
/// Transcripts are pruned after `cleanupPeriodDays` (30 by default), so a scan
/// can never reach further back than that. This file is Claude Code's own
/// summary and survives the pruning, which is what lets the heat map show more
/// than the last month. It is recomputed on demand rather than continuously, so
/// it fills gaps the scan cannot cover and never overrides what the scan found.
enum StatsCacheReader {
    private static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/stats-cache.json")
    }

    private struct Cache: Decodable {
        struct Day: Decodable {
            let date: String
            let tokensByModel: [String: Int]
        }
        let dailyModelTokens: [Day]?
    }

    private static let day: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    static func dailyTokens() -> [Date: Int] {
        guard let data = try? Data(contentsOf: path),
              let cache = try? JSONDecoder().decode(Cache.self, from: data),
              let days = cache.dailyModelTokens
        else { return [:] }
        var totals: [Date: Int] = [:]
        for entry in days {
            guard let date = day.date(from: entry.date) else { continue }
            let sum = entry.tokensByModel.values.reduce(0, +)
            guard sum > 0 else { continue }
            totals[date] = sum
        }
        return totals
    }
}
