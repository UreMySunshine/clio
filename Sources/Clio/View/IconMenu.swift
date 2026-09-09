import SwiftUI
import AppKit

/// A footer icon button and the menu it pops.
///
/// The glyph is drawn by SwiftUI and the AppKit button sits transparently on
/// top: an `NSMenu` popped from a real view anchors and dismisses reliably in a
/// non-activating panel, while a SwiftUI glyph also renders off-screen, which
/// an AppKit control does not.
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

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 13))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if !isSnapshot { MenuTrigger(items: items) }
            }
    }
}

private struct MenuTrigger: NSViewRepresentable {
    var items: [IconMenu.Item]

    func makeNSView(context: Context) -> NSButton {
        let button = NSButton(title: "", target: context.coordinator, action: #selector(Coordinator.present(_:)))
        button.isBordered = false
        button.isTransparent = true
        button.setButtonType(.momentaryChange)
        return button
    }

    func updateNSView(_ view: NSButton, context: Context) {
        context.coordinator.items = items
    }

    func makeCoordinator() -> Coordinator { Coordinator(items: items) }

    final class Coordinator: NSObject {
        var items: [IconMenu.Item]

        init(items: [IconMenu.Item]) {
            self.items = items
        }

        @objc func present(_ sender: NSButton) {
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
        }

        @objc private func fire(_ sender: NSMenuItem) {
            guard items.indices.contains(sender.tag) else { return }
            items[sender.tag].action()
        }
    }
}
