import AppKit
import SwiftUI

/// Full-screen, click-through, non-activating overlay for the 100M milestone.
/// It floats above other apps without taking focus and lets every click through
/// to whatever is underneath, so a celebration never interrupts the user.
@MainActor
final class CelebrationController {
    private let engine = ConfettiEngine()
    private var panel: NSPanel?
    private var dismissTask: Task<Void, Never>?

    /// The design gives the overlay about five seconds on screen.
    private let duration: Duration = .seconds(5)

    func celebrate() {
        guard let screen = NSScreen.main else { return }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(screen.frame, display: false)
        panel.orderFrontRegardless()
        engine.start(in: screen.frame.size)

        dismissTask?.cancel()
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: self?.duration ?? .seconds(5))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func dismiss() {
        engine.stop()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: .zero,
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered,
                            defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: ConfettiView(engine: engine))
        return panel
    }
}
