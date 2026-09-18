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
    /// 可选关联的撤销会话 ID（v1.35.0）
    var undoSessionID: UUID? = nil

    var canUndo: Bool { undoSessionID != nil }

    var deltaString: String {
        releasedBytes.byteStringCN
    }
}

/// 清理成效弹窗。
///
/// 重写要点：
///  - 删掉 64pt 圆形成功徽章（"图标坐进彩色圆底"的翻版），改成左对齐的焦点数字 + 行内小图标。
///  - 磁盘对比、分类分布、指标摘要三处"描边 + 阴影"卡片换成 `GroupBox` 内嵌分组。
///  - 分类分布条是全 App 唯一使用 `ChartPalette`（`cat.chartColor`）的地方——它在这里
///    是数据可视化，不是装饰。
///  - 底部三个等权按钮收成一个主按钮 + 两个文字动作；对比条改用 `LegendItem` 图例。
struct CleanResultSheet: View {
    let snapshot: CleanResultSnapshot
    var onViewHistory: () -> Void
    var onDismiss: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var isRestored = false
    @State private var toastMessage = ""
    @State private var showToast = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            // 1. 焦点：本次释放量
            heroPanel

            // 2. 磁盘可用空间前后对比
            diskComparisonGroup

            // 3. 各分类释放分布（若有明细）
            if !snapshot.breakdown.isEmpty {
                breakdownGroup
            }

            // 4. 清理指标摘要
            metricsGroup

            Spacer(minLength: Space.xxs)

            Hairline()

            // 5. 底部快捷操作
            actionButtons
        }
        .padding(Space.lg)
        .frame(width: 480)
        .background(Surface.window)
        .toast(isPresented: $showToast, text: toastMessage)
    }

    // MARK: - 顶栏：释放量与成功状态
    private var heroPanel: some View {
        HStack(alignment: .center, spacing: Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("本次释放")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.secondary)

                Text("+\(snapshot.deltaString)")
                    .font(.mcNumeric(34, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .motionSafeNumericTransition()

                Text("\(snapshot.itemCount) 个项目 · \(snapshot.mode)")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
            }

            Spacer(minLength: Space.md)

            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 26, weight: .regular))
                .foregroundStyle(Signal.positive)
        }
        .padding(Space.md)
        .background(
            RoundedRectangle(cornerRadius: Radius.overlay, style: .continuous)
                .fill(Accent.softer)
        )
    }

    // MARK: - 磁盘空间前后对比
    private var diskComparisonGroup: some View {
        let before = max(0, snapshot.beforeAvailable)
        let after = max(before, snapshot.afterAvailable)
        let total = max(1, after)
        let beforeRatio = CGFloat(before) / CGFloat(total)

        return GroupBox(title: "Macintosh HD 可用空间") {
            VStack(alignment: .leading, spacing: Space.sm) {
                // 前后对比数值
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("清理前")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.tertiary)
                        Text(snapshot.beforeAvailable.byteStringCN)
                            .font(.mcNumeric(13, weight: .medium))
                            .foregroundStyle(Ink.secondary)
                    }

                    Spacer(minLength: Space.sm)

                    Image(systemName: "arrow.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Ink.quaternary)

                    Spacer(minLength: Space.sm)

                    VStack(alignment: .trailing, spacing: 2) {
                        Text("当前")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.tertiary)
                        Text(snapshot.afterAvailable.byteStringCN)
                            .font(.mcNumeric(15, weight: .semibold))
                            .foregroundStyle(Ink.primary)
                            .motionSafeNumericTransition()
                    }
                }

                // 分段比例条：原有可用 + 本次释放增量
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Signal.positive)
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Accent.tint)
                            .frame(width: max(0, geo.size.width * beforeRatio))
                    }
                }
                .frame(height: 7)

                HStack(spacing: Space.lg) {
                    LegendItem(color: Accent.tint, label: "原有可用",
                               value: snapshot.beforeAvailable.byteStringCN)
                    LegendItem(color: Signal.positive, label: "本次释放",
                               value: "+\(snapshot.deltaString)", emphasized: true)
                }
            }
            .padding(Space.sm)
        }
    }

    // MARK: - 各分类释放分布
    private var breakdownGroup: some View {
        let total = max(1, snapshot.releasedBytes)
        let sortedEntries = snapshot.breakdown.sorted(by: { $0.value > $1.value })

        return GroupBox(title: "分类释放占比") {
            VStack(alignment: .leading, spacing: Space.sm) {
                // 水平分段比例条（唯一使用 ChartPalette 的场景）
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(sortedEntries, id: \.key.id) { cat, bytes in
                            let ratio = CGFloat(bytes) / CGFloat(total)
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(cat.chartColor)
                                .frame(width: max(2, geo.size.width * ratio - 2))
                        }
                    }
                }
                .frame(height: 6)

                // 图例
                VStack(spacing: Space.xxs) {
                    ForEach(sortedEntries, id: \.key.id) { cat, bytes in
                        let pct = Int(Double(bytes) / Double(total) * 100)
                        LegendItem(color: cat.chartColor, label: cat.title,
                                   value: "\(bytes.byteStringCN) (\(pct)%)")
                    }
                }
            }
            .padding(Space.sm)
        }
    }

    // MARK: - 清理指标摘要
    private var metricsGroup: some View {
        GroupBox(title: "本次清理") {
            metricRow(title: "成功项目", value: "\(snapshot.itemCount) 项",
                      isLast: snapshot.failureCount == 0)
            if snapshot.failureCount > 0 {
                metricRow(title: "跳过/锁定", value: "\(snapshot.failureCount) 项",
                          isWarning: true, isLast: true)
            }
        }
    }

    private func metricRow(title: String, value: String,
                           isWarning: Bool = false, isLast: Bool = false) -> some View {
        GroupedRow(isLast: isLast) {
            HStack(spacing: Space.sm) {
                Text(title)
                    .font(Typo.row)
                    .foregroundStyle(Ink.secondary)
                Spacer(minLength: Space.sm)
                Text(value)
                    .font(Typo.rowStrong)
                    .foregroundStyle(isWarning ? Signal.caution : Ink.primary)
            }
        }
    }

    // MARK: - 底部快捷操作
    private var actionButtons: some View {
        HStack(spacing: Space.md) {
            // 撤销放回原位（v1.35.0）
            if let sessionID = snapshot.undoSessionID, snapshot.mode.contains("废纸篓") {
                textAction(isRestored ? "已放回原位" : "撤销（放回原位）",
                           icon: isRestored ? "checkmark" : "arrow.uturn.backward") {
                    guard !isRestored else { return }
                    let res = UndoManagerStore.restore(sessionID: sessionID)
                    isRestored = true
                    toastMessage = res.summary
                    showToast = true
                }
                .disabled(isRestored)
            }

            // 在访达中打开废纸篓
            if snapshot.mode.contains("废纸篓") {
                textAction("查看废纸篓", icon: "trash") {
                    let trashURL = URL(fileURLWithPath: CleanPaths.expand("~/.Trash"))
                    NSWorkspace.shared.open(trashURL)
                }
            }

            // 查看历史趋势
            textAction("历史趋势", icon: "chart.bar.xaxis") {
                onViewHistory()
            }
            .accessibilityIdentifier("resultSheetHistoryButton")

            Spacer(minLength: Space.sm)

            // 完成按钮：唯一主操作
            Button("完成") {
                onDismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("resultSheetDoneButton")
        }
    }

    private func textAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(Typo.row)
            }
            .foregroundStyle(Accent.tint)
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .pressable()
        .rowHover()
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
