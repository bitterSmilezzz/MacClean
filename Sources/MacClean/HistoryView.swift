import SwiftUI

/// 历史时间跨度筛选
enum HistoryTimeRange: String, CaseIterable, Identifiable {
    case all = "全部"
    case last7Days = "近 7 天"
    case last30Days = "近 30 天"

    var id: String { rawValue }
}

/// 清理历史（融合 Mole `mo history`）
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
            Divider().overlay(Theme.hairline)

            Group {
                if app.history.isEmpty {
                    VStack(spacing: Theme.spaceSm) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 36, weight: .light))
                            .foregroundColor(Theme.labelTertiary.opacity(0.6))
                        Text("暂无清理记录")
                            .font(Theme.displayFont(22, weight: .semibold))
                            .foregroundColor(Theme.labelPrimary)
                        Text("完成一次清理后，记录会显示在这里")
                            .font(Theme.bodyFont(13))
                            .foregroundColor(Theme.labelSecondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        VStack(spacing: Theme.spaceMd) {
                            if filteredRecords.isEmpty {
                                VStack(spacing: Theme.spaceSm) {
                                    Image(systemName: "calendar.badge.exclamationmark")
                                        .font(.system(size: 32))
                                        .foregroundColor(Theme.labelTertiary)
                                    Text("所选时间段（\(selectedRange.rawValue)）内暂无清理记录")
                                        .font(Theme.bodyFont(13, weight: .medium))
                                        .foregroundColor(Theme.labelSecondary)
                                    Button("查看全部历史") {
                                        withAnimation(Theme.smoothTransition) {
                                            selectedRange = .all
                                        }
                                    }
                                    .buttonStyle(.link)
                                }
                                .frame(maxWidth: .infinity, minHeight: 180)
                                .macCard(cornerRadius: Theme.radiusMd)
                            } else {
                                // 趋势图表：当记录 >= 2 时展示释放趋势
                                if filteredRecords.count >= 2 {
                                    HistoryTrendChart(records: filteredRecords, range: selectedRange)
                                }

                                // 各分类累计释放分布大卡
                                HistoryCategoryDistributionCard(records: filteredRecords)

                                // 详细流水记录列表
                                VStack(spacing: 0) {
                                    ForEach(Array(filteredRecords.enumerated()), id: \.element.id) { index, record in
                                        if index > 0 {
                                            Divider()
                                                .overlay(Theme.separator.opacity(0.35))
                                                .padding(.leading, 38)
                                        }
                                        HistoryRow(record: record)
                                    }
                                }
                                .macCard(cornerRadius: Theme.radiusMd)
                            }
                        }
                        .padding(Theme.spaceMd)
                    }
                }
            }
            .transition(.opacity)
            .animation(Theme.smoothTransition, value: app.history.isEmpty)

            footer
        }
        .background(Theme.windowBackground)
        .hudToast(isPresented: $showHud, text: hudMessage)
        .confirmationDialog("清空历史记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清空", role: .destructive) {
                withAnimation(Theme.smoothTransition) {
                    app.clearHistory()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private var header: some View {
        HStack(spacing: Theme.spaceMd) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(Theme.actionBlue)
                .frame(width: 40, height: 40)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radiusSm, style: .continuous)
                        .fill(Theme.actionBlue.opacity(0.12))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("清理历史")
                    .font(Theme.displayFont(24, weight: .semibold))
                    .foregroundColor(Theme.labelPrimary)
                Text("记录每一次清理动作，可追溯 · 支持图表与数据导出")
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.labelSecondary)
            }
            Spacer()

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
            .tint(Theme.actionBlue)
            .disabled(filteredRecords.isEmpty)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Theme.spaceMd)
        .frostedBar()
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
        HStack {
            Text("共 \(app.history.count) 次清理")
                .font(Theme.bodyFont(12))
                .foregroundColor(Theme.labelTertiary)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text("累计释放 \(totalBytes.byteStringCN)")
                .font(Theme.bodyFont(13, weight: .semibold))
                .foregroundColor(Theme.labelPrimary)
                .monospacedDigit()
                .contentTransition(.numericText())
            Spacer()
            Button {
                confirmClear = true
            } label: {
                Label("清空记录", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Theme.dangerRed)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, 10)
        .frostedBar()
        .overlay(alignment: .top) {
            Divider().overlay(Theme.separator)
        }
    }
}

struct HistoryRow: View {
    let record: CleanRecord

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: record.failures > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 14))
                .foregroundColor(record.failures > 0 ? Theme.warningOrange : Theme.actionBlue)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(record.categoryName)
                        .font(Theme.bodyFont(13, weight: .medium))
                        .foregroundColor(Theme.labelPrimary)
                    Text(record.mode)
                        .font(Theme.bodyFont(11, weight: .medium))
                        .foregroundColor(record.mode == "彻底删除" ? Theme.textDanger : Theme.actionBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill((record.mode == "彻底删除" ? Theme.dangerRed : Theme.actionBlue).opacity(0.12))
                        )
                }
                Text(Self.formatter.string(from: record.date) + " · \(record.itemCount) 项" +
                     (record.failures > 0 ? " · \(record.failures) 项失败" : ""))
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.labelTertiary)
                    .monospacedDigit()
            }
            Spacer()
            Text(record.bytes.byteStringCN)
                .font(Theme.monoFont(12, weight: .semibold))
                .foregroundColor(Theme.labelPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
        .macRowHover(cornerRadius: 0)
    }
}

/// 各分类累计释放分布卡片
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
                color = cat.accentColor
            } else if name.contains("重复") {
                color = Theme.actionBlue
            } else if name.contains("卸载") {
                color = .purple
            } else {
                color = Theme.warningOrange
            }
            return (name: name, bytes: bytes, count: countMap[name, default: 0], color: color)
        }
    }

    var body: some View {
        let total = max(1, records.reduce(0) { $0 + $1.bytes })
        VStack(alignment: .leading, spacing: Theme.spaceSm) {
            HStack {
                Label("各分类累计释放占比", systemImage: "chart.pie.fill")
                    .font(Theme.bodyFont(13, weight: .semibold))
                    .foregroundColor(Theme.labelPrimary)

                Spacer()

                Text("共 \(categoryTotals.count) 个分类贡献")
                    .font(Theme.bodyFont(11))
                    .foregroundColor(Theme.labelTertiary)
            }

            // 多色水平堆叠比例条
            GeometryReader { geo in
                HStack(spacing: 2) {
                    ForEach(categoryTotals, id: \.name) { item in
                        let ratio = CGFloat(item.bytes) / CGFloat(total)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(item.color)
                            .frame(width: max(3, geo.size.width * ratio - 2))
                    }
                }
            }
            .frame(height: 8)

            // 图例与详情指标
            FlowLayout(spacing: 10) {
                ForEach(categoryTotals, id: \.name) { item in
                    let pct = Int(Double(item.bytes) / Double(total) * 100)
                    HStack(spacing: 5) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 7, height: 7)
                        Text(item.name)
                            .font(Theme.bodyFont(11, weight: .regular))
                            .foregroundColor(Theme.labelSecondary)
                        Text("\(item.bytes.byteStringCN) (\(pct)%)")
                            .font(Theme.monoFont(11, weight: .medium))
                            .foregroundColor(Theme.labelPrimary)
                    }
                }
            }
        }
        .padding(Theme.spaceMd)
        .macCard(cornerRadius: Theme.radiusMd)
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

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spaceSm) {
            // 图表标题及关键度量
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("清理释放趋势")
                        .font(Theme.bodyFont(13, weight: .semibold))
                        .foregroundColor(Theme.labelPrimary)
                    Text(range == .all ? "最近 \(chartRecords.count) 次清理流水分布" : "\(range.rawValue) \(chartRecords.count) 次清理流水分布")
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.labelTertiary)
                }

                Spacer()

                HStack(spacing: Theme.spaceMd) {
                    metricItem(label: "平均单次", value: avgBytes.byteStringCN)
                    metricItem(label: "单次最高", value: maxBytes.byteStringCN)
                    metricItem(label: "历史总计", value: totalBytes.byteStringCN)
                }
            }

            Divider().overlay(Theme.hairline)

            // 柱状图主体
            VStack(spacing: 6) {
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(chartRecords) { record in
                        HistoryBarItem(
                            record: record,
                            maxBytes: maxBytes,
                            isHovered: hoveredRecord?.id == record.id
                        ) { isHovering in
                            withAnimation(Theme.spring) {
                                hoveredRecord = isHovering ? record : nil
                            }
                        }
                    }
                }
                .frame(height: 80)

                // 悬停提示或基准线信息
                HStack {
                    if let hovered = hoveredRecord {
                        HStack(spacing: 6) {
                            Text(hovered.categoryName)
                                .font(Theme.bodyFont(11, weight: .medium))
                                .foregroundColor(Theme.actionBlue)
                            Text("·")
                                .foregroundColor(Theme.labelTertiary)
                            Text(hovered.bytes.byteStringCN)
                                .font(Theme.monoFont(11, weight: .semibold))
                                .foregroundColor(Theme.labelPrimary)
                            Text("·")
                                .foregroundColor(Theme.labelTertiary)
                            Text(formatDate(hovered.date))
                                .font(Theme.bodyFont(11))
                                .foregroundColor(Theme.labelTertiary)
                        }
                        .transition(.opacity)
                    } else {
                        Text("将光标悬停在柱条上可查看单次清理详情")
                            .font(Theme.bodyFont(11))
                            .foregroundColor(Theme.labelTertiary.opacity(0.8))
                            .transition(.opacity)
                    }
                    Spacer()
                }
                .frame(height: 16)
                .animation(Theme.smoothTransition, value: hoveredRecord?.id)
            }
        }
        .padding(Theme.spaceMd)
        .macCard(cornerRadius: Theme.radiusMd)
    }

    private func metricItem(label: String, value: String) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(label)
                .font(Theme.bodyFont(10))
                .foregroundColor(Theme.labelTertiary)
            Text(value)
                .font(Theme.monoFont(11, weight: .semibold))
                .foregroundColor(Theme.labelSecondary)
                .monospacedDigit()
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
        VStack(spacing: 4) {
            Spacer()

            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: isHovered
                            ? [Theme.actionBlue.opacity(0.85), Theme.actionBlue]
                            : [Theme.actionBlue.opacity(0.35), Theme.actionBlue.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: barHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .stroke(isHovered ? Theme.actionBlue : Color.clear, lineWidth: 1)
                )
                .shadow(
                    color: isHovered ? Theme.actionBlue.opacity(0.3) : Color.clear,
                    radius: 4,
                    x: 0,
                    y: 2
                )
                .scaleEffect(isHovered ? 1.05 : 1.0, anchor: .bottom)
                .animation(Theme.spring, value: isHovered)
        }
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onHover(perform: onHover)
    }
}

