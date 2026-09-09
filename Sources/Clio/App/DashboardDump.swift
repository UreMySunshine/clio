import Foundation

/// Text rendering of everything the panel would show, for checking the readers
/// and the aggregation from a terminal.
@MainActor
enum DashboardDump {
    static func run() {
        let started = Date()
        let store = UsageStore()
        Task {
            await PriceService.shared.refreshIfNeeded()
            await store.refresh()
            let origin = await PriceService.shared.origin
            report(store.dashboard, priceOrigin: origin)
            print(String(format: "\n扫描耗时 %.2fs", Date().timeIntervalSince(started)))
            exit(0)
        }
        // A real run loop, not dispatchMain(): the latter parks the actual main
        // thread and services the main queue elsewhere, which SwiftUI's
        // renderer then waits on forever.
        CFRunLoopRun()
    }

    private static func report(_ dashboard: Dashboard, priceOrigin: PriceOrigin) {
        print("价格来源: \(priceOrigin.label)")
        if let live = UsageProbe.fetch() {
            print("实时额度: 已读取于 \(Format.clock(live.updatedAt))")
        } else {
            print("实时额度: Claude Code 未返回额度，无法显示百分比")
        }
        guard !dashboard.isEmpty else {
            print("未检测到本地用量数据")
            return
        }
        for snapshot in dashboard.snapshots {
            print("")
            print("── \(snapshot.tool.displayName) · \(snapshot.plan ?? "未知档位") ──")
            describe(snapshot.fiveHour)
            describe(snapshot.week)
            if let modelQuota = snapshot.modelQuota { describe(modelQuota) }
            for granularity in Granularity.allCases {
                describe(snapshot, granularity)
            }
            print("今日按模型:")
            for model in snapshot.models[.day] ?? [] {
                let name = model.displayName.padding(toLength: 14, withPad: " ", startingAt: 0)
                print("  \(name) \(Format.compact(model.tokens))  \(Format.money(model.cost))  [\(model.model)]")
            }
            let active = snapshot.dailyTokens.values.filter { $0 > 0 }.count
            print("热力图: 近 22 周内 \(active) 天有记录")
        }
    }

    private static func describe(_ window: QuotaWindow) {
        let percent = window.fraction.map(Format.percent) ?? "—"
        let tokens = Format.compact(window.used)
        print("\(window.title): \(percent)  窗口内 \(tokens) tokens  \(Format.reset(window.resetsAt))")
    }

    private static func describe(_ snapshot: ToolSnapshot, _ granularity: Granularity) {
        let counts = snapshot.totals[granularity] ?? TokenCounts()
        let head = "\(granularity.title): 合计 \(Format.grouped(counts.total))"
        let split = "输入 \(Format.compact(counts.input))  输出 \(Format.compact(counts.output))"
        let cache = "缓存读 \(Format.compact(counts.cacheRead))  缓存写 \(Format.compact(counts.cacheWrite))"
        let money = "花费 \(Format.money(snapshot.costs[granularity]))"
        let trend = "环比 \(Format.signedPercent(snapshot.tokenTrend[granularity] ?? 0))"
        print("\(head)  \(split)  \(cache)  \(money)  \(trend)")
    }
}
