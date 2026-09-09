import Foundation

/// One quota window as Claude Code reports it.
struct RateLimitWindow: Codable, Equatable {
    /// 0–100 as reported upstream.
    var usedPercentage: Double?
    var resetsAt: Date?

    var fraction: Double? {
        usedPercentage.map { min(1, max(0, $0 / 100)) }
    }
}

/// A model-scoped weekly allowance, e.g. the Fable window.
struct ScopedRateLimitWindow: Codable, Equatable {
    var displayName: String
    var utilization: Double?
    var resetsAt: Date?

    var fraction: Double? {
        utilization.map { min(1, max(0, $0 / 100)) }
    }
}

/// The real quota state, as Claude Code reports it.
struct RateLimitSnapshot: Codable, Equatable {
    var updatedAt: Date
    var fiveHour: RateLimitWindow?
    var sevenDay: RateLimitWindow?
    var modelScoped: [ScopedRateLimitWindow]
}
