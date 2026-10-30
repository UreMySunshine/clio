import Foundation
import Combine
import AppKit

/// Owns both log readers off the main actor. Parsing runs here so the panel
/// stays responsive while ~1 GiB of session logs is walked.
actor LogReaders {
    private let claude: ClaudeCodeReader
    private let codex: CodexReader

    private var codexQuota: RateLimitSnapshot?
    private var parsed: Result?
    private var cacheKey: UsageCacheKey?
    private var cachedSnapshots: [ToolSnapshot] = []
    private var cachedCombined = UsageSummary.empty
    private var cachedCategories: [CategoryUsage] = []

    private struct UsageCacheKey: Equatable {
        var claudeRevision: Int
        var codexRevision: Int
        var prices: PriceTable
        var history: [Date: Int]
        var claudeLedger: UsageLedger?
        var codexLedger: UsageLedger?
        var categoryLedger: CategoryLedger?
        var retentionDays: Int?
        var day: Date
        var calendar: Calendar
    }

    struct Result: Sendable {
        var claudeEvents: [UsageEvent] = []
        var claudeRejections: [QuotaRejection] = []
        var codexEvents: [UsageEvent] = []
        var codexQuota: RateLimitSnapshot?
        var claudeAvailable = false
        var codexAvailable = false
    }

    init(claude: ClaudeCodeReader = ClaudeCodeReader(), codex: CodexReader = CodexReader()) {
        self.claude = claude
        self.codex = codex
    }

    func refresh() -> Result {
        var result = Result()
        result.claudeAvailable = claude.isAvailable
        result.codexAvailable = codex.isAvailable
        let claudeReading = claude.refresh()
        result.claudeEvents = claudeReading.events
        result.claudeRejections = claudeReading.rejections
        let codexReading = codex.refresh()
        result.codexEvents = codexReading.events
        result.codexQuota = codexReading.quota
        return result
    }

    /// Quota updates reuse parsed events; unchanged usage inputs reuse the summaries.
    func dashboard(prices: PriceTable, quota: [Tool: DashboardBuilder.QuotaConfig], quotaMaxAge: TimeInterval,
                   scanLogs: Bool = true, now: Date = Date(), calendar: Calendar = .current) -> Dashboard {
        if scanLogs || parsed == nil { parsed = refresh() }
        let parsed = parsed!
        let history = StatsCacheReader.dailyTokens()
        var storedClaude = UsageLedger.load(for: .claudeCode)
        var storedCodex = UsageLedger.load(for: .codex)
        let retentionDays = UsageLedger.retentionDays()
        let categoryLedger = CategoryLedger.load()
        var key = UsageCacheKey(claudeRevision: claude.revision, codexRevision: codex.revision,
                                prices: prices, history: history, claudeLedger: storedClaude,
                                codexLedger: storedCodex, categoryLedger: categoryLedger, retentionDays: retentionDays,
                                day: calendar.startOfDay(for: now), calendar: calendar)
        let reuseUsage = key == cacheKey

        var snapshots: [ToolSnapshot] = []
        var events: [UsageEvent] = []
        if (parsed.claudeAvailable && !parsed.claudeEvents.isEmpty) || storedClaude?.days.isEmpty == false || !history.isEmpty {
            let ledger = (reuseUsage ? storedClaude : nil) ?? UsageLedger.updated(storedClaude, events: parsed.claudeEvents, history: history,
                                             now: now, retentionDays: retentionDays, calendar: calendar)
            if ledger != storedClaude { ledger.save(for: .claudeCode) }
            storedClaude = ledger
            snapshots.append(DashboardBuilder.snapshot(tool: .claudeCode,
                                                       events: parsed.claudeEvents,
                                                       rejections: parsed.claudeRejections,
                                                       prices: prices,
                                                       quota: quota[.claudeCode] ?? .init(), ledger: ledger,
                                                       cachedUsage: reuseUsage ? cachedSnapshots.first { $0.tool == .claudeCode }?.usage : nil,
                                                       now: now, calendar: calendar))
            if !reuseUsage { events += parsed.claudeEvents }
        }
        if (parsed.codexAvailable && !parsed.codexEvents.isEmpty) || storedCodex?.days.isEmpty == false {
            let ledger = (reuseUsage ? storedCodex : nil) ?? UsageLedger.updated(storedCodex, events: parsed.codexEvents, history: [:],
                                             now: now, retentionDays: Int(LogScanner.retention / 86400), calendar: calendar)
            if ledger != storedCodex { ledger.save(for: .codex) }
            storedCodex = ledger
            var config = quota[.codex] ?? .init()
            codexQuota = RateLimitSnapshot.latest([config.rateLimits, parsed.codexQuota, codexQuota].compactMap { $0 },
                                                  now: now, maxAge: quotaMaxAge)
            config.rateLimits = codexQuota
            snapshots.append(DashboardBuilder.snapshot(tool: .codex,
                                                       events: parsed.codexEvents,
                                                       rejections: [],
                                                       prices: prices,
                                                       quota: config, ledger: ledger,
                                                       cachedUsage: reuseUsage ? cachedSnapshots.first { $0.tool == .codex }?.usage : nil,
                                                       now: now, calendar: calendar))
            if !reuseUsage { events += parsed.codexEvents }
        }
        if !reuseUsage {
            cachedCategories = DashboardBuilder.categorized([
                (.claudeCode, parsed.claudeEvents, storedClaude), (.codex, parsed.codexEvents, storedCodex)
            ], prices: prices, now: now, calendar: calendar, verified: categoryLedger)
            cachedCombined = DashboardBuilder.combined(cachedCategories.map(\.usage), events: events, now: now, calendar: calendar)
        }
        cachedSnapshots = snapshots
        key.claudeLedger = storedClaude
        key.codexLedger = storedCodex
        cacheKey = key
        return Dashboard(snapshots: snapshots, combined: cachedCombined, updatedAt: now, categories: cachedCategories)
    }
}

/// Main-actor requests share one worker; a pending log scan takes priority.
struct RefreshRequests {
    private var isRunning = false
    private var pending: Bool?

    mutating func request(scanLogs: Bool) -> Bool {
        pending = (pending ?? false) || scanLogs
        guard !isRunning else { return false }
        isRunning = true
        return true
    }

    mutating func next() -> Bool? {
        guard let request = pending else {
            isRunning = false
            return nil
        }
        pending = nil
        return request
    }
}

/// Owns the readers, the refresh timer, and the current dashboard.
@MainActor
final class UsageStore: ObservableObject {
    @Published private(set) var dashboard = Dashboard(snapshots: [], combined: .empty, updatedAt: .distantPast)
    @Published private(set) var isLoading = true
    @Published private(set) var priceOrigin: PriceOrigin = .builtin
    /// When the price table was last read from models.dev.
    @Published private(set) var priceFetchedAt: Date?
    @Published private(set) var lastQuotaQuery: Date?

    /// Raised when a 100M milestone is crossed; the celebration window observes it.
    let milestoneReached = PassthroughSubject<Void, Never>()

    private var isPreview = false
    private let readers = LogReaders()
    private let prefs = Preferences.shared
    private var timer: Timer?
    private var refreshRequests = RefreshRequests()
    private var probeInFlight = false
    private var claudeQuota: RateLimitSnapshot?
    private var codexReading: CodexUsageProbe.Reading?
    private var codexProbeInFlight = false
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
        await refresh(scanLogs: false)
    }

    private func startTimer(_ interval: TimeInterval) {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: max(5, interval), repeats: true) { [weak self] _ in
            Task { @MainActor in
                await PriceService.shared.refreshIfNeeded()
                await self?.refresh()
            }
        }
    }

    func refresh(scanLogs: Bool = true) async {
        guard !isPreview else { return }
        guard refreshRequests.request(scanLogs: scanLogs) else { return }
        while let scanLogs = refreshRequests.next() {
            await performRefresh(scanLogs: scanLogs)
        }
    }

    private func performRefresh(scanLogs: Bool) async {
        let prices = await PriceService.shared.table()
        let feed = RateLimitBridge.load()
        lastFeedUpdate = feed?.updatedAt
        let config = ClaudeConfigReader.read()
        // Fresh enough to trust: two polling periods, so raising the interval
        // in Settings doesn't make the panel drop the percentages in between.
        let maxAge = prefs.quotaInterval * 2
        let liveLimits = RateLimitSnapshot.merged([feed, config].compactMap { $0 },
                                                  now: Date(),
                                                  maxAge: maxAge)?.stabilized(against: claudeQuota, now: Date())
        claudeQuota = liveLimits
        let origin = await PriceService.shared.origin
        let fetchedAt = await PriceService.shared.lastFetch

        let quotaConfig = Tool.allCases.reduce(into: [Tool: DashboardBuilder.QuotaConfig]()) { table, tool in
            let configured = prefs.planName[tool.rawValue]
            table[tool] = DashboardBuilder.QuotaConfig(
                // The tier Claude Code records locally, unless overridden.
                planName: (configured?.isEmpty == false ? configured : nil)
                    ?? (tool == .claudeCode ? PlanReader.claudeCodePlan() : codexReading?.plan),
                rateLimits: tool == .claudeCode ? liveLimits : codexReading?.quota,
                remainingResets: tool == .codex ? codexReading?.remainingResets : nil
            )
        }

        let built = await readers.dashboard(prices: prices, quota: quotaConfig, quotaMaxAge: maxAge, scanLogs: scanLogs)

        priceOrigin = origin
        priceFetchedAt = fetchedAt
        dashboard = built
        isLoading = false

        checkMilestone(built.combined)
        probeIfDue()
    }

    /// Called as the panel opens, so what it shows is current.
    func probeNow() {
        guard !isPreview else { return }
        probeIfDue(force: true)
    }

    /// Both account queries start together and run off the main actor.
    private func probeIfDue(force: Bool = false) {
        let due = lastQuotaQuery.map { Date().timeIntervalSince($0) >= prefs.quotaInterval } ?? true
        guard force || due, !probeInFlight || !codexProbeInFlight else { return }
        lastQuotaQuery = Date()
        if !probeInFlight {
            probeInFlight = true
            Task { [weak self] in
                let probed = await Task.detached(priority: .utility, operation: { UsageProbe.fetch() }).value
                guard let self else { return }
                self.probeInFlight = false
                // Claude's cache records the fetch time; the control response does not.
                guard probed != nil else { return }
                await self.refresh(scanLogs: false)
            }
        }
        if !codexProbeInFlight {
            codexProbeInFlight = true
            Task { [weak self] in
                let reading = await Task.detached(priority: .utility, operation: { CodexUsageProbe.fetch() }).value
                guard let self else { return }
                self.codexReading = reading
                self.codexProbeInFlight = false
                await self.refresh(scanLogs: false)
            }
        }
    }

    /// Daily milestones use the combined usage of both tools.
    private func checkMilestone(_ usage: UsageSummary) {
        let previous = prefs.loadMilestones()
        let current = Milestones.state(dayTokens: usage.totals[.day]?.total ?? 0,
                                       weekTokens: usage.totals[.week]?.total ?? 0,
                                       monthTokens: usage.totals[.month]?.total ?? 0,
                                       at: Date())
        let fire = Milestones.shouldCelebrate(previous: previous, current: current)
        prefs.saveMilestones(Milestones.merged(previous: previous, current: current))
        if fire && prefs.confettiEnabled {
            milestoneReached.send()
        }
    }

    /// A store holding a fixed dashboard, for rendering a design comparison.
    static func preview(_ dashboard: Dashboard) -> UsageStore {
        let store = UsageStore()
        store.isPreview = true
        store.timer?.invalidate()
        store.timer = nil
        store.dashboard = dashboard
        store.isLoading = false
        return store
    }

    func openLogDirectory(for tool: Tool) {
        NSWorkspace.shared.open(tool.logDirectory)
    }
}
