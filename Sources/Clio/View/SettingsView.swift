import SwiftUI

/// The settings window from the design, plus the quota ceilings the
/// subscription card needs — no local file records those, so they are entered
/// here or the percentages stay hidden.
struct SettingsView: View {
    var onPreviewConfetti: () -> Void = {}

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ScrollView { SettingsContent(onPreviewConfetti: onPreviewConfetti) }
            .frame(width: 420, height: 640)
            .background(Theme.resolve(scheme).panelFill)
    }
}

/// The settings body, kept separate from the scroll view so it can be rendered
/// on its own.
struct SettingsContent: View {
    var onPreviewConfetti: () -> Void = {}

    @EnvironmentObject private var prefs: Preferences
    @EnvironmentObject private var store: UsageStore
    @Environment(\.colorScheme) private var scheme
    @State private var bridgeState = StatusLineInstaller.state()
    @ObservedObject private var updater = Updater.shared

    private var theme: Theme { Theme.resolve(scheme) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
                group {
                    row("100M Token 里程碑礼花",
                        detail: "日、周或月累计每突破 100M 时全屏庆祝，不打断操作") {
                        HStack(spacing: 10) {
                            Button("预览", action: onPreviewConfetti)
                                .controlSize(.small)
                            Toggle("", isOn: $prefs.confettiEnabled).labelsHidden()
                        }
                    }
                    divider
                    row("开机自启") {
                        Toggle("", isOn: $prefs.launchAtLogin).labelsHidden()
                    }
                    divider
                    row("刷新频率") {
                        Picker("", selection: $prefs.refreshInterval) {
                            Text("每 15 秒").tag(15.0)
                            Text("每 30 秒").tag(30.0)
                            Text("每 1 分钟").tag(60.0)
                            Text("每 5 分钟").tag(300.0)
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                }

                section("菜单栏显示") {
                    ForEach(MenuBarDisplay.allCases) { mode in
                        Button {
                            prefs.menuBarDisplay = mode
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: prefs.menuBarDisplay == mode
                                      ? "largecircle.fill.circle" : "circle")
                                    .font(.system(size: 13))
                                    .foregroundStyle(prefs.menuBarDisplay == mode ? theme.accent : theme.textSecondary)
                                Text(mode.title)
                                    .foregroundStyle(theme.textPrimary)
                                Spacer()
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        if mode != MenuBarDisplay.allCases.last { divider }
                    }
                    divider
                    row("Token 数来源") {
                        Picker("", selection: $prefs.tokenSource) {
                            ForEach(TokenSource.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 130)
                    }
                }

                section("额度来源") {
                    row("主动查询", detail: liveDetail) {
                        Text(liveStatus)
                            .font(.system(size: 12))
                            .foregroundStyle(store.rateLimits == nil ? theme.textSecondary : theme.positive)
                    }
                    row("查询频率") {
                        Picker("", selection: $prefs.quotaInterval) {
                            Text("每 15 分钟").tag(900.0)
                            Text("每 30 分钟").tag(1800.0)
                            Text("每 1 小时").tag(3600.0)
                            Text("每 2 小时").tag(7200.0)
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                    divider
                    row("状态栏推送", detail: bridgeDetail) {
                        Button(bridgeState == .installed ? "移除" : "接入") {
                            toggleBridge()
                        }
                        .controlSize(.small)
                        .disabled(bridgeState == .unavailable)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Text(bridgeState == .installed
                             ? "已写入 ~/.claude/settings.json 的 statusLine.command："
                             : "按「接入」会把 statusLine.command 改写成：")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(bridgeCommand)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(theme.segmentedFill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 10)
                }

                section("数据来源（只读本地）") {
                    ForEach(Tool.allCases) { tool in
                        HStack(spacing: 8) {
                            BrandIcon(tool: tool, size: 13, color: tool.brandColor ?? theme.textPrimary)
                            Text(tool.displayName)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(theme.textPrimary)
                            Spacer()
                            Text(tool.logDirectoryDisplay)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                            Circle()
                                .fill(store.dashboard.snapshot(for: tool) != nil ? theme.positive : theme.textTertiary)
                                .frame(width: 6, height: 6)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                        if tool != Tool.allCases.last { divider }
                    }
                }

                section("更新") {
                    row("Clio \(Updater.currentVersion)", detail: updateDetail) {
                        updateAction
                    }
                    divider
                    row("自动检查更新", detail: "启动时与每 24 小时查询一次 GitHub Releases") {
                        Toggle("", isOn: $prefs.autoCheckUpdates).labelsHidden()
                    }
                }

                section("价格表") {
                    row("来源", detail: "每 24 小时用 ETag 条件请求校验一次；失败时沿用上次结果") {
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(store.priceOrigin.label)
                                .font(.system(size: 12))
                                .multilineTextAlignment(.trailing)
                                .foregroundStyle(theme.textSecondary)
                            Text("最近更新 \(priceFetched)")
                                .font(.system(size: 10))
                                .foregroundStyle(theme.positive)
                        }
                    }
                    divider
                    HStack {
                        Spacer()
                        Button("立即更新价格") {
                            Task {
                                await PriceService.shared.refresh()
                                await store.refresh()
                            }
                        }
                        Spacer()
                    }
                    .padding(.vertical, 8)
                }
        }
        .font(.system(size: 12))
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .onAppear { bridgeState = StatusLineInstaller.state() }
        .environment(\.theme, theme)
    }

    // MARK: - Building blocks

    private var divider: some View {
        Rectangle().fill(theme.separator).frame(height: 0.5)
    }

    @ViewBuilder
    private func group<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background(theme.cardFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(theme.cardStroke, lineWidth: 0.5))
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.leading, 2)
            group(content: content)
        }
    }

    @ViewBuilder
    private func row<Trailing: View>(_ title: String,
                                     detail: String? = nil,
                                     @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).foregroundStyle(theme.textPrimary)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(theme.textSecondary)
                }
            }
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var updateAction: some View {
        switch updater.phase {
        case .checking:
            ProgressView().controlSize(.small)
        case .installing:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("正在更新…").foregroundStyle(theme.textSecondary)
            }
        case .available(let release):
            Button("更新到 \(release.version)") {
                Task { await updater.install(release) }
            }
            .controlSize(.small)
        case .idle, .upToDate, .failed:
            Button("检查更新") {
                Task { await updater.check() }
            }
            .controlSize(.small)
        }
    }

    private var updateDetail: String {
        let checked = updater.lastChecked.map { "上次检查 \(Format.stamp($0))" } ?? "尚未检查"
        switch updater.phase {
        case .idle: return checked
        case .checking: return "正在检查…"
        case .upToDate: return "已是最新 · \(checked)"
        case .available(let release): return "发现新版本 \(release.version)，下载后替换当前应用并重启"
        case .installing(let release): return "正在下载并安装 \(release.version)"
        case .failed(let message): return message
        }
    }

    private var priceFetched: String {
        guard let fetched = store.priceFetchedAt else { return "尚未获取" }
        return Format.stamp(fetched)
    }

    /// What the button writes: this binary in front of whatever is configured.
    private var bridgeCommand: String {
        let binary = Bundle.main.executableURL?.path ?? "Clio"
        return "\"\(binary)\" --statusline -- <原有 statusLine 命令>"
    }

    private var bridgeDetail: String {
        switch bridgeState {
        case .installed:
            return "Claude Code 每渲染一次状态栏就推送一次额度；原状态栏照常显示"
        case .notInstalled:
            return "让 Claude Code 主动推送额度，用它时几乎实时；不含按模型窗口"
        case .unavailable:
            return "读不到 ~/.claude/settings.json"
        }
    }

    private func toggleBridge() {
        do {
            if bridgeState == .installed {
                try StatusLineInstaller.remove()
            } else {
                try StatusLineInstaller.install()
            }
        } catch {
            // The button reflects whatever the file actually says afterwards.
        }
        bridgeState = StatusLineInstaller.state()
    }

    private var liveStatus: String {
        guard UsageProbe.executable != nil else { return "未找到 claude" }
        guard let snapshot = store.rateLimits else { return "暂无数据" }
        return "已读取 · \(Format.clock(snapshot.updatedAt))"
    }

    private var liveDetail: String {
        guard UsageProbe.executable != nil else {
            return "找不到 claude 命令行，5 小时、本周与模型额度只能显示 Token 数"
        }
        return "展开面板时问一次，其余按下面的频率；失败时沿用上次结果"
    }

    private func binding(_ key: ReferenceWritableKeyPath<Preferences, [String: String]>, _ tool: Tool) -> Binding<String> {
        Binding(
            get: { prefs[keyPath: key][tool.rawValue] ?? "" },
            set: { prefs[keyPath: key][tool.rawValue] = $0 }
        )
    }

}
