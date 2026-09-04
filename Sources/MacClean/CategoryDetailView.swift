import SwiftUI

/// 分类详情页：扫描结果列表 + 勾选 + 清理
struct CategoryDetailView: View {
    @EnvironmentObject private var app: AppState
    let category: CleanCategory

    @State private var showCleanSheet = false
    @State private var permanentMode = false

    private var st: CategoryState { app.state(for: category) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            // 扫描错误横幅（P4 健壮性：失败不静默）
            if let err = st.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.dangerRed)
                    Text(err)
                        .font(Theme.bodyFont(12, weight: .medium))
                        .foregroundColor(Theme.dangerRed)
                    Spacer()
                    Button("重试") { app.scan(category) }
                        .buttonStyle(.borderless)
                        .font(Theme.bodyFont(12, weight: .medium))
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
            } else {
                itemList
            }

            footer
        }
        .background(Theme.parchment)
        .sheet(isPresented: $showCleanSheet) {
            CleanConfirmSheet(
                count: st.selectedCount,
                size: st.selectedSize,
                hasPermanent: st.selectedItems.contains { $0.permanentDelete },
                hasDanger: st.selectedItems.contains { $0.risk == .danger },
                permanent: $permanentMode
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
                    .font(Theme.displayFont(24, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(Theme.ink)
                Text("\(category.subtitle) · 规则 \(category.ruleRef)")
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.inkMuted48)
            }
            Spacer()

            // 全选 / 反选（原生文字按钮）
            if st.isScanned && !st.items.isEmpty {
                Button(st.allSelected ? "取消全选" : "全选") {
                    st.setAllSelected(!st.allSelected)
                }
                .buttonStyle(.borderless)
                .font(Theme.bodyFont(13, weight: .medium))
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
                .font(Theme.displayFont(20, weight: .semibold))
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
                .font(Theme.displayFont(18, weight: .semibold))
                .foregroundColor(Theme.ink)
            Text("此分类很干净")
                .font(Theme.bodyFont(13))
                .foregroundColor(Theme.inkMuted48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 结果列表（按风险分组，降低密度）

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: Theme.spaceMd) {
                // 按风险分组：可安全清理 / 需确认 / 不建议
                ForEach(RiskGroup.allCases, id: \.self) { group in
                    let groupItems = st.items.filter { $0.risk == group.risk }
                    if !groupItems.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.spaceSm) {
                            // 分组标题
                            HStack(spacing: 6) {
                                Circle().fill(group.color).frame(width: 8, height: 8)
                                Text(group.title)
                                    .font(Theme.bodyFont(13, weight: .semibold))
                                    .foregroundColor(Theme.ink)
                                Text("\(groupItems.count) 项 · \(groupItems.reduce(Int64(0)) { $0 + $1.size }.byteStringCN)")
                                    .font(Theme.bodyFont(12))
                                    .foregroundColor(Theme.inkMuted48)
                                Spacer()
                            }
                            .padding(.horizontal, 2)

                            ForEach(Array(groupItems.enumerated()), id: \.element.id) { _, item in
                                ItemRowView(item: item, isSelected: item.isSelected) { selected in
                                    st.setSelected(item.id, selected)
                                } onAskAI: {
                                    app.ai.askAbout(item: item)
                                }
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
        HStack(spacing: Theme.spaceMd) {
            if let summary = app.lastCleanSummary {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(Theme.actionBlue)
                    Text(summary)
                        .font(Theme.bodyFont(12, weight: .medium))
                        .foregroundColor(Theme.inkMuted80)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 0) {
                Text("已选 \(st.selectedCount) 项")
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.inkMuted48)
                Text(st.selectedSize.byteStringCN)
                    .font(Theme.displayFont(17, weight: .semibold))
                    .foregroundColor(Theme.ink)
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

/// 单个清理项行（默认紧凑：名称+大小+风险；点击展开路径/备注）
struct ItemRowView: View {
    let item: CleanItem
    let isSelected: Bool
    let onToggle: (Bool) -> Void
    var onAskAI: (() -> Void)? = nil

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
                            .font(Theme.bodyFont(14, weight: .semibold))
                            .foregroundColor(Theme.ink)
                            .lineLimit(1)
                        RiskBadge(risk: item.risk)
                    }
                    // 展开后显示路径与备注（密度优化：默认隐藏）
                    if isExpanded {
                        Text(item.path)
                            .font(Theme.bodyFont(12))
                            .foregroundColor(Theme.inkMuted48)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
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
                    .font(Theme.bodyFont(14, weight: .semibold))
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
                .help(isExpanded ? "收起路径" : "显示路径")

                // 问 AI：针对该项提问（用途/能否删/是否在用）
                if let onAskAI {
                    Button(action: onAskAI) {
                        Image(systemName: "sparkles")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.actionBlue)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Theme.actionBlue.opacity(0.12)))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("askAIButton")
                    .help("问 AI：这个是什么？能删吗？")
                }
            }
            .padding(.horizontal, Theme.spaceMd)
            .padding(.vertical, Theme.spaceSm)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .fill(Theme.canvas)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusMd)
                        .stroke(isSelected ? Theme.actionBlue.opacity(0.5) : Theme.hairline, lineWidth: 1)
                )
        )
    }
}

/// 风险徽标（G4）
struct RiskBadge: View {
    let risk: RiskLevel

    private var color: Color {
        switch risk {
        case .safe: return Theme.actionBlue
        case .review: return Theme.warningOrange
        case .danger: return Theme.dangerRed
        }
    }

    var body: some View {
        Text(risk.label)
            .font(Theme.bodyFont(10, weight: .semibold))
            .foregroundColor(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.12)))
    }
}
