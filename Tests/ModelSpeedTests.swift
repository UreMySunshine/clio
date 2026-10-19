import AppKit
import SwiftUI

@main @MainActor enum ModelSpeedTests {
    private static var scale: CGFloat = 1
    private static func expect(_ value: Bool, _ message: String) { precondition(value, message) }

    private static func render(_ usage: UsageSummary, prefs: Preferences, into path: URL, diagnostic: Bool = true) throws -> NSBitmapImageRep {
        var theme = Theme.light
        if diagnostic {
            theme.textPrimary = Color(hex: 0xFF0000)
            theme.textSecondary = Color(hex: 0x0000FF)
            theme.cardFill = .white
            theme.cardStroke = .clear
            theme.cardInnerStroke = .clear
            theme.modelPalette = [.clear]
            theme.shareTrack = .clear
        }
        let host = NSHostingView(rootView: ModelBreakdownCard(usage: usage, granularity: .day, basis: .constant(.tokens))
            .environmentObject(prefs)
            .environment(\.theme, theme)
            .environment(\.colorScheme, .light)
            .frame(width: Metrics.panelContentWidth))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        scale = CGFloat(bitmap.pixelsWide) / Metrics.panelContentWidth
        withExtendedLifetime(window) {}
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
        return bitmap
    }

    private final class NameLayout: ObservableObject {
        @Published var width: CGFloat = 220
        @Published var size: CGFloat = 12
        @Published var showSpeed = false
    }

    private struct NameFixture: View {
        @ObservedObject var layout: NameLayout
        var measure: (ModelNameWidths) -> Void
        var body: some View {
            HStack(spacing: 6) {
                ModelName(text: "deepseek-v4.1-flash", font: .system(size: layout.size, weight: .medium))
                if layout.showSpeed { Text("20 t/s").frame(width: 44) }
            }
            .frame(width: layout.width, alignment: .leading)
            .onPreferenceChange(ModelNameWidthsKey.self, perform: measure)
        }
    }

    private static func testModelNameLayout() {
        let layout = NameLayout()
        var measured = ModelNameWidths()
        let host = NSHostingView(rootView: NameFixture(layout: layout) { measured = $0 })
        host.frame = NSRect(x: 0, y: 0, width: 260, height: 40)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        func settle() {
            host.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
        }
        settle()
        expect(measured.natural > 0 && !measured.isTruncated, "full names have no tooltip")
        layout.width = 50
        settle()
        expect(measured.isTruncated, "actual allocated width enables the name tooltip")
        layout.width = 220
        settle()
        expect(!measured.isTruncated, "widening hides the name tooltip again")
        layout.width = 135
        layout.showSpeed = true
        settle()
        expect(measured.isTruncated, "showing the speed column can enable the tooltip")
        layout.showSpeed = false
        settle()
        expect(!measured.isTruncated, "hiding the speed column restores the full name")
        layout.width = 220
        layout.size = 30
        settle()
        expect(measured.isTruncated, "font changes update natural text width")
        layout.size = 12
        settle()
        expect(!measured.isTruncated, "restoring the font removes the tooltip")
        withExtendedLifetime(window) {}
    }

    private static func coloredBounds(_ image: NSBitmapImageRep, x: Range<Int>, blue: Bool) -> (Int, Int) {
        var first = Int.max
        var last = Int.min
        for px in x {
            for py in Int(40 * scale)..<(image.pixelsHigh - Int(9 * scale)) {
                guard let color = image.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { continue }
                let colored = blue
                    ? color.blueComponent > 0.6 && color.redComponent < 0.4 && color.greenComponent < 0.4
                    : color.redComponent > 0.6 && color.blueComponent < 0.4 && color.greenComponent < 0.4
                if colored { first = min(first, px); last = max(last, px) }
            }
        }
        expect(first <= last, "the expected numeric text must be rendered")
        return (first, last)
    }

    private static func inkRows(_ image: NSBitmapImageRep, x: Range<Int>, blue: Bool, y: Range<Int>) -> Set<Int> {
        Set(y.filter { py in
            x.contains { px in
                guard let c = image.colorAt(x: px, y: py)?.usingColorSpace(.deviceRGB) else { return false }
                return blue ? c.blueComponent > 0.6 && c.redComponent < 0.4 && c.greenComponent < 0.4
                    : c.redComponent > 0.6 && c.blueComponent < 0.4 && c.greenComponent < 0.4
            }
        })
    }

    private static func footerIcons(dark: Bool, into path: URL) throws {
        let theme = dark ? Theme.dark : Theme.light
        let host = NSHostingView(rootView: VStack(spacing: 12) {
            ForEach([false, true], id: \.self) { active in
                HStack(spacing: 16) {
                    ForEach(UsageScope.allCases, id: \.self) { scope in
                        VStack {
                            IconMenu(symbol: scope.footerSymbol,
                                     tint: active ? scope.category.map { theme.categorySeries($0) } ?? theme.textPrimary : theme.textPrimary,
                                     tool: scope.tool, action: {})
                                .frame(width: 22, height: 22)
                                .accessibilityLabel("用量范围：\(scope.title)")
                            Text(scope.title).font(.system(size: 11)).foregroundStyle(theme.textPrimary)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(theme.panelFill)
        .background(dark ? Color.black : Color.white)
        .environment(\.theme, theme)
        .environment(\.colorScheme, dark ? .dark : .light)
        .environment(\.isSnapshot, true))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        expect(bitmap.pixelsWide > 0 && bitmap.pixelsHigh > 0, "all four footer icons render in both themes")
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
        withExtendedLifetime(window) {}
    }

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        expect(UsageScope.combined.footerSymbol == "square.stack.3d.up", "combined keeps its stacked symbol")
        expect(UsageScope.other.footerSymbol == "ellipsis.circle", "other has its own symbol")
        expect(UsageScope.combined.footerSymbol != UsageScope.other.footerSymbol, "non-brand scope symbols must differ")
        expect(UsageScope.claudeCode.tool == .claudeCode && UsageScope.codex.tool == .codex,
               "Claude and Codex retain their brand icons")
        expect(UsageScope.combined.tool == nil && UsageScope.other.tool == nil,
               "combined and other use system symbols")
        for scope in UsageScope.allCases {
            expect(NSImage(systemSymbolName: scope.footerSymbol, accessibilityDescription: scope.title) != nil,
                   "each footer symbol exists on the running macOS")
        }
        let suite = "Clio.ModelSpeedTests.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let prefs = Preferences(defaults: defaults)
        expect(!prefs.showModelSpeed, "model speeds are hidden by default")
        let speed = OutputSpeed(outputTokens: 800, duration: 40, samples: 2)
        let model = "deepseek-v4.1-flash-preview-long-version"
        let detail = ModelSourceUsage(tool: .codex, model: "gateway/" + model, tokens: 12_345, cost: 1.23, outputSpeed: speed)
        let rows = [ModelUsage(model: model, displayName: model, tokens: 12_345, cost: 1.23, outputSpeed: speed, sources: [detail]),
                    ModelUsage(model: model + "-2", displayName: model + "-2", tokens: 12_345, cost: 1.23, outputSpeed: speed, sources: [detail])]
        let usage = UsageSummary(totals: [.day: .init(input: 24_690)], previousTotals: [:], costs: [.day: 2.46],
                                 buckets: [:], models: [.day: rows], dailyTokens: [:], activity: .empty,
                                 outputSpeeds: [.day: speed + speed])
        let folder = URL(fileURLWithPath: CommandLine.arguments[1])
        try footerIcons(dark: false, into: folder.appending(path: "footer-light.png"))
        try footerIcons(dark: true, into: folder.appending(path: "footer-dark.png"))
        let off = try render(usage, prefs: prefs, into: folder.appending(path: "speed-off.png"))
        prefs.showModelSpeed = true
        let restored = Preferences(defaults: UserDefaults(suiteName: suite)!)
        expect(restored.showModelSpeed, "enabling model speeds survives a new preferences instance")
        let on = try render(usage, prefs: restored, into: folder.appending(path: "speed-on.png"))
        expect(off.pixelsWide == on.pixelsWide && off.pixelsHigh == on.pixelsHigh,
               "the switch does not add a header line or change card dimensions")
        let offTokens = coloredBounds(off, x: Int(200 * scale)..<Int(255 * scale), blue: false)
        let onTokens = coloredBounds(on, x: Int(150 * scale)..<Int(205 * scale), blue: false)
        let offCost = coloredBounds(off, x: Int(260 * scale)..<Int(309 * scale), blue: true)
        let onCost = coloredBounds(on, x: Int(210 * scale)..<Int(259 * scale), blue: true)
        for pair in [(offTokens.0, onTokens.0), (offTokens.1, onTokens.1), (offCost.0, onCost.0), (offCost.1, onCost.1)] {
            expect(abs(Double(pair.0 - pair.1) / Double(scale) - 50) <= 1,
                   "removing the speed column and its gap gives the model name 50 additional points")
        }
        let rowBand = Int(40 * scale)..<(off.pixelsHigh - Int(9 * scale))
        expect(inkRows(off, x: Int(200 * scale)..<Int(255 * scale), blue: false, y: rowBand)
               == inkRows(on, x: Int(150 * scale)..<Int(205 * scale), blue: false, y: rowBand),
               "token baselines remain fixed when speed visibility changes")
        expect(inkRows(off, x: Int(260 * scale)..<Int(309 * scale), blue: true, y: rowBand)
               == inkRows(on, x: Int(210 * scale)..<Int(259 * scale), blue: true, y: rowBand),
               "money baselines remain fixed when speed visibility changes")
        for image in [off, on] {
            let header = 0..<Int(29 * scale)
            let centers = [(12, 112), (165, 216), (269, 309)].map { left, right -> Double in
                let ink = inkRows(image, x: Int(CGFloat(left) * scale)..<Int(CGFloat(right) * scale), blue: true, y: header)
                expect(!ink.isEmpty, "each header label must be visible")
                return Double(ink.min()! + ink.max()!) / 2 / Double(scale)
            }
            expect(centers.max()! - centers.min()! <= 1.25,
                   "title, speed label and basis button have aligned visual centers")
        }
        let offName = coloredBounds(off, x: Int(25 * scale)..<Int(190 * scale), blue: false)
        let onName = coloredBounds(on, x: Int(25 * scale)..<Int(140 * scale), blue: false)
        expect(offName.1 - onName.1 >= Int(40 * scale), "long names use the released column space")
        _ = try render(usage, prefs: restored, into: folder.appending(path: "aligned-speed-on.png"), diagnostic: false)
        restored.showModelSpeed = false
        _ = try render(usage, prefs: restored, into: folder.appending(path: "aligned-speed-off.png"), diagnostic: false)
        expect(!Preferences(defaults: UserDefaults(suiteName: suite)!).showModelSpeed,
               "disabling model speeds is also persisted")
        expect(usage.totals[.day]?.total == 24_690 && usage.costs[.day] == 2.46,
               "the display setting cannot alter tokens or money")
        expect(usage.models[.day]?.allSatisfy { $0.outputSpeed.tokensPerSecond == 20 && $0.sources.first?.outputSpeed.samples == 2 } == true,
               "speed calculation and source details remain available when the column is hidden")
        testModelNameLayout()
        print("Model name truncation checks passed (allocated width, speed column, widening and font changes)")
        print("Model speed checks passed (default off, restore on/off, 50-point name-space gain, header centers, fixed row baselines, numeric alignment and unchanged usage)")
        print("Rendered card: \(Double(off.pixelsWide) / Double(scale)) x \(Double(off.pixelsHigh) / Double(scale)) points")
    }
}
