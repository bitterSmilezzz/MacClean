import SwiftUI
import AppKit

// MARK: - 访达快速查看缩略图缓存释放微面板卡片 (v1.66.0)

public struct QuickLookThumbnailPurgerCard: View {
    public var onClose: () -> Void
    public var onTriggerClean: (() -> Void)?

    @State private var summary: QuickLookThumbnailSummary = QuickLookThumbnailSummary()
    @State private var isScanning: Bool = false
    @State private var isPurging: Bool = false
    @State private var bannerFeedback: String? = nil
    @State private var showConfirmPurge: Bool = false

    public init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
    }

    private var selectedCount: Int {
        summary.items.filter(\.isSelected).count
    }

    private var selectedSize: Int64 {
        summary.items.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            topHeader
            metricsSummaryBar

            if let feedback = bannerFeedback {
                bannerBar(feedback)
            }

            contentListContainer
            actionFooterBar
        }
        .padding(Space.md)
        .background(Surface.group)
        .clipShape(RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
        .onAppear {
            loadData()
        }
        .confirmationDialog("确认重置并释放 QuickLook 缩略图缓存", isPresented: $showConfirmPurge, titleVisibility: .visible) {
            Button("彻底释放并重置系统缩略图缓存", role: .destructive) {
                executePurge()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空选中的 \(selectedCount) 项快速查看缓存（\(selectedSize.byteStringCN)），并调用系统官方 qlmanage 重置缩略图索引。后续浏览文件时系统将按需自动重建。")
        }
    }

    // MARK: - 子组件：顶部栏

    private var topHeader: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "photo.stack.fill", size: 15, weight: .semibold, color: Accent.tint, width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("访达快速查看（QuickLook）缩略图缓存释放")
                    .font(Typo.title)
                    .foregroundStyle(Ink.primary)
                Text("深潜排查系统级缩略图数据库与扩展渲染缓存，修复卡顿并释放大量磁盘空间")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
            }

            Spacer()

            Button {
                loadData()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isScanning || isPurging)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: - 子组件：指标面板

    private var metricsSummaryBar: some View {
        HStack(spacing: Space.sm) {
            metricItem(title: "发现缓存项", value: "\(summary.items.count)", detail: "系统与用户缓存", color: Ink.primary)
            Divider().frame(height: 28)
            metricItem(title: "缓存总占用", value: summary.totalSize.byteStringCN, detail: "\(summary.items.reduce(0) { $0 + $1.fileCount }) 个文件", color: summary.totalSize > 500_000_000 ? Signal.caution : Ink.secondary)
            Divider().frame(height: 28)
            metricItem(title: "可释放潜力", value: selectedSize.byteStringCN, detail: "已勾选 \(selectedCount) 项", color: selectedSize > 0 ? Signal.positive : Ink.secondary)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(Surface.sunken)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func metricItem(title: String, value: String, detail: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(Typo.micro)
                .foregroundStyle(Ink.quaternary)
            HStack(spacing: 4) {
                Text(value)
                    .font(.mcNumeric(13, weight: .semibold))
                    .foregroundStyle(color)
                Text("(\(detail))")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 子组件：列表容器

    private var contentListContainer: some View {
        ScrollView {
            VStack(spacing: 2) {
                if isScanning {
                    HStack {
                        Spacer()
                        ProgressView()
                            .controlSize(.small)
                        Text("正在探测系统 QuickLook 缩略图数据库…")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                        Spacer()
                    }
                    .padding(.vertical, Space.lg)
                } else if summary.items.isEmpty {
                    Text("未发现可清理的 QuickLook 缩略图缓存（数据库极小或已重置）")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.vertical, Space.lg)
                } else {
                    ForEach(summary.items) { item in
                        HStack(spacing: Space.sm) {
                            Button(action: {
                                toggleItemSelection(id: item.id)
                            }) {
                                Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                                    .font(.system(size: 13))
                                    .foregroundStyle(item.isSelected ? Accent.tint : Ink.tertiary)
                            }
                            .buttonStyle(.plain)

                            Image(systemName: item.kind.icon)
                                .font(.system(size: 14))
                                .foregroundStyle(Accent.tint)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Space.xs) {
                                    Text(item.title)
                                        .font(Typo.rowStrong)
                                        .foregroundStyle(Ink.primary)

                                    Text("\(item.fileCount) 个文件")
                                        .font(.mcNumeric(10))
                                        .foregroundStyle(Ink.tertiary)
                                }

                                Text(item.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Ink.quaternary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }

                            Spacer()

                            Text(item.size.byteStringCN)
                                .font(.mcNumeric(12, weight: .medium))
                                .foregroundStyle(Ink.primary)

                            Button {
                                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                            } label: {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help("在访达中显示")
                        }
                        .padding(.horizontal, Space.sm)
                        .padding(.vertical, 6)
                        .background(Surface.raised)
                        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(minHeight: 160, maxHeight: 240)
    }

    // MARK: - 子组件：反馈条

    private func bannerBar(_ message: String) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: message.contains("未重置") || message.contains("拦下")
                  ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(message.contains("未重置") || message.contains("拦下")
                                 ? Signal.caution : Signal.positive)
            Text(message)
                .font(Typo.caption)
                .foregroundStyle(Ink.primary)
            Spacer()
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 6)
        .background(Signal.positive.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    // MARK: - 子组件：操作底栏

    private var actionFooterBar: some View {
        HStack(spacing: Space.sm) {
            Button(selectedCount == summary.items.count ? "取消全选" : "全部选中") {
                toggleSelectAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(summary.items.isEmpty || isPurging)

            Spacer()

            VStack(alignment: .trailing, spacing: 0) {
                Text("已选 \(selectedCount) 项")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                Text(selectedSize.byteStringCN)
                    .font(.mcNumeric(15, weight: .semibold))
                    .foregroundStyle(Ink.primary)
            }

            Button {
                showConfirmPurge = true
            } label: {
                Label("重置并释放缓存", systemImage: "arrow.triangle.2.circlepath")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(selectedCount == 0 || isPurging)
        }
        .padding(.top, 4)
    }

    // MARK: - 逻辑方法

    private func loadData() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = QuickLookThumbnailPurger.shared.scan()
            DispatchQueue.main.async {
                self.summary = res
                self.isScanning = false
            }
        }
    }

    private func toggleItemSelection(id: String) {
        guard let idx = summary.items.firstIndex(where: { $0.id == id }) else { return }
        summary.items[idx].isSelected.toggle()
    }

    private func toggleSelectAll() {
        let target = selectedCount != summary.items.count
        for i in 0..<summary.items.count {
            summary.items[i].isSelected = target
        }
    }

    private func executePurge() {
        isPurging = true
        let targets = summary.items.filter(\.isSelected)

        DispatchQueue.global(qos: .userInitiated).async {
            let res = QuickLookThumbnailPurger.shared.purge(items: targets, resetSystemCache: true)
            DispatchQueue.main.async {
                self.isPurging = false
                self.bannerFeedback = Self.feedback(for: res)
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }

    /// 播报只说**有证据**的事实：删除量取删除前实测，系统索引是否重置单独交代。
    static func feedback(for res: QuickLookPurgeResult) -> String {
        var text = "已释放 \(res.purgedCount) 项缩略图缓存（\(res.freedBytes.byteStringCN)）"
        if res.systemCacheReset {
            text += "，系统 QuickLook 索引已重置"
        } else if let failure = res.systemResetFailure {
            text += "，但系统缩略图索引**未重置**：\(failure)"
        }
        if res.errorCount > 0 {
            text += "；\(res.errorCount) 项被安全护栏拦下或删除失败"
        }
        return text
    }
}
