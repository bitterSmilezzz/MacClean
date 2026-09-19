import SwiftUI
import AppKit

// MARK: - 通用文件差异对比模型与分析引擎

enum FileWinnerChoice: String, Equatable {
    case left = "建议保留文件 A"
    case right = "建议保留文件 B"
    case tie = "两份相当"
    case none = "无明显优势"
}

struct FileDiffRow: Identifiable, Equatable {
    let id = UUID()
    let icon: String
    let label: String
    let valA: String
    let valB: String
    let winner: FileWinnerChoice
    let hint: String?
}

struct FileComparisonResult: Equatable {
    let itemA: DuplicateFileItem
    let itemB: DuplicateFileItem
    let diffRows: [FileDiffRow]
    let textPreviewA: [String]?
    let textPreviewB: [String]?
    let recommendedChoice: FileWinnerChoice
    let recommendationReason: String

    static func compare(itemA: DuplicateFileItem, itemB: DuplicateFileItem) -> FileComparisonResult {
        var rows: [FileDiffRow] = []
        var scoreA: Double = 50.0
        var scoreB: Double = 50.0
        var reasons: [String] = []

        // 1. 体积大小对比
        let sizeA = itemA.size
        let sizeB = itemB.size
        let sizeWinner: FileWinnerChoice
        let sizeHint: String?
        if sizeA == sizeB {
            sizeWinner = .tie
            sizeHint = "大小完全一致"
        } else if sizeA > sizeB {
            sizeWinner = .left
            let diff = (sizeA - sizeB).byteStringCN
            sizeHint = "文件较大 (+ \(diff))"
            scoreA += 5.0
            reasons.append("文件 A 包含更多数据（体积大 \(diff)）")
        } else {
            sizeWinner = .right
            let diff = (sizeB - sizeA).byteStringCN
            sizeHint = "文件较大 (+ \(diff))"
            scoreB += 5.0
            reasons.append("文件 B 包含更多数据（体积大 \(diff)）")
        }
        rows.append(FileDiffRow(
            icon: "scalemass",
            label: "文件大小",
            valA: sizeA.byteStringCN,
            valB: sizeB.byteStringCN,
            winner: sizeWinner,
            hint: sizeHint
        ))

        // 2. 修改时间对比
        let dateA = itemA.modificationDate
        let dateB = itemB.modificationDate
        let dateWinner: FileWinnerChoice
        let dateHint: String?
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let dateStrA = dateA.map { formatter.string(from: $0) } ?? "未知"
        let dateStrB = dateB.map { formatter.string(from: $0) } ?? "未知"

        if let dA = dateA, let dB = dateB {
            let diffSeconds = dA.timeIntervalSince(dB)
            if abs(diffSeconds) < 1.0 {
                dateWinner = .tie
                dateHint = "时间完全一致"
            } else if diffSeconds > 0 {
                dateWinner = .left
                let diffDesc = formatTimeInterval(diffSeconds)
                dateHint = "较新（更新 \(diffDesc)）"
                scoreA += 10.0
                reasons.append("文件 A 拥有更新的修改时间（更新 \(diffDesc)）")
            } else {
                dateWinner = .right
                let diffDesc = formatTimeInterval(-diffSeconds)
                dateHint = "较新（更新 \(diffDesc)）"
                scoreB += 10.0
                reasons.append("文件 B 拥有更新的修改时间（更新 \(diffDesc)）")
            }
        } else {
            dateWinner = .none
            dateHint = nil
        }
        rows.append(FileDiffRow(
            icon: "clock",
            label: "最后修改",
            valA: dateStrA,
            valB: dateStrB,
            winner: dateWinner,
            hint: dateHint
        ))

        // 3. 存储位置与目录重要性对比 (Downloads 目录降权)
        let pathA = itemA.path
        let pathB = itemB.path
        let isDownloadsA = pathA.contains("/Downloads/") || pathA.hasSuffix("/Downloads")
        let isDownloadsB = pathB.contains("/Downloads/") || pathB.hasSuffix("/Downloads")
        let isDesktopOrDocsA = pathA.contains("/Documents/") || pathA.contains("/Desktop/")
        let isDesktopOrDocsB = pathB.contains("/Documents/") || pathB.contains("/Desktop/")

        let locWinner: FileWinnerChoice
        let locHint: String?
        if isDownloadsA && !isDownloadsB {
            locWinner = .right
            locHint = "正规目录（非临时下载）"
            scoreB += 20.0
            reasons.append("文件 B 位于工作目录，文件 A 位于下载文件夹")
        } else if !isDownloadsA && isDownloadsB {
            locWinner = .left
            locHint = "正规目录（非临时下载）"
            scoreA += 20.0
            reasons.append("文件 A 位于工作目录，文件 B 位于下载文件夹")
        } else if isDesktopOrDocsA && !isDesktopOrDocsB {
            locWinner = .left
            locHint = "文稿/桌面工作区"
            scoreA += 8.0
            reasons.append("文件 A 位于文稿/桌面重要工作区")
        } else if !isDesktopOrDocsA && isDesktopOrDocsB {
            locWinner = .right
            locHint = "文稿/桌面工作区"
            scoreB += 8.0
            reasons.append("文件 B 位于文稿/桌面重要工作区")
        } else {
            locWinner = .tie
            locHint = nil
        }
        rows.append(FileDiffRow(
            icon: "folder",
            label: "存储目录",
            valA: (pathA as NSString).deletingLastPathComponent,
            valB: (pathB as NSString).deletingLastPathComponent,
            winner: locWinner,
            hint: locHint
        ))

        // 4. 文件名衍生特征对比 (识别带副本后缀 (1), copy 等)
        let nameA = itemA.name
        let nameB = itemB.name
        let isCopyA = hasCopySuffix(nameA)
        let isCopyB = hasCopySuffix(nameB)
        let nameWinner: FileWinnerChoice
        let nameHint: String?
        if isCopyA && !isCopyB {
            nameWinner = .right
            nameHint = "原始命名（无副本标记）"
            scoreB += 15.0
            reasons.append("文件 B 保持原文件名，文件 A 带有副本标记")
        } else if !isCopyA && isCopyB {
            nameWinner = .left
            nameHint = "原始命名（无副本标记）"
            scoreA += 15.0
            reasons.append("文件 A 保持原文件名，文件 B 带有副本标记")
        } else {
            nameWinner = .tie
            nameHint = nil
        }
        rows.append(FileDiffRow(
            icon: "textformat",
            label: "文件名",
            valA: nameA,
            valB: nameB,
            winner: nameWinner,
            hint: nameHint
        ))

        // 5. 抓取文本类前部预览
        let previewA = extractTextPreview(path: pathA)
        let previewB = extractTextPreview(path: pathB)

        // 综合推荐裁定
        let finalChoice: FileWinnerChoice
        let finalReason: String
        if scoreA > scoreB + 4.0 {
            finalChoice = .left
            finalReason = reasons.isEmpty ? "文件 A 各项参数更优" : reasons.joined(separator: "；")
        } else if scoreB > scoreA + 4.0 {
            finalChoice = .right
            finalReason = reasons.isEmpty ? "文件 B 各项参数更优" : reasons.joined(separator: "；")
        } else {
            finalChoice = .tie
            finalReason = "两份文件内容及属性基本相当，任选其一即可"
        }

        return FileComparisonResult(
            itemA: itemA,
            itemB: itemB,
            diffRows: rows,
            textPreviewA: previewA,
            textPreviewB: previewB,
            recommendedChoice: finalChoice,
            recommendationReason: finalReason
        )
    }

    private static func hasCopySuffix(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains(" copy") || lower.contains(" 副本") || lower.contains("(1)") ||
               lower.contains(" (1)") || lower.contains("-1.") || lower.contains("_1.")
    }

    private static func formatTimeInterval(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s) 秒" }
        if s < 3600 { return "\(s / 60) 分钟" }
        if s < 86400 { return "\(s / 3600) 小时" }
        let days = s / 86400
        return "\(days) 天"
    }

    /// 提取文本文件首部（最多 maxLines 行），附带整齐行号。非纯文本文件返回 nil
    static func extractTextPreview(path: String, maxLines: Int = 16) -> [String]? {
        let ext = (path as NSString).pathExtension.lowercased()
        let textExtensions: Set<String> = [
            "txt", "md", "json", "swift", "py", "js", "ts", "html", "css", "xml",
            "sh", "yaml", "yml", "csv", "c", "cpp", "h", "m", "sql", "rb", "php", "log"
        ]
        guard textExtensions.contains(ext) else { return nil }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped) else {
            return nil
        }
        // 最多只读前 32KB，防止超大文件卡死
        let prefixData = data.prefix(32768)
        guard let str = String(data: prefixData, encoding: .utf8) ?? String(data: prefixData, encoding: .ascii) else {
            return nil
        }
        let lines = str.components(separatedBy: .newlines)
        return Array(lines.prefix(maxLines))
    }
}

// MARK: - 通用文件双栏对比弹窗

struct FileCompareSheet: View {
    let group: DuplicateGroup
    @ObservedObject var dupState: DuplicateState
    var onDismiss: () -> Void

    @State var itemAIndex: Int
    @State var itemBIndex: Int
    @State var comparison: FileComparisonResult?

    init(group: DuplicateGroup, dupState: DuplicateState, onDismiss: @escaping () -> Void) {
        self.group = group
        self.dupState = dupState
        self.onDismiss = onDismiss

        let idxA = 0
        let idxB = group.items.count > 1 ? 1 : 0
        self._itemAIndex = State(initialValue: idxA)
        self._itemBIndex = State(initialValue: idxB)

        if group.items.indices.contains(idxA) && group.items.indices.contains(idxB) {
            self._comparison = State(initialValue: FileComparisonResult.compare(
                itemA: group.items[idxA],
                itemB: group.items[idxB]
            ))
        } else {
            self._comparison = State(initialValue: nil)
        }
    }

    private var currentItemA: DuplicateFileItem? {
        guard group.items.indices.contains(itemAIndex) else { return nil }
        if let currentGroup = dupState.groups.first(where: { $0.id == group.id }),
           let item = currentGroup.items.first(where: { $0.id == group.items[itemAIndex].id }) {
            return item
        }
        return group.items[itemAIndex]
    }

    private var currentItemB: DuplicateFileItem? {
        guard group.items.indices.contains(itemBIndex) else { return nil }
        if let currentGroup = dupState.groups.first(where: { $0.id == group.id }),
           let item = currentGroup.items.first(where: { $0.id == group.items[itemBIndex].id }) {
            return item
        }
        return group.items[itemBIndex]
    }

    var body: some View {
        VStack(spacing: 0) {
            // MARK: - 顶栏
            headerView

            Hairline()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: Space.md) {
                    // MARK: - 推荐理由条
                    recommendationStrip

                    // MARK: - 双栏卡片对比
                    dualColumnCardsSection

                    // MARK: - 属性差异矩阵
                    diffMatrixSection

                    // MARK: - 文本内容前部预览（若有）
                    if let linesA = comparison?.textPreviewA, let linesB = comparison?.textPreviewB {
                        textContentPreviewSection(linesA: linesA, linesB: linesB)
                    }
                }
                .padding(Space.md)
            }

            Hairline()

            // MARK: - 底部操作栏
            footerView
        }
        .frame(minWidth: 840, idealWidth: 920, minHeight: 640, idealHeight: 740)
        .background(Surface.window)
        .overlay(
            Group {
                Button("") { keepOnlyA() }.keyboardShortcut("1", modifiers: [])
                Button("") { keepOnlyA() }.keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { keepOnlyB() }.keyboardShortcut("2", modifiers: [])
                Button("") { keepOnlyB() }.keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { keepBoth() }.keyboardShortcut("0", modifiers: [])
                Button("") { applyRecommendation() }.keyboardShortcut(.return, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
    }

    // MARK: - 顶栏
    private var headerView: some View {
        HStack(spacing: Space.sm) {
            IconSlot(systemName: "square.split.2x1", size: 13, weight: .medium,
                     color: Ink.secondary, width: 18)

            Text("文件双栏比对")
                .font(Typo.title)
                .foregroundStyle(Ink.primary)

            Text("\(group.items.count) 个副本")
                .font(.mcNumeric(11))
                .foregroundStyle(Ink.tertiary)

            Spacer(minLength: Space.sm)

            if group.items.count > 2 {
                HStack(spacing: Space.xs) {
                    Picker("文件 A", selection: Binding(
                        get: { itemAIndex },
                        set: { newIdx in
                            itemAIndex = newIdx
                            reloadComparison()
                        }
                    )) {
                        ForEach(0..<group.items.count, id: \.self) { idx in
                            Text("A: \(group.items[idx].name)").tag(idx)
                        }
                    }
                    .frame(width: 160)
                    .controlSize(.small)

                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ink.quaternary)

                    Picker("文件 B", selection: Binding(
                        get: { itemBIndex },
                        set: { newIdx in
                            itemBIndex = newIdx
                            reloadComparison()
                        }
                    )) {
                        ForEach(0..<group.items.count, id: \.self) { idx in
                            Text("B: \(group.items[idx].name)").tag(idx)
                        }
                    }
                    .frame(width: 160)
                    .controlSize(.small)
                }
                .padding(.horizontal, Space.xs)
                .padding(.vertical, 3)
                .background(
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .fill(Surface.sunken)
                )
            }

            Button {
                onDismiss()
            } label: {
                Text("完成")
                    .font(Typo.rowStrong)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityIdentifier("fileCompareDoneButton")
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    // MARK: - 智能推荐理由条
    private var recommendationStrip: some View {
        GroupBox {
            GroupedRow(isLast: true) {
                HStack(alignment: .top, spacing: Space.sm) {
                    IconSlot(systemName: "checkmark.seal", size: 13, weight: .medium,
                             color: Accent.tint, width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(recommendationTitle)
                            .font(Typo.rowStrong)
                            .foregroundStyle(Ink.primary)

                        Text(comparison?.recommendationReason ?? "正在分析两份文件的属性与工作区权重…")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: Space.sm)

                    if comparison?.recommendedChoice == .left || comparison?.recommendedChoice == .right {
                        Button {
                            applyRecommendation()
                        } label: {
                            HStack(spacing: Space.xxs) {
                                Image(systemName: "wand.and.stars")
                                    .font(.system(size: 11))
                                Text("一键应用推荐")
                                    .font(Typo.caption)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("applyRecommendationButton")
                    }
                }
            }
        }
    }

    private var recommendationTitle: String {
        guard let choice = comparison?.recommendedChoice else { return "正在分析…" }
        switch choice {
        case .left: return "建议保留文件 A"
        case .right: return "建议保留文件 B"
        case .tie: return "两份属性相当"
        case .none: return "无明显倾向"
        }
    }

    // MARK: - 双栏卡片
    private var dualColumnCardsSection: some View {
        HStack(alignment: .top, spacing: Space.md) {
            if let itemA = currentItemA {
                fileCard(
                    title: "文件 A",
                    item: itemA,
                    isRecommended: comparison?.recommendedChoice == .left,
                    onKeepThis: { keepOnlyA() }
                )
            }

            if let itemB = currentItemB {
                fileCard(
                    title: "文件 B",
                    item: itemB,
                    isRecommended: comparison?.recommendedChoice == .right,
                    onKeepThis: { keepOnlyB() }
                )
            }
        }
    }

    private func fileCard(
        title: String,
        item: DuplicateFileItem,
        isRecommended: Bool,
        onKeepThis: @escaping () -> Void
    ) -> some View {
        GroupBox {
            GroupedRow(padding: Space.sm) {
                HStack(spacing: Space.sm) {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: item.path))
                        .resizable()
                        .frame(width: 36, height: 36)

                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: Space.xs) {
                            Text(title)
                                .font(Typo.rowStrong)
                                .foregroundStyle(Ink.primary)

                            if isRecommended {
                                HStack(spacing: 3) {
                                    Image(systemName: "star.fill")
                                        .font(.system(size: 9))
                                    Text("推荐保留")
                                }
                                .font(Typo.micro)
                                .foregroundStyle(Accent.tint)
                            }

                            Spacer()

                            statusBadge(isSelected: item.isSelected)
                        }

                        Text(item.name)
                            .font(Typo.row)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            GroupedRow(isLast: true) {
                VStack(spacing: Space.xs) {
                    if isRecommended {
                        Button(action: onKeepThis) {
                            HStack(spacing: 4) {
                                Image(systemName: item.isSelected ? "arrow.uturn.backward" : "hand.thumbsup")
                                    .font(.system(size: 11))
                                Text(item.isSelected ? "保留此文件（撤销清理）" : "保留此文件（清理另一份）")
                                    .font(Typo.row)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)
                    } else {
                        Button(action: onKeepThis) {
                            HStack(spacing: 4) {
                                Image(systemName: item.isSelected ? "arrow.uturn.backward" : "hand.thumbsup")
                                    .font(.system(size: 11))
                                Text(item.isSelected ? "保留此文件（撤销清理）" : "保留此文件（清理另一份）")
                                    .font(Typo.row)
                            }
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }

                    HStack(spacing: Space.xs) {
                        Text(item.path)
                            .font(Typo.micro)
                            .foregroundStyle(Ink.quaternary)
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Spacer()

                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
                        } label: {
                            Label("在访达中显示", systemImage: "folder")
                                .font(Typo.micro)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Accent.tint)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func statusBadge(isSelected: Bool) -> some View {
        if isSelected {
            HStack(spacing: 3) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                Text("待清理")
            }
            .font(Typo.micro)
            .foregroundStyle(Signal.critical)
        } else {
            HStack(spacing: 3) {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                Text("保留")
            }
            .font(Typo.micro)
            .foregroundStyle(Ink.secondary)
        }
    }

    // MARK: - 属性差异矩阵
    private var diffMatrixSection: some View {
        GroupBox(title: "文件属性比对矩阵") {
            GroupedRow(padding: 6) {
                HStack(spacing: 0) {
                    Text("比对维度")
                        .font(Typo.section)
                        .foregroundStyle(Ink.tertiary)
                        .frame(width: 140, alignment: .leading)

                    Text("文件 A")
                        .font(Typo.section)
                        .foregroundStyle(Ink.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("文件 B")
                        .font(Typo.section)
                        .foregroundStyle(Ink.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let rows = comparison?.diffRows {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    GroupedRow(isLast: idx == rows.count - 1) {
                        HStack(spacing: 0) {
                            HStack(spacing: Space.xxs) {
                                IconSlot(systemName: row.icon, size: 11, color: Ink.tertiary, width: 16)
                                Text(row.label)
                                    .font(Typo.row)
                                    .foregroundStyle(Ink.primary)
                                    .lineLimit(1)
                            }
                            .frame(width: 140, alignment: .leading)

                            diffCell(row.valA, isWinner: row.winner == .left, hint: row.hint)
                            diffCell(row.valB, isWinner: row.winner == .right, hint: row.hint)
                        }
                    }
                }
            }
        }
    }

    private func diffCell(_ value: String, isWinner: Bool, hint: String?) -> some View {
        HStack(spacing: Space.xxs) {
            Text(value)
                .font(.mcNumeric(11, weight: isWinner ? .medium : .regular))
                .foregroundStyle(isWinner ? Ink.primary : Ink.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            if isWinner, let hint {
                Text("[\(hint)]")
                    .font(Typo.micro)
                    .foregroundStyle(Accent.tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                .fill(isWinner ? Accent.softer : Color.clear)
        )
    }

    // MARK: - 文本内容首部对比
    private func textContentPreviewSection(linesA: [String], linesB: [String]) -> some View {
        GroupBox(title: "文本内容首部对比 (前 16 行)") {
            GroupedRow(isLast: true, padding: Space.xs) {
                HStack(alignment: .top, spacing: Space.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("文件 A 文本内容")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(linesA.enumerated()), id: \.offset) { idx, line in
                                    HStack(spacing: 6) {
                                        Text("\(idx + 1)")
                                            .font(.mcNumeric(10))
                                            .foregroundStyle(Ink.quaternary)
                                            .frame(width: 20, alignment: .trailing)
                                        Text(line)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Ink.primary)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                        .padding(Space.xs)
                        .background(Surface.sunken)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("文件 B 文本内容")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                        ScrollView(.horizontal) {
                            VStack(alignment: .leading, spacing: 1) {
                                ForEach(Array(linesB.enumerated()), id: \.offset) { idx, line in
                                    HStack(spacing: 6) {
                                        Text("\(idx + 1)")
                                            .font(.mcNumeric(10))
                                            .foregroundStyle(Ink.quaternary)
                                            .frame(width: 20, alignment: .trailing)
                                        Text(line)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Ink.primary)
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 180)
                        .padding(Space.xs)
                        .background(Surface.sunken)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.inner, style: .continuous))
                    }
                }
            }
        }
    }

    // MARK: - 底部操作栏
    private var footerView: some View {
        HStack(spacing: Space.sm) {
            Text("1 / ← 保留 A · 2 / → 保留 B · 0 均保留 · ↵ 应用推荐 · Esc 关闭")
                .font(Typo.caption)
                .foregroundStyle(Ink.tertiary)

            Spacer()

            Button {
                keepBoth()
            } label: {
                Text("两份均保留")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if comparison?.recommendedChoice == .left || comparison?.recommendedChoice == .right {
                Button {
                    applyRecommendation()
                } label: {
                    Label("应用推荐", systemImage: "checkmark.circle")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .background(.bar)
    }

    // MARK: - 动作逻辑
    private func reloadComparison() {
        guard let itemA = currentItemA, let itemB = currentItemB else { return }
        self.comparison = FileComparisonResult.compare(itemA: itemA, itemB: itemB)
    }

    func keepOnlyA() {
        guard let itemA = currentItemA, let itemB = currentItemB else { return }
        setSelection(itemID: itemA.id, selected: false)
        setSelection(itemID: itemB.id, selected: true)
    }

    func keepOnlyB() {
        guard let itemA = currentItemA, let itemB = currentItemB else { return }
        setSelection(itemID: itemA.id, selected: true)
        setSelection(itemID: itemB.id, selected: false)
    }

    func keepBoth() {
        guard let itemA = currentItemA, let itemB = currentItemB else { return }
        setSelection(itemID: itemA.id, selected: false)
        setSelection(itemID: itemB.id, selected: false)
    }

    func applyRecommendation() {
        guard let comp = comparison else { return }
        if comp.recommendedChoice == .left {
            keepOnlyA()
        } else if comp.recommendedChoice == .right {
            keepOnlyB()
        }
    }

    private func setSelection(itemID: UUID, selected: Bool) {
        guard let gIdx = dupState.groups.firstIndex(where: { $0.id == group.id }),
              let iIdx = dupState.groups[gIdx].items.firstIndex(where: { $0.id == itemID }) else { return }
        dupState.groups[gIdx].items[iIdx].isSelected = selected
    }
}
