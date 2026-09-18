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

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏品牌与主操作
            headerView

            Hairline()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Space.sm) {
                    // 1. 磁盘用量
                    diskGroup

                    // 2. 内存用量与压力监控
                    memoryGroup

                    // 3. 快捷操作
                    quickActions

                    // 4. 各分类快捷概览与直达
                    categoriesGroup
                }
                .padding(Space.sm)
            }

            Hairline()

            // 底栏
            footerView
        }
        .frame(width: 320, height: 490)
        .background(Surface.window)
        .onAppear {
            app.refreshDisk()
            sysMonitor.refresh()
            // 用户在盯着看 → 用最快档位
            sysMonitor.apply(mode: .foreground)
        }
        .onDisappear {
            // 浮窗关掉 → 回到"标签需要什么就给什么"的最低档位
            sysMonitor.apply(mode: MenuBarLabelView.requiredPollingMode(
                displayMode: app.diskMonitor.config.menuBarDisplayMode))
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

    // MARK: - 快捷操作
    private var quickActions: some View {
        let isScanning = app.categories.contains(where: { $0.isScanning })

        return HStack(spacing: Space.xs) {
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
                } else {
                    app.quickCleanSafeItems()
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                    Text(app.totalSelected > 0 ? "清理选中 (\(app.totalSelected.byteStringCN))" : "安全速清")
                        .font(Typo.rowStrong)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderedProminent)
            .disabled(app.isCleaning || (app.totalSelected == 0 && app.totalCleanable == 0))
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

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "internaldrive")
                .font(.system(size: 12, weight: .medium))

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
