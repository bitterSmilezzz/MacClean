import SwiftUI

/// 分类详情页：扫描结果列表 + 勾选 + 清理
struct CategoryDetailView: View {
    @EnvironmentObject private var app: AppState
    let category: CleanCategory

    @State private var showCleanSheet = false
    @State private var permanentMode = false
    @State private var filterQuery = ""

    private var st: CategoryState { app.state(for: category) }

    /// 过滤后的列表（支持名称/路径子串匹配，大小写不敏感）
    private var filteredItems: [CleanItem] {
        let q = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return st.items }
        return st.items.filter {
            $0.name.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || $0.path.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            // 扫描错误横幅（P4 健壮性：失败不静默）
            if let err = st.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textDanger)
                    Text(err)
                        .font(Theme.bodyFont(14, weight: .medium))
                        .foregroundColor(Theme.textDanger)
                    Spacer()
                    Button("重试") { app.scan(category) }
                        .buttonStyle(.borderless)
                        .font(Theme.bodyFont(14, weight: .medium))
                        .foregroundColor(Theme.actionBlue)
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.dangerRed.opacity(0.06))
            }

            if st.isScanning {
                scanningView
            } else if !st.isScanned {
                emptyView
            } else if st.items.isEmpty {
                emptyResultView
            } else if filteredItems.isEmpty {
                // 有扫描结果但过滤无匹配
                noFilterMatchView
            } else {
                itemList
            }

            footer
        }
        .background(Theme.parchment)
        .sheet(isPresented: $showCleanSheet) {
            // 过滤激活且有隐藏已选时，确认弹窗显示全量口径并附提示（二轮 #4）
            let filtering = !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let hiddenSelected = filtering ? max(0, st.selectedCount - filteredItems.filter(\.isSelected).count) : 0
            CleanConfirmSheet(
                count: st.selectedCount,
                size: st.selectedSize,
                hasPermanent: st.selectedItems.contains { $0.permanentDelete },
                hasDanger: st.selectedItems.contains { $0.risk == .danger },
                permanent: $permanentMode,
                hint: hiddenSelected > 0 ? "含隐藏已选 \(hiddenSelected) 项" : nil,
                recentlyUsedCount: st.selectedItems.filter { $0.usage.isRecentlyUsed }.count
            ) { permanent in
                app.cleanSelected(in: category, permanently: permanent)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.spaceMd) {
            Image(systemName: category.icon)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(Theme.actionBlue)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.actionBlue.opacity(0.1)))

            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(Theme.displayFont(28, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(Theme.ink)
                Text("\(category.subtitle) · 规则 \(category.ruleRef)")
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.inkMuted48)
            }
            Spacer()

            // 全选 / 反选（原生文字按钮；M5：过滤激活时只作用于可见项）
            // 三巡：过滤无匹配（filteredItems 空）时隐藏，避免空集 allSatisfy=true 误显示"取消全选"
            if st.isScanned && !st.items.isEmpty && !filteredItems.isEmpty {
                Button {
                    if filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        st.setAllSelected(!st.allSelected)
                    } else {
                        // 过滤中：仅切换可见项（filteredItems）的勾选
                        let target = !filteredItems.allSatisfy(\.isSelected)
                        for item in filteredItems {
                            st.setSelected(item.id, target)
                        }
                    }
                } label: {
                    Text(filteredItems.allSatisfy(\.isSelected) ? "取消全选" : "全选")
                }
                .buttonStyle(.borderless)
                .font(Theme.bodyFont(15, weight: .medium))
                .foregroundColor(Theme.actionBlue)
            }

            // 扫描 / 重新扫描（原生 bordered 按钮）
            Button {
                app.scan(category)
            } label: {
                Label(st.isScanned ? "重新扫描" : "扫描", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Theme.actionBlue)
            .accessibilityIdentifier("scanButton")
            .disabled(st.isScanning)

            // 列表内联过滤（仅过滤已扫描结果，不重新扫描）
            if st.isScanned && !st.items.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.inkMuted48)
                    TextField("过滤", text: $filterQuery)
                        .textFieldStyle(.plain)
                        .font(Theme.bodyFont(14))
                        .frame(width: 130)
                        .accessibilityIdentifier("filterField")
                    if !filterQuery.isEmpty {
                        Button { filterQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.inkMuted48)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSm)
                        .fill(Theme.pearl)
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusSm)
                                .stroke(Theme.hairline, lineWidth: 1)
                        )
                )
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Theme.spaceMd)
        .background(Theme.canvas)
    }

    // MARK: - 状态视图

    private var scanningView: some View {
        VStack(spacing: Theme.spaceMd) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.actionBlue)
            Text("正在扫描…")
                .font(Theme.bodyFont(14))
                .foregroundColor(Theme.inkMuted48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyView: some View {
        VStack(spacing: Theme.spaceMd) {
            Image(systemName: category.icon)
                .font(.system(size: 42, weight: .light))
                .foregroundColor(Theme.inkMuted48.opacity(0.6))
            Text("尚未扫描此分类")
                .font(Theme.displayFont(24, weight: .semibold))
                .foregroundColor(Theme.ink)
            Text("点击右上角「扫描」，将按固化规则 \(category.ruleRef) 发现可清理项")
                .font(Theme.bodyFont(13))
                .foregroundColor(Theme.inkMuted48)
            Button {
                app.scan(category)
            } label: {
                Label("开始扫描", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.actionBlue)
            .padding(.top, Theme.spaceXs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyResultView: some View {
        VStack(spacing: Theme.spaceSm) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(Theme.actionBlue.opacity(0.7))
            Text("没有发现可清理项")
                .font(Theme.displayFont(22, weight: .semibold))
                .foregroundColor(Theme.ink)
            Text("此分类很干净")
                .font(Theme.bodyFont(13))
                .foregroundColor(Theme.inkMuted48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noFilterMatchView: some View {
        VStack(spacing: Theme.spaceSm) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 36, weight: .light))
                .foregroundColor(Theme.inkMuted48.opacity(0.6))
            Text("没有与「\(filterQuery)」匹配的项")
                .font(Theme.displayFont(20, weight: .semibold))
                .foregroundColor(Theme.ink)
            Text("清除过滤条件查看全部 \(st.items.count) 项")
                .font(Theme.bodyFont(13))
                .foregroundColor(Theme.inkMuted48)
            Button("清除过滤") { filterQuery = "" }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(Theme.actionBlue)
                .padding(.top, Theme.spaceXs)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 结果列表（按风险分组，降低密度）

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: Theme.spaceLg) {
                // 按风险分组：可安全清理 / 需确认 / 不建议
                ForEach(RiskGroup.allCases, id: \.self) { group in
                    let groupItems = filteredItems.filter { $0.risk == group.risk }
                    if !groupItems.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.spaceSm) {
                            // 分组标题（eyebrow 模式：大写小字 + 宽字距 + mono 计数）
                            HStack(spacing: 8) {
                                Circle().fill(group.color).frame(width: 8, height: 8)
                                Text(group.title.uppercased())
                                    .font(Theme.bodyFont(12, weight: .semibold))
                                    .tracking(1.2)
                                    .foregroundColor(Theme.inkMuted80)
                                Text("\(groupItems.count) 项 · \(groupItems.reduce(Int64(0)) { $0 + $1.size }.byteStringCN)")
                                    .font(Theme.monoFont(12))
                                    .foregroundColor(Theme.inkMuted48)
                                Spacer()
                                // 组级快捷勾选（仍走 G2 确认弹窗，只是快捷方式）
                                Button(groupItems.allSatisfy(\.isSelected) ? "取消本组" : "勾选本组") {
                                    let target = !groupItems.allSatisfy(\.isSelected)
                                    for item in groupItems {
                                        st.setSelected(item.id, target)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .font(Theme.bodyFont(12, weight: .medium))
                                .foregroundColor(group == .danger ? Theme.inkMuted48 : Theme.actionBlue)
                                .disabled(group == .danger)   // 危险组不支持一键勾选（安全护栏）
                            }
                            .padding(.horizontal, 2)

                            ForEach(Array(groupItems.enumerated()), id: \.element.id) { _, item in
                                ItemRowView(
                                    item: item,
                                    isSelected: item.isSelected,
                                    onToggle: { selected in st.setSelected(item.id, selected) },
                                    onAskAI: { app.ai.askAbout(item: item) },
                                    isDisabled: app.ai.isLoading
                                )
                            }
                        }
                    }
                }
            }
            .padding(Theme.spaceLg)
        }
        .background(Theme.parchment)
    }

    /// 风险分组（G4 三档）
    private enum RiskGroup: CaseIterable {
        case safe, review, danger

        var risk: RiskLevel {
            switch self {
            case .safe: return .safe
            case .review: return .review
            case .danger: return .danger
            }
        }

        var title: String {
            switch self {
            case .safe: return "可安全清理"
            case .review: return "需确认"
            case .danger: return "不建议删除"
            }
        }

        var color: Color {
            switch self {
            case .safe: return Theme.actionBlue
            case .review: return Theme.warningOrange
            case .danger: return Theme.dangerRed
            }
        }
    }

    // MARK: - Footer（清理栏）

    private var footer: some View {
        // M5：过滤激活时统计口径切换为可见项，并提示隐藏已选
        let filtering = !filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let visibleSelected = filteredItems.filter(\.isSelected)
        let hiddenSelectedCount = st.selectedCount - visibleSelected.count
        let shownCount = filtering ? visibleSelected.count : st.selectedCount
        let shownSize = filtering ? visibleSelected.reduce(Int64(0)) { $0 + $1.size } : st.selectedSize

        return HStack(spacing: Theme.spaceMd) {
            if let summary = app.lastCleanSummary {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.actionBlue)
                    Text(summary)
                        .font(Theme.bodyFont(14, weight: .medium))
                        .foregroundColor(Theme.inkMuted80)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("已选 \(shownCount) 项" + (filtering && hiddenSelectedCount > 0 ? "（另有 \(hiddenSelectedCount) 项隐藏已选）" : ""))
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.inkMuted48)
                Text(shownSize.byteStringCN)
                    .font(Theme.displayFont(20, weight: .semibold))
                    .foregroundColor(Theme.ink)
            }

            // 清理（原生 macOS 主按钮）
            // 门槛用全量已选：过滤激活时隐藏已选也参与清理（三巡：可见=0 但隐藏>0 时按钮可点）
            Button {
                showCleanSheet = true
            } label: {
                Label("清理", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.actionBlue)
            .accessibilityIdentifier("cleanButton")
            .disabled(st.selectedCount == 0 || app.isCleaning)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Theme.spaceSm)
        .background(Theme.canvas.overlay(alignment: .top) {
            Divider().overlay(Theme.hairline)
        })
    }
}

/// 单个清理项行（默认紧凑：名称+大小+风险+使用频率；点击展开路径/备注）
struct ItemRowView: View {
    let item: CleanItem
    let isSelected: Bool
    let onToggle: (Bool) -> Void
    var onAskAI: (() -> Void)? = nil
    var isDisabled: Bool = false   // LOW-2：AI 请求在途时禁用行内 ✨

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.spaceSm) {
                // 勾选框
                Button(action: { onToggle(!isSelected) }) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 18))
                        .foregroundColor(isSelected ? Theme.actionBlue : Theme.hairline)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("itemToggle")

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(Theme.bodyFont(15, weight: .semibold))
                            .foregroundColor(Theme.ink)
                            .lineLimit(1)
                        RiskBadge(risk: item.risk)
                        // 使用频率徽标（用户诉求：最近是否在用/是否频繁，判断值不值得删）
                        UsageBadge(usage: item.usage)
                    }
                    // 展开后显示路径、使用情况与备注（密度优化：默认隐藏）
                    if isExpanded {
                        Text(item.path)
                            .font(Theme.bodyFont(12))
                            .foregroundColor(Theme.inkMuted48)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if let lastUsed = item.lastUsed {
                            Text("最近使用：\(Date.usageFormatter.string(from: lastUsed))（\(lastUsed.relativeUsage)）")
                                .font(Theme.bodyFont(12, weight: .medium))
                                .foregroundColor(item.usage.isRecentlyUsed ? Theme.textWarning : Theme.inkMuted48)
                        }
                        if !item.note.isEmpty {
                            Text(item.note)
                                .font(Theme.bodyFont(12))
                                .foregroundColor(Theme.inkMuted48.opacity(0.8))
                                .lineLimit(2)
                        }
                    }
                }
                Spacer()
                Text(item.size.byteStringCN)
                    .font(Theme.bodyFont(15, weight: .semibold))
                    .foregroundColor(Theme.ink)
                    .monospacedDigit()

                // 展开/收起路径备注
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.inkMuted48)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.parchment))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("itemExpandButton")
                .accessibilityLabel(isExpanded ? "收起路径" : "显示路径")
                .help(isExpanded ? "收起路径" : "显示路径")

                // 问 AI：针对该项提问（用途/能否删/是否在用）
                // LOW-2（终检）：请求在途时禁用，避免静默无效
                if let onAskAI {
                    Button(action: onAskAI) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.actionBlue)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Theme.actionBlue.opacity(isDisabled ? 0.05 : 0.12)))
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    .accessibilityIdentifier("askAIButton")
                    .accessibilityLabel("问 AI")
                    .help(isDisabled ? "AI 回复中，请稍候" : "问 AI：这个是什么？能删吗？")
                }
            }
            .padding(.horizontal, Theme.spaceMd)
            .padding(.vertical, Theme.spaceSm)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .fill(Theme.canvas)
                
        )
    }
}

/// 风险徽标（G4）
struct RiskBadge: View {
    let risk: RiskLevel

    // M7：文字用深色变体保证 WCAG AA；背景保留原色淡色
    private var color: Color {
        switch risk {
        case .safe: return Theme.actionBlue
        case .review: return Theme.textWarning
        case .danger: return Theme.textDanger
        }
    }

    private var bg: Color {
        switch risk {
        case .safe: return Theme.actionBlue
        case .review: return Theme.warningOrange
        case .danger: return Theme.dangerRed
        }
    }

    var body: some View {
        Text(risk.label)
            .font(Theme.bodyFont(12, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg.opacity(0.12)))
    }
}

/// 使用频率徽标（用户诉求：标注最近是否在用/是否频繁，辅助判断值不值得删）
struct UsageBadge: View {
    let usage: UsageLevel

    private var color: Color {
        switch usage {
        case .active: return Theme.textDanger       // 频繁使用中 → 警示
        case .recent: return Theme.textWarning      // 近期使用 → 提醒
        case .occasional: return Theme.textWarning.opacity(0.8)
        case .dormant: return Theme.inkMuted48      // 长期未用 → 中性
        case .unknown: return Theme.inkMuted48.opacity(0.7)
        }
    }

    private var bg: Color {
        switch usage {
        case .active: return Theme.dangerRed
        case .recent, .occasional: return Theme.warningOrange
        case .dormant, .unknown: return Theme.hairline
        }
    }

    var body: some View {
        Text(usage.label)
            .font(Theme.bodyFont(11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg.opacity(0.12)))
            .accessibilityLabel(usage.label)
    }
}
