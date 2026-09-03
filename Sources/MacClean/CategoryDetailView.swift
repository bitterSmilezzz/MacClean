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

    // MARK: - 结果列表

    private var itemList: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(Array(st.items.enumerated()), id: \.element.id) { idx, item in
                    ItemRowView(item: item, isSelected: item.isSelected) { selected in
                        st.setSelected(item.id, selected)
                    } onAskAI: {
                        app.ai.askAbout(item: item)
                    }
                }
            }
            .padding(Theme.contentPadding)
        }
        .background(Theme.parchment)
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

/// 单个清理项行
struct ItemRowView: View {
    let item: CleanItem
    let isSelected: Bool
    let onToggle: (Bool) -> Void
    var onAskAI: (() -> Void)? = nil

    var body: some View {
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
                        .font(Theme.bodyFont(13, weight: .semibold))
                        .foregroundColor(Theme.ink)
                        .lineLimit(1)
                    RiskBadge(risk: item.risk)
                }
                Text(item.path)
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.inkMuted48)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if !item.note.isEmpty {
                    Text(item.note)
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.inkMuted48.opacity(0.8))
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(item.size.byteStringCN)
                .font(Theme.bodyFont(13, weight: .semibold))
                .foregroundColor(Theme.ink)
                .monospacedDigit()

            // 问 AI：针对该项提问（用途/能否删/是否在用）
            if let onAskAI {
                Button(action: onAskAI) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Theme.actionBlue)
                        .frame(width: 24, height: 24)
                        .background(Circle().fill(Theme.actionBlue.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("askAIButton")
                .help("问 AI：这个是什么？能删吗？")
            }
        }
        .padding(.horizontal, Theme.spaceMd)
        .padding(.vertical, 10)
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
