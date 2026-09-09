import SwiftUI
import CoreGraphics
import ImageIO
import AppKit

/// 相似照片高质量下采样预览视图
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
                VStack(spacing: 8) {
                    Image(systemName: "photo")
                        .font(.system(size: 36))
                        .foregroundColor(Theme.labelTertiary)
                    Text("载入中...")
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.labelTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

/// 相似照片双栏快速对比与 EXIF 快门参数分析弹窗
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

            Divider().overlay(Theme.separator)

            ScrollView(.vertical, showsIndicators: true) {
                VStack(spacing: 16) {
                    // MARK: - 智能推荐理由横幅
                    recommendationBanner

                    // MARK: - 双栏大图对比与快速勾选卡片
                    dualColumnPreviewSection

                    // MARK: - EXIF 快门与画质参数对比矩阵
                    exifMatrixSection
                }
                .padding(16)
            }

            Divider().overlay(Theme.separator)

            // MARK: - 底部快捷操作与提示栏
            footerView
        }
        .frame(minWidth: 840, idealWidth: 920, minHeight: 640, idealHeight: 720)
        .background(Theme.canvas)
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
            }
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
        )
    }

    // MARK: - 顶栏视图
    private var headerView: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundColor(Color.purple)

                VStack(alignment: .leading, spacing: 2) {
                    Text("相似照片双栏对比与 EXIF 参数分析")
                        .font(Theme.bodyFont(14, weight: .bold))
                        .foregroundColor(Theme.labelPrimary)

                    Text("组内共 \(group.items.count) 张相似图片 · 智能解析快门防抖、感光度与画质差异")
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.labelSecondary)
                }
            }

            Spacer()

            // 当组内图片超过 2 张时，提供左右对比切换下拉菜单
            if group.items.count > 2 {
                HStack(spacing: 6) {
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
                        .font(.system(size: 11))
                        .foregroundColor(Theme.labelTertiary)

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
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            Button {
                onDismiss()
            } label: {
                Text("完成")
                    .font(Theme.bodyFont(12, weight: .medium))
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .keyboardShortcut(.escape, modifiers: [])
            .accessibilityIdentifier("photoCompareDoneButton")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Theme.parchment)
    }

    // MARK: - 智能推荐理由横幅
    private var recommendationBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "sparkles")
                .font(.system(size: 18))
                .foregroundColor(Color.purple)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("智能画质分析建议")
                        .font(Theme.bodyFont(12, weight: .bold))
                        .foregroundColor(Color.purple)

                    if let sim = comparison?.similarity {
                        Text("感知相似度 \(String(format: "%.1f", sim * 100))%")
                            .font(Theme.bodyFont(10, weight: .semibold))
                            .foregroundColor(Theme.labelSecondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.purple.opacity(0.12)))
                    }
                }

                Text(comparison?.recommendationReason ?? "正在分析照片曝光与画质参数...")
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.labelPrimary)
            }

            Spacer()
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.purple.opacity(0.06))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.purple.opacity(0.2), lineWidth: 1)
                )
        )
    }

    // MARK: - 双栏大图对比部分
    private var dualColumnPreviewSection: some View {
        HStack(alignment: .top, spacing: 16) {
            // 左图卡片
            if let itemA = currentItemA, let mA = metaA {
                singlePhotoCard(
                    title: "照片 A",
                    item: itemA,
                    meta: mA,
                    isRecommended: comparison?.recommendedChoice == .left,
                    onKeepThis: { keepOnlyA() }
                )
            }

            // 右图卡片
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

    // MARK: - 单个照片展示卡片
    private func singlePhotoCard(
        title: String,
        item: DuplicateFileItem,
        meta: PhotoMetadata,
        isRecommended: Bool,
        onKeepThis: @escaping () -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // 头部状态条
            HStack(spacing: 8) {
                Text(title)
                    .font(Theme.bodyFont(12, weight: .bold))
                    .foregroundColor(Theme.labelPrimary)

                if isRecommended {
                    HStack(spacing: 3) {
                        Image(systemName: "star.fill")
                            .font(.system(size: 9))
                        Text("推荐保留")
                    }
                    .font(Theme.bodyFont(10, weight: .semibold))
                    .foregroundColor(Color.purple)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.purple.opacity(0.15)))
                }

                Spacer()

                // 清理 / 保留状态
                if item.isSelected {
                    HStack(spacing: 3) {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                        Text("已标记待清理")
                    }
                    .font(Theme.bodyFont(10, weight: .medium))
                    .foregroundColor(Theme.dangerRed)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.dangerRed.opacity(0.12)))
                } else {
                    HStack(spacing: 3) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 10))
                        Text("保留此照片")
                    }
                    .font(Theme.bodyFont(10, weight: .medium))
                    .foregroundColor(Theme.actionBlue)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Theme.actionBlue.opacity(0.12)))
                }
            }

            // 大图预览区域
            PhotoThumbnailPreview(path: item.path, maxPixelSize: 1024)
                .frame(height: 220)
                .frame(maxWidth: .infinity)
                .background(Color.black.opacity(0.04))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 0.5)
                )

            // 操作主按键
            Button {
                onKeepThis()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: item.isSelected ? "arrow.uturn.backward" : "hand.thumbsup.fill")
                        .font(.system(size: 11))
                    Text("保留此张 (清理对面)")
                        .font(Theme.bodyFont(11, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
            }
            .buttonStyle(.borderedProminent)
            .tint(isRecommended ? Color.purple : Theme.actionBlue)
            .controlSize(.regular)

            // 文件基础属性
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .font(Theme.bodyFont(12, weight: .medium))
                    .foregroundColor(Theme.labelPrimary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    Text(meta.resolutionString)
                        .font(Theme.monoFont(10))
                        .foregroundColor(Theme.labelSecondary)
                    Text("·")
                        .foregroundColor(Theme.labelTertiary)
                    Text(meta.fileSize.byteStringCN)
                        .font(Theme.monoFont(10))
                        .foregroundColor(Theme.labelSecondary)
                    Text("·")
                        .foregroundColor(Theme.labelTertiary)
                    Text(meta.format)
                        .font(Theme.bodyFont(10, weight: .medium))
                        .foregroundColor(Theme.labelTertiary)
                }

                Text(item.path)
                    .font(Theme.monoFont(9))
                    .foregroundColor(Theme.labelTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(12)
        .macCard(cornerRadius: Theme.radiusMd)
    }

    // MARK: - EXIF 快门与画质参数对比矩阵
    private var exifMatrixSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "camera.badge.ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.labelPrimary)
                Text("EXIF 曝光与画质参数对比矩阵")
                    .font(Theme.bodyFont(13, weight: .bold))
                    .foregroundColor(Theme.labelPrimary)
                Spacer()
            }

            VStack(spacing: 0) {
                // 表头
                HStack(spacing: 0) {
                    Text("参数指标")
                        .font(Theme.bodyFont(11, weight: .semibold))
                        .foregroundColor(Theme.labelSecondary)
                        .frame(width: 140, alignment: .leading)

                    Text("照片 A")
                        .font(Theme.bodyFont(11, weight: .semibold))
                        .foregroundColor(Theme.labelSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Text("照片 B")
                        .font(Theme.bodyFont(11, weight: .semibold))
                        .foregroundColor(Theme.labelSecondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Theme.parchment.opacity(0.8))

                Divider().overlay(Theme.separator.opacity(0.4))

                // 行列表
                if let rows = comparison?.diffRows {
                    ForEach(rows) { row in
                        diffRowView(row)
                        if row.id != rows.last?.id {
                            Divider().overlay(Theme.separator.opacity(0.2))
                        }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 0.5)
            )
        }
        .padding(12)
        .macCard(cornerRadius: Theme.radiusMd)
    }

    private func diffRowView(_ row: PhotoDiffRow) -> some View {
        HStack(spacing: 0) {
            // 参数名
            HStack(spacing: 6) {
                Image(systemName: row.icon)
                    .font(.system(size: 11))
                    .foregroundColor(Theme.labelTertiary)
                    .frame(width: 14)
                Text(row.label)
                    .font(Theme.bodyFont(11, weight: .medium))
                    .foregroundColor(Theme.labelPrimary)
            }
            .frame(width: 140, alignment: .leading)

            // 照片 A
            HStack(spacing: 6) {
                Text(row.valA)
                    .font(Theme.bodyFont(11))
                    .foregroundColor(row.winner == .left ? Color.purple : Theme.labelPrimary)

                if row.winner == .left, let hint = row.hint {
                    Text(hint)
                        .font(Theme.bodyFont(9, weight: .semibold))
                        .foregroundColor(Color.purple)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.purple.opacity(0.12)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(row.winner == .left ? Color.purple.opacity(0.04) : Color.clear)

            // 照片 B
            HStack(spacing: 6) {
                Text(row.valB)
                    .font(Theme.bodyFont(11))
                    .foregroundColor(row.winner == .right ? Color.purple : Theme.labelPrimary)

                if row.winner == .right, let hint = row.hint {
                    Text(hint)
                        .font(Theme.bodyFont(9, weight: .semibold))
                        .foregroundColor(Color.purple)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.purple.opacity(0.12)))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 6)
            .padding(.horizontal, 6)
            .background(row.winner == .right ? Color.purple.opacity(0.04) : Color.clear)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
    }

    // MARK: - 底部控制与快捷键说明
    private var footerView: some View {
        HStack(spacing: 12) {
            Text("快捷键：[1] 或 [←] 保留左图 · [2] 或 [→] 保留右图 · [0] 均保留 · [Esc] 关闭")
                .font(Theme.monoFont(10))
                .foregroundColor(Theme.labelTertiary)

            Spacer()

            Button {
                keepBoth()
            } label: {
                Text("两张均保留")
                    .font(Theme.bodyFont(11))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            if let itemA = currentItemA {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: itemA.path)])
                } label: {
                    Label("在访达中显示", systemImage: "folder")
                        .font(Theme.bodyFont(11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.parchment)
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
