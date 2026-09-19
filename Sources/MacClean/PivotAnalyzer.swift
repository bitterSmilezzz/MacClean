import Foundation
import SwiftUI

/// 多维交叉透视单元格
struct PivotCell: Identifiable, Equatable {
    var id: String { "\(year)_\(type.rawValue)" }
    let year: String
    let type: LargeFileTypeFilter
    var count: Int = 0
    var totalBytes: Int64 = 0
    var itemIDs: [UUID] = []

    var sizeString: String {
        totalBytes.byteStringCN
    }
}

/// 多维交叉透视聚合矩阵
struct PivotMatrix: Equatable {
    let years: [String]
    let types: [LargeFileTypeFilter]
    let cells: [String: PivotCell]
    let topHotspots: [PivotCell]
    let totalBytes: Int64
    let totalCount: Int

    func cell(year: String, type: LargeFileTypeFilter) -> PivotCell? {
        cells["\(year)_\(type.rawValue)"]
    }

    /// 获取特定年份的总占用
    func totalBytes(forYear year: String) -> Int64 {
        types.reduce(0) { $0 + (cell(year: year, type: $1)?.totalBytes ?? 0) }
    }

    /// 获取特定类型的总占用
    func totalBytes(forType type: LargeFileTypeFilter) -> Int64 {
        years.reduce(0) { $0 + (cell(year: $1, type: type)?.totalBytes ?? 0) }
    }
}

/// 多维交叉透视分析引擎
enum PivotAnalyzer {
    /// 对给定的清理项目列表按「修改年份 × 文件类型」生成交叉透视分析矩阵
    static func analyze(items: [CleanItem]) -> PivotMatrix {
        guard !items.isEmpty else {
            return PivotMatrix(years: [], types: [], cells: [:], topHotspots: [], totalBytes: 0, totalCount: 0)
        }

        let cal = Calendar.current
        let currentYear = cal.component(.year, from: Date())

        // 收集所有出现的年份
        var yearSet = Set<String>()
        for item in items {
            let y = yearString(for: item.modificationDate, currentYear: currentYear)
            yearSet.insert(y)
        }

        // 确定展示年份排序：从新到旧排，最后排「更早」
        let sortedYears = yearSet.sorted { y1, y2 in
            if y1.contains("更早") { return false }
            if y2.contains("更早") { return true }
            return y1 > y2
        }

        let activeTypes = LargeFileTypeFilter.allCases.filter { $0 != .all }

        var cellMap: [String: PivotCell] = [:]
        var totalBytes: Int64 = 0

        for item in items {
            let y = yearString(for: item.modificationDate, currentYear: currentYear)
            // 找到匹配的具体类型（非 .all）
            let matchedType = activeTypes.first(where: { $0.matches(item: item) }) ?? .other
            let key = "\(y)_\(matchedType.rawValue)"

            var cell = cellMap[key] ?? PivotCell(year: y, type: matchedType)
            cell.count += 1
            cell.totalBytes += item.size
            cell.itemIDs.append(item.id)
            cellMap[key] = cell

            totalBytes += item.size
        }

        // 计算占用最高的前 3 大空间浪费热点
        let hotspots = cellMap.values
            .filter { $0.totalBytes > 0 }
            .sorted { $0.totalBytes > $1.totalBytes }
            .prefix(3)

        return PivotMatrix(
            years: sortedYears,
            types: activeTypes,
            cells: cellMap,
            topHotspots: Array(hotspots),
            totalBytes: totalBytes,
            totalCount: items.count
        )
    }

    /// 从文件修改时间推导规范化年份标签
    static func yearString(for date: Date?, currentYear: Int = Calendar.current.component(.year, from: Date())) -> String {
        guard let date else { return "未知年份" }
        let y = Calendar.current.component(.year, from: date)
        if y <= currentYear - 3 {
            return "\(currentYear - 3)及更早"
        } else {
            return "\(y)年"
        }
    }

    /// 便捷获取年份标签
    static func yearLabel(for date: Date?) -> String {
        yearString(for: date)
    }
}

// MARK: - 透视年份筛选胶囊徽章

struct YearFilterBadge: View {
    let year: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "calendar")
                .font(.system(size: 10))
            Text(year)
                .font(Typo.micro)
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(Accent.tint.opacity(0.12))
        .foregroundColor(Accent.tint)
        .clipShape(Capsule())
    }
}

// MARK: - 多维交叉透视卡片视图

struct CrossPivotCard: View {
    let matrix: PivotMatrix
    @Binding var selectedType: LargeFileTypeFilter
    @Binding var selectedYear: String?
    let onClose: () -> Void

    var body: some View {
        content
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            PivotHeaderView(totalBytes: matrix.totalBytes, onClose: onClose)
            if !matrix.topHotspots.isEmpty {
                PivotHotspotsView(
                    hotspots: matrix.topHotspots,
                    selectedType: $selectedType,
                    selectedYear: $selectedYear
                )
            }
            PivotTableView(
                matrix: matrix,
                selectedType: $selectedType,
                selectedYear: $selectedYear
            )
        }
        .padding(10)
        .background(Surface.group)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - 矩阵头部视图

struct PivotHeaderView: View {
    let totalBytes: Int64
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                Image(systemName: "square.grid.3x3.fill")
                    .foregroundColor(Accent.tint)
                    .font(.system(size: 12))
                Text("年份 × 类型多维透视矩阵")
                    .font(Typo.section)
                    .foregroundColor(Ink.primary)
                Text("总计 \(totalBytes.byteStringCN)")
                    .font(.mcNumeric(11))
                    .foregroundColor(Ink.tertiary)
            }

            Spacer()

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(Ink.tertiary)
                    .padding(4)
                    .background(Surface.sunken)
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("closePivotCard")
        }
    }
}

// MARK: - 空间热点胶囊条视图

struct PivotHotspotsView: View {
    let hotspots: [PivotCell]
    @Binding var selectedType: LargeFileTypeFilter
    @Binding var selectedYear: String?

    var body: some View {
        HStack(spacing: 6) {
            Text("空间热点:")
                .font(Typo.micro)
                .foregroundColor(Ink.tertiary)
            ForEach(hotspots) { spot in
                let isSelected = selectedYear == spot.year && selectedType == spot.type
                Button(action: {
                    if isSelected {
                        selectedYear = nil
                        selectedType = .all
                    } else {
                        selectedYear = spot.year
                        selectedType = spot.type
                    }
                }) {
                    HStack(spacing: 4) {
                        Image(systemName: "flame.fill")
                            .font(.system(size: 9))
                            .foregroundColor(Signal.caution)
                        Text("\(spot.year) · \(spot.type.rawValue)")
                            .font(Typo.micro)
                        Text(spot.sizeString)
                            .font(.mcNumeric(10, weight: .medium))
                            .foregroundColor(Ink.primary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(isSelected ? Accent.tint.opacity(0.18) : Surface.sunken)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - 矩阵表格视图

struct PivotTableView: View {
    let matrix: PivotMatrix
    @Binding var selectedType: LargeFileTypeFilter
    @Binding var selectedYear: String?

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                headerRow
                Divider().overlay(Surface.hairline.opacity(0.5))
                ForEach(matrix.types, id: \.self) { type in
                    if matrix.totalBytes(forType: type) > 0 {
                        typeRow(type: type)
                    }
                }
                footerRow
            }
        }
    }

    private var headerRow: some View {
        HStack(spacing: 0) {
            Text("类型 \\ 年份")
                .font(Typo.micro)
                .foregroundColor(Ink.tertiary)
                .frame(width: 96, alignment: .leading)
                .padding(.vertical, 4)

            ForEach(matrix.years, id: \.self) { yr in
                Text(yr)
                    .font(Typo.micro)
                    .foregroundColor(selectedYear == yr ? Accent.tint : Ink.secondary)
                    .frame(width: 72, alignment: .trailing)
                    .padding(.vertical, 4)
            }

            Text("合计")
                .font(Typo.micro)
                .foregroundColor(Ink.tertiary)
                .frame(width: 76, alignment: .trailing)
                .padding(.vertical, 4)
        }
        .background(Surface.sunken.opacity(0.5))
    }

    private func typeRow(type: LargeFileTypeFilter) -> some View {
        let rowTotal = matrix.totalBytes(forType: type)
        return VStack(spacing: 0) {
            HStack(spacing: 0) {
                HStack(spacing: 4) {
                    Image(systemName: type.icon)
                        .font(.system(size: 9))
                        .foregroundColor(selectedType == type ? Accent.tint : Ink.tertiary)
                    Text(type.rawValue)
                        .font(Typo.micro)
                        .foregroundColor(selectedType == type ? Accent.tint : Ink.primary)
                        .lineLimit(1)
                }
                .frame(width: 96, alignment: .leading)
                .padding(.vertical, 3)

                ForEach(matrix.years, id: \.self) { yr in
                    cellButton(yr: yr, type: type)
                }

                Text(rowTotal.byteStringCN)
                    .font(.mcNumeric(10, weight: .medium))
                    .foregroundColor(Ink.secondary)
                    .frame(width: 76, alignment: .trailing)
                    .padding(.vertical, 3)
            }
            Divider().overlay(Surface.hairline.opacity(0.2))
        }
    }

    private func cellButton(yr: String, type: LargeFileTypeFilter) -> some View {
        let cell = matrix.cell(year: yr, type: type)
        let bytes = cell?.totalBytes ?? 0
        let isCellActive = selectedYear == yr && selectedType == type

        return Button(action: {
            guard bytes > 0 else { return }
            if isCellActive {
                selectedYear = nil
                selectedType = .all
            } else {
                selectedYear = yr
                selectedType = type
            }
        }) {
            Text(bytes > 0 ? bytes.byteStringCN : "-")
                .font(.mcNumeric(10))
                .foregroundColor(bytes > 0 ? (isCellActive ? Accent.tint : Ink.primary) : Ink.tertiary.opacity(0.5))
                .frame(width: 72, alignment: .trailing)
                .padding(.vertical, 3)
                .background(isCellActive ? Accent.tint.opacity(0.15) : Color.clear)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(bytes == 0)
    }

    private var footerRow: some View {
        HStack(spacing: 0) {
            Text("合计")
                .font(Typo.micro)
                .foregroundColor(Ink.tertiary)
                .frame(width: 96, alignment: .leading)
                .padding(.vertical, 4)

            ForEach(matrix.years, id: \.self) { yr in
                let yrTotal = matrix.totalBytes(forYear: yr)
                Text(yrTotal > 0 ? yrTotal.byteStringCN : "-")
                    .font(.mcNumeric(10, weight: .medium))
                    .foregroundColor(selectedYear == yr ? Accent.tint : Ink.secondary)
                    .frame(width: 72, alignment: .trailing)
                    .padding(.vertical, 4)
            }

            Text(matrix.totalBytes.byteStringCN)
                .font(.mcNumeric(10, weight: .bold))
                .foregroundColor(Accent.tint)
                .frame(width: 76, alignment: .trailing)
                .padding(.vertical, 4)
        }
        .background(Surface.sunken.opacity(0.4))
    }
}
