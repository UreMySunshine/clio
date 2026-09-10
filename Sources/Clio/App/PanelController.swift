import AppKit
import SwiftUI

/// A borderless panel that behaves like a popover under the status item, but
/// keeps the design's own corner radius and background instead of an arrow.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class PanelController {
    private var panel: NSPanel?
    private var hosting: NSView?
    private var outsideClickMonitor: Any?
    private var spaceChangeObserver: Any?
    /// Reported on every path that opens or closes the panel, so the menu-bar
    /// item can show the matching state.
    var onVisibilityChange: ((Bool) -> Void)?
    private let store: UsageStore
    private let prefs: Preferences
    private let onOpenSettings: () -> Void

    init(store: UsageStore, prefs: Preferences, onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.prefs = prefs
        self.onOpenSettings = onOpenSettings
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle(relativeTo button: NSStatusBarButton?) {
        isVisible ? hide() : show(relativeTo: button)
    }

    func show(relativeTo button: NSStatusBarButton?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        fitContent(panel)
        position(panel, under: button)
        panel.makeKeyAndOrderFront(nil)
        panel.invalidateShadow()
        NSApp.activate(ignoringOtherApps: true)
        startWatchingForOutsideClicks()
        startWatchingForSpaceChange()
        store.probeNow()
        onVisibilityChange?(true)
        publishFrame(panel)
    }

    /// Sizes the window before it is first placed, so the opening frame is
    /// already right; afterwards the content reports its own height.
    private func fitContent(_ panel: NSPanel) {
        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        applyHeight(hosting.intrinsicContentSize.height, to: panel)
    }

    private func applyHeight(_ height: CGFloat, to panel: NSPanel) {
        let wanted = ceil(height)
        guard wanted > 0, abs(wanted - panel.frame.height) > 0.5 else { return }
        // One geometry change rather than a resize followed by a move, with the
        // top edge kept under the status item.
        panel.setFrame(NSRect(x: panel.frame.minX,
                              y: panel.frame.maxY - wanted,
                              width: Metrics.panelWidth,
                              height: wanted),
                       display: true)
        // The shadow is cached from the previous shape; without this the old
        // outline's square corner stays visible beside the rounded one.
        panel.invalidateShadow()
    }

    /// Records where the panel landed, so a screenshot can target it exactly.
    private func publishFrame(_ panel: NSPanel) {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        // Screen coordinates are bottom-left origin; screencapture wants top-left.
        let top = screen.frame.maxY - panel.frame.maxY
        var line = "\(Int(panel.frame.minX)),\(Int(top)),\(Int(panel.frame.width)),\(Int(panel.frame.height))\n"
        if let effect = panel.contentView as? NSVisualEffectView {
            line += "backdrop=NSVisualEffectView material=\(effect.material.rawValue)"
                + " blending=\(effect.blendingMode == .behindWindow ? "behindWindow" : "withinWindow")"
                + " state=\(effect.state == .active ? "active" : "other")"
                + " windowOpaque=\(panel.isOpaque)\n"
        } else {
            line += "backdrop=缺失\n"
        }
        try? line.write(to: AppPaths.support.appending(path: "panel-frame.txt"),
                        atomically: true,
                        encoding: .utf8)
    }

    func hide() {
        panel?.orderOut(nil)
        stopWatchingForOutsideClicks()
        stopWatchingForSpaceChange()
        onVisibilityChange?(false)
    }

    /// Anchor the panel under the status item, clamped to the screen so it
    /// never hangs off the right edge on a narrow display.
    private func position(_ panel: NSPanel, under button: NSStatusBarButton?) {
        guard let screen = button?.window?.screen ?? NSScreen.main else { return }
        let size = panel.frame.size
        var origin = CGPoint(x: screen.frame.maxX - size.width - 12,
                             y: screen.visibleFrame.maxY - size.height)
        if let frame = button?.window?.frame {
            origin.x = frame.midX - size.width / 2
            origin.y = frame.minY - size.height - 6
        }
        origin.x = min(max(screen.frame.minX + 8, origin.x), screen.frame.maxX - size.width - 8)
        panel.setFrameOrigin(origin)
    }

    private func makePanel() -> NSPanel {
        let root = PanelView(onOpenSettings: { [weak self] in
            self?.hide()
            self?.onOpenSettings()
        }, onContentHeight: { [weak self] height in
            // Applied in the update the content changed in. Deferring it by a
            // run-loop turn left one frame where the new layout sat in the old
            // window and was drawn shifted and clipped.
            guard let self, let panel = self.panel else { return }
            self.applyHeight(height, to: panel)
            if panel.isVisible { self.publishFrame(panel) }
        })
        .environmentObject(store)
        .environmentObject(prefs)

        let hosting = NSHostingView(rootView: root)
        // Measurement only: the frame is driven by the autoresizing mask below,
        // so an intrinsic size can never fight the window's own height.
        hosting.sizingOptions = [.intrinsicContentSize]
        self.hosting = hosting

        // The panel's translucent fills are designed to sit over a blurred
        // backdrop; without one they composite against the desktop and read as
        // washed-out grey.
        let backdrop = NSVisualEffectView()
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        // Stays blurred even when the panel isn't the key window; `.followsWindowActiveState`
        // would flatten it the moment focus moves elsewhere.
        backdrop.state = .active
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = Metrics.panelRadius
        backdrop.layer?.masksToBounds = true
        // The behind-window blur — and the window shadow derived from it — take
        // their shape from this mask. A layer corner radius only clips what is
        // drawn on top, which left the shadow square at the corners.
        backdrop.maskImage = Self.roundedMask(radius: Metrics.panelRadius)
        backdrop.frame = NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 200)
        hosting.frame = backdrop.bounds
        hosting.autoresizingMask = [.width, .height]
        backdrop.addSubview(hosting)

        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 200),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.contentView = backdrop
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovable = false
        // Chart and heatmap readouts follow the pointer.
        panel.acceptsMouseMovedEvents = true
        return panel
    }

    /// A stretchable rounded rectangle: the corners are drawn once and the
    /// straight runs are stretched to whatever size the panel has.
    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func startWatchingForOutsideClicks() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func stopWatchingForOutsideClicks() {
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    /// The panel joins every space, so switching desktops would otherwise carry
    /// it along — with the menu-bar item left showing as selected.
    private func startWatchingForSpaceChange() {
        guard spaceChangeObserver == nil else { return }
        spaceChangeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.hide() }
        }
    }

    private func stopWatchingForSpaceChange() {
        if let observer = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceChangeObserver = nil
        }
    }
}
