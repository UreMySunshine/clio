import SwiftUI

/// Shown when neither log directory yielded a usage record.
struct EmptyStateView: View {
    @Environment(\.theme) private var theme
    var onRescan: () -> Void
    var onSettings: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(theme.textSecondary)
                .padding(.bottom, 2)

            Text("未检测到本地用量数据")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.textPrimary)

            Text("已检查 ~/.claude 与 ~/.codex，未找到会话记录。运行一次 Claude Code 或 Codex 后再刷新。")
                .font(.system(size: 12))
                .lineSpacing(3)
                .multilineTextAlignment(.center)
                .foregroundStyle(theme.textSecondary)

            Button(action: onRescan) {
                Text("重新扫描")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 5)
                    .background(theme.accent, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)

            HStack {
                Text("菜单栏显示：图标")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textSecondary)
                Spacer()
                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textPrimary)
                }
                .buttonStyle(.plain)
                .frame(width: 22, height: 22)
            }
            .padding(.top, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 36)
        .padding(.bottom, 14)
    }
}
