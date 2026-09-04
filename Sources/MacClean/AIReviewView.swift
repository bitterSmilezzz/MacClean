import SwiftUI

/// AI 再筛查抽屉：筛查时侧边弹出，展示思考过程（进度/日志/结论流）
/// 用户诉求：AI 筛查时侧面弹抽屉，展示正在做什么 + 思考过程
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
            Divider().overlay(Theme.hairline)

            if app.aiReview.totalCount > 0 || app.aiReview.isReviewing {
                progressCard
            }
            if app.aiReview.lastError != nil {
                errorCard
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
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
                    .padding(Theme.spaceSm)
                }
                .onChange(of: app.aiReview.processLog.count) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .onChange(of: app.aiReview.completedCount) { _ in
                    withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .background(Theme.parchment)
        }
        .frame(width: 340)
        .background(Theme.canvas)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles.rectangle.stack")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.actionBlue)
            Text("AI 再筛查")
                .font(Theme.bodyFont(13, weight: .semibold))
                .foregroundColor(Theme.ink)
            Spacer()
            if app.aiReview.isReviewing {
                ProgressView().controlSize(.small).tint(Theme.actionBlue)
                Text("分析中…")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.inkMuted48)
            }
            Button {
                app.aiReview.closeDrawer()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.inkMuted48)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("收起 AI 筛查")
            .help("收起 AI 筛查面板")
        }
        .padding(.horizontal, Theme.spaceSm)
        .padding(.vertical, 10)
        .background(Theme.canvas)
    }

    // MARK: - 进度卡

    private var progressCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("筛查进度")
                    .font(Theme.bodyFont(12, weight: .semibold))
                    .foregroundColor(Theme.inkMuted80)
                Spacer()
                Text("\(app.aiReview.completedCount)/\(app.aiReview.totalCount)")
                    .font(Theme.monoFont(12, weight: .semibold))
                    .foregroundColor(Theme.inkMuted48)
            }
            // 进度条
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.hairline)
                    let ratio = app.aiReview.totalCount > 0
                        ? Double(app.aiReview.completedCount) / Double(app.aiReview.totalCount)
                        : 0
                    Capsule()
                        .fill(Theme.actionBlue)
                        .frame(width: max(6, geo.size.width * ratio))
                }
            }
            .frame(height: 6)
            .animation(.easeOut(duration: 0.3), value: app.aiReview.completedCount)
            if let text = app.aiReview.progressText {
                Text(text)
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.inkMuted48)
            }
        }
        .padding(Theme.spaceSm)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .fill(Theme.parchment)
        )
        .padding(.horizontal, Theme.spaceSm)
        .padding(.vertical, 6)
    }

    // MARK: - 错误卡

    private var errorCard: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundColor(Theme.textWarning)
            Text("筛查失败：\(app.aiReview.lastError ?? "")")
                .font(Theme.bodyFont(12, weight: .medium))
                .foregroundColor(Theme.textWarning)
                .lineLimit(2)
            Spacer()
            Button("重试") {
                let all = app.searchableItems
                app.aiReview.review(items: all)
            }
            .buttonStyle(.borderless)
            .font(Theme.bodyFont(12, weight: .medium))
            .foregroundColor(Theme.actionBlue)
            .disabled(app.searchableItems.isEmpty)
        }
        .padding(.horizontal, Theme.spaceSm)
        .padding(.vertical, 8)
        .background(Theme.warningOrange.opacity(0.06))
    }

    // MARK: - 思考过程日志

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("思考过程")
                .font(Theme.bodyFont(12, weight: .semibold))
                .tracking(0.5)
                .foregroundColor(Theme.inkMuted80)
            ForEach(Array(app.aiReview.processLog.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 6) {
                    Circle()
                        .fill(Theme.actionBlue.opacity(0.4))
                        .frame(width: 4, height: 4)
                        .padding(.top, 5)
                    Text(line)
                        .font(Theme.bodyFont(12))
                        .foregroundColor(Theme.inkMuted80)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(Theme.spaceSm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .fill(Theme.canvas)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusMd)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        )
    }

    // MARK: - 结论列表

    private var resultSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("筛查结论")
                    .font(Theme.bodyFont(12, weight: .semibold))
                    .tracking(0.5)
                    .foregroundColor(Theme.inkMuted80)
                Spacer()
                Text("\(sortedReviews.count) 项")
                    .font(Theme.monoFont(12))
                    .foregroundColor(Theme.inkMuted48)
            }
            ForEach(sortedReviews, id: \.itemID) { review in
                ReviewResultRow(
                    name: app.aiReview.itemNames[review.itemID] ?? "未知项",
                    review: review
                )
            }
        }
        .padding(Theme.spaceSm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .fill(Theme.canvas)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radiusMd)
                        .stroke(Theme.hairline, lineWidth: 1)
                )
        )
    }
}

// MARK: - 单条筛查结论行

struct ReviewResultRow: View {
    let name: String
    let review: ItemReview

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ReviewBadge(verdict: review.verdict)
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.bodyFont(13, weight: .semibold))
                    .foregroundColor(Theme.ink)
                    .lineLimit(1)
                if !review.reason.isEmpty {
                    Text(review.reason)
                        .font(Theme.bodyFont(12))
                        .foregroundColor(Theme.inkMuted48)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
