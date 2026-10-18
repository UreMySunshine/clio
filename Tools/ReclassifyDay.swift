import Foundation

/// Rebuilds a closed day's model categories only after source totals reconcile.
@main
enum ReclassifyDay {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 3, let zone = TimeZone(identifier: args[2]) else {
            throw Failure.message("Usage: reclassify-day yyyy-MM-dd Area/City [--apply]")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard let start = formatter.date(from: args[1]), formatter.string(from: start) == args[1],
              let end = calendar.date(byAdding: .day, value: 1, to: start), end <= Date() else {
            throw Failure.message("A completed calendar day is required")
        }
        let day = args[1]
        let support = AppPaths.support
        let names = ["daily-tokens.json", "codex-daily-tokens.json"]
        let originals = try names.map { try Data(contentsOf: support.appending(path: $0)) }
        let old = try originals.map { try JSONDecoder().decode(UsageLedger.self, from: $0) }
        let records = [ClaudeCodeReader(sleepHistory: { SleepTimeline() }).refresh().events,
                       CodexReader(sleepHistory: { SleepTimeline() }).refresh().events]
        var totals: [String: Int] = Dictionary(uniqueKeysWithValues: ModelCategory.allCases.map { ($0.rawValue, 0) })
        for index in records.indices {
            let selected = records[index].filter { $0.timestamp >= start && $0.timestamp < end }
            let actual = selected.reduce(0) { $0 + $1.counts.total }
            guard let expected = old[index].days[day], actual == expected else {
                throw Failure.message("Source \(names[index]) does not reconcile: logs=\(actual), ledger=\(old[index].days[day].map(String.init) ?? "missing"); no statistics written")
            }
            print("source \(names[index]): \(actual) Token, \(selected.count) records")
            for event in selected { totals[ModelCategory(model: event.model).rawValue, default: 0] += event.counts.total }
        }
        let total = totals.values.reduce(0, +)
        guard total == old.reduce(0, { $0 + ($1.days[day] ?? 0) }) else { throw Failure.message("Total mismatch") }
        for category in ModelCategory.allCases { print("\(category.displayName): \(totals[category.rawValue] ?? 0) Token") }
        print("total: \(total) Token")
        guard args.contains("--apply") else { print("dry run; no statistics written"); return }
        let existingData = try? Data(contentsOf: CategoryLedger.path)
        var updated = CategoryLedger(timeZone: zone.identifier, days: [:])
        if let existingData {
            updated = try JSONDecoder().decode(CategoryLedger.self, from: existingData)
            guard updated.timeZone == zone.identifier else { throw Failure.message("Existing category ledger uses another time zone") }
        }
        if updated.days[day] == totals { print("already repaired; no changes"); return }
        updated.days[day] = totals
        let backup = support.appending(path: "Backups/model-categories-\(day)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        for index in names.indices {
            guard try Data(contentsOf: support.appending(path: names[index])) == originals[index] else {
                throw Failure.message("Source ledger changed during scan; no statistics written")
            }
            try originals[index].write(to: backup.appending(path: names[index]), options: .atomic)
        }
        if let existingData { try existingData.write(to: backup.appending(path: "model-category-days.json"), options: .atomic) }
        let cache = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/stats-cache.json")
        if FileManager.default.fileExists(atPath: cache.path) {
            try FileManager.default.copyItem(at: cache, to: backup.appending(path: "claude-stats-cache.json"))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(updated)
        try data.write(to: CategoryLedger.path, options: .atomic)
        guard try Data(contentsOf: CategoryLedger.path) == data else { throw Failure.message("Read-back verification failed") }
        print("backup: \(backup.path)")
        print("saved: \(CategoryLedger.path.path)")
        print(existingData == nil ? "rollback: remove model-category-days.json" : "rollback: restore model-category-days.json from backup")
    }

    enum Failure: Error { case message(String) }
}
