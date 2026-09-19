import SwiftUI

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
            Text("将把检测到的 \(danglingCount) 个幽灵/已卸载自启项安全移入废纸篓。清理后这些启动项将不再常驻系统，可在废纸篓中随时还原。")
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
                        Text("一键安全清理")
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

    private var contentListView: some View {
        VStack(spacing: 0) {
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
                    Image(systemName: "checkmark.shield")
                        .font(.system(size: 36))
                        .foregroundColor(Signal.positive)
                    Text("当前筛选下没有启动项")
                        .font(Typo.section)
                        .foregroundColor(Ink.secondary)
                    Text("系统自启配置健康规范")
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
            let scanned = StartupItemManager.shared.scanAll()
            DispatchQueue.main.async {
                self.items = scanned
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
            bannerMessage = updated.isDisabled ? "已停用自启服务: \(item.name)" : "已启用自启服务: \(item.name)"
        } catch {
            bannerMessage = "切换状态失败: \(error.localizedDescription)"
        }
    }

    private func trashItem(_ item: StartupItem) {
        do {
            try StartupItemManager.shared.moveToTrash(item: item)
            items.removeAll { $0.id == item.id }
            bannerMessage = "已移入废纸篓: \(item.name)"
        } catch {
            bannerMessage = "移入废纸篓失败: \(error.localizedDescription)"
        }
    }

    private func cleanDanglingItems() {
        let res = StartupItemManager.shared.cleanAllDangling(items: items)
        reload()
        bannerMessage = "已清理 \(res.removedCount) 个幽灵自启残留，释放 \(res.freedBytes.byteStringCN)"
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
