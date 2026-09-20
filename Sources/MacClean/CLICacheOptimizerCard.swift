import SwiftUI
import AppKit

// MARK: - 终端与命令行开发缓存治理微面板卡片 (v1.65.0)

public struct CLICacheOptimizerCard: View {
    public var onClose: () -> Void
    public var onTriggerClean: (() -> Void)?

    @State private var summary: CLICacheSummary = CLICacheSummary()
    @State private var isScanning: Bool = false
    @State private var isCleaning: Bool = false
    @State private var bannerFeedback: String? = nil
    @State private var showConfirmClean: Bool = false

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
        .confirmationDialog("确认清空选中的命令行工具缓存", isPresented: $showConfirmClean, titleVisibility: .visible) {
            Button("安全移入废纸篓", role: .destructive) {
                executeClean(toTrash: true)
            }
            Button("彻底删除", role: .destructive) {
                executeClean(toTrash: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清空选中的 \(selectedCount) 项开发工具缓存（\(selectedSize.byteStringCN)）。仅清理缓存文件，绝对不影响工程源码和全局配置文件。")
        }
    }

    // MARK: - 子组件：顶部栏

    private var topHeader: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "terminal.fill", size: 15, weight: .semibold, color: Accent.tint, width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("终端与命令行开发缓存治理")
                    .font(Typo.title)
                    .foregroundStyle(Ink.primary)
                Text("深度排查 Homebrew、npm、pnpm、yarn、Cargo、pip、Gradle 等工具的下载与包缓存")
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
            .disabled(isScanning || isCleaning)

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
            metricItem(title: "发现工具数", value: "\(summary.toolCount)", detail: "已扫描 8 类工具", color: Ink.primary)
            Divider().frame(height: 28)
            metricItem(title: "缓存总占用", value: summary.totalSize.byteStringCN, detail: "\(summary.items.reduce(0) { $0 + $1.fileCount }) 个文件", color: summary.totalSize > 1_000_000_000 ? Signal.caution : Ink.secondary)
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
                        Text("正在排查常用命令行工具缓存目录…")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                        Spacer()
                    }
                    .padding(.vertical, Space.lg)
                } else if summary.items.isEmpty {
                    Text("未发现命令行工具缓存（系统非常干净）")
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

                            Image(systemName: item.toolKind.icon)
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

                                HStack(spacing: Space.xs) {
                                    Text(item.path)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Ink.quaternary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)

                                    Text("·")
                                        .font(Typo.caption)
                                        .foregroundStyle(Ink.quaternary)

                                    Button {
                                        NSPasteboard.general.clearContents()
                                        NSPasteboard.general.setString(item.toolKind.commandSuggestion, forType: .string)
                                        bannerFeedback = "已复制 CLI 命令：\(item.toolKind.commandSuggestion)"
                                    } label: {
                                        Text(item.toolKind.commandSuggestion)
                                            .font(.system(size: 10, design: .monospaced))
                                            .foregroundStyle(Accent.tint)
                                            .underline()
                                    }
                                    .buttonStyle(.plain)
                                    .help("点击复制推荐清理命令")
                                }
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
        .frame(minHeight: 180, maxHeight: 260)
    }

    // MARK: - 子组件：反馈条

    private func bannerBar(_ message: String) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Signal.positive)
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
            .disabled(summary.items.isEmpty || isCleaning)

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
                showConfirmClean = true
            } label: {
                Label("一键安全清理", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(selectedCount == 0 || isCleaning)
        }
        .padding(.top, 4)
    }

    // MARK: - 逻辑方法

    private func loadData() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = CLICacheScanner.shared.scan()
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

    private func executeClean(toTrash: Bool) {
        isCleaning = true
        let targets = summary.items.filter(\.isSelected)

        DispatchQueue.global(qos: .userInitiated).async {
            let res = CLICacheScanner.shared.clean(items: targets, toTrash: toTrash)
            DispatchQueue.main.async {
                self.isCleaning = false
                let mode = toTrash ? "移入废纸篓" : "彻底清空"
                self.bannerFeedback = "已安全\(mode) \(res.cleanedCount) 项命令行缓存，释放 \(res.freedBytes.byteStringCN)"
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }
}
