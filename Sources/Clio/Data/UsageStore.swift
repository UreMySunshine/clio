import Foundation
import Combine
import AppKit

/// Owns both log readers off the main actor. Parsing runs here so the panel
/// stays responsive while ~1 GiB of session logs is walked.
actor LogReaders {
    private let claude = ClaudeCodeReader()
    private let codex = CodexReader()

    struct Result: Sendable {
        var claudeEvents: [UsageEvent] = []
        var claudeRejections: [QuotaRejection] = []
        var codexEvents: [UsageEvent] = []
        var claudeAvailable = false
        var codexAvailable = false
    }

    func refresh() -> Result {
        var result = Result()
        result.claudeAvailable = claude.isAvailable
        result.codexAvailable = codex.isAvailable
        if result.claudeAvailable {
            let parsed = claude.refresh()
            result.claudeEvents = parsed.events
            result.claudeRejections = parsed.rejections
        }
        if result.codexAvailable {
            result.codexEvents = codex.refresh()
        }
        return result
    }
}

/// Owns the readers, the refresh timer, and the current dashboard.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var dashboard = Dashboard(snapshots: [], updatedAt: .distantPast)
    @Published private(set) var isLoading = true
    @Published private(set) var priceOrigin: PriceOrigin = .builtin
    /// When the price table was last read from models.dev.
    @Published private(set) var priceFetchedAt: Date?
    /// Quota state captured from the status-line feed, when it is connected.
    @Published private(set) var rateLimits: RateLimitSnapshot?

    /// Raised when a 100M milestone is crossed; the celebration window observes it.
    let milestoneReached = PassthroughSubject<Void, Never>()

    private let readers = LogReaders()
    private let prefs = Preferences.shared
    private var timer: Timer?
    private var lastProbe: Date?
    private var probeInFlight = false
    private var lastProbeResult: RateLimitSnapshot?
    private var lastFeedUpdate: Date?
    private var quotaWatch: DispatchSourceFileSystemObject?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        prefs.$refreshInterval
            .removeDuplicates()
            .sink { [weak self] interval in self?.startTimer(interval) }
            .store(in: &cancellables)
    }

    func start() {
        Task {
            await PriceService.shared.refreshIfNeeded()
            await refresh()
        }
        startTimer(prefs.refreshInterval)
        watchQuotaFeed()
    }

    /// The status-line feed is written whenever Claude Code renders, which is
    /// not on our schedule. Watching the directory picks a new payload up as it
    /// lands instead of on the next tick.
    private func watchQuotaFeed() {
        let descriptor = open(AppPaths.support.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                                                              eventMask: [.write],
                                                              queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in await self?.refreshIfFeedChanged() }
        }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        quotaWatch = source
    }

    /// The directory also holds files this app writes itself, so a rebuild only
    /// happens when the feed itself changed.
    private func refreshIfFeedChanged() async {
        guard RateLimitBridge.load()?.updatedAt != lastFeedUpdate else { return }
        await refresh()
    }

    private func startTimer(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(5, interval), repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func refresh() async {
        let prices = await PriceService.shared.table()
        let feed = RateLimitBridge.load()
        lastFeedUpdate = feed?.updatedAt
        // Fresh enough to trust: two polling periods, so raising the interval
        // in Settings doesn't make the panel drop the percentages in between.
        let liveLimits = combined(lastProbeResult, feed).flatMap {
            Date().timeIntervalSince($0.updatedAt) < prefs.quotaInterval * 2 ? $0 : nil
        }
        rateLimits = liveLimits
        let origin = await PriceService.shared.origin
        let fetchedAt = await PriceService.shared.lastFetch

        let quotaConfig = Tool.allCases.reduce(into: [Tool: DashboardBuilder.QuotaConfig]()) { table, tool in
            let configured = prefs.planName[tool.rawValue]
            table[tool] = DashboardBuilder.QuotaConfig(
                // The tier Claude Code records locally, unless overridden.
                planName: (configured?.isEmpty == false ? configured : nil)
                    ?? (tool == .claudeCode ? PlanReader.claudeCodePlan() : nil),
                rateLimits: tool == .claudeCode ? liveLimits : nil
            )
        }

        let parsed = await readers.refresh()

        var snapshots: [ToolSnapshot] = []
        if parsed.claudeAvailable && !parsed.claudeEvents.isEmpty {
            snapshots.append(DashboardBuilder.snapshot(tool: .claudeCode,
                                                       events: parsed.claudeEvents,
                                                       rejections: parsed.claudeRejections,
                                                       prices: prices,
                                                       quota: quotaConfig[.claudeCode] ?? .init()))
        }
        if parsed.codexAvailable && !parsed.codexEvents.isEmpty {
            snapshots.append(DashboardBuilder.snapshot(tool: .codex,
                                                       events: parsed.codexEvents,
                                                       rejections: [],
                                                       prices: prices,
                                                       quota: quotaConfig[.codex] ?? .init()))
        }

        priceOrigin = origin
        priceFetchedAt = fetchedAt
        dashboard = Dashboard(snapshots: snapshots, updatedAt: Date())
        isLoading = false

        if !snapshots.contains(where: { $0.tool == prefs.selectedTool }), let first = snapshots.first {
            prefs.selectedTool = first.tool
        }
        checkMilestone(snapshots)
        probeIfDue()
    }

    /// Called as the panel opens, so what it shows is current.
    func probeNow() {
        probeIfDue(force: true)
    }

    /// Runs alongside the panel rather than in front of it: the CLI takes a
    /// second or two to answer, and the rest of the dashboard shouldn't wait.
    private func probeIfDue(force: Bool = false) {
        guard !probeInFlight else { return }
        let due = lastProbe.map { Date().timeIntervalSince($0) >= prefs.quotaInterval } ?? true
        guard force || due else { return }
        probeInFlight = true
        lastProbe = Date()
        Task { [weak self] in
            let probed = await Task.detached(priority: .utility, operation: { UsageProbe.fetch() }).value
            guard let self else { return }
            self.probeInFlight = false
            // An answer without limits leaves the previous reading in place.
            guard let probed else { return }
            self.lastProbeResult = probed
            await self.refresh()
        }
    }

    /// Newer wins, except that a source without the model-scoped window doesn't
    /// erase one the other still has — the status line has never carried it.
    private func combined(_ a: RateLimitSnapshot?, _ b: RateLimitSnapshot?) -> RateLimitSnapshot? {
        guard let a else { return b }
        guard let b else { return a }
        var newest = a.updatedAt >= b.updatedAt ? a : b
        let older = a.updatedAt >= b.updatedAt ? b : a
        if newest.modelScoped.isEmpty { newest.modelScoped = older.modelScoped }
        return newest
    }

    /// All three periods are watched: a calendar week can straddle a month
    /// boundary, and the day is what the panel shows by default.
    private func checkMilestone(_ snapshots: [ToolSnapshot]) {
        let day = snapshots.reduce(0) { $0 + ($1.totals[.day]?.total ?? 0) }
        let week = snapshots.reduce(0) { $0 + ($1.totals[.week]?.total ?? 0) }
        let month = snapshots.reduce(0) { $0 + ($1.totals[.month]?.total ?? 0) }
        let previous = prefs.loadMilestones()
        let current = Milestones.state(dayTokens: day, weekTokens: week, monthTokens: month, at: Date())
        let fire = Milestones.shouldCelebrate(previous: previous, current: current)
        prefs.saveMilestones(Milestones.merged(previous: previous, current: current))
        if fire && prefs.confettiEnabled {
            milestoneReached.send()
        }
    }

    /// A store holding a fixed dashboard, for rendering a design comparison.
    static func preview(_ dashboard: Dashboard) -> UsageStore {
        let store = UsageStore()
        store.dashboard = dashboard
        store.isLoading = false
        return store
    }

    func openLogDirectory() {
        NSWorkspace.shared.open(prefs.selectedTool.logDirectory)
    }
}
