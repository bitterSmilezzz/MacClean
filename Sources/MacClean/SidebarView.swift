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
                VStack(spacing: 6) {
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

                    Divider().overlay(Theme.separator).padding(.vertical, 4)

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

                    Divider().overlay(Theme.separator).padding(.vertical, 4)

                    // 电脑风险提醒（独立于文件清理的风险检查模块）
                    ToolRow(icon: "exclamationmark.shield", title: "风险提醒",
                            subtitle: app.riskScanned
                                ? (app.riskItems.isEmpty ? "检查通过，无风险项" : "\(app.totalRiskCount) 项风险")
                                : "检查敏感数据与系统风险",
                            isActive: app.destination == .riskCheck) {
                        withAnimation(.easeOut(duration: 0.15)) {
                            app.destination = .riskCheck
                        }
                    }

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

            // 统计条（已扫描 X/6 · 可清理 Y）
            statsLine
                .padding(.horizontal, Theme.contentPadding)
                .padding(.top, Theme.spaceXs)

            // 底部扫描全部
            Button(action: { app.scanAll() }) {
                Label("扫描全部分类", systemImage: "arrow.clockwise")
                    .font(Theme.bodyFont(14, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.actionBlue)
            .padding(.horizontal, Theme.contentPadding)
            .padding(.top, Theme.spaceSm)
            .padding(.bottom, Theme.contentPadding)
        }
    }

    /// 概览统计（Dashboard / 侧栏底部统计条共用）
    var statsLine: some View {
        HStack(spacing: 0) {
            Text("\(app.scannedCount)/\(CleanCategory.allCases.count)")
                .font(Theme.monoFont(11, weight: .medium))
                .foregroundColor(Theme.labelSecondary)
                .monospacedDigit()
            Text(" 已扫描")
                .font(Theme.bodyFont(11))
                .foregroundColor(Theme.labelTertiary)
            Spacer()
            Text(app.totalCleanable.byteStringCN)
                .font(Theme.monoFont(11, weight: .semibold))
                .foregroundColor(Theme.actionBlue)
                .monospacedDigit()
            Text(" 可清理")
                .font(Theme.bodyFont(11))
                .foregroundColor(Theme.labelTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                .fill(Color.primary.opacity(0.035))
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                        .stroke(Theme.separator.opacity(0.4), lineWidth: 0.5)
                )
        )
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
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(isActive ? Theme.actionBlue : Theme.labelSecondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isActive ? Theme.actionBlue.opacity(0.12) : Color.primary.opacity(0.04))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                        .font(Theme.bodyFont(13, weight: isActive ? .semibold : .regular))
                        .foregroundColor(isActive ? Theme.actionBlue : Theme.labelPrimary)
                    Text(subtitle)
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.labelTertiary)
                }
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                    .fill(isActive ? Theme.actionBlue.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("toolRow_\(title)")
    }
}

struct CategoryRow: View {
    let category: CleanCategory
    @ObservedObject var state: CategoryState
    var isActive: Bool = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: category.icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(category.accentColor)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(category.accentColor.opacity(0.14))
                )

            VStack(alignment: .leading, spacing: 1) {
                Text(category.title)
                    .font(Theme.bodyFont(13, weight: isActive ? .semibold : .regular))
                    .foregroundColor(isActive ? Theme.actionBlue : Theme.labelPrimary)
                Text(state.isScanned ? "已扫描 · \(state.items.count) 项" : "未扫描")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.labelTertiary)
                    .monospacedDigit()
            }
            Spacer()
            if state.isScanning {
                ProgressView()
                    .controlSize(.small)
            }
            if state.isScanned && state.totalSize > 0 && !state.isScanning {
                Text(state.totalSize.byteStringCN)
                    .font(Theme.monoFont(11, weight: .medium))
                    .foregroundColor(Theme.labelSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                .fill(isActive ? Theme.actionBlue.opacity(0.12) : Color.clear)
        )
    }
}

