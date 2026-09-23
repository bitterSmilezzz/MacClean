import SwiftUI

/// 历史时间跨度筛选
enum HistoryTimeRange: String, CaseIterable, Identifiable {
    case all = "全部"
    case last7Days = "近 7 天"
    case last30Days = "近 30 天"

    var id: String { rawValue }
}

/// 清理历史（融合 Mole `mo history`）
///
/// 重写要点：
///  - 表头删掉「图标彩色底板 + 大标题 + 装饰性副标题」三件套。左对齐一个 `Typo.title` 标题，
///    右侧留给真正要用的控件（时间跨度、导出）。真数据（清理次数、累计释放）留在底部状态条。
///  - 三张浮空描边卡片（趋势图 / 分布图 / 流水列表）统一降级为 `GroupBox` inset group，
///    行分隔交给 `GroupedRow` 的发丝线。
///  - `HistoryRow` 从"圆角标签堆叠"改成表格式对齐：图标｜分类｜方式｜时间｜条目｜体积，
///    每列固定宽度，方式不再画成彩色胶囊——密集列表里胶囊只会制造噪声。
///  - 趋势柱状图去掉渐变与投影，改用单一 `Accent.tint` 填充（唯一强调色）；悬停只做透明度与
///    轻微缩放，不改变布局尺寸。
struct HistoryView: View {
    @EnvironmentObject private var app: AppState
    @State private var confirmClear = false
    @State private var showHud = false
    @State private var hudMessage = ""
    @State private var selectedRange: HistoryTimeRange = .all

    private var filteredRecords: [CleanRecord] {
        let now = Date()
        switch selectedRange {
        case .all:
            return app.history
        case .last7Days:
            let cutoff = now.addingTimeInterval(-7 * 86400)
            return app.history.filter { $0.date >= cutoff }
        case .last30Days:
            let cutoff = now.addingTimeInterval(-30 * 86400)
            return app.history.filter { $0.date >= cutoff }
        }
    }

    private var totalBytes: Int64 { filteredRecords.reduce(0) { $0 + $1.bytes } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            Group {
                if app.history.isEmpty {
                    EmptyState(
                        icon: "clock.arrow.circlepath",
                        title: "暂无清理记录",
                        message: "完成一次清理后，记录会显示在这里"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: Space.lg) {
                            if filteredRecords.isEmpty {
                                EmptyState(
                                    icon: "calendar.badge.exclamationmark",
                                    title: "所选时间段（\(selectedRange.rawValue)）内暂无清理记录",
                                    actionTitle: "查看全部历史"
                                ) {
                                    withAnimation(Motion.standard) {
                                        selectedRange = .all
                                    }
                                }
                            } else {
                                // 趋势图表：当记录 >= 2 时展示释放趋势
                                if filteredRecords.count >= 2 {
                                    HistoryTrendChart(records: filteredRecords, range: selectedRange)
                                }

                                // 各分类累计释放分布
                                HistoryCategoryDistributionCard(records: filteredRecords)

                                // 详细流水记录列表
                                historyList
                            }
                        }
                        .padding(.horizontal, Space.gutter)
                        .padding(.vertical, Space.md)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .motionSafeTransition(.opacity)
            .motionSafe(Motion.micro, value: app.history.isEmpty)

            footer
        }
        .background(Surface.window)
        .onAppear { app.reloadHistory() }
        .toast(isPresented: $showHud, text: hudMessage)
        .confirmationDialog("清空历史记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                withAnimation(Motion.standard) {
                    app.clearHistory()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 详细流水列表

    private var historyList: some View {
        GroupBox(title: "全部记录") {
            ForEach(Array(filteredRecords.enumerated()), id: \.element.id) { index, record in
                GroupedRow(isLast: index == filteredRecords.count - 1) {
                    HistoryRow(record: record) { rec in
                        let res = app.restoreCleanRecord(recordID: rec.id)
                        hudMessage = res.summary
                        showHud = true
                    }
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: Space.sm) {
            Text("清理历史")
                .font(Typo.title)
                .foregroundStyle(Ink.primary)

            Spacer(minLength: Space.md)

            // 时间跨度筛选分段器
            Picker("", selection: $selectedRange) {
                ForEach(HistoryTimeRange.allCases) { range in
                    Text(range.rawValue).tag(range)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 170)

            // 导出历史操作菜单
            Menu {
                Button {
                    exportCSV()
                } label: {
                    Label("导出为 CSV 表格…", systemImage: "tablecells")
                }
                .keyboardShortcut("e", modifiers: .command)

                Button {
                    exportReport()
                } label: {
                    Label("导出为文本报告…", systemImage: "doc.text")
                }
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderedButton)
            .controlSize(.regular)
            // 不加 fixedSize 时 borderedButton 菜单会吃掉整条 Spacer 之外的剩余宽度，
            // 变成一根横贯表头的空按钮
            .fixedSize()
            .disabled(filteredRecords.isEmpty)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .barSurface()
    }

    private func exportCSV() {
        let content = HistoryExporter.generateCSV(records: filteredRecords)
        let filename = HistoryExporter.makeDefaultFilename(prefix: "MacClean_History_\(selectedRange.rawValue)", ext: "csv")
        HistoryExporter.exportWithSavePanel(content: content, defaultFilename: filename, fileExtension: "csv") { ok, name in
            if ok, let name {
                hudMessage = "已成功导出 \(name)"
                showHud = true
            }
        }
    }

    private func exportReport() {
        let content = HistoryExporter.generateReport(records: filteredRecords)
        let filename = HistoryExporter.makeDefaultFilename(prefix: "MacClean_Report_\(selectedRange.rawValue)", ext: "md")
        HistoryExporter.exportWithSavePanel(content: content, defaultFilename: filename, fileExtension: "md") { ok, name in
            if ok, let name {
                hudMessage = "已成功导出 \(name)"
                showHud = true
            }
        }
    }

    private var footer: some View {
        HStack(spacing: Space.md) {
            HStack(spacing: Space.xxs) {
                Text("共")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                Text("\(app.history.count)")
                    .font(.mcNumeric(11, weight: .medium))
                    .foregroundStyle(Ink.secondary)
                    .motionSafeNumericTransition()
                Text("次清理")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
            }

            HStack(spacing: Space.xxs) {
                Text("累计释放")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                Text(totalBytes.byteStringCN)
                    .font(.mcNumeric(12, weight: .semibold))
                    .foregroundStyle(Ink.primary)
                    .motionSafeNumericTransition()
            }

            Spacer(minLength: Space.sm)

            Button {
                confirmClear = true
            } label: {
                Label("清空记录", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Signal.critical)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.xs)
        .barSurface()
        .overlay(alignment: .top) {
            Hairline()
        }
    }
}

/// 单条清理流水。表格式对齐：图标｜分类｜方式｜时间｜条目｜体积。
///
/// 原先"分类 + 彩色方式胶囊 / 灰色元数据行 / 右侧体积"的三行堆叠在列表里读起来是散的：
/// 每行高度不一致、数字不对齐。拆成固定宽度的列之后，视线可以竖着扫下来比较体积。
struct HistoryRow: View {
    let record: CleanRecord
    var onRestore: ((CleanRecord) -> Void)? = nil

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private var undoSession: CleanUndoSession? {
        UndoManagerStore.session(for: record.id)
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            IconSlot(
                systemName: record.failures > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle",
                size: 12,
                color: record.failures > 0 ? Signal.caution : Ink.tertiary,
                width: 16
            )

            Text(record.categoryName)
                .font(Typo.rowStrong)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .frame(width: 88, alignment: .leading)

            Text(record.mode)
                .font(Typo.caption)
                .foregroundStyle(record.mode == "彻底删除" ? Signal.critical : Ink.tertiary)
                .lineLimit(1)
                .frame(width: 58, alignment: .leading)

            Text(Self.formatter.string(from: record.date))
                .font(.mcNumeric(11))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 104, alignment: .leading)

            Text(record.failures > 0 ? "\(record.itemCount) 项 · \(record.failures) 项失败" : "\(record.itemCount) 项")
                .font(.mcNumeric(11))
                .foregroundStyle(record.failures > 0 ? Signal.caution : Ink.tertiary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 放回原位操作按钮（若有可还原项）
            if let session = undoSession, session.canRestore {
                Button {
                    onRestore?(record)
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 10, weight: .medium))
                        Text("放回")
                            .font(Typo.caption)
                    }
                    .foregroundStyle(Accent.tint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                            .fill(Accent.soft)
                    )
                }
                .buttonStyle(.plain)
                .help("将废纸篓中的文件放回原路径")
            } else if let session = undoSession, session.isFullyRestored {
                Text("已放回")
                    .font(Typo.caption)
                    .foregroundStyle(Signal.positive)
            }

            Text(record.bytes.byteStringCN)
                .font(.mcNumeric(12, weight: .semibold))
                .foregroundStyle(Ink.primary)
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.horizontal, Space.xxs)
        .contentShape(Rectangle())
        .rowHover()
    }
}

/// 各分类累计释放分布。
///
/// 分段比例条是数据可视化，继续用分类图表色（`ChartPalette`）；图例换成 `LegendItem`——
/// 色点 + 分类 + 右对齐等宽数值，比原来"色点 + 名称 + 括号百分比"的流式排布更容易竖着比较。
struct HistoryCategoryDistributionCard: View {
    let records: [CleanRecord]

    private var categoryTotals: [(name: String, bytes: Int64, count: Int, color: Color)] {
        var bytesMap: [String: Int64] = [:]
        var countMap: [String: Int] = [:]
        for r in records {
            bytesMap[r.categoryName, default: 0] += r.bytes
            countMap[r.categoryName, default: 0] += 1
        }
        let sorted = bytesMap.sorted(by: { $0.value > $1.value })
        return sorted.map { name, bytes in
            let color: Color
            if let cat = CleanCategory.allCases.first(where: { $0.title == name }) {
                color = cat.chartColor
            } else if name.contains("重复") {
                color = ChartPalette.color(at: 0)
            } else if name.contains("卸载") {
                color = ChartPalette.color(at: 5)
            } else {
                color = ChartPalette.color(at: 3)
            }
            return (name: name, bytes: bytes, count: countMap[name, default: 0], color: color)
        }
    }

    var body: some View {
        let total = max(1, records.reduce(0) { $0 + $1.bytes })
        return GroupBox(title: "各分类累计释放", footer: "共 \(categoryTotals.count) 个分类贡献") {
            VStack(alignment: .leading, spacing: Space.sm) {
                // 多色水平堆叠比例条
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(categoryTotals, id: \.name) { item in
                            let ratio = CGFloat(item.bytes) / CGFloat(total)
                            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                                .fill(item.color)
                                .frame(width: max(3, geo.size.width * ratio - 2))
                        }
                    }
                }
                .frame(height: 8)

                // 图例与详情指标
                VStack(spacing: 6) {
                    ForEach(categoryTotals, id: \.name) { item in
                        let pct = Int(Double(item.bytes) / Double(total) * 100)
                        LegendItem(
                            color: item.color,
                            label: item.count > 1 ? "\(item.name) · \(item.count) 次" : item.name,
                            value: "\(item.bytes.byteStringCN) (\(pct)%)"
                        )
                    }
                }
            }
            .padding(Space.sm)
        }
    }
}

/// 清理历史趋势图表（展示最近清理的释放容量分布、峰值与平均值）
struct HistoryTrendChart: View {
    let records: [CleanRecord]
    var range: HistoryTimeRange = .all

    @State private var hoveredRecord: CleanRecord?

    // 取最近最多 14 次记录按时间正序排列
    private var chartRecords: [CleanRecord] {
        Array(records.suffix(14).reversed())
    }

    private var maxBytes: Int64 {
        max(chartRecords.map(\.bytes).max() ?? 1, 1)
    }

    private var avgBytes: Int64 {
        guard !chartRecords.isEmpty else { return 0 }
        return chartRecords.reduce(0) { $0 + $1.bytes } / Int64(chartRecords.count)
    }

    private var totalBytes: Int64 {
        records.reduce(0) { $0 + $1.bytes }
    }

    private var footerText: String {
        let shown = "最近 \(chartRecords.count) 次清理流水"
        return range == .all ? shown : "\(range.rawValue) · \(shown)"
    }

    var body: some View {
        GroupBox(title: "清理释放趋势", footer: footerText) {
            VStack(alignment: .leading, spacing: Space.sm) {
                // 关键度量：右对齐，`Typo.micro` 标签 + 等宽数字
                HStack(alignment: .firstTextBaseline, spacing: Space.lg) {
                    Spacer(minLength: 0)
                    metricItem(label: "平均单次", value: avgBytes.byteStringCN)
                    metricItem(label: "单次最高", value: maxBytes.byteStringCN)
                    metricItem(label: "历史总计", value: totalBytes.byteStringCN)
                }

                Hairline()

                // 柱状图主体
                VStack(spacing: 6) {
                    HStack(alignment: .bottom, spacing: Space.xs) {
                        ForEach(chartRecords) { record in
                            HistoryBarItem(
                                record: record,
                                maxBytes: maxBytes,
                                isHovered: hoveredRecord?.id == record.id
                            ) { isHovering in
                                withAnimation(Motion.micro) {
                                    hoveredRecord = isHovering ? record : nil
                                }
                            }
                        }
                    }
                    .frame(height: 80)

                    // 悬停读出或提示
                    HStack(spacing: Space.xxs) {
                        if let hovered = hoveredRecord {
                            Text(hovered.categoryName)
                                .font(Typo.caption)
                                .fontWeight(.medium)
                                .foregroundStyle(Ink.primary)
                            Text("·")
                                .foregroundStyle(Ink.quaternary)
                            Text(hovered.bytes.byteStringCN)
                                .font(.mcNumeric(11, weight: .semibold))
                                .foregroundStyle(Ink.primary)
                            Text("·")
                                .foregroundStyle(Ink.quaternary)
                            Text(formatDate(hovered.date))
                                .font(.mcNumeric(11))
                                .foregroundStyle(Ink.tertiary)
                        } else {
                            Text("将光标悬停在柱条上可查看单次清理详情")
                                .font(Typo.caption)
                                .foregroundStyle(Ink.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: 16)
                    .motionSafe(Motion.micro, value: hoveredRecord?.id)
                }
            }
            .padding(Space.sm)
        }
    }

    private func metricItem(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(Typo.micro)
                .foregroundStyle(Ink.tertiary)
            Text(value)
                .font(.mcNumeric(11, weight: .semibold))
                .foregroundStyle(Ink.secondary)
        }
    }

    private func formatDate(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "MM-dd HH:mm"
        return df.string(from: date)
    }
}

/// 柱状图单条条目
struct HistoryBarItem: View {
    let record: CleanRecord
    let maxBytes: Int64
    let isHovered: Bool
    let onHover: (Bool) -> Void

    private var barHeight: CGFloat {
        let ratio = CGFloat(record.bytes) / CGFloat(max(maxBytes, 1))
        return max(ratio * 70, 4)
    }

    var body: some View {
        VStack(spacing: Space.xxs) {
            Spacer(minLength: 0)

            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .fill(Accent.tint.opacity(isHovered ? 1.0 : 0.55))
                .frame(height: barHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                        .stroke(isHovered ? Accent.tint : Color.clear, lineWidth: 1)
                )
                .scaleEffect(isHovered ? 1.05 : 1.0, anchor: .bottom)
                .motionSafe(Motion.micro, value: isHovered)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }
}
