import AppKit
import SwiftUI

/// The standalone settings window.
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let store: UsageStore
    private let prefs: Preferences
    private let onPreviewConfetti: () -> Void

    init(store: UsageStore, prefs: Preferences, onPreviewConfetti: @escaping () -> Void) {
        self.store = store
        self.prefs = prefs
        self.onPreviewConfetti = onPreviewConfetti
    }

    func show() {
        let window = self.window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.center()
    }

    private func makeWindow() -> NSWindow {
        let root = SettingsView(onPreviewConfetti: onPreviewConfetti)
            .environmentObject(store)
            .environmentObject(prefs)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 640),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered,
                              defer: false)
        window.title = "设置"
        // The content runs under the title bar, so the bar keeps its material:
        // made transparent, scrolled rows showed straight through the title.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: root)
        return window
    }
}
