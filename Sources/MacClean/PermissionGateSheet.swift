import SwiftUI

/// 扫描前权限门的待决状态。
///
/// `category == nil` 表示被拦下的是"全部扫描"；否则只拦下了某一个分类。
struct PermissionGate: Identifiable {
    let id = UUID()
    let category: CleanCategory?

    /// 「仍然扫描」按钮的文案：说清这次要扫的范围，而不是一句泛泛的"继续"。
    var actionLabel: String {
        guard let category else { return "仍然扫描全部分类" }
        return "仍然扫描「\(category.title)」"
    }
}

/// 缺「完全磁盘访问权限」时的**扫描前**提示。
///
/// ## 为什么必须在扫描之前问，而不是扫完再补一句
///
/// 缺这项授权时扫描**不会报错**：它只是安静地少看到一批位置，而界面上"没看到"
/// 和"这里本来就没东西"长得一模一样。事后那条 caption 是补救，不是替代——
/// 用户的第一反应应该是"要不要现在授权"，而不是先拿到一份偏小的结果再自己发现。
///
/// ## 为什么保留「仍然扫描」
///
/// 硬拦会变成"不给权限就不让用"。缺 FDA 时用户自己的缓存、下载、开发残留其实都读得到，
/// 拒绝扫描等于把工具废掉。所以给一条明确的出口：照常扫，但结果里会如实列出
/// 哪些位置因权限没能读到（`ScanIssue` 那条链路）。
struct PermissionGateSheet: View {
    @EnvironmentObject private var app: AppState
    let gate: PermissionGate

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    IconSlot(systemName: "lock.shield", size: 13, weight: .semibold,
                             color: Signal.caution, width: 18)
                    Text(PermissionGuide.gateTitle)
                        .font(Typo.title)
                        .foregroundStyle(Ink.primary)
                }
                Text("本次扫描尚未开始")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
            }

            Text(PermissionGuide.gateMessage)
                .font(Typo.body)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("permissionGateMessage")

            if app.permissionSettingsOpenFailed {
                // 老系统没有那个 URL scheme 时不能静默：把人工路径写出来。
                noticeRow(icon: "exclamationmark.triangle.fill",
                          text: "没能自动打开系统设置。请手动前往 系统设置 → 隐私与安全性 → 完全磁盘访问权限，勾选 MacClean 后回到这里重新扫描。",
                          color: Signal.critical)
            }

            VStack(alignment: .leading, spacing: Space.sm) {
                Button {
                    app.openPermissionSettings()
                } label: {
                    Label("去系统设置授权", systemImage: "gearshape")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(Accent.tint)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("permissionGateOpenSettingsButton")

                HStack(spacing: Space.sm) {
                    Button {
                        app.proceedScanWithoutFullDiskAccess()
                    } label: {
                        Text(gate.actionLabel).font(Typo.row)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("permissionGateProceedButton")

                    Button {
                        app.dismissPermissionGate()
                    } label: {
                        Text("稍后")
                            .font(Typo.row)
                            .foregroundStyle(Ink.secondary)
                            .padding(.horizontal, Space.xs)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .pressable()
                    .rowHover()
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("permissionGateLaterButton")

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(Space.xl)
        .frame(width: 480)
    }

    private func noticeRow(icon: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: Space.xs) {
            IconSlot(systemName: icon, size: 12, weight: .medium, color: color, width: 16)
            Text(text)
                .font(Typo.row)
                .foregroundStyle(Ink.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(color.opacity(0.08))
        )
    }
}
