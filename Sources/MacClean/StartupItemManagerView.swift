import SwiftUI

// MARK: - 语义色 → Theme 色板（v1.74.0：颜色映射从模型层移回视图层）

extension StartupItemTone {
    var color: Color {
        switch self {
        case .positive: return Signal.positive
        case .neutral: return Ink.tertiary
        case .caution: return Signal.caution
        case .accent: return Accent.tint
        case .critical: return Signal.critical
        }
    }
}

private extension StartupItemStatus {
    var color: Color { tone.color }
}

// MARK: - 启动项与后台服务筛选模式

public enum StartupItemFilter: String, CaseIterable, Identifiable {
    case all = "全部项"
    case danglingOnly = "幽灵残留"
    case userOnly = "用户代理"
    case globalOnly = "全局守护"
    case disabledOnly = "已停用"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .danglingOnly: return "exclamationmark.triangle"
        case .userOnly: return "person"
        case .globalOnly: return "globe"
        case .disabledOnly: return "pause.circle"
        }
    }
}

// MARK: - 启动项管理主视图

public struct StartupItemManagerView: View {
    @State private var items: [StartupItem] = []
    @State private var isLoading: Bool = false
    @State private var filter: StartupItemFilter = .all
    @State private var searchText: String = ""
    @State private var bannerMessage: String?
    @State private var showCleanConfirm: Bool = false
    /// 本轮巡检读不到的位置（非空即结论不完整）
    @State private var scanIssues: [GovernanceEvidenceIssue] = []

    public init() {}

    private var filteredItems: [StartupItem] {
        items.filter { item in
            let matchesFilter: Bool
            switch filter {
            case .all: matchesFilter = true
            case .danglingOnly: matchesFilter = item.status.isDangling
            case .userOnly: matchesFilter = item.location == .userAgent
            case .globalOnly: matchesFilter = item.location == .globalAgent || item.location == .globalDaemon
            case .disabledOnly: matchesFilter = item.isDisabled
            }

            guard matchesFilter else { return false }
            if searchText.isEmpty { return true }
            return item.label.localizedCaseInsensitiveContains(searchText) ||
                item.name.localizedCaseInsensitiveContains(searchText) ||
                (item.programPath ?? "").localizedCaseInsensitiveContains(searchText) ||
                item.vendor.localizedCaseInsensitiveContains(searchText)
        }
    }

    private var danglingCount: Int {
        items.filter { $0.status.isDangling }.count
    }

    public var body: some View {
        VStack(spacing: 0) {
            // 顶栏 Header
            headerBar

            Divider()

            // 统计指标卡
            metricsOverviewBar
                .padding(.horizontal, 20)
                .padding(.top, 14)
                .padding(.bottom, 10)

            // 操作提示横幅
            if let msg = bannerMessage {
                bannerView(message: msg)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 8)
            }

            // 列表与空状态
            contentListView
        }
        .background(Surface.window)
        .onAppear {
            reload()
        }
        .alert("清理幽灵自启残留", isPresented: $showCleanConfirm) {
            Button("移入废纸篓", role: .destructive) {
                cleanDanglingItems()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将逐条把这 \(danglingCount) 个幽灵/已卸载自启定义移入废纸篓（可还原）。"
                 + "白名单、系统受保护项与 /Library 下由 root 管理的定义会被网关拒绝，不计入成功；"
                 + "已加载的服务本次登录会话内可能仍在运行。")
        }
    }

    // MARK: - 子视图组件

    private var headerBar: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text("启动项与后台服务治理")
                        .font(Typo.title)
                        .foregroundColor(Ink.primary)
                    if danglingCount > 0 {
                        Text("\(danglingCount) 个幽灵残留")
                            .font(Typo.micro)
                            .foregroundColor(Signal.caution)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Signal.caution.opacity(0.12))
                            .clipShape(Capsule())
                    }
                }
                Text("全面审查 ~/Library/LaunchAgents 与系统守护，排查已卸载残留与无用自启服务")
                    .font(Typo.micro)
                    .foregroundColor(Ink.tertiary)
            }

            Spacer()

            // 搜索框
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(Ink.tertiary)
                    .font(.system(size: 11))
                TextField("搜索 Label / 路径 / 厂商...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(Typo.body)
                if !searchText.isEmpty {
                    Button(action: { searchText = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(Ink.tertiary)
                            .font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Surface.sunken)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .frame(width: 220)

            // 刷新按钮
            Button(action: { reload() }) {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                    Text("重新扫描")
                        .font(Typo.body)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Surface.group)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("reloadStartupItems")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var metricsOverviewBar: some View {
        HStack(spacing: 12) {
            metricTile(title: "全部启动项", count: items.count, icon: "tray.full.fill", color: Ink.primary)
            metricTile(title: "正常激活", count: items.filter { $0.status == .valid }.count, icon: "checkmark.circle.fill", color: Signal.positive)
            metricTile(title: "已停用", count: items.filter { $0.isDisabled }.count, icon: "pause.circle.fill", color: Ink.tertiary)

            // 幽灵卡片
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(danglingCount > 0 ? Signal.caution : Ink.tertiary)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text("幽灵自启残留")
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                    Text("\(danglingCount)")
                        .font(.mcNumeric(18, weight: .semibold))
                        .foregroundColor(danglingCount > 0 ? Signal.caution : Ink.primary)
                }
                Spacer()
                if danglingCount > 0 {
                    Button(action: { showCleanConfirm = true }) {
                        Text("逐条清理幽灵残留")
                            .font(Typo.micro)
                            .foregroundColor(.white)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Signal.caution)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(10)
            .background(Surface.group)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
    }

    private func metricTile(title: String, count: Int, icon: String, color: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundColor(color)
                .font(.system(size: 16))
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Typo.micro)
                    .foregroundColor(Ink.tertiary)
                Text("\(count)")
                    .font(.mcNumeric(18, weight: .semibold))
                    .foregroundColor(Ink.primary)
            }
            Spacer()
        }
        .padding(10)
        .background(Surface.group)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func bannerView(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle.fill")
                .foregroundColor(Accent.tint)
                .font(.system(size: 12))
            Text(message)
                .font(Typo.micro)
                .foregroundColor(Ink.primary)
            Spacer()
            Button(action: { bannerMessage = nil }) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Ink.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Accent.soft)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .motionSafeTransition(.opacity)
    }

    /// 自启目录读不到时的常驻提示：不再把"没权限看"渲染成"没有启动项"
    @ViewBuilder
    private var incompleteNotice: some View {
        if !scanIssues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundColor(Signal.caution)
                    Text(GovernanceEvidenceIssue.incompleteBanner(scanIssues))
                        .font(Typo.micro)
                        .foregroundColor(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(scanIssues) { issue in
                    Text("· \(issue.message)")
                        .font(Typo.micro)
                        .foregroundColor(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("/Library/LaunchAgents 与 /Library/LaunchDaemons 由 root 管理：MacClean 不提权，删除请求会被网关判为「无权限」。")
                    .font(Typo.micro)
                    .foregroundColor(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Signal.caution.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .accessibilityIdentifier("startup-item-incomplete-notice")
        }
    }

    private var contentListView: some View {
        VStack(spacing: 0) {
            incompleteNotice
            // 筛选分段器
            HStack(spacing: 8) {
                ForEach(StartupItemFilter.allCases) { f in
                    let isSelected = filter == f
                    Button(action: { filter = f }) {
                        HStack(spacing: 4) {
                            Image(systemName: f.icon)
                                .font(.system(size: 10))
                            Text(f.rawValue)
                                .font(Typo.micro)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(isSelected ? Accent.tint.opacity(0.18) : Surface.sunken)
                        .foregroundColor(isSelected ? Accent.tint : Ink.primary)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Text("共 \(filteredItems.count) 项")
                    .font(Typo.micro)
                    .foregroundColor(Ink.tertiary)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)

            Divider()

            if filteredItems.isEmpty {
                VStack(spacing: 10) {
                    Spacer()
                    // 有目录没读到就不给绿色盾牌：0 项可能只是"没权限看"
                    Image(systemName: scanIssues.isEmpty ? "checkmark.shield" : "exclamationmark.triangle")
                        .font(.system(size: 36))
                        .foregroundColor(scanIssues.isEmpty ? Signal.positive : Signal.caution)
                    Text("当前筛选下没有启动项")
                        .font(Typo.section)
                        .foregroundColor(Ink.secondary)
                    Text(scanIssues.isEmpty
                         ? "已读到的目录里没有自启定义"
                         : "有 \(scanIssues.count) 个自启目录读不到，无法判断是否健康")
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                    Spacer()
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredItems) { item in
                            StartupItemRowView(
                                item: item,
                                onToggle: { toggleItem(item) },
                                onTrash: { trashItem(item) },
                                onReveal: { revealItem(item) }
                            )
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                }
            }
        }
    }

    // MARK: - 数据流方法

    private func reload() {
        isLoading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let manager = StartupItemManager.shared
            let scanned = manager.scanAll()
            let issues = manager.lastScanIssues
            DispatchQueue.main.async {
                self.items = scanned
                self.scanIssues = issues
                self.isLoading = false
            }
        }
    }

    private func toggleItem(_ item: StartupItem) {
        do {
            let updated = try StartupItemManager.shared.toggleDisabled(item: item)
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx] = updated
            }
            // 只有拿到 launchd 会话证据才敢说"已停用"
            if updated.isDisabled && !updated.isConfirmedDisabled {
                bannerMessage = "定义文件已改名，但\(updated.note ?? "无法确认服务已停止")"
            } else {
                bannerMessage = updated.isDisabled ? "已停用自启服务: \(item.name)" : "已启用自启服务: \(item.name)"
            }
        } catch {
            bannerMessage = "切换状态失败: \(error.localizedDescription)"
        }
    }

    private func trashItem(_ item: StartupItem) {
        do {
            try StartupItemManager.shared.moveToTrash(item: item)
            items.removeAll { $0.id == item.id }
            bannerMessage = item.serviceEvidence == .loaded
                ? "定义文件已移入废纸篓，但该服务本次登录会话内仍在运行（下次登录才不再自启）"
                : "已移入废纸篓: \(item.name)"
        } catch {
            bannerMessage = "未删除: \(error.localizedDescription)"
        }
    }

    private func cleanDanglingItems() {
        let outcome = StartupItemManager.shared.deleteOutcome(
            items.filter { $0.status.isDangling })
        reload()
        // 网关的 summary 已经区分"清了几项 / 被护栏拦下几项 / 几项无权限 / 几项失败"
        bannerMessage = outcome.summary
    }

    private func revealItem(_ item: StartupItem) {
        let url = URL(fileURLWithPath: item.path)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - 单个启动项行组件

struct StartupItemRowView: View {
    let item: StartupItem
    let onToggle: () -> Void
    let onTrash: () -> Void
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            // 图标
            Image(systemName: item.location.icon)
                .font(.system(size: 16))
                .foregroundColor(item.status.color)
                .frame(width: 26)

            // 核心信息
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(item.label)
                        .font(Typo.body)
                        .foregroundColor(Ink.primary)
                        .lineLimit(1)

                    // 状态徽章
                    HStack(spacing: 3) {
                        Image(systemName: item.status.icon)
                            .font(.system(size: 8))
                        Text(item.status.rawValue)
                            .font(Typo.micro)
                    }
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .foregroundColor(item.status.color)
                    .background(item.status.color.opacity(0.12))
                    .clipShape(Capsule())

                    // 「已停用」只有在拿到 launchd 会话证据后才成立
                    if item.needsConfirmation {
                        Text("需确认")
                            .font(Typo.micro)
                            .foregroundColor(Signal.caution)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Signal.caution.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }

                    // 厂商标识
                    Text(item.vendor)
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                }

                // 路径与执行程序
                HStack(spacing: 6) {
                    Text(item.location.shortTitle)
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                    Text("•")
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                    if let prog = item.programPath {
                        Text(prog)
                            .font(Typo.micro)
                            .foregroundColor(item.status.isDangling ? Signal.caution : Ink.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("未声明执行目标")
                            .font(Typo.micro)
                            .foregroundColor(Signal.caution)
                    }
                }
            }

            Spacer()

            // 右侧操作
            HStack(spacing: 10) {
                // 在访达中显示
                Button(action: onReveal) {
                    Image(systemName: "magnifyingglass.circle")
                        .font(.system(size: 13))
                        .foregroundColor(Ink.tertiary)
                }
                .buttonStyle(.plain)
                .help("在访达中定位 plist 文件")

                // 停用/启用 Toggle
                if !item.location.requiresAdmin {
                    Toggle("", isOn: Binding(
                        get: { !item.isDisabled },
                        set: { _ in onToggle() }
                    ))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .scaleEffect(0.75)
                    .help(item.isDisabled ? "点击恢复自启服务" : "点击停用自启服务")
                }

                // 废纸篓清理按钮
                Button(action: onTrash) {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundColor(item.status.isDangling ? Signal.caution : Ink.tertiary)
                        .padding(5)
                        .background(Surface.sunken)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
                .help("将此自启配置移入废纸篓")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Surface.group)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
