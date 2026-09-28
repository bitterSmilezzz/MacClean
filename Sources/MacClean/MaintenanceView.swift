import SwiftUI

// MARK: - 系统维护（工具页，v1.73.15，对标 CleanMyMac X「Maintenance」）
//
// 三张动作卡 + 一张指引卡，逐条独立确认：
// * 磁盘 First Aid —— `diskutil verifyVolume`（只读，无需管理员，实测 181 GB 约 34 s）；
// * DNS 缓存刷新 —— 转发 `NetworkPrivacyInspector.flushDNSCache()`；
// * Spotlight 索引重建 —— 转发 `SpotlightScanner.rebuildVolumeIndex`；
// * 启动卷修复 —— **指引卡**：运行态根卷是封存只读快照，repair 在设备打开那一步就会
//   失败（2026-09-28 本机一次性盘实测 `Error: -69845`），提权也改变不了挂载态，
//   唯一官方路径是重启进恢复模式跑磁盘工具急救。不提供假装能修的按钮。
//
// 结果三态（未执行 / 成功 / 失败）原样播报，失败与输出摘录不许被成功盖掉。

struct MaintenanceView: View {
    @StateObject private var service = MaintenanceService()

    var body: some View {
        // 外层只负责持有状态，内层用 `@ObservedObject` 观察它（仓库既有范式）
        MaintenanceBody(service: service)
    }
}

private struct MaintenanceBody: View {
    @ObservedObject var service: MaintenanceService

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                header

                actionCard(.firstAid)
                actionCard(.dnsFlush)
                actionCard(.spotlightRebuild)

                repairGuidanceCard
                footerNote
            }
            .padding(Space.xl)
            // 确认弹窗挂在有尺寸的容器上（RELEASE-CHECKLIST：EmptyView 挂法自检绿、真机不弹）
            .confirmationDialog(
                confirmationTitle,
                isPresented: Binding(
                    get: { service.pendingConfirmation != nil },
                    set: { if !$0 { service.cancelConfirmation() } }),
                titleVisibility: .visible
            ) {
                Button(confirmationButtonLabel, role: confirmationIsDestructive ? .destructive : nil) {
                    service.confirmRun()
                }
                .accessibilityIdentifier("maintenanceConfirmButton")
                Button("取消", role: .cancel) { service.cancelConfirmation() }
            } message: {
                Text(confirmationMessage)
            }
        }
    }

    // MARK: - 顶部

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                IconSlot(systemName: "wrench.and.screwdriver", size: 14, weight: .semibold,
                         color: Accent.tint, width: 20)
                Text("系统维护")
                    .font(Typo.title)
                    .foregroundStyle(Ink.primary)
            }
            Text("三类系统级维护动作：只读的磁盘验证、DNS 缓存刷新、Spotlight 索引重建。"
                 + "每个动作独立确认、独立播报结果；「未执行」与「失败」分开显示，不混成一句成功。")
                .font(Typo.caption)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maintenanceHeader")
    }

    // MARK: - 动作卡

    private func actionCard(_ action: MaintenanceService.Action) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    IconSlot(systemName: Self.icon(for: action), size: 13,
                             color: Ink.secondary, width: 18)
                    Text(Self.title(for: action))
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)
                    Spacer(minLength: Space.xs)
                    if service.runningActions.contains(action) {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityIdentifier("maintenanceRunning-\(action.rawValue)")
                    }
                }

                Text(Self.description(for: action))
                    .font(Typo.caption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(Self.buttonLabel(for: action)) {
                    service.requestRun(action)
                }
                .buttonStyle(.bordered)
                .disabled(service.isBusy)
                .accessibilityIdentifier("maintenanceRunButton-\(action.rawValue)")

                if let outcome = service.outcomes[action] {
                    outcomeSection(outcome)
                }
            }
            .padding(.vertical, Space.xxs)
        }
    }

    private func outcomeSection(_ outcome: MaintenanceService.Outcome) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            Hairline()
            HStack(alignment: .top, spacing: Space.xxs) {
                IconSlot(systemName: Self.statusIcon(outcome.status),
                         size: 12, weight: .medium,
                         color: Self.statusColor(outcome.status), width: 16)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(outcome.message)
                        .font(Typo.caption)
                        .foregroundStyle(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let excerpt = outcome.outputExcerpt, !excerpt.isEmpty {
                        Text(excerpt)
                            .font(Typo.caption.monospaced())
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Space.xs)
                            .background(
                                RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                                    .fill(Surface.group)
                            )
                    }
                    if outcome.duration > 0.05 {
                        Text(String(format: "耗时 %.1f 秒", outcome.duration))
                            .font(Font.mcNumeric(11, weight: .regular))
                            .foregroundStyle(Ink.tertiary)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maintenanceOutcome-\(outcome.action.rawValue)")
    }

    // MARK: - 修复指引卡（不给假装能修的按钮）

    private var repairGuidanceCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: Space.xs) {
                HStack(spacing: Space.xs) {
                    IconSlot(systemName: "arrow.up.circle", size: 13,
                             color: Ink.secondary, width: 18)
                    Text("启动卷修复（需恢复模式）")
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)
                }
                Text("运行中的启动卷是封存的只读快照，「修复」在写入前就会被系统拒绝（提权也一样），"
                     + "所以这里不提供运行态修复按钮。上面验证发现问题时的官方修复路径："
                     + "关机 → 按住电源键进入「选项」（Intel 机型为开机按 Command-R）→"
                     + "选择「磁盘工具」→ 选中「Macintosh HD」→ 点「急救」。"
                     + "修复会改动文件系统，中断有风险；恢复模式下的磁盘工具会先卸载卷再修复。")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, Space.xxs)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("maintenanceRepairGuidance")
    }

    private var footerNote: some View {
        Text("磁盘验证是只读的；DNS 刷新只影响域名解析缓存；Spotlight 重建会擦除索引并自动重建成，"
             + "重建期间搜索不可用。这里没有「一键维护全部」——每个动作都该是你自己点下去的。")
            .font(Typo.caption)
            .foregroundStyle(Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - 确认弹窗文案（随待确认动作变化）

    private var confirmationTitle: String {
        guard let action = service.pendingConfirmation else { return "确认执行" }
        return "确认执行：\(Self.title(for: action))"
    }

    private var confirmationButtonLabel: String {
        guard let action = service.pendingConfirmation else { return "执行" }
        return Self.buttonLabel(for: action)
    }

    private var confirmationIsDestructive: Bool {
        service.pendingConfirmation == .spotlightRebuild
    }

    private var confirmationMessage: String {
        switch service.pendingConfirmation {
        case .firstAid:
            return "将对系统卷执行只读验证（diskutil verifyVolume）。验证不改动文件系统；"
                 + "大容量磁盘可能需要数十秒到数分钟。"
        case .dnsFlush:
            return "将清空系统本地 DNS 解析缓存（dscacheutil -flushcache）。"
                 + "只影响域名解析缓存，之后首次访问网站可能稍慢。"
        case .spotlightRebuild:
            return "将擦除并重建启动卷的 Spotlight 索引（mdutil -E /）。"
                 + "重建期间 Spotlight 搜索不可用，完整重建可能持续数分钟到更久，完成后索引自动重建成。"
        case nil:
            return ""
        }
    }

    // MARK: - 文案与语义色

    static func title(for action: MaintenanceService.Action) -> String {
        switch action {
        case .firstAid: return "磁盘 First Aid（只读验证）"
        case .dnsFlush: return "刷新 DNS 缓存"
        case .spotlightRebuild: return "重建 Spotlight 索引"
        }
    }

    static func icon(for action: MaintenanceService.Action) -> String {
        switch action {
        case .firstAid: return "internaldrive"
        case .dnsFlush: return "network"
        case .spotlightRebuild: return "magnifyingglass"
        }
    }

    static func buttonLabel(for action: MaintenanceService.Action) -> String {
        switch action {
        case .firstAid: return "开始验证"
        case .dnsFlush: return "刷新 DNS 缓存"
        case .spotlightRebuild: return "重建索引"
        }
    }

    static func description(for action: MaintenanceService.Action) -> String {
        switch action {
        case .firstAid:
            return "对系统卷执行只读文件系统验证（diskutil verifyVolume），检查文件系统结构是否损坏。"
                 + "不改动文件系统；实测 181 GB 数据卷约 34 秒，大容量磁盘可能更久。"
                 + "验证发现问题时的修复路径见下方指引卡。"
        case .dnsFlush:
            return "清空系统本地 DNS 解析缓存（dscacheutil -flushcache）。"
                 + "适合域名解析异常、网站指向旧地址时使用；代价是之后首次访问网站可能稍慢。"
        case .spotlightRebuild:
            return "擦除并重建启动卷的 Spotlight 索引（mdutil -E）。"
                 + "适合搜索结果缺失或混乱时使用；重建期间搜索不可用，耗时可能数分钟到更久。"
        }
    }

    static func statusIcon(_ status: MaintenanceService.OutcomeStatus) -> String {
        switch status {
        case .notExecuted: return "minus.circle"
        case .succeeded: return "checkmark.circle"
        case .failed: return "xmark.octagon"
        }
    }

    static func statusColor(_ status: MaintenanceService.OutcomeStatus) -> Color {
        switch status {
        case .notExecuted: return Ink.tertiary
        case .succeeded: return Signal.positive
        case .failed: return Signal.critical
        }
    }
}
