import SwiftUI

/// 分类详情页：扫描结果列表 + 勾选 + 清理
struct CategoryDetailView: View {
    @EnvironmentObject private var app: AppState
    let category: CleanCategory

    @State private var showCleanSheet = false
    @State private var permanentMode = false
    @State private var filterQuery = ""
    @State private var showHud = false
    @State private var hudMessage = ""

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
                .background(Theme.dangerRed.opacity(0.12))
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            // AI 再筛查状态横幅（进度 / 错误 / 完成摘要）
            if app.aiReview.isReviewing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small).tint(Theme.actionBlue)
                    Text(app.aiReview.progressText ?? "AI 筛查中…")
                        .font(Theme.bodyFont(13, weight: .medium))
                        .foregroundColor(Theme.inkMuted80)
                    Spacer()
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.actionBlue.opacity(0.10))
                .transition(.move(edge: .top).combined(with: .opacity))
            } else if let reviewError = app.aiReview.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textWarning)
                    Text("AI 筛查失败：\(reviewError)")
                        .font(Theme.bodyFont(13, weight: .medium))
                        .foregroundColor(Theme.textWarning)
                    Spacer()
                    Button("重试") { app.aiReview.review(items: st.items) }
                        .buttonStyle(.borderless)
                        .font(Theme.bodyFont(13, weight: .medium))
                        .foregroundColor(Theme.actionBlue)
                        .disabled(st.items.isEmpty)
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.warningOrange.opacity(0.12))
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                let reviewSummary = app.aiReview.summary(for: st.items)
                if !reviewSummary.isEmpty {
                    HStack(spacing: 8) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12))
                            .foregroundColor(Theme.actionBlue)
                        Text("AI 再筛查：\(reviewSummary)")
                            .font(Theme.bodyFont(13, weight: .medium))
                            .foregroundColor(Theme.inkMuted80)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.contentPadding)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.actionBlue.opacity(0.10))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }

            Group {
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
            }
            .transition(.opacity)
            .animation(Theme.smoothTransition, value: st.isScanning)

            footer
        }
        .background(Theme.windowBackground)
        .onChange(of: app.lastCleanSummary) { summary in
            if let summary, !summary.isEmpty {
                hudMessage = summary
                showHud = true
            }
        }
        .hudToast(isPresented: $showHud, text: hudMessage)
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
                .symbolRenderingMode(.hierarchical)
                .foregroundColor(category.accentColor)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: Theme.radiusMd, style: .continuous).fill(category.accentColor.opacity(0.14)))

            VStack(alignment: .leading, spacing: 2) {
                Text(category.title)
                    .font(Theme.displayFont(26, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(Theme.labelPrimary)
                Text("\(category.subtitle) · 规则 \(category.ruleRef)")
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.labelSecondary)
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
                .font(Theme.bodyFont(14, weight: .medium))
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
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityIdentifier("scanButton")
            .disabled(st.isScanning)

            // AI 再筛查（AI 扫描）：脚本扫描之外，用 AI 逐项二次判断值不值得删
            if st.isScanned && !st.items.isEmpty {
                Button {
                    app.aiReview.review(items: st.items)
                } label: {
                    if app.aiReview.isReviewing {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small).tint(Theme.actionBlue)
                            Text("AI 筛查中…")
                                .font(Theme.bodyFont(13, weight: .medium))
                        }
                    } else {
                        Label("AI 再筛查", systemImage: "sparkles.rectangle.stack")
                            .font(Theme.bodyFont(13, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(Theme.actionBlue)
                .accessibilityIdentifier("aiReviewButton")
                .disabled(app.aiReview.isReviewing || st.isScanning)
                .help("用 AI 对已扫描结果逐项二次判断：可删 / 谨慎 / 不建议删")
            }

            // 列表内联过滤（仅过滤已扫描结果，不重新扫描）
            if st.isScanned && !st.items.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.labelSecondary)
                    TextField("过滤", text: $filterQuery)
                        .textFieldStyle(.plain)
                        .font(Theme.bodyFont(13))
                        .frame(width: 130)
                        .accessibilityIdentifier("filterField")
                    if !filterQuery.isEmpty {
                        Button { filterQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 13))
                                .foregroundColor(Theme.labelTertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                        .overlay(
                            RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                                .stroke(Theme.separator, lineWidth: 0.5)
                        )
                )
            }
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Theme.spaceMd)
        .frostedBar()
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

    // MARK: - 结果列表（按风险分组，macOS 原生 Grouped List 规范）

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: Theme.spaceLg) {
                // 按风险分组：可安全清理 / 需确认 / 不建议
                ForEach(RiskGroup.allCases, id: \.self) { group in
                    let groupItems = filteredItems.filter { $0.risk == group.risk }
                    if !groupItems.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            // 分组标题
                            HStack(spacing: 8) {
                                Circle().fill(group.color).frame(width: 7, height: 7)
                                Text(group.title)
                                    .font(Theme.bodyFont(12, weight: .semibold))
                                    .foregroundColor(Theme.labelSecondary)
                                Text("\(groupItems.count) 项 · \(groupItems.reduce(Int64(0)) { $0 + $1.size }.byteStringCN)")
                                    .font(Theme.monoFont(11))
                                    .foregroundColor(Theme.labelTertiary)
                                    .monospacedDigit()
                                Spacer()
                                // 组级快捷勾选
                                Button(groupItems.allSatisfy(\.isSelected) ? "取消本组" : "勾选本组") {
                                    let target = !groupItems.allSatisfy(\.isSelected)
                                    for item in groupItems {
                                        st.setSelected(item.id, target)
                                    }
                                }
                                .buttonStyle(.borderless)
                                .font(Theme.bodyFont(11, weight: .medium))
                                .foregroundColor(group == .danger ? Theme.labelTertiary : Theme.actionBlue)
                                .disabled(group == .danger)   // 危险组不支持一键勾选（安全护栏）
                            }
                            .padding(.horizontal, 4)

                            // 原生分组容器（组内各行由精细分割线隔开）
                            VStack(spacing: 0) {
                                ForEach(Array(groupItems.enumerated()), id: \.element.id) { index, item in
                                    if index > 0 {
                                        Divider()
                                            .overlay(Theme.separator.opacity(0.35))
                                            .padding(.leading, 38)
                                    }
                                    ItemRowView(
                                        item: item,
                                        isSelected: item.isSelected,
                                        onToggle: { selected in st.setSelected(item.id, selected) },
                                        onAskAI: { app.ai.askAbout(item: item) },
                                        isDisabled: app.ai.isLoading,
                                        aiReview: app.aiReview.review(for: item)
                                    )
                                }
                            }
                            .macCard(cornerRadius: Theme.radiusMd)
                        }
                    }
                }
            }
            .padding(Theme.spaceMd)
        }
        .background(Theme.windowBackground)
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
                        .font(Theme.bodyFont(13, weight: .medium))
                        .foregroundColor(Theme.labelPrimary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 1) {
                Text("已选 \(shownCount) 项" + (filtering && hiddenSelectedCount > 0 ? "（另有 \(hiddenSelectedCount) 项隐藏已选）" : ""))
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.labelTertiary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                Text(shownSize.byteStringCN)
                    .font(Theme.displayFont(18, weight: .semibold))
                    .foregroundColor(Theme.labelPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }

            // 清理（原生 macOS 主按钮）
            Button {
                showCleanSheet = true
            } label: {
                Label("清理", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.actionBlue)
            .keyboardShortcut(.delete, modifiers: .command)
            .accessibilityIdentifier("cleanButton")
            .disabled(st.selectedCount == 0 || app.isCleaning)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 10)
        .frostedBar()
        .overlay(alignment: .top) {
            Divider().overlay(Theme.separator)
        }
    }
}

/// 单个清理项行（macOS 原生数据行：整洁、紧凑、支持行悬停）
struct ItemRowView: View {
    let item: CleanItem
    let isSelected: Bool
    let onToggle: (Bool) -> Void
    var onAskAI: (() -> Void)? = nil
    var isDisabled: Bool = false   // LOW-2：AI 请求在途时禁用行内 ✨
    /// AI 再筛查结论（无则 nil）
    var aiReview: ItemReview? = nil

    @State private var isExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // 勾选框
                Button(action: { onToggle(!isSelected) }) {
                    Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 15))
                        .foregroundColor(isSelected ? Theme.actionBlue : Theme.labelTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("itemToggle")
                .accessibilityLabel(isSelected ? "已勾选" : "未勾选")

                // 名称 + 风险/使用/AI 标签
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .font(Theme.bodyFont(13, weight: .medium))
                            .foregroundColor(Theme.labelPrimary)
                            .lineLimit(1)
                        RiskBadge(risk: item.risk)
                        UsageBadge(usage: item.usage)
                        if let aiReview {
                            ReviewBadge(verdict: aiReview.verdict)
                        }
                    }

                    // 展开后显示路径、使用情况、AI 理由与备注
                    if isExpanded {
                        Text(item.path)
                            .font(Theme.monoFont(11))
                            .foregroundColor(Theme.labelTertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        if let lastUsed = item.lastUsed {
                            Text("最近使用：\(Date.usageFormatter.string(from: lastUsed))（\(lastUsed.relativeUsage)）")
                                .font(Theme.bodyFont(11))
                                .foregroundColor(item.usage.isRecentlyUsed ? Theme.textWarning : Theme.labelTertiary)
                        }
                        if let aiReview, !aiReview.reason.isEmpty {
                            Text("AI 建议：\(aiReview.reason)")
                                .font(Theme.bodyFont(11, weight: .medium))
                                .foregroundColor(aiReview.verdict == .keep ? Theme.textDanger
                                                : aiReview.verdict == .caution ? Theme.textWarning
                                                : Theme.actionBlue)
                                .lineLimit(2)
                        }
                        if !item.note.isEmpty {
                            Text(item.note)
                                .font(Theme.bodyFont(11))
                                .foregroundColor(Theme.labelTertiary.opacity(0.8))
                                .lineLimit(2)
                        }
                    }
                }
                Spacer()
                Text(item.size.byteStringCN)
                    .font(Theme.monoFont(12, weight: .medium))
                    .foregroundColor(Theme.labelPrimary)
                    .monospacedDigit()

                // 展开/收起路径备注（平滑旋转动效）
                Button {
                    withAnimation(Theme.fastTransition) { isExpanded.toggle() }
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Theme.labelTertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("itemExpandButton")
                .accessibilityLabel(isExpanded ? "收起路径" : "显示路径")
                .help(isExpanded ? "收起路径" : "显示路径")

                // 问 AI：针对该项提问
                if let onAskAI {
                    Button(action: onAskAI) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(Theme.actionBlue)
                            .frame(width: 22, height: 22)
                            .background(
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .fill(Theme.actionBlue.opacity(isDisabled ? 0.04 : 0.1))
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(isDisabled)
                    .accessibilityIdentifier("askAIButton")
                    .accessibilityLabel("问 AI")
                    .help(isDisabled ? "AI 回复中，请稍候" : "问 AI：这个是什么？能删吗？")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .macRowHover(cornerRadius: 0)
            .contextMenu {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(item.path, forType: .string)
                } label: {
                    Label("拷贝路径", systemImage: "doc.on.doc")
                }

                Divider()

                Button {
                    onToggle(!isSelected)
                } label: {
                    Label(isSelected ? "取消勾选" : "勾选", systemImage: isSelected ? "square" : "checkmark.square")
                }
            }
        }
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

/// AI 再筛查结论徽标（AI 扫描：可删/谨慎/不建议删）
struct ReviewBadge: View {
    let verdict: ReviewVerdict

    private var color: Color {
        switch verdict {
        case .delete: return Theme.actionBlue
        case .caution: return Theme.textWarning
        case .keep: return Theme.textDanger
        case .unknown: return Theme.inkMuted48
        }
    }

    private var bg: Color {
        switch verdict {
        case .delete: return Theme.actionBlue
        case .caution: return Theme.warningOrange
        case .keep: return Theme.dangerRed
        case .unknown: return Theme.hairline
        }
    }

    var body: some View {
        Text("AI·\(verdict.label)")
            .font(Theme.bodyFont(11, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg.opacity(0.12)))
            .accessibilityLabel("AI 结论：\(verdict.label)")
    }
}
