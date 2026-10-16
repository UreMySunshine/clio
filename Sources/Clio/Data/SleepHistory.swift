import Foundation

/// System sleep intervals, sorted and merged so overlapping records count once.
struct SleepTimeline: Equatable {
    let intervals: [DateInterval]

    init(_ intervals: [DateInterval] = []) {
        var merged: [DateInterval] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.duration > 0 {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        self.intervals = merged
    }

    func estimatedDuration(from start: Date?, to end: Date) -> TimeInterval? {
        guard let start, end > start else { return nil }
        var lower = 0
        var upper = intervals.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if intervals[middle].end <= start { lower = middle + 1 } else { upper = middle }
        }
        var asleep: TimeInterval = 0
        for interval in intervals[lower...] {
            if interval.start >= end { break }
            asleep += min(end, interval.end).timeIntervalSince(max(start, interval.start))
        }
        return OutputSpeed.estimatedDuration(from: start, to: end.addingTimeInterval(-asleep))
    }

    /// pmset reports completed sleep intervals in local time with an explicit offset.
    static func parse(_ log: String) -> SleepTimeline {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        var intervals: [DateInterval] = []
        for line in log.split(separator: "\n") where line.contains("Entering Sleep state") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count > 4, fields[3] == "Sleep",
                let unit = fields.lastIndex(of: "secs"), unit > 0,
                let seconds = TimeInterval(fields[unit - 1]), seconds > 0,
                let start = formatter.date(from: String(line.prefix(25)))
            else { continue }
            intervals.append(DateInterval(start: start, duration: seconds))
        }
        return SleepTimeline(intervals)
    }
}

/// Read power history once, then reload after sleep or a wall-clock adjustment.
/// Refreshes without either event reuse the cached timeline and start no process.
final class SleepHistory {
    static let shared = SleepHistory()

    private let load: () -> String?
    private let clock: () -> (date: Date, uptime: TimeInterval)
    private let lock = NSLock()
    private var cached: SleepTimeline?
    private var checkedAt: (date: Date, uptime: TimeInterval)?

    init(
        load: @escaping () -> String? = SleepHistory.systemLog,
        clock: @escaping () -> (date: Date, uptime: TimeInterval) = {
            (Date(), ProcessInfo.processInfo.systemUptime)
        }
    ) {
        self.load = load
        self.clock = clock
    }

    func snapshot() -> SleepTimeline {
        lock.lock()
        defer { lock.unlock() }
        let current = clock()
        if let previous = checkedAt,
            abs(current.date.timeIntervalSince(previous.date) - (current.uptime - previous.uptime)) > 1
        {
            cached = nil
        }
        checkedAt = current
        if let cached { return cached }
        let timeline = load().map(SleepTimeline.parse) ?? SleepTimeline()
        cached = timeline
        return timeline
    }

    static func systemLog() -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "log"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
