import Foundation

/// The CLI a usage record came from.
enum Tool: String, CaseIterable, Codable, Identifiable {
    case claudeCode
    case codex

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude Code"
        case .codex: return "Codex"
        }
    }

    /// Directory scanned for session logs, shown in Settings.
    var logDirectory: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        switch self {
        case .claudeCode: return home.appending(path: ".claude/projects")
        case .codex: return home.appending(path: ".codex/sessions")
        }
    }

    var logDirectoryDisplay: String {
        switch self {
        case .claudeCode: return "~/.claude/projects"
        case .codex: return "~/.codex/sessions"
        }
    }
}

/// Token counts for one assistant response. Cache writes are split by TTL
/// because the two tiers are priced differently (1.25x vs 2x base input).
struct TokenCounts: Equatable {
    var input = 0
    var output = 0
    var cacheRead = 0
    var cacheWrite5m = 0
    var cacheWrite1h = 0
    /// Codex's reported total can differ from its available token breakdown.
    var reportedTotal: Int?

    var total: Int { reportedTotal ?? (input + output + cacheRead + cacheWrite5m + cacheWrite1h) }
    var cacheWrite: Int { cacheWrite5m + cacheWrite1h }

    static func + (a: TokenCounts, b: TokenCounts) -> TokenCounts {
        TokenCounts(input: a.input + b.input,
                    output: a.output + b.output,
                    cacheRead: a.cacheRead + b.cacheRead,
                    cacheWrite5m: a.cacheWrite5m + b.cacheWrite5m,
                    cacheWrite1h: a.cacheWrite1h + b.cacheWrite1h,
                    reportedTotal: a.reportedTotal != nil || b.reportedTotal != nil ? a.total + b.total : nil)
    }

    static func += (a: inout TokenCounts, b: TokenCounts) { a = a + b }
}

/// One assistant response read from a session log.
struct UsageEvent {
    let timestamp: Date
    let model: String
    let counts: TokenCounts
    /// Identity used to drop the duplicates that resumed sessions write into
    /// more than one log file.
    let dedupeKey: String
    /// The session the response belongs to. Empty for sources that do not
    /// record one, which then count as a single session.
    var sessionID: String = ""
}

/// The two summary cards above the heat map.
struct ActivitySummary {
    let activeHours: Double
    let previousActiveHours: Double
    let requests: Int
    let sessions: Int
    /// Recent days, oldest first, behind the two sparklines.
    let activeTrend: [Double]
    let requestTrend: [Double]

    static let empty = ActivitySummary(activeHours: 0, previousActiveHours: 0, requests: 0,
                                       sessions: 0, activeTrend: [], requestTrend: [])
}

/// A rate-limit rejection recorded in the log. Claude Code only writes these
/// when a request was actually turned away, so `resetsAt` is the one piece of
/// real quota information available locally.
struct QuotaRejection {
    let timestamp: Date
    let resetsAt: Date
    let kind: String
}

/// What one bar in the usage chart covers.
struct Bucket: Identifiable {
    let id: Int
    let label: String
    let byTool: [Tool: Int]

    var tokens: Int { byTool.values.reduce(0, +) }
}

enum Granularity: String, CaseIterable, Identifiable {
    case day, week, month, recentWeek, recentMonth

    var id: String { rawValue }

    var title: String {
        switch self {
        case .day: return "今日"
        case .week: return "本周"
        case .month: return "本月"
        case .recentWeek: return "近7天"
        case .recentMonth: return "近30天"
        }
    }
}

struct ModelUsage: Identifiable {
    let model: String
    let displayName: String
    let tokens: Int
    let cost: Double?

    var id: String { model }
}

/// A rolling quota window.
///
/// `fraction` is the real utilisation Claude Code reports through its status
/// line, or zero after a reported reset with no new local usage. When the
/// percentage is unavailable, the row shows the tokens observed locally.
/// The allowance behind the percentage is never a fixed token count — windows
/// that hit the limit in the logs range from 53M to 206M tokens — so it is never inferred.
struct QuotaWindow {
    let title: String
    let used: Int
    let fraction: Double?
    let resetsAt: Date?
    /// How long the window runs, which is what turns the pace so far into a
    /// projection. Nil when the window's span isn't known.
    var length: TimeInterval?

    /// Time until the allowance would be spent at the pace so far. Nil when
    /// there is nothing to project from — no utilisation, no boundary, or a
    /// window that has only just opened.
    func timeToExhaustion(now: Date = Date()) -> TimeInterval? {
        guard let fraction, fraction > 0, fraction < 1,
              let length, let resetsAt
        else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining > 0 else { return nil }
        let elapsed = length - remaining
        guard elapsed > 300 else { return nil }
        return elapsed * (1 - fraction) / fraction
    }
}

/// Token usage over the selectable periods, for one tool or for all of them together.
struct UsageSummary {
    let totals: [Granularity: TokenCounts]
    /// Tokens in the preceding period of the same length.
    let previousTotals: [Granularity: Int]
    /// Absent for a period with any unpriced model.
    let costs: [Granularity: Double]
    let buckets: [Granularity: [Bucket]]
    let models: [Granularity: [ModelUsage]]
    let dailyTokens: [Date: Int]
    let activity: ActivitySummary

    /// Change against the preceding period of the same length.
    func tokenTrend(_ granularity: Granularity) -> Double {
        let old = Double(previousTotals[granularity] ?? 0)
        guard old > 0 else { return 0 }
        return (Double(totals[granularity]?.total ?? 0) - old) / old
    }

    static let empty = UsageSummary(totals: [:], previousTotals: [:], costs: [:], buckets: [:],
                                    models: [:], dailyTokens: [:], activity: .empty)
}

/// Everything one tool's screen needs.
struct ToolSnapshot {
    let tool: Tool
    let plan: String?
    let fiveHour: QuotaWindow?
    let week: QuotaWindow
    /// A per-model allowance shown beneath the two windows, when configured.
    let modelQuota: QuotaWindow?
    let usage: UsageSummary
    let updatedAt: Date
}

struct Dashboard {
    let snapshots: [ToolSnapshot]
    /// Every tool's usage added together.
    let combined: UsageSummary
    let updatedAt: Date

    var isEmpty: Bool { snapshots.isEmpty }

    func snapshot(for tool: Tool) -> ToolSnapshot? {
        snapshots.first { $0.tool == tool }
    }
}
