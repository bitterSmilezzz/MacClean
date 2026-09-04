import SwiftUI

/// 概览仪表页（融合 PureMac/Pearcleaner 的 Smart Care 思想）：
/// 磁盘总览 + 可清理汇总 + 风险分布 + 分类快捷卡片 + 最近历史
struct DashboardView: View {
    @EnvironmentObject private var app: AppState
    @State private var showCleanSheet = false
    @State private var permanentMode = false

    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spaceLg) {
                // 顶部汇总条：可清理总量 + 已选 + 全扫/清理 CTA
                summaryBar

                // 磁盘 + 风险分布双卡
                HStack(alignment: .top, spacing: Theme.spaceLg) {
                    diskCard
                    riskCard
                }

                // 分类快捷卡片网格
                VStack(alignment: .leading, spacing: Theme.spaceSm) {
                    Text("清理分类")
                        .font(Theme.bodyFont(12, weight: .semibold))
                        .tracking(1.2)
                        .foregroundColor(Theme.inkMuted80)
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(CleanCategory.allCases) { cat in
                            DashboardCategoryCard(category: cat)
                        }
                    }
                }

                // 最近历史
                if !app.history.isEmpty {
                    recentHistory
                }
            }
            .padding(Theme.spaceLg)
        }
        .background(Theme.parchment)
        // UI 审查 M1：跨分类清理必须走与详情页一致的确认弹窗（permanentDelete/danger 项需显式警告）
        .sheet(isPresented: $showCleanSheet) {
            cleanSheet
        }
    }

    /// 跨分类勾选项（确认弹窗统计用）
    private var selectedItemsAcrossCategories: [CleanItem] {
        app.categories.flatMap { $0.selectedItems }
    }

    private var cleanSheet: some View {
        let all = selectedItemsAcrossCategories
        return CleanConfirmSheet(
            count: all.count,
            size: all.reduce(Int64(0)) { $0 + $1.size },
            hasPermanent: all.contains { $0.permanentDelete },
            hasDanger: all.contains { $0.risk == .danger },
            permanent: $permanentMode,
            recentlyUsedCount: all.filter { $0.usage.isRecentlyUsed }.count
        ) { permanent in
            app.cleanSelectedAcrossCategories(permanently: permanent)
        }
    }

    // MARK: - 汇总条

    private var summaryBar: some View {
        HStack(spacing: Theme.spaceMd) {
            VStack(alignment: .leading, spacing: 2) {
                Text("可清理总量")
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.inkMuted48)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(app.totalCleanable.byteStringCN)
                        .font(Theme.displayFont(34, weight: .bold))
                        .tracking(-0.5)
                        .foregroundColor(Theme.ink)
                    Text("\(app.scannedCount)/\(CleanCategory.allCases.count) 分类已扫")
                        .font(Theme.monoFont(12))
                        .foregroundColor(Theme.inkMuted48)
                }
            }
            Spacer()

            Button {
                app.scanAll()
            } label: {
                Label(app.scannedCount > 0 ? "重新扫描全部" : "扫描全部", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Theme.actionBlue)
            .disabled(app.categories.contains { $0.isScanning })

            Button {
                showCleanSheet = true
            } label: {
                Label("清理已选 \(app.totalSelectedCount)", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.actionBlue)
            .disabled(app.totalSelectedCount == 0 || app.isCleaning)
            .accessibilityIdentifier("dashboardCleanButton")
        }
        .padding(Theme.spaceMd)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusLg)
                .fill(Theme.canvas)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusLg)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        )
    }

    // MARK: - 磁盘卡

    private var diskCard: some View {
        VStack(alignment: .leading, spacing: Theme.spaceSm) {
            Text("磁盘空间")
                .font(Theme.bodyFont(12, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(Theme.inkMuted80)

            HStack(spacing: Theme.spaceMd) {
                ZStack {
                    Circle()
                        .stroke(Theme.hairline, lineWidth: 12)
                    Circle()
                        .trim(from: 0, to: max(0.02, app.usedRatio))
                        .stroke(
                            app.usedRatio > 0.9 ? Theme.dangerRed : Theme.actionBlue,
                            style: StrokeStyle(lineWidth: 12, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .animation(.easeOut(duration: 0.6), value: app.usedRatio)
                    VStack(spacing: 2) {
                        Text(app.diskUsed.byteStringCN)
                            .font(Theme.displayFont(24, weight: .bold))
                            .tracking(-0.3)
                            .foregroundColor(Theme.ink)
                        Text("已用")
                            .font(Theme.bodyFont(11))
                            .foregroundColor(Theme.inkMuted48)
                    }
                }
                .frame(width: 120, height: 120)

                VStack(alignment: .leading, spacing: 6) {
                    statRow("总容量", app.diskTotal.byteStringCN)
                    statRow("已用", app.diskUsed.byteStringCN)
                    statRow("可用", app.diskAvailable.byteStringCN)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spaceMd)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusLg)
                .fill(Theme.canvas)
        )
    }

    private func statRow(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Theme.bodyFont(12))
                .foregroundColor(Theme.inkMuted48)
                .frame(width: 48, alignment: .leading)
            Text(value)
                .font(Theme.monoFont(13, weight: .semibold))
                .foregroundColor(Theme.ink)
        }
    }

    // MARK: - 风险分布卡

    private var riskCard: some View {
        let totals = app.riskTotals
        let total = max(1, app.totalCleanable)

        return VStack(alignment: .leading, spacing: Theme.spaceSm) {
            Text("风险分布")
                .font(Theme.bodyFont(12, weight: .semibold))
                .tracking(1.2)
                .foregroundColor(Theme.inkMuted80)

            // 堆叠条
            HStack(spacing: 2) {
                if totals[.safe, default: 0] > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.actionBlue)
                        .frame(width: max(4, CGFloat(totals[.safe, default: 0]) / CGFloat(total) * 260))
                }
                if totals[.review, default: 0] > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.warningOrange)
                        .frame(width: max(4, CGFloat(totals[.review, default: 0]) / CGFloat(total) * 260))
                }
                if totals[.danger, default: 0] > 0 {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Theme.dangerRed)
                        .frame(width: max(4, CGFloat(totals[.danger, default: 0]) / CGFloat(total) * 260))
                }
            }
            .frame(height: 8, alignment: .leading)
            .animation(.easeOut(duration: 0.4), value: app.totalCleanable)

            VStack(spacing: 6) {
                riskRow("可安全清理", totals[.safe, default: 0], Theme.actionBlue)
                riskRow("需确认", totals[.review, default: 0], Theme.warningOrange)
                riskRow("不建议删除", totals[.danger, default: 0], Theme.dangerRed)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.spaceMd)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusLg)
                .fill(Theme.canvas)
        )
    }

    private func riskRow(_ label: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(Theme.bodyFont(13))
                .foregroundColor(Theme.inkMuted80)
            Spacer()
            Text(bytes.byteStringCN)
                .font(Theme.monoFont(13, weight: .semibold))
                .foregroundColor(Theme.ink)
        }
    }

    // MARK: - 最近历史

    private var recentHistory: some View {
        VStack(alignment: .leading, spacing: Theme.spaceSm) {
            HStack {
                Text("最近清理")
                    .font(Theme.bodyFont(12, weight: .semibold))
                    .tracking(1.2)
                    .foregroundColor(Theme.inkMuted80)
                Spacer()
                Button("查看全部 →") { app.destination = .history }
                    .buttonStyle(.borderless)
                    .font(Theme.bodyFont(13, weight: .medium))
                    .foregroundColor(Theme.actionBlue)
            }
            ForEach(app.history.prefix(3)) { record in
                HistoryRow(record: record)
            }
        }
    }
}

// MARK: - 分类快捷卡片

struct DashboardCategoryCard: View {
    @EnvironmentObject private var app: AppState
    let category: CleanCategory

    private var st: CategoryState { app.state(for: category) }

    var body: some View {
        Button {
            app.destination = .category(category)
        } label: {
            HStack(spacing: Theme.spaceSm) {
                Image(systemName: category.icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.actionBlue)
                    .frame(width: 32, height: 32)
                    .background(RoundedRectangle(cornerRadius: Theme.radiusSm).fill(Theme.actionBlue.opacity(0.1)))

                VStack(alignment: .leading, spacing: 2) {
                    Text(category.title)
                        .font(Theme.bodyFont(14, weight: .semibold))
                        .foregroundColor(Theme.ink)
                    Text(st.isScanned ? "\(st.items.count) 项 · \(st.totalSize.byteStringCN)" : "未扫描")
                        .font(Theme.bodyFont(11))
                        .foregroundColor(st.isScanned ? Theme.inkMuted80 : Theme.inkMuted48)
                }
                Spacer()
                if st.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.inkMuted48.opacity(0.7))
                }
            }
            .padding(.horizontal, Theme.spaceSm)
            .padding(.vertical, Theme.spaceXs)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Theme.radiusMd)
                    .fill(Theme.canvas)
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radiusMd)
                            .stroke(Theme.hairline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("dashboardCategory_\(category.rawValue)")
    }
}
