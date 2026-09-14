import AppKit
import SwiftUI

/// A borderless panel that behaves like a popover under the status item, but
/// keeps the design's own corner radius and background instead of an arrow.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// Whether the panel is open, published into the SwiftUI tree so the cards can
/// animate along with the window.
private final class PanelPresence: ObservableObject {
    @Published var isOpen = false
}

private struct PanelRoot<Content: View>: View {
    @ObservedObject var presence: PanelPresence
    var content: Content

    var body: some View {
        content.environment(\.panelIsOpen, presence.isOpen)
    }
}

/// A critically damped spring stepped by hand, for animating AppKit properties
/// with the same curve SwiftUI's springs use.
private struct Spring {
    let response: Double
    var value = 0.0
    var velocity = 0.0
    var target = 0.0

    var isSettled: Bool { abs(value - target) < 5e-4 && abs(velocity) < 5e-3 }

    mutating func step(_ dt: Double) {
        let omega = 2 * Double.pi / response
        let substeps = max(1, Int((dt * 120).rounded(.up)))
        let h = dt / Double(substeps)
        for _ in 0..<substeps {
            velocity += (-omega * omega * (value - target) - 2 * omega * velocity) * h
            value += velocity * h
        }
        if isSettled {
            value = target
            velocity = 0
        }
    }
}

/// Calls back on every display refresh until the callback returns false.
private final class FrameTicker: NSObject {
    private var link: CADisplayLink?
    private var last: CFTimeInterval?
    private let onFrame: (Double) -> Bool

    init(onFrame: @escaping (Double) -> Bool) {
        self.onFrame = onFrame
    }

    func start(on view: NSView) {
        guard link == nil else { return }
        last = nil
        let link = view.displayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        let dt = last.map { min(max(link.timestamp - $0, 1.0 / 240), 1.0 / 15) } ?? 1.0 / 60
        last = link.timestamp
        if !onFrame(dt) { stop() }
    }
}

@MainActor
final class PanelController {
    private var panel: NSPanel?
    private var hosting: NSView?
    private var container: NSView?
    private var outsideClickMonitor: Any?
    private var spaceChangeObserver: Any?
    /// Reported on every path that opens or closes the panel, so the menu-bar
    /// item can show the matching state.
    var onVisibilityChange: ((Bool) -> Void)?
    private let store: UsageStore
    private let prefs: Preferences
    private let onOpenSettings: () -> Void

    private let presence = PanelPresence()
    private var openness = Spring(response: Motion.panel)
    private lazy var ticker = FrameTicker { [weak self] dt in
        MainActor.assumeIsolated { self?.advance(dt) ?? false }
    }
    /// Where the status item sits along the panel's top edge: the point the
    /// panel grows from.
    private var growthOriginX = Metrics.panelWidth / 2

    init(store: UsageStore, prefs: Preferences, onOpenSettings: @escaping () -> Void) {
        self.store = store
        self.prefs = prefs
        self.onOpenSettings = onOpenSettings
    }

    /// Open, or opening. A panel still fading out counts as closed, so a click
    /// on the status item reverses it.
    var isVisible: Bool { (panel?.isVisible ?? false) && openness.target == 1 }

    func toggle(relativeTo button: NSStatusBarButton?) {
        isVisible ? hide() : show(relativeTo: button)
    }

    func show(relativeTo button: NSStatusBarButton?) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        if !panel.isVisible {
            fitContent(panel)
            position(panel, under: button)
            openness.value = 0
            openness.velocity = 0
            apply(openness: 0, to: panel)
            panel.makeKeyAndOrderFront(nil)
        }
        panel.ignoresMouseEvents = false
        NSApp.activate(ignoringOtherApps: true)
        startWatchingForOutsideClicks()
        startWatchingForSpaceChange()
        store.probeNow()
        onVisibilityChange?(true)
        publishFrame(panel)
        animateOpenness(to: 1)
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
        if let effect = container?.subviews.first as? NSVisualEffectView {
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

    /// Closes the panel. Switching desktops passes `animated: false`: the
    /// desktop slides away at once, and the panel should not linger over it.
    func hide(animated: Bool = true) {
        stopWatchingForOutsideClicks()
        stopWatchingForSpaceChange()
        onVisibilityChange?(false)
        guard let panel, panel.isVisible else { return }
        guard animated else {
            ticker.stop()
            openness.target = 0
            openness.value = 0
            openness.velocity = 0
            presence.isOpen = false
            panel.orderOut(nil)
            return
        }
        // Clicks go through a panel that is on its way out.
        panel.ignoresMouseEvents = true
        animateOpenness(to: 0)
    }

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func animateOpenness(to target: Double) {
        guard openness.target != target || !openness.isSettled else { return }
        openness.target = target
        // Under Reduce Motion the panel only fades; the cards stay as they are.
        if reduceMotion {
            presence.isOpen = true
        } else {
            withAnimation(Motion.spring(Motion.panel, reduce: false)) {
                presence.isOpen = target == 1
            }
        }
        if let container { ticker.start(on: container) }
    }

    private func advance(_ dt: Double) -> Bool {
        guard let panel else { return false }
        openness.step(dt)
        apply(openness: openness.value, to: panel)
        guard openness.isSettled else { return true }
        if openness.target == 0 { panel.orderOut(nil) }
        return false
    }

    /// Opacity, plus a lift and scale about the status item that end at rest:
    /// the panel condenses out of the menu bar rather than simply appearing.
    private func apply(openness: Double, to panel: NSPanel) {
        let progress = CGFloat(min(max(openness, 0), 1))
        panel.alphaValue = progress
        guard let layer = container?.layer else { return }
        var transform = CATransform3DIdentity
        if !reduceMotion && progress < 1 {
            let scale = 0.94 + 0.06 * progress
            let lift = 8 * (1 - progress)
            // A sublayer transform pivots on the layer's bottom-left origin, so
            // the growth point is moved there and back.
            let top = layer.bounds.height
            transform = CATransform3DMakeTranslation(growthOriginX, top + lift, 0)
            transform = CATransform3DScale(transform, scale, scale, 1)
            transform = CATransform3DTranslate(transform, -growthOriginX, -top, 0)
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = transform
        CATransaction.commit()
        // The window shadow is drawn from the content's shape, which the
        // transform just changed.
        panel.invalidateShadow()
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
        let itemX = button?.window?.frame.midX ?? origin.x + size.width / 2
        growthOriginX = min(max(itemX - origin.x, 0), size.width)
    }

    private func makePanel() -> NSPanel {
        let root = PanelRoot(presence: presence, content: PanelView(onOpenSettings: { [weak self] in
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
        .environmentObject(prefs))

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
        backdrop.autoresizingMask = [.width, .height]
        hosting.frame = backdrop.bounds
        hosting.autoresizingMask = [.width, .height]
        backdrop.addSubview(hosting)

        // The open and close animation transforms this container's sublayers,
        // which carries the blur, its mask and the content together.
        let container = NSView(frame: backdrop.frame)
        container.wantsLayer = true
        container.addSubview(backdrop)
        self.container = container

        let panel = KeyablePanel(contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: 200),
                                 styleMask: [.borderless, .nonactivatingPanel],
                                 backing: .buffered,
                                 defer: false)
        panel.contentView = container
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
            Task { @MainActor in self?.hide(animated: false) }
        }
    }

    private func stopWatchingForSpaceChange() {
        if let observer = spaceChangeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            spaceChangeObserver = nil
        }
    }
}
