import AppKit
import SwiftUI

/// Renders each screen off-screen to PNG, for comparing against the design
/// without driving the menu bar by hand.
@MainActor
enum Snapshot {
    static func run(into directory: String) {
        let folder = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // SwiftUI's off-screen renderer needs AppKit initialised, but this mode
        // must not put anything on screen.
        NSApplication.shared.setActivationPolicy(.prohibited)

        let store = UsageStore()
        let prefs = Preferences.shared

        Task {
            await PriceService.shared.refreshIfNeeded()
            await store.refresh()
            // The quota probe answers after the first build; wait for it so the
            // rendered panel carries percentages rather than bare token counts.
            store.probeNow()
            try? await Task.sleep(nanoseconds: 6_000_000_000)

            for scheme in [ColorScheme.light, .dark] {
                let name = scheme == .light ? "light" : "dark"
                write(PanelView(onOpenSettings: {})
                        .environmentObject(store)
                        .environmentObject(prefs)
                        .environment(\.colorScheme, scheme)
                        .background(backdrop(scheme)),
                      to: folder.appending(path: "panel-\(name).png"))

                write(SettingsContent()
                        .environmentObject(store)
                        .environmentObject(prefs)
                        .environment(\.colorScheme, scheme)
                        .background(backdrop(scheme)),
                      to: folder.appending(path: "settings-\(name).png"))

                write(EmptyStateView(onRescan: {}, onSettings: {})
                        .frame(width: Metrics.panelWidth)
                        .environment(\.theme, Theme.resolve(scheme))
                        .background(Theme.resolve(scheme).panelFill)
                        .environment(\.colorScheme, scheme)
                        .background(backdrop(scheme)),
                      to: folder.appending(path: "empty-\(name).png"))
            }

            write(PanelView(onOpenSettings: {}, initialGranularity: .week)
                    .environmentObject(store)
                    .environmentObject(prefs)
                    .environment(\.colorScheme, .light)
                    .background(backdrop(.light)),
                  to: folder.appending(path: "panel-week.png"))

            for scheme in [ColorScheme.light, .dark] {
                let name = scheme == .light ? "light" : "dark"
                write(PanelView(onOpenSettings: {})
                        .environmentObject(UsageStore.preview(DesignSample.dashboard()))
                        .environmentObject(prefs)
                        .environment(\.colorScheme, scheme)
                        .background(backdrop(scheme)),
                      to: folder.appending(path: "sample-\(name).png"))
            }

            write(menuBarStrip(), to: folder.appending(path: "menubar.png"))
            write(confettiFrame(), to: folder.appending(path: "confetti.png"))
            print("已输出到 \(folder.path)")
            exit(0)
        }
        CFRunLoopRun()
    }

    /// A frame partway through a celebration, over a stand-in desktop.
    private static func confettiFrame() -> some View {
        let size = CGSize(width: 640, height: 400)
        let engine = ConfettiEngine()
        engine.start(in: size)
        engine.stop()
        engine.start(in: size)
        // Advance far enough that several sprays are airborne and falling.
        for _ in 0..<70 { engine.step(1.0 / 60) }
        return ConfettiView(engine: engine)
            .frame(width: size.width, height: size.height)
            .background(Color(hex: 0x141416))
    }

    /// Stand-in for the window's blurred backdrop, which an off-screen render
    /// has no desktop to sample.
    private static func backdrop(_ scheme: ColorScheme) -> Color {
        scheme == .light ? Color(hex: 0xECECF0) : Color(hex: 0x1E1E20)
    }

    /// All six menu-bar states from the design's close-up, stacked.
    private static func menuBarStrip() -> some View {
        VStack(spacing: 0) {
            ForEach(Array([(0.32, false, false), (0.62, false, false), (0.91, false, false),
                           (0.62, true, false), (0.91, true, false), (0.91, true, true)].enumerated()),
                    id: \.offset) { _, state in
                HStack {
                    Spacer()
                    MenuBarLabel(fraction: state.0,
                                 text: Format.compact(1_243_610),
                                 isDark: state.1,
                                 isSelected: state.2)
                }
                .padding(.horizontal, 20)
                .frame(width: 420, height: 44)
                .background(state.1 ? Color(hex: 0x2A2A2D) : Color(hex: 0xE4E4E9))
            }
        }
    }

    private static func write<V: View>(_ view: V, to url: URL) {
        let renderer = ImageRenderer(content: view.environment(\.isSnapshot, true))
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: url)
    }
}
