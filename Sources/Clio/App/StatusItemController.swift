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
                          prefs.$menuBarDisplay.map { _ in () }.eraseToAnyPublisher(),
                          prefs.$tokenSource.map { _ in () }.eraseToAnyPublisher(),
                          prefs.$selectedTool.map { _ in () }.eraseToAnyPublisher()] {
            publisher
                .receive(on: RunLoop.main)
                .sink { [weak self] in self?.render() }
                .store(in: &cancellables)
        }

        // The system's theme notification arrives before the button's own
        // appearance has caught up, so a redraw on that alone can paint light
        // glyphs onto a menu bar that has already turned light. Observing the
        // value itself fires once it has actually changed.
        appearanceObservation = item.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            Task { @MainActor in self?.render() }
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

    /// Which tool the menu-bar number is drawn from.
    private var sourceSnapshot: ToolSnapshot? {
        switch prefs.tokenSource {
        case .selectedTool: return store.dashboard.snapshot(for: prefs.selectedTool) ?? store.dashboard.snapshots.first
        case .claudeCode: return store.dashboard.snapshot(for: .claudeCode)
        case .codex: return store.dashboard.snapshot(for: .codex)
        }
    }

    private func render() {
        let snapshot = sourceSnapshot
        let fraction = snapshot?.fiveHour.fraction
        let text: String?
        switch prefs.menuBarDisplay {
        case .iconOnly:
            text = nil
        case .iconAndWindowPercent:
            text = fraction.map(Format.percent)
        case .iconAndTodayTokens:
            text = snapshot.map { Format.compact(($0.totals[.day] ?? TokenCounts()).total) }
        }

        // The button's own appearance, never the application's: the theme
        // setting darkens the panel, and must not reach the menu bar.
        guard let button = item.button else { return }
        let isDark = button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua

        let label = MenuBarLabel(fraction: fraction, text: text, isDark: isDark, isSelected: isSelected)
        let renderer = ImageRenderer(content: label)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return }
        // Drawn in color rather than as a template so the ring can turn orange
        // and red with the window, as the design specifies.
        image.isTemplate = false
        button.image = image
    }
}
