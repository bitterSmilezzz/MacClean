import SwiftUI
import CoreGraphics
import ImageIO
import AppKit

/// 相似照片高质量下采样预览视图。
///
/// 重写要点：图片是内容，chrome 要退到后面。占位态不再用彩色图标底板，
/// 只留一个中性灰的 `photo` 符号 + 一句说明。
struct PhotoThumbnailPreview: View {
    let path: String
    let maxPixelSize: Int

    @State private var image: NSImage? = nil

    init(path: String, maxPixelSize: Int = 1024) {
        self.path = path
        self.maxPixelSize = maxPixelSize
        // 同步尝试轻量解码，避免无头测试或初始瞬间空白
        let url = URL(fileURLWithPath: path)
        if let source = CGImageSourceCreateWithURL(url as CFURL, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailWithTransform: true
            ]
            if let cgImg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                self._image = State(initialValue: NSImage(cgImage: cgImg, size: NSSize(width: cgImg.width, height: cgImg.height)))
            }
        }
    }

    var body: some View {
        Group {
            if let img = image {
                Image(nsImage: img)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                VStack(spacing: Space.xs) {
                    Image(systemName: "photo")
                        .font(.system(size: 26, weight: .light))
                        .foregroundStyle(Ink.quaternary)
                    Text("载入中…")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }
}

/// 相似照片双栏快速对比与 EXIF 快门参数分析弹窗。
///
/// 重写要点：
///  - 紫色"AI 分析"配色整套删掉。全弹窗只用 `Accent.tint` 一个强调色，画质优劣靠字重与
///    淡强调底色表达。
///  - 浮空卡片（描边 + 阴影）换成 inset group：单张照片是一组 `GroupedRow`，参数矩阵也是。
///  - 装饰性副标题（"智能解析快门防抖、感光度与画质差异"）删掉，右侧位置改放真实数据：
///    组内张数、感知相似度。
///  - chrome 全部走中性色，底色用 `Surface.sunken`，让照片本身成为视觉主体。
struct PhotoCompareSheet: View {
    let group: DuplicateGroup
    @ObservedObject var dupState: DuplicateState
    var onDismiss: () -> Void

    @State var itemAIndex: Int
    @State var itemBIndex: Int

    @State var metaA: PhotoMetadata?
    @State var metaB: PhotoMetadata?
    @State var comparison: PhotoComparisonResult?

    init(group: DuplicateGroup, dupState: DuplicateState, onDismiss: @escaping () -> Void) {
        self.group = group
        self.dupState = dupState
        self.onDismiss = onDismiss

        let idxA = 0
        let idxB = group.items.count > 1 ? 1 : 0
        self._itemAIndex = State(initialValue: idxA)
        self._itemBIndex = State(initialValue: idxB)

        let itemA = group.items.indices.contains(idxA) ? group.items[idxA] : nil
        let itemB = group.items.indices.contains(idxB) ? group.items[idxB] : nil

        let mA = itemA != nil ? PhotoMetadata.extract(from: URL(fileURLWithPath: itemA!.path)) : nil
        let mB = itemB != nil ? PhotoMetadata.extract(from: URL(fileURLWithPath: itemB!.path)) : nil
        self._metaA = State(initialValue: mA)
        self._metaB = State(initialValue: mB)

        if let mA = mA, let mB = mB {
            self._comparison = State(initialValue: PhotoComparisonResult.compare(photoA: mA, photoB: mB))
        } else {
            self._comparison = State(initialValue: nil)
        }
    }

    private var currentItemA: DuplicateFileItem? {
        guard group.items.indices.contains(itemAIndex) else { return nil }
        // 从 dupState 获取最新的勾选状态
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
            // MARK: - 顶栏标题与多图切换
            headerView

            Hairline()

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: Space.md) {
                    // MARK: - 智能推荐理由
                    recommendationStrip

                    // MARK: - 双栏大图对比
                    dualColumnPreviewSection

                    // MARK: - EXIF 快门与画质参数对比矩阵
                    exifMatrixSection
                }
                .padding(Space.md)
            }

            Hairline()

            // MARK: - 底部快捷操作与提示栏
            footerView
        }
        .frame(minWidth: 840, idealWidth: 920, minHeight: 640, idealHeight: 720)
        .background(Surface.window)
        .overlay(
            // 隐形快捷键监听
            Group {
                Button("") { keepOnlyA() }
                    .keyboardShortcut("1", modifiers: [])
                Button("") { keepOnlyA() }
                    .keyboardShortcut(.leftArrow, modifiers: [])
                Button("") { keepOnlyB() }
                    .keyboardShortcut("2", modifiers: [])
                Button("") { keepOnlyB() }
                    .keyboardShortcut(.rightArrow, modifiers: [])
                Button("") { keepBoth() }
                    .keyboardShortcut("0", modifiers: [])
                Button("") { applyRecommendation() }
                    .keyboardShortcut(.return, modifiers: [])
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
    }

    // MARK: - 顶栏视图
    private var headerView: some View {
        HStack(spacing: Space.sm) {
            IconSlot(systemName: "square.split.2x1", size: 13, weight: .medium,
                     color: Ink.secondary, width: 18)

            Text("照片对比")
                .font(Typo.title)
                .foregroundStyle(Ink.primary)

            Text("\(group.items.count) 张")
                .font(.mcNumeric(11))
                .foregroundStyle(Ink.tertiary)

            Spacer(minLength: Space.sm)

            // 当组内图片超过 2 张时，提供左右对比切换下拉菜单
            if group.items.count > 2 {
                HStack(spacing: Space.xs) {
                    Picker("照片 A", selection: Binding(
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
                    .frame(width: 150)
                    .controlSize(.small)

                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Ink.quaternary)

                    Picker("照片 B", selection: Binding(
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
                    .frame(width: 150)
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
            .accessibilityIdentifier("photoCompareDoneButton")
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.sm)
        .background(.bar)
    }

    // MARK: - 智能推荐理由
    private var recommendationStrip: some View {
        GroupBox {
            GroupedRow(isLast: true) {
                HStack(alignment: .center, spacing: Space.sm) {
                    IconSlot(systemName: "checkmark.seal.fill", size: 14, weight: .medium,
                             color: Accent.tint, width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(recommendationTitle)
                            .font(Typo.rowStrong)
                            .foregroundStyle(Ink.primary)

                        Text(comparison?.recommendationReason ?? "正在分析曝光与画质参数…")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: Space.sm)

                    if let choice = comparison?.recommendedChoice, (choice == .left || choice == .right) {
                        Button {
                            applyRecommendation()
                        } label: {
                            Label("一键采纳推荐", systemImage: "wand.and.stars")
                                .font(Typo.rowStrong)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityIdentifier("photoCompareApplyRecButton")
                    }

                    if let sim = comparison?.similarity {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(String(format: "%.1f%%", sim * 100))
                                .font(.mcNumeric(13, weight: .medium))
                                .foregroundStyle(Ink.primary)
                            Text("感知相似度")
                                .font(Typo.caption)
                                .foregroundStyle(Ink.tertiary)
                        }
                    }
                }
            }
        }
    }

    private var recommendationTitle: String {
        guard let choice = comparison?.recommendedChoice else { return "正在分析…" }
        switch choice {
        case .left: return "建议保留照片 A"
        case .right: return "建议保留照片 B"
        case .tie: return "两张画质相当"
        case .none: return "两张均无明显优势"
        }
    }

    // MARK: - 双栏大图对比部分
    private var dualColumnPreviewSection: some View {
        HStack(alignment: .top, spacing: Space.md) {
            // 左图
            if let itemA = currentItemA, let mA = metaA {
                singlePhotoCard(
                    title: "照片 A",
                    item: itemA,
                    meta: mA,
                    isRecommended: comparison?.recommendedChoice == .left,
                    onKeepThis: { keepOnlyA() }
                )
            }

            // 右图
            if let itemB = currentItemB, let mB = metaB {
                singlePhotoCard(
                    title: "照片 B",
                    item: itemB,
                    meta: mB,
                    isRecommended: comparison?.recommendedChoice == .right,
                    onKeepThis: { keepOnlyB() }
                )
            }
        }
    }

    // MARK: - 单张照片
    private func singlePhotoCard(
        title: String,
        item: DuplicateFileItem,
        meta: PhotoMetadata,
        isRecommended: Bool,
        onKeepThis: @escaping () -> Void
    ) -> some View {
        GroupBox {
            // 大图：靠中性深底衬托，图片本身是唯一焦点
            GroupedRow(padding: Space.sm) {
                PhotoThumbnailPreview(path: item.path, maxPixelSize: 1024)
                    .frame(height: 240)
                    .frame(maxWidth: .infinity)
                    .background(Surface.sunken)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }

            // 标题 + 推荐标记 + 清理/保留状态
            GroupedRow {
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

                    Spacer(minLength: Space.xs)

                    photoStatusLabel(item: item)
                }
            }

            // 主操作 + 文件属性
            GroupedRow(isLast: true) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    keepButton(item: item, isRecommended: isRecommended, action: onKeepThis)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name)
                            .font(Typo.row)
                            .foregroundStyle(Ink.primary)
                            .lineLimit(1)

                        HStack(spacing: Space.xxs) {
                            Text(meta.resolutionString)
                                .font(.mcNumeric(10))
                            Text("·")
                            Text(meta.fileSize.byteStringCN)
                                .font(.mcNumeric(10))
                            Text("·")
                            Text(meta.format)
                                .font(Typo.caption)
                        }
                        .foregroundStyle(Ink.tertiary)

                        Text(item.path)
                            .font(Typo.micro)
                            .foregroundStyle(Ink.quaternary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func keepButton(item: DuplicateFileItem, isRecommended: Bool, action: @escaping () -> Void) -> some View {
        let label = HStack(spacing: 5) {
            Image(systemName: item.isSelected ? "arrow.uturn.backward" : "hand.thumbsup")
                .font(.system(size: 11, weight: .medium))
            Text(item.isSelected ? "保留这张（撤销待清理）" : "保留这张（清理另一张）")
                .font(Typo.row)
        }
        .frame(maxWidth: .infinity)

        if isRecommended {
            Button(action: action) { label }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)
        } else {
            Button(action: action) { label }
                .buttonStyle(.bordered)
                .controlSize(.regular)
        }
    }

    @ViewBuilder
    private func photoStatusLabel(item: DuplicateFileItem) -> some View {
        if item.isSelected {
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

    // MARK: - EXIF 快门与画质参数对比矩阵
    private var exifMatrixSection: some View {
        GroupBox(title: "曝光与画质参数") {
            // 表头
            GroupedRow(padding: 6) {
                HStack(spacing: 0) {
                    Text("参数")
                        .font(Typo.section)
                        .foregroundStyle(Ink.tertiary)
                        .frame(width: 140, alignment: .leading)

                    Text("照片 A")
                        .font(Typo.section)
                        .foregroundStyle(Ink.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("照片 B")
                        .font(Typo.section)
                        .foregroundStyle(Ink.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if let rows = comparison?.diffRows {
                ForEach(Array(rows.enumerated()), id: \.element.id) { idx, row in
                    GroupedRow(isLast: idx == rows.count - 1) {
                        diffRowView(row)
                    }
                }
            }
        }
    }

    private func diffRowView(_ row: PhotoDiffRow) -> some View {
        HStack(spacing: 0) {
            // 参数名
            HStack(spacing: Space.xxs) {
                IconSlot(systemName: row.icon, size: 11, color: Ink.tertiary, width: 16)
                Text(row.label)
                    .font(Typo.row)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
            }
            .frame(width: 140, alignment: .leading)

            diffValueCell(row.valA, isWinner: row.winner == .left, hint: row.hint)

            diffValueCell(row.valB, isWinner: row.winner == .right, hint: row.hint)
        }
    }

    private func diffValueCell(_ value: String, isWinner: Bool, hint: String?) -> some View {
        HStack(spacing: Space.xxs) {
            Text(value)
                .font(.mcNumeric(11, weight: isWinner ? .medium : .regular))
                .foregroundStyle(isWinner ? Ink.primary : Ink.secondary)

            if isWinner, let hint {
                Text("[\(hint)]")
                    .font(Typo.micro)
                    .foregroundStyle(Accent.tint)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(Accent.softer)
                    )
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

    // MARK: - 底部控制与快捷键说明
    private var footerView: some View {
        HStack(spacing: Space.sm) {
            Text("1/← 保留左 · 2/→ 保留右 · 0 均保留 · ↵ 采纳推荐 · Esc 关闭")
                .font(Typo.caption)
                .foregroundStyle(Ink.tertiary)

            Spacer()

            if let choice = comparison?.recommendedChoice, (choice == .left || choice == .right) {
                Button {
                    applyRecommendation()
                } label: {
                    Label("采纳推荐", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            Button {
                keepBoth()
            } label: {
                Text("两张均保留")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let itemA = currentItemA {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: itemA.path)])
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, Space.md)
        .padding(.vertical, Space.xs)
        .background(.bar)
    }

    // MARK: - 决策处理逻辑

    private func reloadComparison() {
        let itemA = group.items.indices.contains(itemAIndex) ? group.items[itemAIndex] : nil
        let itemB = group.items.indices.contains(itemBIndex) ? group.items[itemBIndex] : nil

        let mA = itemA != nil ? PhotoMetadata.extract(from: URL(fileURLWithPath: itemA!.path)) : nil
        let mB = itemB != nil ? PhotoMetadata.extract(from: URL(fileURLWithPath: itemB!.path)) : nil
        self.metaA = mA
        self.metaB = mB

        if let mA = mA, let mB = mB {
            self.comparison = PhotoComparisonResult.compare(photoA: mA, photoB: mB)
        } else {
            self.comparison = nil
        }
    }

    /// 一键采纳系统推荐选项
    func applyRecommendation() {
        guard let choice = comparison?.recommendedChoice else { return }
        switch choice {
        case .left:
            keepOnlyA()
        case .right:
            keepOnlyB()
        default:
            break
        }
    }

    /// 保留左侧，勾选右侧待清理
    func keepOnlyA() {
        guard let itemA = currentItemA, let itemB = currentItemB else { return }
        // 修改 dupState 中相应 item 的勾选
        setSelection(itemID: itemA.id, selected: false)
        setSelection(itemID: itemB.id, selected: true)
    }

    /// 保留右侧，勾选左侧待清理
    func keepOnlyB() {
        guard let itemA = currentItemA, let itemB = currentItemB else { return }
        setSelection(itemID: itemA.id, selected: true)
        setSelection(itemID: itemB.id, selected: false)
    }

    /// 两张均保留，取消两张的勾选
    func keepBoth() {
        guard let itemA = currentItemA, let itemB = currentItemB else { return }
        setSelection(itemID: itemA.id, selected: false)
        setSelection(itemID: itemB.id, selected: false)
    }

    private func setSelection(itemID: UUID, selected: Bool) {
        guard let gIdx = dupState.groups.firstIndex(where: { $0.id == group.id }),
              let iIdx = dupState.groups[gIdx].items.firstIndex(where: { $0.id == itemID }) else { return }
        dupState.groups[gIdx].items[iIdx].isSelected = selected
    }
}
