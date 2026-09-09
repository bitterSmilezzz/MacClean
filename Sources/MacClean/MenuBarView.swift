import SwiftUI
import AppKit

/// 菜单栏常驻助手浮窗视图
struct MenuBarView: View {
    @EnvironmentObject private var app: AppState
    @StateObject private var sysMonitor = SystemMonitor.shared
    @Environment(\.openWindow) private var openWindow

    @State private var isHoveredScan = false
    @State private var isHoveredClean = false

    var body: some View {
        VStack(spacing: 0) {
            // 顶栏品牌与主操作
            headerView

            Divider().overlay(Theme.hairline)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Theme.spaceSm) {
                    // 1. 磁盘用量卡片
                    diskCard

                    // 2. 内存用量与压力监控卡片
                    memoryCard

                    // 3. 快捷操作栏
                    quickActions

                    // 4. 各分类快捷概览与直达
                    categoriesOverview
                }
                .padding(Theme.spaceSm)
            }

            Divider().overlay(Theme.hairline)

            // 底栏状态与版本
            footerView
        }
        .frame(width: 320, height: 490)
        .background(Theme.canvas)
        .onAppear {
            app.refreshDisk()
            sysMonitor.refresh()
        }
    }

    // MARK: - 顶栏
    private var headerView: some View {
        HStack(spacing: 8) {
            // 品牌图标底板
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(LinearGradient(
                        colors: [Theme.actionBlue, Theme.actionBlue.opacity(0.8)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ))
                    .frame(width: 22, height: 22)
                Image(systemName: "sparkles")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text("MacClean")
                    .font(Theme.bodyFont(12, weight: .bold))
                    .foregroundColor(Theme.ink)
                Text("菜单栏助手")
                    .font(Theme.bodyFont(10, weight: .regular))
                    .foregroundColor(Theme.bodyMuted)
            }

            Spacer()

            // 打开主界面
            Button {
                openMainWindow()
            } label: {
                Image(systemName: "macwindow.on.rectangle")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundColor(Theme.bodyMuted)
            .help("打开 MacClean 主窗口")
            .accessibilityLabel("打开主窗口")

            // 偏好设置
            Button {
                app.ai.showSettings = true
                openMainWindow()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundColor(Theme.bodyMuted)
            .help("偏好设置")
            .accessibilityLabel("偏好设置")

            // 退出应用
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
                    .font(.system(size: 12))
            }
            .buttonStyle(.borderless)
            .foregroundColor(Theme.dangerRed.opacity(0.8))
            .help("退出 MacClean")
            .accessibilityLabel("退出应用")
        }
        .padding(.horizontal, Theme.spaceSm)
        .padding(.vertical, 8)
    }

    // MARK: - 磁盘用量卡片
    private var diskCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Macintosh HD", systemImage: "internaldrive")
                    .font(Theme.bodyFont(11, weight: .semibold))
                    .foregroundColor(Theme.ink)
                Spacer()
                Button {
                    withAnimation {
                        app.refreshDisk()
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .foregroundColor(Theme.bodyMuted)
                .help("刷新磁盘用量")
            }

            HStack {
                Text("已用 \(app.diskUsed.byteStringCN)")
                    .font(Theme.bodyFont(11, weight: .medium))
                    .foregroundColor(Theme.ink)
                Spacer()
                Text("可用 \(app.diskAvailable.byteStringCN)")
                    .font(Theme.bodyFont(11, weight: .regular))
                    .foregroundColor(Theme.bodyMuted)
            }

            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.pearl.opacity(0.8))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(LinearGradient(
                            colors: [Theme.actionBlue, Theme.skyLinkBlue],
                            startPoint: .leading,
                            endPoint: .trailing
                        ))
                        .frame(width: max(0, geo.size.width * CGFloat(app.usedRatio)))
                }
            }
            .frame(height: 6)

            HStack {
                if app.totalCleanable > 0 {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Theme.warningOrange)
                            .frame(width: 6, height: 6)
                        Text("可清理 \(app.totalCleanable.byteStringCN)")
                            .font(Theme.bodyFont(10, weight: .semibold))
                            .foregroundColor(Theme.warningOrange)
                    }
                } else {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(Theme.successGreen)
                            .frame(width: 6, height: 6)
                        Text("磁盘健康良好")
                            .font(Theme.bodyFont(10, weight: .regular))
                            .foregroundColor(Theme.bodyMuted)
                    }
                }
                Spacer()
                Text("\(Int(app.usedRatio * 100))% 已用")
                    .font(Theme.monoFont(10, weight: .regular))
                    .foregroundColor(Theme.bodyMuted)
            }
        }
        .padding(Theme.spaceSm)
        .macCard(cornerRadius: Theme.radiusSm)
    }

    // MARK: - 物理内存监控卡片
    private var memoryCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("物理内存", systemImage: "memorychip")
                    .font(Theme.bodyFont(11, weight: .semibold))
                    .foregroundColor(Theme.ink)
                Spacer()
                // 压力指示灯
                HStack(spacing: 4) {
                    Circle()
                        .fill(sysMonitor.memory.pressure.color)
                        .frame(width: 6, height: 6)
                    Text(sysMonitor.memory.pressure.rawValue)
                        .font(Theme.bodyFont(10, weight: .semibold))
                        .foregroundColor(sysMonitor.memory.pressure.color)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(sysMonitor.memory.pressure.color.opacity(0.12))
                .cornerRadius(4)
            }

            HStack {
                Text("已用 \(sysMonitor.memory.usedString)")
                    .font(Theme.bodyFont(11, weight: .medium))
                    .foregroundColor(Theme.ink)
                Spacer()
                Text("总量 \(sysMonitor.memory.totalString)")
                    .font(Theme.bodyFont(11, weight: .regular))
                    .foregroundColor(Theme.bodyMuted)
            }

            // 内存进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.pearl.opacity(0.8))
                    RoundedRectangle(cornerRadius: 3)
                        .fill(sysMonitor.memory.pressure.color)
                        .frame(width: max(0, geo.size.width * CGFloat(sysMonitor.memory.usageRatio)))
                }
            }
            .frame(height: 6)

            // 细分指标（活动监视器标准）
            HStack(spacing: 6) {
                Text("App: \(sysMonitor.memory.appString)")
                Text("·")
                Text("联动: \(sysMonitor.memory.wiredString)")
                Text("·")
                Text("压缩: \(sysMonitor.memory.compressedString)")
            }
            .font(Theme.monoFont(9, weight: .regular))
            .foregroundColor(Theme.bodyMuted)
        }
        .padding(Theme.spaceSm)
        .macCard(cornerRadius: Theme.radiusSm)
    }

    // MARK: - 快捷操作栏
    private var quickActions: some View {
        HStack(spacing: 8) {
            // 全盘智能扫描按钮
            let isScanning = app.categories.contains(where: { $0.isScanning })
            Button {
                app.scanAll()
            } label: {
                HStack(spacing: 6) {
                    if isScanning {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .medium))
                    }
                    Text(isScanning ? "扫描中…" : "全盘扫描")
                        .font(Theme.bodyFont(11, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            }
            .buttonStyle(.bordered)
            .disabled(isScanning)

            // 一键清理或安全清理
            Button {
                if app.totalSelected > 0 {
                    app.cleanSelectedAcrossCategories(permanently: false)
                } else {
                    app.quickCleanSafeItems()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .medium))
                    Text(app.totalSelected > 0 ? "清理选中 (\(app.totalSelected.byteStringCN))" : "安全速清")
                        .font(Theme.bodyFont(11, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.actionBlue)
            .disabled(app.isCleaning || (app.totalSelected == 0 && app.totalCleanable == 0))
        }
    }

    // MARK: - 各分类快捷概览与直达
    private var categoriesOverview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("清理与优化直达")
                .font(Theme.bodyFont(10, weight: .medium))
                .foregroundColor(Theme.bodyMuted)
                .padding(.horizontal, 2)
                .padding(.top, 2)

            ForEach(CleanCategory.allCases) { cat in
                MenuBarCategoryRow(category: cat, state: app.state(for: cat)) {
                    openMainWindow(destination: .category(cat))
                }
            }

            // 重复文件入口
            Button {
                openMainWindow(destination: .duplicates)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.actionBlue)
                        .frame(width: 14)
                    Text("重复与相似大文件")
                        .font(Theme.bodyFont(11, weight: .regular))
                        .foregroundColor(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.bodyMuted.opacity(0.6))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .macRowHover(cornerRadius: 4)

            // App 卸载器入口
            Button {
                openMainWindow(destination: .uninstaller)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "trash.circle")
                        .font(.system(size: 11))
                        .foregroundColor(.purple)
                        .frame(width: 14)
                    Text("App 卸载器")
                        .font(Theme.bodyFont(11, weight: .regular))
                        .foregroundColor(Theme.ink)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9))
                        .foregroundColor(Theme.bodyMuted.opacity(0.6))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .macRowHover(cornerRadius: 4)
        }
        .padding(6)
        .macCard(cornerRadius: Theme.radiusSm)
    }

    // MARK: - 底栏
    private var footerView: some View {
        HStack {
            Text("MacClean 后台常驻守护")
                .font(Theme.bodyFont(10, weight: .regular))
                .foregroundColor(Theme.bodyMuted)

            Spacer()

            Button("打开主窗口") {
                openMainWindow()
            }
            .buttonStyle(.link)
            .font(Theme.bodyFont(10, weight: .semibold))
        }
        .padding(.horizontal, Theme.spaceSm)
        .padding(.vertical, 6)
    }

    // MARK: - 激活并调出主窗口
    private func openMainWindow(destination: Destination? = nil) {
        if let destination {
            withAnimation(.easeOut(duration: 0.15)) {
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

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .medium))

            switch app.diskMonitor.config.menuBarDisplayMode {
            case .iconOnly:
                EmptyView()
            case .iconAndDisk:
                Text(app.diskAvailable.byteStringCN)
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
            case .iconAndMemory:
                Text("\(Int(sysMonitor.memory.usageRatio * 100))%")
                    .font(.system(size: 11, weight: .regular, design: .monospaced))
            }
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
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .font(.system(size: 11))
                    .foregroundColor(category.accentColor)
                    .frame(width: 14)

                Text(category.title)
                    .font(Theme.bodyFont(11, weight: .regular))
                    .foregroundColor(Theme.ink)

                Spacer()

                if state.isScanning {
                    ProgressView()
                        .scaleEffect(0.5)
                        .frame(width: 12, height: 12)
                } else if state.isScanned {
                    Text(state.totalSize > 0 ? state.totalSize.byteStringCN : "0 KB")
                        .font(Theme.monoFont(10, weight: .medium))
                        .foregroundColor(state.totalSize > 0 ? Theme.warningOrange : Theme.bodyMuted)
                } else {
                    Text("未扫描")
                        .font(Theme.bodyFont(10, weight: .regular))
                        .foregroundColor(Theme.bodyMuted)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9))
                    .foregroundColor(Theme.bodyMuted.opacity(0.6))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .macRowHover(cornerRadius: 4)
    }
}
