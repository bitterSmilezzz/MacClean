import SwiftUI

/// 概览页。
///
/// 原版是「汇总条卡片 + 两张统计卡 + 六宫格等宽分类卡 + 风险卡 + 历史卡」——五层卡片叠在
/// 灰色底上，每张都带描边和阴影。等宽卡片网格是最典型的模板化仪表盘布局，六个分类被撑成
/// 六张一样大的卡片，信息密度极低。
///
/// 重写后：
///  - 一个视觉焦点：可清理总量。大字号、左对齐、旁边直接放主操作。
///  - 存储用量用一条横向容量条 + 图例，替代重复的圆环（圆环原本在侧栏和这里各画一遍）。
///  - 分类改成一张统一的列表：图标、名称、条目数、体积、占比条，一行一个。
///    表格式对齐比卡片网格信息密度高得多，也不需要六种颜色。
///  - 风险与历史降级为同一种分组容器，不再各自成卡。
struct DashboardView: View {
    @EnvironmentObject private var app: AppState
    @State private var showCleanSheet = false
    @State private var permanentMode = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.lg) {
                heroPanel

                if app.smartRecommendedCount > 0 {
                    smartRecommendationGroup
                }

                storageGroup
                categoryGroup

                if app.riskScanned || app.isRiskScanning {
                    riskGroup
                }

                if !app.history.isEmpty {
                    historyGroup
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.lg)
            .frame(maxWidth: 920, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Surface.window)
        .sheet(isPresented: $showCleanSheet) { cleanSheet }
    }

    private var selectedItemsAcrossCategories: [CleanItem] {
        app.categories.flatMap { $0.selectedItems }
    }

    private var cleanSheet: some View {
        let all = selectedItemsAcrossCategories
        return CleanConfirmSheet(
            count: all.count,
            size: all.reduce(Int64(0)) { $0 + $1.size },
            hasPermanent: all.contains { $0.permanentDelete },
            hasDanger: all.contains { $0.recommendation.kind == .keep },
            permanent: $permanentMode,
            recentlyUsedCount: all.filter { $0.usage.isRecentlyUsed }.count
        ) { permanent in
            app.cleanSelectedAcrossCategories(permanently: permanent)
        }
    }

    // MARK: - 焦点区

    private var heroPanel: some View {
        HStack(alignment: .center, spacing: Space.lg) {
            VStack(alignment: .leading, spacing: 2) {
                Text("可清理")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.secondary)

                Text(app.totalCleanable.byteStringCN)
                    .font(Typo.hero)
                    .monospacedDigit()
                    .foregroundStyle(app.totalCleanable > 0 ? Ink.primary : Ink.tertiary)
                    .motionSafeNumericTransition()

                Text(scanStatusText)
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .monospacedDigit()
                    .motionSafeNumericTransition()

                incompleteScanNotice

                // 可清理项的构成。这行是安全相关的：用户动手前应当知道待清理总量里
                // 有多少是"直接可清"、多少正在被使用、多少需要先看一眼。
                if app.totalCleanable > 0 {
                    HStack(spacing: Space.sm) {
                        verdictChip("可清理", app.verdictTotals[.safe, default: 0], Signal.tint(for: .safe))
                        verdictChip("使用中", app.verdictTotals[.inUse, default: 0], Signal.tint(for: .inUse))
                        verdictChip("需确认", app.verdictTotals[.review, default: 0], Signal.tint(for: .review))
                        verdictChip("不建议删除", app.verdictTotals[.keep, default: 0], Signal.tint(for: .keep))
                    }
                    .padding(.top, Space.xxs)
                }
            }

            Spacer(minLength: Space.md)

            VStack(alignment: .trailing, spacing: Space.xs) {
                Button {
                    showCleanSheet = true
                } label: {
                    Label(app.totalSelectedCount > 0 ? "清理已选 \(app.totalSelectedCount) 项" : "清理已选项",
                          systemImage: "trash")
                        .font(Typo.rowStrong)
                        .frame(minWidth: 124)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(app.totalSelectedCount == 0 || app.isCleaning)
                .accessibilityIdentifier("dashboardCleanButton")

                Button {
                    app.scanAll()
                } label: {
                    HStack(spacing: 6) {
                        if app.isScanningAll {
                            ProgressView()
                                .controlSize(.small)
                                .progressViewStyle(.circular)
                        }
                        Label(app.isScanningAll ? "扫描中…"
                              : app.scannedCount > 0 ? "重新扫描全部" : "扫描全部分类",
                              systemImage: "arrow.clockwise")
                    }
                    .font(Typo.row)
                    .frame(minWidth: 124)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(app.isScanningAll || app.categories.contains { $0.isScanning })

                Button {
                    app.aiReview.review(items: app.categories.flatMap { $0.items })
                } label: {
                    HStack(spacing: 6) {
                        if app.aiReview.isReviewing {
                            ProgressView().controlSize(.small)
                            Text("AI 筛查中")
                        } else {
                            Image(systemName: "checkmark.seal")
                            Text("AI 再筛查")
                        }
                    }
                    .font(Typo.row)
                    .frame(minWidth: 124)
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .foregroundStyle(Accent.tint)
                .disabled(app.aiReview.isReviewing || app.searchableItems.isEmpty)
                .help("用 AI 对全部已扫描结果逐项二次判断：可删 / 谨慎 / 不建议删")
                .accessibilityLabel("用 AI 对全部已扫描结果逐项二次判断：可删 / 谨慎 / 不建议删")
            }
        }
        .padding(Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous)
                .fill(Accent.softer)
        )
    }

    /// 结论构成的小标签：色点 + 名称 + 数值。中性档不着色，避免满屏都是颜色。
    private func verdictChip(_ label: String, _ bytes: Int64, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)
            Text(bytes.byteStringCN)
                .font(.mcNumeric(11))
                .foregroundStyle(color == Signal.tint(for: .safe) ? Ink.secondary : color)
                .motionSafeNumericTransition()
        }
    }

    /// 扫描完整度提示。非空即代表"总数被低估了"——必须说出来，
    /// 否则用户会以为 0 KB 就是真的没东西可清。
    @ViewBuilder
    private var incompleteScanNotice: some View {
        let issues = app.allScanIssues
        if !issues.isEmpty {
            HStack(spacing: 6) {
                Image(systemName: "lock.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Signal.caution)
                Text("\(issues.count) 个位置因权限无法读取，实际可清理量可能更高")
                    .font(Typo.caption)
                    .foregroundColor(Ink.secondary)
                Text("查看")
                    .font(Typo.caption)
                    .foregroundColor(Accent.tint)
            }
            .padding(.top, Space.xxs)
        }
    }

    private var scanStatusText: String {
        if app.isScanningAll {
            let done = Int(app.scanProgress * Double(CleanCategory.allCases.count))
            return "正在并发扫描… \(done)/\(CleanCategory.allCases.count)"
        }
        if app.categories.contains(where: { $0.isScanning }) {
            return "正在扫描…"
        }
        if app.scannedCount == 0 {
            return "尚未扫描。先扫描一次看看能释放多少空间。"
        }
        if let dur = app.lastScanDuration {
            let base = "\(app.scannedCount)/\(CleanCategory.allCases.count) 个分类已扫描 · 用时 \(String(format: "%.1f", dur)) 秒"
            if app.incrementalHits > 0 {
                return "\(base) · 增量命中 \(app.incrementalHits) 项"
            }
            return base
        }
        return "\(app.scannedCount)/\(CleanCategory.allCases.count) 个分类已扫描"
    }

    // MARK: - 智能推荐精选

    private var smartRecommendationGroup: some View {
        GroupBox(title: "智能精选推荐") {
            HStack(spacing: Space.md) {
                IconSlot(systemName: "sparkles", size: 14, color: Accent.tint, width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: Space.xs) {
                        Text("\(app.smartRecommendedCount) 项高价值无损数据建议优先清理")
                            .font(Typo.rowStrong)
                            .foregroundStyle(Ink.primary)
                        Text("预计释放 \(app.smartRecommendedBytes.byteStringCN)")
                            .font(.mcNumeric(12, weight: .semibold))
                            .foregroundStyle(Accent.tint)
                    }
                    Text("基于文件本质安全性、长期闲置天数和空间释放收益综合加权评估")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.secondary)
                }

                Spacer(minLength: Space.sm)

                let isAllSmartSelected = !app.smartRecommendedItems.isEmpty && app.smartRecommendedItems.allSatisfy(\.isSelected)

                HStack(spacing: Space.xs) {
                    Button {
                        if isAllSmartSelected {
                            app.clearAllSelections()
                        } else {
                            app.selectSmartRecommendations()
                        }
                    } label: {
                        Text(isAllSmartSelected ? "取消推荐勾选" : "勾选推荐项")
                            .font(Typo.row)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button {
                        app.selectSmartRecommendations()
                        showCleanSheet = true
                    } label: {
                        Label("清理推荐", systemImage: "trash")
                            .font(Typo.rowStrong)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(app.isCleaning)
                }
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 8)
        }
    }

    // MARK: - 存储

    private var storageGroup: some View {
        let reclaimableRatio = app.diskTotal > 0 ? Double(app.totalCleanable) / Double(app.diskTotal) : 0

        return GroupBox(title: "存储") {
            VStack(alignment: .leading, spacing: Space.sm) {
                CapacityBar(used: app.usedRatio, reclaimable: reclaimableRatio,
                            height: 10, isCritical: app.usedRatio > 0.88)

                HStack(alignment: .top, spacing: Space.lg) {
                    LegendItem(color: Accent.tint, label: "已用",
                               value: app.diskUsed.byteStringCN)
                    LegendItem(color: Signal.positive, label: "其中可清理",
                               value: app.totalCleanable.byteStringCN, emphasized: app.totalCleanable > 0)
                    LegendItem(color: Surface.hairline, label: "可用",
                               value: app.diskAvailable.byteStringCN)
                }
                .padding(.top, 2)
            }
            .padding(Space.sm)
        }
    }

    // MARK: - 分类

    private var categoryGroup: some View {
        let total = max(1, app.totalCleanable)

        return GroupBox(title: "分类") {
            ForEach(Array(CleanCategory.allCases.enumerated()), id: \.element) { idx, cat in
                let st = app.state(for: cat)
                CategoryTableRow(
                    category: cat,
                    state: st,
                    share: st.isScanned ? Double(st.totalSize) / Double(total) : 0,
                    isLast: idx == CleanCategory.allCases.count - 1
                ) {
                    withAnimation(Motion.micro) { app.destination = .category(cat) }
                }
                .accessibilityIdentifier("dashboardCategory_\(cat.rawValue)")
            }
        }
    }

    // MARK: - 风险

    private var riskGroup: some View {
        GroupBox(title: "风险") {
            Button {
                withAnimation(Motion.micro) { app.destination = .riskCheck }
            } label: {
                HStack(spacing: Space.sm) {
                    IconSlot(
                        systemName: riskIcon,
                        size: 14,
                        weight: .medium,
                        color: app.riskItems.isEmpty ? Ink.tertiary : Signal.caution,
                        width: 18
                    )

                    VStack(alignment: .leading, spacing: 1) {
                        Text(riskTitle)
                            .font(Typo.rowStrong)
                            .foregroundStyle(Ink.primary)
                        Text(riskSubtitle)
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                    }

                    Spacer(minLength: Space.sm)

                    if app.isRiskScanning {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Ink.quaternary)
                    }
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .rowHover()
            .padding(.horizontal, Space.xxs)
            .padding(.vertical, Space.xxs)
        }
    }

    private var riskIcon: String {
        if app.isRiskScanning { return "stethoscope" }
        if !app.riskScanned { return "shield" }
        return app.riskItems.isEmpty ? "checkmark.shield" : "exclamationmark.shield"
    }

    private var riskTitle: String {
        if app.isRiskScanning { return "正在检查…" }
        if app.riskItems.isEmpty { return "未发现风险项" }
        return "发现 \(app.totalRiskCount) 项风险"
    }

    private var riskSubtitle: String {
        if app.riskItems.isEmpty {
            return "敏感文件权限、明文密钥、可疑启动项"
        }
        return "高 \(app.riskCounts[.high, default: 0]) · 中 \(app.riskCounts[.medium, default: 0]) · 低 \(app.riskCounts[.low, default: 0])"
    }

    // MARK: - 历史

    private var historyGroup: some View {
        GroupBox(title: "最近清理") {
            ForEach(Array(app.history.prefix(3).enumerated()), id: \.element.id) { idx, record in
                HistoryRow(record: record)
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 7)

                if idx < min(3, app.history.count) - 1 {
                    Hairline(inset: Space.sm)
                }
            }

            Hairline(inset: Space.sm)
            Button {
                withAnimation(Motion.micro) { app.destination = .history }
            } label: {
                HStack {
                    Text("查看全部 \(app.history.count) 条记录")
                        .font(Typo.caption)
                        .foregroundStyle(Accent.tint)
                    Spacer()
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: - 分类表格行
//
// 一行一个分类：图标、名称、条目数、体积、占比条。表格式对齐，密度远高于等宽卡片网格。

private struct CategoryTableRow: View {
    let category: CleanCategory
    @ObservedObject var state: CategoryState
    let share: Double
    let isLast: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.sm) {
                IconSlot(systemName: category.icon, size: 13, color: Ink.secondary, width: 18)

                Text(category.title)
                    .font(Typo.row)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(detailText)
                    .font(.mcNumeric(11))
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 78, alignment: .trailing)
                    .motionSafeNumericTransition()

                Text(sizeText)
                    .font(.mcNumeric(12, weight: state.isScanned && state.totalSize > 0 ? .medium : .regular))
                    .foregroundStyle(state.isScanned && state.totalSize > 0 ? Ink.primary : Ink.quaternary)
                    .frame(width: 72, alignment: .trailing)
                    .motionSafeNumericTransition()

                // 占比条：把"这个分类占可清理总量的多少"变成可比的视觉量
                ZStack(alignment: .leading) {
                    Capsule().fill(Surface.hairline.opacity(0.28))
                    Capsule()
                        .fill(Accent.tint.opacity(0.75))
                        .frame(width: max(0, 64 * min(share, 1)))
                }
                .frame(width: 64, height: 4)
                .opacity(state.isScanned && state.totalSize > 0 ? 1 : 0)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Ink.quaternary)
                    .frame(width: 8)
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .rowHover()
        .padding(.horizontal, Space.xxs)
        .overlay(alignment: .bottom) {
            if !isLast { Hairline(inset: Space.md) }
        }
    }

    private var detailText: String {
        if state.isScanning { return "扫描中" }
        if !state.isScanned { return "未扫描" }
        return "\(state.items.count) 项"
    }

    private var sizeText: String {
        state.isScanned && state.totalSize > 0 ? state.totalSize.byteStringCN : "—"
    }
}
