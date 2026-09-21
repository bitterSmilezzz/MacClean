import SwiftUI
import AppKit

/// 菜单栏常驻助手浮窗。
///
/// 重写要点：
///  - 删掉品牌图标底下的渐变圆角方块，图标就是图标；"菜单栏助手"这类装饰性副标题一并删除。
///  - 磁盘、内存两张"描边 + 阴影"浮空卡片换成 `GroupBox` 内嵌分组：中性底色 + 发丝分隔线，
///    组内用 `GroupedRow` 分行。
///  - 进度条统一改用 `CapacityBar`，不再各画一条渐变条。
///  - 六个分类的彩虹图标色全部去掉——分类身份由 SF Symbol + 文字表达，唯一强调色是
///    `Accent.tint`；语义色只留给内存压力这种真实信号。
///  - 快捷操作从"两个等权按钮"收成一个主按钮（清理）+ 一个文字动作（扫描）。
///  - 所有可点元素补上 hover / 按压反馈与 `contentShape` 命中范围。
struct MenuBarView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var sysMonitor = SystemMonitor.shared
    @Environment(\.openWindow) private var openWindow

    @State var localSnapshots: [APFSSnapshot] = []
    /// `tmutil` 是否真的跑成功过。false 时"0 个快照"没有任何含义——
    /// 以前这里只看 `listLocalSnapshots()` 是否为空，命令失败/工具缺失都会得到空数组，
    /// 于是菜单栏绿勾写着"无快照占用物理空间"，而实际是"没读到"。
    @State var snapshotsKnown: Bool = true
    @State var danglingStartupItems: [StartupItem] = []
    @State var isCleaningSnapshots: Bool = false
    @State var isCleaningDangling: Bool = false
    @State var recentTrend: [(dayLabel: String, bytes: Int64)] = []
    @State var weekTotalFreed: Int64 = 0

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏品牌与主操作
            headerView

            Hairline()

            // 清理成效反馈横幅（v1.45.0）
            cleanFeedbackBanner

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Space.sm) {
                    // 1. 磁盘用量
                    diskGroup

                    // 2. 内存用量与压力监控
                    memoryGroup

                    // 3. 底层存储与后台守护体检（v1.51.0）
                    systemToolsGroup

                    // 4. 存储回收趋势微卡（v1.51.0）
                    recoveryTrendGroup

                    // 5. 快捷操作
                    quickActions

                    // 6. 各分类快捷概览与直达
                    categoriesGroup
                }
                .padding(Space.sm)
            }

            Hairline()

            // 底栏
            footerView
        }
        .frame(width: 320, height: 530)
        .background(Surface.window)
        .onAppear {
            app.refreshDisk()
            sysMonitor.refresh()
            refreshQuickStatus()
            // 用户在盯着看 → 用最快档位
            sysMonitor.apply(mode: .foreground)
        }
        .onDisappear {
            // 浮窗关掉 → 回到"标签需要什么就给什么"的最低档位
            sysMonitor.apply(mode: MenuBarLabelView.requiredPollingMode(
                displayMode: app.diskMonitor.config.menuBarDisplayMode))
        }
    }

    // MARK: - 清理成效反馈横幅
    @ViewBuilder
    private var cleanFeedbackBanner: some View {
        if let summary = app.lastCleanSummary, !summary.isEmpty {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Signal.positive)

                    Text(summary)
                        .font(Typo.caption)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(2)

                    Spacer(minLength: Space.xxs)

                    if let snap = app.lastCleanResult, let sessionID = snap.undoSessionID, snap.mode.contains("废纸篓") {
                        Button {
                            withAnimation(Motion.micro) {
                                let res = UndoManagerStore.restore(sessionID: sessionID)
                                app.refreshDisk()
                                app.lastCleanSummary = "已撤销：\(res.summary)"
                                app.lastCleanResult = nil
                            }
                        } label: {
                            Text("撤销")
                                .font(Typo.section)
                                .foregroundStyle(Accent.tint)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("撤销本次清理")
                    }

                    Button {
                        withAnimation(Motion.micro) {
                            app.lastCleanSummary = nil
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Ink.tertiary)
                            .frame(width: 14, height: 14)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("关闭清理反馈")
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .background(Signal.positive.opacity(0.12))
            .overlay(alignment: .bottom) { Hairline() }
            .motionSafeTransition(.move(edge: .top).combined(with: .opacity))
            .accessibilityIdentifier("menuBarCleanFeedbackBanner")
        }
    }

    // MARK: - 顶栏
    private var headerView: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "internaldrive")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Accent.tint)

            Text("MacClean")
                .font(Typo.rowStrong)
                .foregroundStyle(Ink.primary)

            Spacer(minLength: Space.xs)

            // 打开主界面
            iconButton("macwindow.on.rectangle", help: "打开 MacClean 主窗口", label: "打开主窗口") {
                openMainWindow()
            }

            // 偏好设置
            iconButton("gearshape", help: "偏好设置", label: "偏好设置") {
                app.ai.showSettings = true
                openMainWindow()
            }

            // 退出应用
            iconButton("power", help: "退出 MacClean", label: "退出应用") {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
    }

    private func iconButton(_ systemName: String, help: String, label: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12))
                .foregroundStyle(Ink.secondary)
                .frame(width: 22, height: 20)
                .contentShape(Rectangle())
        }
        .pressable()
        .rowHover()
        .help(help)
        .accessibilityLabel(label)
    }

    // MARK: - 磁盘用量
    private var diskGroup: some View {
        GroupBox {
            GroupedRow {
                HStack(spacing: Space.xs) {
                    IconSlot(systemName: "internaldrive", size: 12, color: Ink.tertiary, width: 16)

                    Text("Macintosh HD")
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)

                    Spacer(minLength: Space.xs)

                    Button {
                        withAnimation {
                            app.refreshDisk()
                        }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11))
                            .foregroundStyle(Ink.secondary)
                            .frame(width: 18, height: 16)
                            .contentShape(Rectangle())
                    }
                    .pressable()
                    .rowHover()
                    .help("刷新磁盘用量")
                    .accessibilityLabel("刷新磁盘用量")
                }
            }

            GroupedRow(isLast: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("已用 \(app.diskUsed.byteStringCN)")
                            .font(Typo.row)
                            .monospacedDigit()
                            .foregroundStyle(Ink.primary)
                        Spacer(minLength: Space.xs)
                        Text("可用 \(app.diskAvailable.byteStringCN)")
                            .font(Typo.caption)
                            .monospacedDigit()
                            .foregroundStyle(Ink.tertiary)
                    }

                    CapacityBar(
                        used: app.usedRatio,
                        reclaimable: app.diskTotal > 0 ? Double(app.totalCleanable) / Double(app.diskTotal) : 0,
                        height: 6,
                        isCritical: app.usedRatio > 0.88
                    )

                    HStack(spacing: Space.xs) {
                        if app.totalCleanable > 0 {
                            Text("可清理")
                                .font(Typo.caption)
                                .foregroundStyle(Ink.secondary)
                            Text(app.totalCleanable.byteStringCN)
                                .font(.mcNumeric(11, weight: .medium))
                                .foregroundStyle(Accent.tint)
                                .motionSafeNumericTransition()
                        } else {
                            IconSlot(systemName: "checkmark.circle", size: 11, color: Ink.tertiary, width: 14)
                            Text("无待清理项")
                                .font(Typo.caption)
                                .foregroundStyle(Ink.tertiary)
                        }

                        Spacer(minLength: Space.xs)

                        Text("\(Int(app.usedRatio * 100))% 已用")
                            .font(.mcNumeric(11))
                            .foregroundStyle(Ink.tertiary)
                            .motionSafeNumericTransition()
                    }
                }
            }
        }
    }

    // MARK: - 物理内存监控
    private var memoryGroup: some View {
        GroupBox {
            GroupedRow {
                HStack(spacing: Space.xs) {
                    IconSlot(systemName: "memorychip", size: 12, color: Ink.tertiary, width: 16)

                    Text("物理内存")
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)

                    Spacer(minLength: Space.xs)

                    // 压力指示灯
                    Circle()
                        .fill(pressureSignal)
                        .frame(width: 6, height: 6)
                    Text(sysMonitor.memory.pressure.rawValue)
                        .font(Typo.micro)
                        .foregroundStyle(pressureSignal)
                }
            }

            GroupedRow(isLast: true) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("已用 \(sysMonitor.memory.usedString)")
                            .font(Typo.row)
                            .monospacedDigit()
                            .foregroundStyle(Ink.primary)
                        Spacer(minLength: Space.xs)
                        Text("总量 \(sysMonitor.memory.totalString)")
                            .font(Typo.caption)
                            .monospacedDigit()
                            .foregroundStyle(Ink.tertiary)
                    }

                    CapacityBar(
                        used: sysMonitor.memory.usageRatio,
                        height: 6,
                        isCritical: sysMonitor.memory.pressure == .high
                    )

                    // 细分指标（活动监视器标准）
                    HStack(spacing: Space.xs) {
                        Text("App \(sysMonitor.memory.appString)")
                        Text("·").foregroundStyle(Ink.quaternary)
                        Text("联动 \(sysMonitor.memory.wiredString)")
                        Text("·").foregroundStyle(Ink.quaternary)
                        Text("压缩 \(sysMonitor.memory.compressedString)")
                    }
                    .font(Typo.caption)
                    .monospacedDigit()
                    .foregroundStyle(Ink.tertiary)
                }
            }
        }
    }

    /// 内存压力是真实语义信号：正常/适中/紧张。
    private var pressureSignal: Color {
        switch sysMonitor.memory.pressure {
        case .normal: return Signal.positive
        case .moderate: return Signal.caution
        case .high: return Signal.critical
        }
    }

    // MARK: - 底层存储与后台守护体检（v1.51.0）
    private var systemToolsGroup: some View {
        GroupBox(title: "底层存储与后台守护体检") {
            // 1. APFS 本地时间机器快照
            GroupedRow {
                HStack(spacing: Space.xs) {
                    IconSlot(systemName: "camera.badge.clock", size: 12, color: localSnapshots.isEmpty ? (snapshotsKnown ? Signal.positive : Ink.quaternary) : Signal.caution, width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("APFS 本地快照")
                            .font(Typo.row)
                            .foregroundStyle(Ink.primary)
                        Text(localSnapshots.isEmpty
                                ? (snapshotsKnown ? "无快照占用物理空间" : "快照状态未知（tmutil 未成功返回）")
                                : "发现 \(localSnapshots.count) 个快照霸占磁盘")
                            .font(Typo.micro)
                            .foregroundStyle(localSnapshots.isEmpty ? Ink.tertiary : Signal.caution)
                    }

                    Spacer(minLength: Space.xs)

                    if !localSnapshots.isEmpty {
                        Button {
                            isCleaningSnapshots = true
                            DispatchQueue.global(qos: .userInitiated).async {
                                let res = SystemDeepStorageInspector.deleteAllLocalSnapshots(snapshots: localSnapshots)
                                DispatchQueue.main.async {
                                    isCleaningSnapshots = false
                                    app.refreshDisk()
                                    withAnimation(Motion.micro) {
                                        // 成功数之外必须带上失败/跳过数：一键删除时只播报
                                        // "已释放 N 个"，用户会以为剩下那些也清了。
                                        app.lastCleanSummary = res.failedCount == 0
                                            ? "已释放 \(res.succeededCount) 个 APFS 本地快照"
                                            : "已释放 \(res.succeededCount) 个快照，\(res.failedCount) 个未成功（需逐条确认或已被系统回收）"
                                    }
                                    refreshQuickStatus()
                                }
                            }
                        } label: {
                            if isCleaningSnapshots {
                                ProgressView().controlSize(.mini)
                            } else {
                                Label("释放", systemImage: "bolt.fill")
                                    .font(Typo.micro)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isCleaningSnapshots)
                        .accessibilityIdentifier("menuBarReleaseSnapshotsButton")
                    }
                }
            }

            // 2. 幽灵自启项
            GroupedRow(isLast: true) {
                HStack(spacing: Space.xs) {
                    IconSlot(systemName: "bolt.horizontal.circle", size: 12, color: danglingStartupItems.isEmpty ? Signal.positive : Signal.caution, width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("后台启动项")
                            .font(Typo.row)
                            .foregroundStyle(Ink.primary)
                        Text(danglingStartupItems.isEmpty ? "启动项正常，无幽灵残留" : "发现 \(danglingStartupItems.count) 个失效幽灵自启项")
                            .font(Typo.micro)
                            .foregroundStyle(danglingStartupItems.isEmpty ? Ink.tertiary : Signal.caution)
                    }

                    Spacer(minLength: Space.xs)

                    if !danglingStartupItems.isEmpty {
                        Button {
                            isCleaningDangling = true
                            DispatchQueue.global(qos: .userInitiated).async {
                                let res = StartupItemManager.shared.cleanAllDangling(items: danglingStartupItems)
                                DispatchQueue.main.async {
                                    isCleaningDangling = false
                                    withAnimation(Motion.micro) {
                                        app.lastCleanSummary = "已清理 \(res.removedCount) 个幽灵自启项"
                                    }
                                    refreshQuickStatus()
                                }
                            }
                        } label: {
                            if isCleaningDangling {
                                ProgressView().controlSize(.mini)
                            } else {
                                Label("清理", systemImage: "trash")
                                    .font(Typo.micro)
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(isCleaningDangling)
                        .accessibilityIdentifier("menuBarCleanDanglingButton")
                    } else {
                        Button {
                            openMainWindow(destination: .startupItems)
                        } label: {
                            Text("管理")
                                .font(Typo.micro)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .accessibilityIdentifier("menuBarSystemToolsGroup")
    }

    // MARK: - 存储回收趋势微卡（v1.51.0）
    private var recoveryTrendGroup: some View {
        GroupBox(title: "存储回收趋势") {
            GroupedRow(isLast: true) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack {
                        Text("近 7 天累计减负")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                        Spacer()
                        Text(weekTotalFreed > 0 ? weekTotalFreed.byteStringCN : "0 KB")
                            .font(.mcNumeric(12, weight: .semibold))
                            .foregroundStyle(weekTotalFreed > 0 ? Signal.positive : Ink.tertiary)
                            .motionSafeNumericTransition()
                    }

                    // 迷你 7 天柱状趋势图
                    let maxBytes = max(1, recentTrend.map(\.bytes).max() ?? 1)
                    HStack(alignment: .bottom, spacing: 6) {
                        ForEach(recentTrend.indices, id: \.self) { idx in
                            let item = recentTrend[idx]
                            let heightRatio = min(1.0, max(0.08, Double(item.bytes) / Double(maxBytes)))
                            VStack(spacing: 3) {
                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(Surface.hairline.opacity(0.4))
                                        .frame(width: 22, height: 28)
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(item.bytes > 0 ? Accent.tint : Signal.neutral.opacity(0.3))
                                        .frame(width: 22, height: CGFloat(28 * heightRatio))
                                }
                                Text(item.dayLabel)
                                    .font(Typo.micro)
                                    .foregroundStyle(idx == recentTrend.count - 1 ? Accent.tint : Ink.quaternary)
                            }
                            .help("\(item.dayLabel): \(item.bytes.byteStringCN)")
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 2)
                }
            }
        }
        .accessibilityIdentifier("menuBarRecoveryTrendGroup")
    }

    // MARK: - 快捷操作
    private var quickActions: some View {
        let isScanning = app.categories.contains(where: { $0.isScanning })

        return VStack(spacing: 6) {
            HStack(spacing: Space.xs) {
                // 全盘智能扫描：次要动作，bordered
                Button {
                    app.scanAll()
                } label: {
                    HStack(spacing: 5) {
                        if isScanning {
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                                .frame(width: 12, height: 12)
                        } else {
                            Image(systemName: "arrow.triangle.2.circlepath")
                                .font(.system(size: 11, weight: .medium))
                        }
                        Text(isScanning ? "扫描中…" : "全盘扫描")
                            .font(Typo.row)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .disabled(isScanning)

                // 一键清理或安全清理：唯一主操作
                Button {
                    if app.totalSelected > 0 {
                        app.cleanSelectedAcrossCategories(permanently: false)
                    } else if app.smartRecommendedCount > 0 {
                        app.quickCleanSmartRecommendations()
                    } else {
                        app.quickCleanSafeItems()
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                        let labelText: String = {
                            if app.totalSelected > 0 {
                                return "清理选中 (\(app.totalSelected.byteStringCN))"
                            } else if app.smartRecommendedBytes > 0 {
                                return "清理推荐 (\(app.smartRecommendedBytes.byteStringCN))"
                            } else {
                                return "安全速清"
                            }
                        }()
                        Text(labelText)
                            .font(Typo.rowStrong)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 28)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .disabled(app.isCleaning || (app.totalSelected == 0 && app.totalCleanable == 0))
            }

            // 极速清理微面板入口 (v1.56.0)
            Button {
                QuickCleanPanelController.shared.toggle(with: app)
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Accent.tint)
                    Text("极速清理微面板")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.primary)
                    Spacer()
                    Text(app.diskMonitor.config.globalHotkeyPreset.shortDisplay)
                        .font(Typo.micro)
                        .foregroundStyle(Ink.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1.5)
                        .background(Surface.sunken)
                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .background(Surface.group)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("menuBarQuickCleanPanelButton")
        }
    }

    // MARK: - 各分类快捷概览与直达
    private var categoriesGroup: some View {
        GroupBox(title: "快速访问") {
            ForEach(CleanCategory.allCases) { cat in
                GroupedRow {
                    MenuBarCategoryRow(category: cat, state: app.state(for: cat)) {
                        openMainWindow(destination: .category(cat))
                    }
                }
            }

            // 启动项管理入口
            GroupedRow {
                navRow(icon: "bolt.horizontal.circle", title: "启动项与后台守护") {
                    openMainWindow(destination: .startupItems)
                }
            }

            // 系统底层存储入口
            GroupedRow {
                navRow(icon: "internaldrive.badge.gearshape", title: "系统底层存储与快照") {
                    openMainWindow(destination: .category(.browserAndSystem))
                }
            }

            // 重复文件入口
            GroupedRow {
                navRow(icon: "doc.on.doc", title: "重复与相似大文件") {
                    openMainWindow(destination: .duplicates)
                }
            }

            // App 卸载器入口
            GroupedRow(isLast: true) {
                navRow(icon: "app.dashed", title: "App 卸载器") {
                    openMainWindow(destination: .uninstaller)
                }
            }
        }
    }

    func refreshQuickStatus() {
        DispatchQueue.global(qos: .userInitiated).async {
            let inventory = SystemDeepStorageInspector.snapshotInventory(volume: "/")
            let snaps = inventory.snapshots
            let startups = StartupItemManager.shared.scanAll().filter { $0.status.isDangling }
            let history = HistoryStore.load()
            let trend = HistoryStore.dailyFreedBytesLast7Days(records: history)
            let weekTotal = HistoryStore.totalFreedLast7Days(records: history)

            DispatchQueue.main.async {
                self.localSnapshots = snaps
                self.snapshotsKnown = inventory.commandSucceeded
                self.danglingStartupItems = startups
                self.recentTrend = trend
                self.weekTotalFreed = weekTotal
            }
        }
    }

    private func navRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                IconSlot(systemName: icon, size: 12, color: Ink.secondary, width: 16)

                Text(title)
                    .font(Typo.row)
                    .foregroundStyle(Ink.primary)

                Spacer(minLength: Space.xs)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.quaternary)
            }
            .contentShape(Rectangle())
        }
        .pressable()
        .rowHover()
    }

    // MARK: - 底栏
    private var footerView: some View {
        Button {
            openMainWindow()
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 11))
                Text("打开主窗口")
                    .font(Typo.caption)
            }
            .foregroundStyle(Ink.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .pressable()
        .rowHover()
        .padding(.horizontal, Space.xs)
        .padding(.vertical, Space.xxs)
    }

    // MARK: - 激活并调出主窗口
    private func openMainWindow(destination: Destination? = nil) {
        if let destination {
            withAnimation(Motion.micro) {
                app.destination = destination
            }
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        for window in NSApplication.shared.windows {
            if window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
                return
            }
        }
        openWindow(id: "mainWindow")
    }
}

/// 菜单栏常驻状态图标 Label 视图
struct MenuBarLabelView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var sysMonitor = SystemMonitor.shared

    /// 标签在后台需要多快的轮询。
    ///
    /// 关键在于**只有"图标 + 内存"这一档才真的需要内存轮询**：
    ///  - `iconOnly`：标签上没有任何动态内容 → 完全不需要轮询；
    ///  - `iconAndDisk`：磁盘数值来自 `AppState.diskAvailable`（由 `refreshDisk()` 更新），
    ///    跟这个内存定时器无关 → 同样不需要；
    ///  - `iconAndMemory`：标签显示内存占用率 → 需要中等频率刷新。
    ///
    /// 原实现是无条件 3 秒一轮，等于让一个纯图标模式也在后台每 3 秒唤醒一次 CPU。
    static func requiredPollingMode(displayMode: MenuBarDisplayMode) -> SystemMonitor.PollingMode {
        switch displayMode {
        case .iconOnly, .iconAndDisk: return .dormant
        case .iconAndMemory: return .background
        }
    }

    private var isLowSpaceWarning: Bool {
        app.diskMonitor.config.lowSpaceAlertEnabled
            && app.diskAvailable < Int64(app.diskMonitor.config.lowSpaceThresholdGB) * 1024 * 1024 * 1024
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: isLowSpaceWarning ? "exclamationmark.circle.fill" : "internaldrive")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(isLowSpaceWarning ? Signal.caution : nil)

            switch app.diskMonitor.config.menuBarDisplayMode {
            case .iconOnly:
                EmptyView()
            case .iconAndDisk:
                Text(app.diskAvailable.byteStringCN)
                    .font(.mcNumeric(11))
            case .iconAndMemory:
                Text("\(Int(sysMonitor.memory.usageRatio * 100))%")
                    .font(.mcNumeric(11))
            }
        }
        // 显示模式改变时立刻调整档位（比如从"仅图标"切到"图标 + 内存"）
        .onAppear {
            sysMonitor.apply(mode: Self.requiredPollingMode(
                displayMode: app.diskMonitor.config.menuBarDisplayMode))
        }
        .onChange(of: app.diskMonitor.config.menuBarDisplayMode) { newMode in
            sysMonitor.apply(mode: Self.requiredPollingMode(displayMode: newMode))
        }
    }
}

/// 菜单栏分类跳转与指标项
struct MenuBarCategoryRow: View {
    let category: CleanCategory
    @ObservedObject var state: CategoryState
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: Space.xs) {
                IconSlot(systemName: category.icon, size: 12, color: Ink.secondary, width: 16)

                Text(category.title)
                    .font(Typo.row)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)

                Spacer(minLength: Space.xs)

                if state.isScanning {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.7)
                        .frame(width: 12, height: 12)
                } else if state.isScanned {
                    Text(state.totalSize > 0 ? state.totalSize.byteStringCN : "0 KB")
                        .font(.mcNumeric(11))
                        .foregroundStyle(state.totalSize > 0 ? Ink.secondary : Ink.quaternary)
                        .motionSafeNumericTransition()
                } else {
                    Text("未扫描")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.quaternary)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.quaternary)
            }
            .contentShape(Rectangle())
        }
        .pressable()
        .rowHover()
    }
}
