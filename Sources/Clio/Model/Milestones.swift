import Foundation

/// The last observed 100M floor for each period, persisted so a crossing is
/// celebrated once and never replayed after a restart.
struct MilestoneState: Codable, Equatable {
    var dayID: String
    var dayFloor: Int
    var weekID: String
    var weekFloor: Int
    var monthID: String
    var monthFloor: Int
}

enum Milestones {
    static let step = 100_000_000

    static func periodIDs(_ date: Date, calendar: Calendar = .current) -> (day: String, week: String, month: String) {
        let c = calendar.dateComponents([.yearForWeekOfYear, .weekOfYear, .year, .month, .day], from: date)
        let day = String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
        let week = String(format: "%04d-W%02d", c.yearForWeekOfYear ?? 0, c.weekOfYear ?? 0)
        let month = String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
        return (day, week, month)
    }

    static func state(dayTokens: Int, weekTokens: Int, monthTokens: Int, at date: Date) -> MilestoneState {
        let ids = periodIDs(date)
        return MilestoneState(dayID: ids.day,
                              dayFloor: dayTokens / step,
                              weekID: ids.week,
                              weekFloor: weekTokens / step,
                              monthID: ids.month,
                              monthFloor: monthTokens / step)
    }

    /// Fire when any period reached a higher 100M floor *within the same
    /// period*. A period-id change means the counter reset, which re-baselines
    /// silently; `nil` is the first observation ever and never fires, so
    /// pre-existing usage isn't celebrated on first launch.
    static func shouldCelebrate(previous: MilestoneState?, current: MilestoneState) -> Bool {
        guard let previous else { return false }
        let dayCrossed = previous.dayID == current.dayID && current.dayFloor > previous.dayFloor
        let weekCrossed = previous.weekID == current.weekID && current.weekFloor > previous.weekFloor
        let monthCrossed = previous.monthID == current.monthID && current.monthFloor > previous.monthFloor
        return dayCrossed || weekCrossed || monthCrossed
    }

    /// Keep the stored floors monotonic inside a period so a partial read can't
    /// regress the snapshot and re-fire the same milestone later.
    static func merged(previous: MilestoneState?, current: MilestoneState) -> MilestoneState {
        guard let previous else { return current }
        var next = current
        if previous.dayID == next.dayID { next.dayFloor = max(next.dayFloor, previous.dayFloor) }
        if previous.weekID == next.weekID { next.weekFloor = max(next.weekFloor, previous.weekFloor) }
        if previous.monthID == next.monthID { next.monthFloor = max(next.monthFloor, previous.monthFloor) }
        return next
    }
}
