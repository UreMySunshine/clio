import SwiftUI
import AppKit

/// The popover. With both tools present the top row is a switch; with one it
/// becomes a title row and the plan badge moves up beside the name.
struct PanelView: View {
    var onOpenSettings: () -> Void
    var initialGranularity: Granularity = .day
    /// Reports the height the content needs. The panel window follows it: the
    /// period switch and a refresh both change how many model rows there are.
    var onContentHeight: (CGFloat) -> Void = { _ in }

    @EnvironmentObject private var store: UsageStore
    @EnvironmentObject private var prefs: Preferences
    @ObservedObject private var updater = Updater.shared
    @Environment(\.colorScheme) private var scheme
    @Environment(\.panelIsOpen) private var panelIsOpen
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var granularity: Granularity = .day
    @State private var basis: ShareBasis = .tokens
    @State private var didApplyInitial = false
    /// Height of the page area and the tool it was measured for. It animates
    /// only when it moves from one tool's page to the other's.
    @State private var pageHeight: CGFloat?
    @State private var pageHeightTool: Tool?

    private var theme: Theme { Theme.resolve(scheme) }

    var body: some View {
        Group {
            if store.isLoading {
                LoadingView()
            } else if let snapshot = current {
                content(snapshot)
            } else {
                EmptyStateView(onRescan: { Task { await store.refresh() } },
                               onSettings: onOpenSettings)
            }
        }
        .blur(radius: panelIsOpen ? 0 : 10)
        .environment(\.theme, theme)
        .frame(width: Metrics.panelWidth)
        // Translucent fill over the window's blurred backdrop, plus the two
        // hairlines the design gives the glass edge: light inside, dark on it.
        .background(theme.panelFill, in: RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                .inset(by: 0.25)
                .strokeBorder(theme.panelInnerStroke, lineWidth: 0.5)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.panelRadius, style: .continuous)
                .strokeBorder(theme.panelStroke, lineWidth: 0.5)
        )
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                    onContentHeight(height)
                }
            }
        )
        .onAppear {
            guard !didApplyInitial else { return }
            didApplyInitial = true
            granularity = initialGranularity
        }
    }

    private var current: ToolSnapshot? {
        store.dashboard.snapshot(for: prefs.selectedTool) ?? store.dashboard.snapshots.first
    }

    @ViewBuilder
    private func content(_ snapshot: ToolSnapshot) -> some View {
        VStack(spacing: 10) {
            Group {
                if store.dashboard.snapshots.count > 1 {
                    ToolSwitch(tools: store.dashboard.snapshots.map(\.tool),
                               selection: $prefs.selectedTool)
                } else {
                    HStack(spacing: 7) {
                        BrandIcon(tool: snapshot.tool, size: 14, color: snapshot.tool.brandColor ?? theme.textPrimary)
                        Text(snapshot.tool.displayName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textPrimary)
                        if let plan = snapshot.plan, !plan.isEmpty {
                            PlanBadge(text: plan)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, 2)
                }
            }
            .padding(.horizontal, 12)

            page(snapshot)
            footer(snapshot)
                .padding(.horizontal, 12)
        }
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    /// The selected tool's cards. Switching tools slides the old page out and
    /// the new one in from the side of its segment, clipped at the panel's
    /// edges, while the area's height moves from one page's to the other's.
    private func page(_ snapshot: ToolSnapshot) -> some View {
        ZStack(alignment: .top) {
            VStack(spacing: 10) {
                SubscriptionCard(snapshot: snapshot,
                                 showsHeader: store.dashboard.snapshots.count > 1)
                UsageCard(snapshot: snapshot, granularity: $granularity, basis: $basis)
                ActivityCards(activity: snapshot.activity)
                HeatmapCard(dailyTokens: snapshot.dailyTokens)
            }
            .padding(.horizontal, 12)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size.height, initial: true) { _, height in
                        pageMeasured(height, for: snapshot.tool)
                    }
                }
            )
            .id(snapshot.tool)
            .transition(.move(edge: snapshot.tool == Tool.allCases.first ? .leading : .trailing))
        }
        .modifier(WholePointHeight(height: pageHeight ?? 0, isActive: pageHeight != nil))
        .clipped()
        .animation(Motion.spring(Motion.tool, reduce: reduceMotion), value: snapshot.tool)
    }

    private func pageMeasured(_ height: CGFloat, for tool: Tool) {
        // The outgoing page still reports while it slides away.
        guard tool == current?.tool else { return }
        if pageHeightTool == tool || pageHeightTool == nil || reduceMotion {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                pageHeight = height
                pageHeightTool = tool
            }
        } else {
            withAnimation(Motion.spring(Motion.tool, reduce: false)) {
                pageHeight = height
                pageHeightTool = tool
            }
        }
    }

    private func footer(_ snapshot: ToolSnapshot) -> some View {
        HStack {
            Text("更新于 \(Format.clock(snapshot.updatedAt)) · 本地读取")
                .font(.system(size: 11))
                .foregroundStyle(theme.textSecondary)
            if let release = updater.availableRelease {
                // Leads to Settings rather than installing on the spot: the
                // install ends in a restart, too much for a stray click.
                Button {
                    onOpenSettings()
                } label: {
                    Text("新版本 \(release.version)")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.accent)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(theme.accent.opacity(0.12), in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
            Spacer()
            IconMenu(symbol: prefs.appearance.symbol,
                     tint: theme.textPrimary,
                     items: Appearance.allCases.map { option in
                         .init(title: option.title, shortcut: "", isOn: prefs.appearance == option) {
                             prefs.appearance = option
                         }
                     })
                .frame(width: 22, height: 22)
            IconMenu(symbol: "gearshape", tint: theme.textPrimary, items: [
                .init(title: "刷新", shortcut: "r") { Task { await store.refresh() } },
                .init(title: "打开日志目录", shortcut: "l") { store.openLogDirectory() },
                .init(title: "", shortcut: "") {},
                .init(title: "设置…", shortcut: ",") { onOpenSettings() },
                .init(title: "", shortcut: "") {},
                .init(title: "退出", shortcut: "q") { NSApplication.shared.terminate(nil) },
            ])
            .frame(width: 22, height: 22)
        }
        .frame(height: 22)
        .padding(.top, 2)
        .padding(.horizontal, 2)
    }
}

/// Rounds the page area's height to a whole point on every animation frame.
/// The window can only take whole points, and content shorter than the window
/// is centred in it, which would shift the panel by a fraction each frame.
private struct WholePointHeight: ViewModifier, Animatable {
    var height: CGFloat
    var isActive: Bool

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        content.frame(height: isActive ? height.rounded() : nil, alignment: .top)
    }
}

private struct LoadingView: View {
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small)
            Text("正在读取本地会话日志…")
                .font(.system(size: 12))
                .foregroundStyle(theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 42)
    }
}
