import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 顶部品牌区
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(Theme.actionBlue)
                Text("MacClean")
                    .font(Theme.displayFont(20, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(Theme.ink)
                Spacer()
            }
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, Theme.contentPadding)
            .padding(.bottom, Theme.spaceMd)

            // 磁盘仪表
            DiskGaugeView()
                .padding(.horizontal, Theme.contentPadding)
                .padding(.bottom, Theme.spaceLg)

            // 导航列表
            ScrollView {
                VStack(spacing: 8) {
                    // 概览仪表页
                    ToolRow(icon: "square.grid.2x2", title: "概览",
                            subtitle: "磁盘与清理总览",
                            isActive: app.destination == .dashboard) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            app.destination = .dashboard
                        }
                    }
                    // 全局检索
                    ToolRow(icon: "magnifyingglass", title: "检索",
                            subtitle: "跨分类与历史搜索",
                            isActive: app.destination == .search) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            app.destination = .search
                        }
                    }

                    Divider().overlay(Theme.hairline).padding(.vertical, Theme.spaceXs)

                    ForEach(CleanCategory.allCases) { cat in
                        let st = app.state(for: cat)
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                app.destination = .category(cat)
                            }
                        } label: {
                            CategoryRow(category: cat, state: st, isActive: app.destination == .category(cat))
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("sidebarCategory_\(cat.rawValue)")
                    }

                    Divider().overlay(Theme.hairline).padding(.vertical, Theme.spaceXs)

                    // App 卸载器（融合 Pearcleaner/PureMac）
                    ToolRow(icon: "app.dashed", title: "App 卸载器",
                            subtitle: "卸载 App 及其全部残留",
                            isActive: app.destination == .uninstaller) {
                        app.destination = .uninstaller
                    }
                    // 清理历史（融合 Mole history）
                    ToolRow(icon: "clock.arrow.circlepath", title: "清理历史",
                            subtitle: "\(app.history.count) 条记录",
                            isActive: app.destination == .history) {
                        app.destination = .history
                    }
                }
                .padding(.horizontal, Theme.spaceSm)
            }

            // 统计条（已扫描 X/6 · 可清理 Y）——化废为用：接入侧栏底部
            statsLine
                .padding(.horizontal, Theme.contentPadding)
                .padding(.top, Theme.spaceXs)

            // 底部扫描全部（原生 macOS 主按钮，居中不贴边）
            Button(action: { app.scanAll() }) {
                Label("扫描全部分类", systemImage: "arrow.clockwise")
                    .font(Theme.bodyFont(15, weight: .medium))
                    .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.actionBlue)
            .padding(.top, Theme.spaceSm)
            .padding(.bottom, Theme.contentPadding)
        }
        .background(Theme.parchment)
    }

    /// 概览统计（Dashboard / 侧栏底部统计条共用）
    var statsLine: some View {
        HStack(spacing: 0) {
            Text("\(app.scannedCount)/\(CleanCategory.allCases.count)")
                .font(Theme.monoFont(12, weight: .semibold))
                .foregroundColor(Theme.inkMuted80)
            Text(" 已扫描")
                .font(Theme.bodyFont(11))
                .foregroundColor(Theme.inkMuted48)
            Spacer()
            Text(app.totalCleanable.byteStringCN)
                .font(Theme.monoFont(12, weight: .semibold))
                .foregroundColor(Theme.actionBlue)
            Text(" 可清理")
                .font(Theme.bodyFont(11))
                .foregroundColor(Theme.inkMuted48)
        }
    }
}

/// 侧边栏工具入口（卸载器 / 历史）
struct ToolRow: View {
    let icon: String
    let title: String
    let subtitle: String
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.spaceSm) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Theme.actionBlue)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.actionBlue.opacity(0.1)))

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.bodyFont(15, weight: .medium))
                        .foregroundColor(Theme.ink)
                    Text(subtitle)
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.inkMuted48)
                }
                Spacer()
                if isActive {
                    Circle().fill(Theme.actionBlue).frame(width: 7, height: 7)
                }
            }
            .padding(.horizontal, Theme.spaceSm)
            .padding(.vertical, Theme.spaceXs)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .fill(isActive ? Theme.actionBlue.opacity(0.08) : Theme.canvas)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("toolRow_\(title)")
    }
}

struct CategoryRow: View {
    let category: CleanCategory
    @ObservedObject var state: CategoryState
    var isActive: Bool = false   // 三巡：分类行激活高亮，与 ToolRow 一致

    var body: some View {
        HStack(spacing: Theme.spaceSm) {
            Image(systemName: category.icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(Theme.actionBlue)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Theme.actionBlue.opacity(0.1)))

            VStack(alignment: .leading, spacing: 1) {
                Text(category.title)
                    .font(Theme.bodyFont(15, weight: .medium))
                    .foregroundColor(Theme.ink)
                Text(state.isScanned ? "已扫描 · \(state.items.count) 项" : "未扫描")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.inkMuted48)
            }
            Spacer()
            if state.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
            if state.isScanned && state.totalSize > 0 && !state.isScanning {
                Text(state.totalSize.byteStringCN)
                    .font(Theme.bodyFont(14, weight: .semibold))
                    .foregroundColor(Theme.inkMuted48)
                    .monospacedDigit()
            }
            if isActive {
                Circle().fill(Theme.actionBlue).frame(width: 7, height: 7)
            }
        }
        .padding(.horizontal, Theme.spaceSm)
        .padding(.vertical, Theme.spaceXs)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .fill(isActive ? Theme.actionBlue.opacity(0.08) : Theme.canvas)
        )
    }
}
