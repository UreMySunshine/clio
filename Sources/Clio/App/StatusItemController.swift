import AppKit
import SwiftUI
import Combine

/// Owns the menu-bar item and keeps its rendered image in step with the data,
/// the display setting, and the system's light/dark menu bar.
@MainActor
final class StatusItemController {
    private let item: NSStatusItem
    private let store: UsageStore
    private let prefs: Preferences
    private let onToggle: (NSStatusBarButton?) -> Void
    private var cancellables: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?
    /// The menu bar's lightness the current image was drawn for.
    private var renderedDark: Bool?
    private var isSelected = false

    init(store: UsageStore, prefs: Preferences, onToggle: @escaping (NSStatusBarButton?) -> Void) {
        self.store = store
        self.prefs = prefs
        self.onToggle = onToggle
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        item.button?.target = self
        item.button?.action = #selector(handleClick)
        item.button?.imagePosition = .imageOnly

        // `@Published` fires before the property is set, so a handler that reads
        // the object back sees the previous value; the hop lets it settle first.
        for publisher in [store.$dashboard.map { _ in () }.eraseToAnyPublisher(),
                          prefs.$menuBarDisplay.map { _ in () }.eraseToAnyPublisher()] {
            publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.render() }
                .store(in: &cancellables)
        }

        // The system's theme notification arrives before the button's own
        // appearance has caught up, so a redraw on that alone can paint light
        // glyphs onto a menu bar that has already turned light. Observing the
        // value itself fires once it has actually changed — but it also fires
        // whenever the button re-resolves its appearance, which setting a new
        // image does, so it redraws only when the lightness really differs.
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.isMenuBarDark != self.renderedDark else { return }
                self.render()
            }
        }

        render()
    }

    var button: NSStatusBarButton? { item.button }

    @objc private func handleClick() {
        onToggle(item.button)
    }

    /// Called as the panel opens and closes.
    func setSelected(_ selected: Bool) {
        guard selected != isSelected else { return }
        isSelected = selected
        render()
    }

    /// The button's own appearance, never the application's: the theme setting
    /// darkens the panel, and must not reach the menu bar.
    private var isMenuBarDark: Bool? {
        item.button.map { $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    }

    private let appIcon = NSImage(named: "AppIcon") ?? NSApplication.shared.applicationIconImage

    private func render() {
        let dashboard = store.dashboard
        let text = prefs.menuBarDisplay.todayTokenText(dashboard)

        guard let button = item.button, let isDark = isMenuBarDark else { return }
        renderedDark = isDark

        let showsQuota = prefs.menuBarDisplay.showsQuota
        let label = Group {
            if showsQuota {
                MenuBarQuotaLabel(claudeFraction: dashboard.snapshot(for: .claudeCode)?.menuBarQuota.fraction,
                                  codexFraction: dashboard.snapshot(for: .codex)?.menuBarQuota.fraction,
                                  isDark: isDark, isSelected: isSelected,
                                  showsPercentages: prefs.menuBarDisplay.showsQuotaPercentages,
                                  tokenText: text)
            } else {
                MenuBarLabel(text: text, isDark: isDark, isSelected: isSelected, appIcon: appIcon)
            }
        }
        button.toolTip = showsQuota ? quotaTooltip(dashboard) : nil
        let renderer = ImageRenderer(content: label)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return }
        // The app icon retains its colors; quota rings use their threshold colors.
        image.isTemplate = false
        button.image = image
    }

    private func quotaTooltip(_ dashboard: Dashboard) -> String {
        [Tool.claudeCode, .codex].map { tool in
            guard let snapshot = dashboard.snapshot(for: tool) else {
                return "\(tool.displayName)：暂无额度数据"
            }
            let windows: [QuotaWindow]
            if let fiveHour = snapshot.fiveHour {
                windows = fiveHour.fraction != nil ? [fiveHour, snapshot.week] : [snapshot.week, fiveHour]
            } else {
                windows = [snapshot.week]
            }
            let lines = windows.map { window in
                let remaining = MenuBarQuotaLabel.remainingPercent(window.fraction)
                    .map { "\($0)%" } ?? "—"
                var line = "\(window.title)剩余 \(remaining)"
                if let reset = window.resetsAt {
                    line += "\n重置：\(reset.formatted(date: .abbreviated, time: .shortened))"
                }
                return line
            }
            return "\(tool.displayName) · " + lines.joined(separator: "\n")
        }.joined(separator: "\n\n")
    }
}
