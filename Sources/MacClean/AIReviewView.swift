import SwiftUI

/// AI 再筛查抽屉：筛查时侧边弹出，展示思考过程（进度/日志/结论流）
/// 用户诉求：AI 筛查时侧面弹抽屉，展示正在做什么 + 思考过程
///
/// 重写要点：
///  - 抽屉是浮层：材质底 + 宿主投影，内部改用 inset group，不再"描边卡片套描边卡片"。
///  - 进度条复用 `CapacityBar`，不再手搓 `GeometryReader` 与裸 `Capsule`。
///  - 语义色只留给结论徽标与失败提示；日志、进度、元数据全部回到中性色阶。
///  - 分组标题用 `Typo.section`，不再用 `tracking` 撑开的伪小标题。
struct AIReviewView: View {
    @EnvironmentObject private var app: AppState

    /// 已按结论排序的筛查结果（可删 → 谨慎 → 不建议删）
    private var sortedReviews: [ItemReview] {
        let order: [ReviewVerdict] = [.delete, .caution, .keep, .unknown]
        return app.aiReview.reviews.values.sorted {
            (order.firstIndex(of: $0.verdict) ?? 3) < (order.firstIndex(of: $1.verdict) ?? 3)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            if app.aiReview.totalCount > 0 || app.aiReview.isReviewing {
                progressSection
            }
            if app.aiReview.lastError != nil {
                errorRow
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.sm) {
                        // 思考过程日志
                        if !app.aiReview.processLog.isEmpty {
                            logSection
                        }
                        // 结论列表（实时流入）
                        if !sortedReviews.isEmpty {
                            resultSection
                        }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(Space.sm)
                }
                .onChange(of: app.aiReview.processLog.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: app.aiReview.completedCount) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
        }
        .frame(width: 340)
        .background(.regularMaterial)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Accent.tint)

            Text("AI 再筛查")
                .font(Typo.rowStrong)
                .foregroundStyle(Ink.primary)

            Spacer()

            if app.aiReview.isReviewing {
                ProgressView().controlSize(.small)
                Text("分析中…")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
            }

            Button {
                app.aiReview.closeDrawer()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Ink.secondary)
            .accessibilityLabel("收起 AI 筛查")
            .help("收起 AI 筛查面板")
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 10)
    }

    // MARK: - 进度

    private var progressSection: some View {
        let ratio = app.aiReview.totalCount > 0
            ? Double(app.aiReview.completedCount) / Double(app.aiReview.totalCount)
            : 0

        return GroupBox {
            GroupedRow(isLast: true) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack {
                        Text("筛查进度")
                            .font(Typo.section)
                            .foregroundStyle(Ink.secondary)
                        Spacer()
                        Text("\(app.aiReview.completedCount)/\(app.aiReview.totalCount)")
                            .font(.mcNumeric(12, weight: .semibold))
                            .foregroundStyle(Ink.secondary)
                            .motionSafeNumericTransition()
                    }

                    CapacityBar(used: ratio, height: 6)

                    if let text = app.aiReview.progressText {
                        Text(text)
                            .font(Typo.caption)
                            .foregroundStyle(Ink.tertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.horizontal, Space.sm)
        .padding(.top, Space.sm)
    }

    // MARK: - 失败提示

    private var errorRow: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "exclamationmark.triangle.fill", size: 12,
                     color: Signal.caution, width: 16)
            Text("筛查失败：\(app.aiReview.lastError ?? "")")
                .font(Typo.caption)
                .foregroundStyle(Signal.caution)
                .lineLimit(2)
            Spacer()
            Button("重试") {
                let all = app.searchableItems
                app.aiReview.review(items: all)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Accent.tint)
            .disabled(app.searchableItems.isEmpty)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(Signal.caution.opacity(0.08))
        .padding(.top, Space.xs)
    }

    // MARK: - 思考过程日志

    private var logSection: some View {
        GroupBox(title: "思考过程") {
            GroupedRow(isLast: true) {
                VStack(alignment: .leading, spacing: Space.xxs) {
                    ForEach(Array(app.aiReview.processLog.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .top, spacing: Space.xs) {
                            Circle()
                                .fill(Accent.tint.opacity(0.45))
                                .frame(width: 4, height: 4)
                                .padding(.top, 5)
                            Text(line)
                                .font(Typo.caption)
                                .foregroundStyle(Ink.secondary)
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - 结论列表

    private var resultSection: some View {
        GroupBox(title: "筛查结论", footer: "\(sortedReviews.count) 项") {
            ForEach(Array(sortedReviews.enumerated()), id: \.element.itemID) { idx, review in
                GroupedRow(isLast: idx == sortedReviews.count - 1) {
                    ReviewResultRow(
                        name: app.aiReview.itemNames[review.itemID] ?? "未知项",
                        review: review
                    )
                }
            }
        }
    }
}

// MARK: - 单条筛查结论行

struct ReviewResultRow: View {
    let name: String
    let review: ItemReview

    var body: some View {
        HStack(alignment: .top, spacing: Space.xs) {
            ReviewBadge(verdict: review.verdict)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Typo.rowStrong)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                if !review.reason.isEmpty {
                    Text(review.reason)
                        .font(Typo.caption)
                        .foregroundStyle(Ink.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
    }
}
