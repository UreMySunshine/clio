import Foundation
import Combine
import ServiceManagement

enum MenuBarDisplay: String, CaseIterable, Identifiable {
    case iconOnly
    case iconAndTodayTokens
    case dualQuotaPercent
    case dualQuotaAndTodayTokens
    case dualQuotaAndSeparateTodayTokens

    var id: String { rawValue }

    var title: String {
        switch self {
        case .iconOnly: return "仅图标"
        case .iconAndTodayTokens: return "图标 + 今日 Token 数"
        case .dualQuotaPercent: return "双环 + 百分比"
        case .dualQuotaAndTodayTokens: return "双环 + Token（合并显示）"
        case .dualQuotaAndSeparateTodayTokens: return "双环 + Token（分开显示）"
        }
    }

    var showsQuota: Bool {
        self == .dualQuotaPercent || self == .dualQuotaAndTodayTokens || self == .dualQuotaAndSeparateTodayTokens
    }

    func todayTokenText(_ dashboard: Dashboard) -> String? {
        guard !dashboard.isEmpty else { return nil }
        switch self {
        case .iconOnly, .dualQuotaPercent:
            return nil
        case .iconAndTodayTokens, .dualQuotaAndTodayTokens:
            return Format.compact(dashboard.combined.totals[.day]?.total ?? 0)
        case .dualQuotaAndSeparateTodayTokens:
            return ModelCategory.allCases.map { category in
                Format.compact(dashboard.usageParts.first { $0.tool == category }?.usage.totals[.day]?.total ?? 0, fractionDigits: 0)
            }.joined(separator: " ")
        }
    }
}

enum Appearance: String, CaseIterable, Identifiable {
    case system, light, dark

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// User settings. Everything lives in UserDefaults except the milestone
/// snapshot, which is kept as a file so a defaults reset can't replay a
/// celebration the user already saw.
@MainActor
final class Preferences: ObservableObject {
    static let shared = Preferences()

    private let defaults: UserDefaults

    @Published var showModelSpeed: Bool { didSet { defaults.set(showModelSpeed, forKey: "showModelSpeed") } }
    @Published var confettiEnabled: Bool { didSet { defaults.set(confettiEnabled, forKey: "confettiEnabled") } }
    @Published var refreshInterval: TimeInterval { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    /// How often both tools are asked for their quota state in the background.
    @Published var quotaInterval: TimeInterval { didSet { defaults.set(quotaInterval, forKey: "quotaInterval") } }
    @Published var menuBarDisplay: MenuBarDisplay { didSet { defaults.set(menuBarDisplay.rawValue, forKey: "menuBarDisplay") } }
    @Published var usageScope: UsageScope { didSet { defaults.set(usageScope.rawValue, forKey: "usageScope") } }
    @Published var customUsageRange: UsageDateRange? {
        didSet { defaults.set(customUsageRange?.storedDays(), forKey: "customUsageRange") }
    }
    @Published var appearance: Appearance { didSet { defaults.set(appearance.rawValue, forKey: "appearance") } }
    @Published var autoCheckUpdates: Bool { didSet { defaults.set(autoCheckUpdates, forKey: "autoCheckUpdates") } }
    /// Applies only while `autoCheckUpdates` is on.
    @Published var autoInstallUpdates: Bool { didSet { defaults.set(autoInstallUpdates, forKey: "autoInstallUpdates") } }

    /// Overrides the plan label read from Claude Code's own config.
    @Published var planName: [String: String] { didSet { defaults.set(planName, forKey: "planName") } }

    @Published var launchAtLogin: Bool {
        didSet {
            guard launchAtLogin != oldValue else { return }
            applyLaunchAtLogin()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: [
            "showModelSpeed": false,
            "confettiEnabled": true,
            "refreshInterval": 30.0,
            "quotaInterval": 1800.0,
            "menuBarDisplay": MenuBarDisplay.iconAndTodayTokens.rawValue,
            "usageScope": UsageScope.combined.rawValue,
            "appearance": Appearance.system.rawValue,
            "autoCheckUpdates": true,
            "autoInstallUpdates": true,
        ])
        showModelSpeed = defaults.bool(forKey: "showModelSpeed")
        confettiEnabled = defaults.bool(forKey: "confettiEnabled")
        refreshInterval = defaults.double(forKey: "refreshInterval")
        quotaInterval = defaults.double(forKey: "quotaInterval")
        menuBarDisplay = MenuBarDisplay(rawValue: defaults.string(forKey: "menuBarDisplay") ?? "") ?? .iconAndTodayTokens
        usageScope = UsageScope(rawValue: defaults.string(forKey: "usageScope") ?? "") ?? .combined
        customUsageRange = UsageDateRange(storedDays: defaults.stringArray(forKey: "customUsageRange") ?? [])
        appearance = Appearance(rawValue: defaults.string(forKey: "appearance") ?? "") ?? .system
        autoCheckUpdates = defaults.bool(forKey: "autoCheckUpdates")
        autoInstallUpdates = defaults.bool(forKey: "autoInstallUpdates")
        planName = defaults.dictionary(forKey: "planName") as? [String: String] ?? [:]
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    private func applyLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration fails for an app that isn't in a signed bundle
            // (a development build run from ./build). Reflect the real state
            // rather than leaving the toggle lying.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    // MARK: - Milestone snapshot

    private var milestonePath: URL { AppPaths.support.appending(path: "milestones.json") }

    func loadMilestones() -> MilestoneState? {
        guard let data = try? Data(contentsOf: milestonePath) else { return nil }
        return try? JSONDecoder().decode(MilestoneState.self, from: data)
    }

    func saveMilestones(_ state: MilestoneState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: milestonePath, options: .atomic)
    }
}
