import SwiftUI
import AppKit

/// 一次清理动作的成效快照
struct CleanResultSnapshot: Identifiable, Equatable {
    let id = UUID()
    var title: String = "清理完成"
    var releasedBytes: Int64
    var itemCount: Int
    var failureCount: Int
    var mode: String                   // "废纸篓" 或 "彻底删除"
    var beforeAvailable: Int64         // 清理前可用空间
    var afterAvailable: Int64          // 清理后可用空间
    var breakdown: [CleanCategory: Int64] = [:] // 各分类释放量
    var timestamp: Date = Date()

    var deltaString: String {
        releasedBytes.byteStringCN
    }
}

/// 清理成效可视化大卡弹窗
struct CleanResultSheet: View {
    let snapshot: CleanResultSnapshot
    var onViewHistory: () -> Void
    var onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: Theme.spaceMd) {
            // 1. 庆祝徽章与释放大字
            headerSection

            // 2. 磁盘可用空间前后对比大卡
            diskComparisonCard

            // 3. 各分类释放分布条（若有明细）
            if !snapshot.breakdown.isEmpty {
                breakdownCard
            }

            // 4. 清理指标摘要行
            metricsRow

            Spacer(minLength: 4)

            Divider().overlay(Theme.hairline)

            // 5. 底部快捷操作
            actionButtons
        }
        .padding(Theme.spaceLg)
        .frame(width: 480)
        .background(Theme.windowBackground)
    }

    // MARK: - 顶栏庆祝徽标与数字
    private var headerSection: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(Theme.successGreen.opacity(0.14))
                    .frame(width: 64, height: 64)

                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 38, weight: .semibold))
                    .foregroundColor(Theme.successGreen)
            }
            .padding(.top, 4)

            VStack(spacing: 4) {
                Text("+\(snapshot.deltaString)")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundColor(Theme.labelPrimary)
                    .contentTransition(.numericText())

                Text("已成功安全释放 \(snapshot.itemCount) 个项目 · \(snapshot.mode)")
                    .font(Theme.bodyFont(13, weight: .medium))
                    .foregroundColor(Theme.labelSecondary)
            }
        }
    }

    // MARK: - 磁盘空间前后对比大卡
    private var diskComparisonCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Macintosh HD 可用空间变化", systemImage: "internaldrive")
                    .font(Theme.bodyFont(12, weight: .semibold))
                    .foregroundColor(Theme.labelPrimary)

                Spacer()

                // 增量角标
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("+\(snapshot.deltaString)")
                        .font(Theme.monoFont(10, weight: .bold))
                }
                .foregroundColor(Theme.successGreen)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Theme.successGreen.opacity(0.15))
                .cornerRadius(4)
            }

            // 前后对比数值条
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("清理前可用")
                        .font(Theme.bodyFont(10))
                        .foregroundColor(Theme.labelTertiary)
                    Text(snapshot.beforeAvailable.byteStringCN)
                        .font(Theme.monoFont(12, weight: .medium))
                        .foregroundColor(Theme.labelSecondary)
                }

                Spacer()

                Image(systemName: "arrow.forward")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundColor(Theme.successGreen)

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text("当前可用")
                        .font(Theme.bodyFont(10))
                        .foregroundColor(Theme.labelTertiary)
                    Text(snapshot.afterAvailable.byteStringCN)
                        .font(Theme.monoFont(13, weight: .bold))
                        .foregroundColor(Theme.labelPrimary)
                }
            }

            // 比例条可视化对比
            let before = max(0, snapshot.beforeAvailable)
            let after = max(before, snapshot.afterAvailable)
            let total = max(1, after)
            let beforeRatio = CGFloat(before) / CGFloat(total)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // 底条：代表当前增加后的可用容量
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.successGreen.opacity(0.35))
                        .frame(width: geo.size.width)

                    // 内条：代表原有可用容量
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Theme.actionBlue.opacity(0.7))
                        .frame(width: max(0, geo.size.width * beforeRatio))
                }
            }
            .frame(height: 7)

            HStack {
                HStack(spacing: 4) {
                    Circle().fill(Theme.actionBlue.opacity(0.7)).frame(width: 6, height: 6)
                    Text("原有容量").font(Theme.bodyFont(9)).foregroundColor(Theme.labelTertiary)
                }
                HStack(spacing: 4) {
                    Circle().fill(Theme.successGreen).frame(width: 6, height: 6)
                    Text("释放增量").font(Theme.bodyFont(9)).foregroundColor(Theme.labelTertiary)
                }
                Spacer()
            }
        }
        .padding(Theme.spaceSm)
        .macCard(cornerRadius: Theme.radiusSm)
    }

    // MARK: - 各分类释放分布条
    private var breakdownCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("分类释放占比")
                .font(Theme.bodyFont(11, weight: .semibold))
                .foregroundColor(Theme.labelPrimary)

            let total = max(1, snapshot.releasedBytes)
            let sortedEntries = snapshot.breakdown.sorted(by: { $0.value > $1.value })

            // 水平分段比例条
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(sortedEntries, id: \.key.id) { cat, bytes in
                        let ratio = CGFloat(bytes) / CGFloat(total)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(cat.accentColor)
                            .frame(width: max(2, geo.size.width * ratio - 2))
                    }
                }
            }
            .frame(height: 6)

            // 图例
            FlowLayout(spacing: 8) {
                ForEach(sortedEntries, id: \.key.id) { cat, bytes in
                    let pct = Int(Double(bytes) / Double(total) * 100)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(cat.accentColor)
                            .frame(width: 6, height: 6)
                        Text(cat.title)
                            .font(Theme.bodyFont(10))
                            .foregroundColor(Theme.labelSecondary)
                        Text("\(bytes.byteStringCN) (\(pct)%)")
                            .font(Theme.monoFont(10, weight: .medium))
                            .foregroundColor(Theme.labelPrimary)
                    }
                }
            }
        }
        .padding(Theme.spaceSm)
        .macCard(cornerRadius: Theme.radiusSm)
    }

    // MARK: - 清理指标摘要
    private var metricsRow: some View {
        HStack(spacing: Theme.spaceSm) {
            metricItem(title: "成功项目", value: "\(snapshot.itemCount) 项")
            metricItem(title: "清理方式", value: snapshot.mode)
            if snapshot.failureCount > 0 {
                metricItem(title: "跳过/锁定", value: "\(snapshot.failureCount) 项", isWarning: true)
            }
            metricItem(title: "归档状态", value: "已记入历史")
        }
    }

    private func metricItem(title: String, value: String, isWarning: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(Theme.bodyFont(10))
                .foregroundColor(Theme.labelTertiary)
            Text(value)
                .font(Theme.bodyFont(11, weight: .medium))
                .foregroundColor(isWarning ? Theme.warningOrange : Theme.labelPrimary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                .fill(Theme.controlBackground.opacity(0.6))
        )
    }

    // MARK: - 底部快捷操作按钮
    private var actionButtons: some View {
        HStack(spacing: 12) {
            // 在访达中打开废纸篓
            if snapshot.mode.contains("废纸篓") {
                Button {
                    let trashURL = URL(fileURLWithPath: CleanPaths.expand("~/.Trash"))
                    NSWorkspace.shared.open(trashURL)
                } label: {
                    Label("查看废纸篓", systemImage: "trash")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }

            // 查看历史趋势
            Button {
                onViewHistory()
            } label: {
                Label("历史趋势", systemImage: "chart.bar.xaxis")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .accessibilityIdentifier("resultSheetHistoryButton")

            Spacer()

            // 完成按钮
            Button("完成") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .tint(Theme.actionBlue)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("resultSheetDoneButton")
        }
    }
}

/// 简易自适应流动排列容器
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 400
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > width && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }

        return CGSize(width: width, height: currentY + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX: CGFloat = bounds.minX
        var currentY: CGFloat = bounds.minY
        var lineHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX && currentX > bounds.minX {
                currentX = bounds.minX
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
