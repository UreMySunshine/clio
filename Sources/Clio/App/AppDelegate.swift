import AppKit
import SwiftUI
import Combine

private extension Appearance {
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = UsageStore()
    private let prefs = Preferences.shared
    private var statusItem: StatusItemController?
    private var panel: PanelController?
    private var settings: SettingsWindowController?
    private let celebration = CelebrationController()
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only: no Dock tile, no app menu.
        NSApp.setActivationPolicy(.accessory)

        let settings = SettingsWindowController(store: store, prefs: prefs) { [celebration] in
            celebration.celebrate()
        }
        self.settings = settings

        let panel = PanelController(store: store, prefs: prefs) { settings.show() }
        self.panel = panel

        let statusItem = StatusItemController(store: store, prefs: prefs) { button in
            panel.toggle(relativeTo: button)
        }
        self.statusItem = statusItem
        panel.onVisibilityChange = { [weak statusItem] visible in statusItem?.setSelected(visible) }

        prefs.$appearance
            .sink { NSApp.appearance = $0.nsAppearance }
            .store(in: &cancellables)

        store.milestoneReached
            .sink { [weak self] in self?.celebration.celebrate() }
            .store(in: &cancellables)

        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleURL(_:withReply:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )

        store.start()
        Updater.shared.start(prefs: prefs)
    }

    /// `clio://open` shows the panel, `clio://settings` the window.
    @objc private func handleURL(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        let url = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue ?? ""
        if url.contains("settings") {
            settings?.show()
        } else {
            panel?.show(relativeTo: statusItem?.button)
        }
    }
}
