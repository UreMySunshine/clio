import SwiftUI
import AppKit

/// A footer icon button and the menu it pops.
///
/// The glyph is drawn by SwiftUI and the AppKit button sits transparently on
/// top: an `NSMenu` popped from a real view anchors and dismisses reliably in a
/// non-activating panel, while a SwiftUI glyph also renders off-screen, which
/// an AppKit control does not. The button receives the pointer, so it reports
/// hover and press for the glyph to show.
struct IconMenu: View {
    struct Item {
        let title: String
        let shortcut: String
        var isOn = false
        let action: () -> Void
    }

    var symbol: String
    var tint: Color
    var items: [Item]

    @Environment(\.isSnapshot) private var isSnapshot
    @Environment(\.theme) private var theme
    @State private var isHovered = false
    @State private var isPressed = false

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(isHovered ? theme.segmentedFill : .clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .scaleEffect(isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.08), value: isHovered)
            .animation(.easeOut(duration: 0.1), value: isPressed)
            .overlay {
                if !isSnapshot {
                    MenuTrigger(items: items,
                                onHover: { isHovered = $0 },
                                onPress: { isPressed = $0 })
                }
            }
    }
}

private struct MenuTrigger: NSViewRepresentable {
    var items: [IconMenu.Item]
    var onHover: (Bool) -> Void
    var onPress: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingButton {
        let button = TrackingButton(title: "", target: context.coordinator, action: #selector(Coordinator.present(_:)))
        button.isBordered = false
        button.isTransparent = true
        button.setButtonType(.momentaryChange)
        return button
    }

    func updateNSView(_ view: TrackingButton, context: Context) {
        context.coordinator.items = items
        view.onHover = onHover
        view.onPress = onPress
    }

    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    final class Coordinator: NSObject {
        var items: [IconMenu.Item]

        init(items: [IconMenu.Item]) {
            self.items = items
        }

        @objc func present(_ sender: NSButton) {
            let button = sender as? TrackingButton
            button?.onPress?(false)
            let menu = NSMenu()
            for (index, item) in items.enumerated() {
                if item.title.isEmpty {
                    menu.addItem(.separator())
                    continue
                }
                let entry = NSMenuItem(title: item.title,
                                       action: #selector(fire(_:)),
                                       keyEquivalent: item.shortcut)
                entry.keyEquivalentModifierMask = item.shortcut.isEmpty ? [] : [.command]
                entry.target = self
                entry.tag = index
                entry.state = item.isOn ? .on : .off
                menu.addItem(entry)
            }
            menu.popUp(positioning: nil,
                       at: NSPoint(x: 0, y: sender.bounds.height + 4),
                       in: sender)
            // The menu swallows the exit event when the pointer leaves while it
            // is open.
            button?.syncHover()
        }

        @objc private func fire(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag) else { return }
            items[sender.tag].action()
        }
    }
}

private final class TrackingButton: NSButton {
    var onHover: ((Bool) -> Void)?
    var onPress: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(false)
    }

    override func mouseDown(with event: NSEvent) {
        onPress?(true)
        // Returns once the button is released, after any menu it opened closes.
        super.mouseDown(with: event)
        onPress?(false)
    }

    func syncHover() {
        guard let window else { return }
        onHover?(bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil)))
    }
}
