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

    private static func sourceTip(_ sources: [ModelSourceUsage], dark: Bool, into path: URL) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: HoverTip { ModelSourceTipTable(sources: sources) }
            .environment(\.colorScheme, dark ? .dark : .light)
            .padding(10)
            .background(Color.white))
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        let window = NSWindow(contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        withExtendedLifetime(window) {}
        try bitmap.representation(using: .png, properties: [:])!.write(to: path)
        return bitmap
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

    static func main() throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
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
        let sources = [ModelSourceUsage(tool: .claudeCode, model: "deepseek-flash", tokens: 700_000, cost: 0.03,
                                           outputSpeed: OutputSpeed(outputTokens: 1330, duration: 10, samples: 1)),
                       ModelSourceUsage(tool: .codex, model: "workbuddy-ai/deepseek-v4.1-flash-with-a-long-gateway-identifier", tokens: 200_000,
                                           cost: nil, outputSpeed: OutputSpeed())]
        let lightTip = try sourceTip(sources, dark: false, into: folder.appending(path: "source-tip-light.png"))
        let darkTip = try sourceTip(sources, dark: true, into: folder.appending(path: "source-tip-dark.png"))
        expect(lightTip.pixelsWide == Int((Metrics.cardContentWidth + 20) * scale)
               && lightTip.pixelsWide == darkTip.pixelsWide && lightTip.pixelsHigh == darkTip.pixelsHigh,
               "source readouts wrap long raw identities within the panel in both themes")
        let lightFill = lightTip.colorAt(x: lightTip.pixelsWide / 2, y: Int(12 * scale))!.usingColorSpace(.deviceRGB)!
        let darkFill = darkTip.colorAt(x: darkTip.pixelsWide / 2, y: Int(12 * scale))!.usingColorSpace(.deviceRGB)!
        expect(lightFill.redComponent < 0.3 && abs(lightFill.redComponent - darkFill.redComponent) < 0.01,
               "source readouts use the shared dark HoverTip background in both themes")
        expect(sources.count == 2 && sources[0].tokens + sources[1].tokens == 900_000 && sources[1].cost == nil,
               "styling source readouts preserves their raw identities, usage and unknown cost")
        print("Model source HoverTip checks passed (shared style, both themes, long identities and unchanged source usage)")
        print("Model speed checks passed (default off, restore on/off, 50-point name-space gain, header centers, fixed row baselines, numeric alignment and unchanged usage)")
        print("Rendered card: \(Double(off.pixelsWide) / Double(scale)) x \(Double(off.pixelsHigh) / Double(scale)) points")
    }
}
