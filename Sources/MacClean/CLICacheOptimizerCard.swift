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
    @State private var bannerIsWarning: Bool = false
    @State private var gateNotes: [String] = []
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
            if !summary.unrecognizedTools.isEmpty || !gateNotes.isEmpty {
                gateNotesPanel
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
            Text("将把选中缓存目录的**直接子项**逐条提交统一删除网关裁决（缓存根目录本身保留）。关键配置文件（.npmrc / .zshrc / config.toml / settings.json 等）按子项路径校验后拒绝清理；工具数据目录（如 ~/.npm）一律不清空。")
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
            metricItem(title: "发现工具数", value: "\(summary.toolCount)", detail: "已扫描 \(CLIToolKind.allCases.count) 类工具", color: Ink.primary)
            Divider().frame(height: 28)
            metricItem(title: "缓存总占用", value: summary.totalSize.byteStringCN, detail: "\(summary.items.reduce(0) { $0 + $1.fileCount }) 个文件", color: summary.totalSize > 1_000_000_000 ? Signal.caution : Ink.secondary)
            Divider().frame(height: 28)
            metricItem(title: "可释放潜力", value: selectedSize.byteStringCN, detail: "已勾选 \(selectedCount) 项", color: selectedSize > 0 ? Signal.positive : Ink.secondary)
            Divider().frame(height: 28)
            metricItem(title: "位置未识别", value: "\(summary.unrecognizedTools.count) 类", detail: "只报不删", color: summary.unrecognizedTools.isEmpty ? Ink.tertiary : Signal.caution)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
        .background(Surface.sunken)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    /// 网关拦下的原因 + "该工具缓存位置未识别"的如实说明
    private var gateNotesPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
            if !summary.unrecognizedTools.isEmpty {
                HStack(alignment: .top, spacing: Space.xs) {
                    Image(systemName: "questionmark.folder")
                        .font(.system(size: 10))
                        .foregroundStyle(Signal.caution)
                    Text("该工具缓存位置未识别：\(summary.unrecognizedTools.map { $0.rawValue }.joined(separator: "、"))。"
                         + "本工具不会退化成清空它们的工具目录，请用官方命令清理（点条目上的命令可复制）。")
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
            ForEach(Array(gateNotes.enumerated()), id: \.offset) { _, note in
                HStack(alignment: .top, spacing: Space.xs) {
                    Image(systemName: "shield.lefthalf.filled")
                        .font(.system(size: 10))
                        .foregroundStyle(Signal.caution)
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                }
            }
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 5)
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
            Image(systemName: bannerIsWarning ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(bannerIsWarning ? Signal.caution : Signal.positive)
            Text(message)
                .font(Typo.caption)
                .foregroundStyle(Ink.primary)
            Spacer()
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 6)
        .background((bannerIsWarning ? Signal.caution : Signal.positive).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    // MARK: - 子组件：操作底栏

    private var actionFooterBar: some View {
        HStack(spacing: Space.sm) {
            Button(selectedCount == selectableCount && selectableCount > 0 ? "取消全选" : "全部选中") {
                toggleSelectAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(summary.items.isEmpty || isCleaning || selectableCount == 0)

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
        let target = selectedCount != selectableCount
        for i in 0..<summary.items.count {
            // 全选只勾"本轮真的读全了"的项——`readable == false` 的那一项 size 只是下限，
            // 用户点一次全选就把它翻回默认勾选，等于绕过 scan 阶段那道闸（v1.73.7 复审 P1-1）。
            summary.items[i].isSelected = target && summary.items[i].readable
        }
    }

    /// 全选作用域：只统计"可以安全默认勾选"的项。用 `summary.items.count` 会让
    /// 存在残缺项时按钮永远显示"全部选中"——即使所有可读项已被勾上，用户也点不到
    /// "取消全选"（因为 selectedCount 永远达不到 items.count）。
    private var selectableCount: Int { summary.items.filter(\.readable).count }

    private func executeClean(toTrash: Bool) {
        isCleaning = true
        gateNotes = []
        let targets = summary.items.filter(\.isSelected)

        DispatchQueue.global(qos: .userInitiated).async {
            let res = CLICacheScanner.shared.clean(items: targets, toTrash: toTrash)
            let notes = Self.explanationNotes(from: res)
            let blocked = res.errorCount

            DispatchQueue.main.async {
                self.isCleaning = false
                self.gateNotes = notes
                self.bannerIsWarning = (res.cleanedCount == 0 && blocked > 0)
                let mode = toTrash ? "移入废纸篓" : "彻底清空"
                self.bannerFeedback = res.cleanedCount == 0
                    ? "未清理任何缓存子项（\(blocked) 项被拦或失败）：\(notes.joined(separator: "；"))"
                    : "已安全\(mode) \(res.cleanedCount) 项缓存子项，释放 \(res.freedBytes.byteStringCN)（删除前实测）"
                    + (blocked > 0 ? "；另有 \(blocked) 项未通过网关" : "")
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }

    /// 网关/判据拦下的原因，逐条如实呈现
    static func explanationNotes(from outcome: ResidueDeletionGate.Outcome) -> [String] {
        var notes: [String] = []
        for priv in outcome.needsPrivilege {
            notes.append("「\(priv.name)」未清理：该位置由 root 管理，本工具不提权")
        }
        for rejection in outcome.rejected where rejection.reason != .needsPrivilege {
            notes.append("「\(rejection.name)」未清理：\(rejection.message)")
        }
        for failure in outcome.failed {
            notes.append("「\(failure.name)」清理失败：\(failure.message)")
        }
        return Array(notes.prefix(6))
    }
}
