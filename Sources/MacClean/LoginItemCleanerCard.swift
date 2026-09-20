import SwiftUI
import AppKit

// MARK: - 已卸载应用登录项与自启残存治理卡片 (v1.67.0)

public struct LoginItemCleanerCard: View {
    public var onClose: (() -> Void)?
    public var onTriggerClean: (() -> Void)?

    @State private var summary: LoginItemSummary = LoginItemSummary()
    @State private var isScanning: Bool = false
    @State private var isCleaning: Bool = false
    @State private var bannerFeedback: String? = nil
    @State private var showConfirmClean: Bool = false
    @State private var showOrphansOnly: Bool = true

    public init(onClose: (() -> Void)? = nil, onTriggerClean: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
    }

    private var displayedItems: [LoginItemEntry] {
        if showOrphansOnly {
            return summary.items.filter { $0.issue.isOrphan }
        }
        return summary.items
    }

    private var selectedCount: Int {
        displayedItems.filter(\.isSelected).count
    }

    private var selectedSize: Int64 {
        displayedItems.filter(\.isSelected).reduce(0) { $0 + $1.size }
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
        .confirmationDialog("确认清理选中的死链自启项", isPresented: $showConfirmClean, titleVisibility: .visible) {
            Button("安全移入废纸篓并卸载", role: .destructive) {
                executeClean(toTrash: true)
            }
            Button("彻底删除并卸载", role: .destructive) {
                executeClean(toTrash: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将注销并移除选中的 \(selectedCount) 个死链自启项。这些启动项的目标应用程序均已被卸载，清理后可消除开机控制台报错。")
        }
    }

    // MARK: - 子组件：顶部栏

    private var topHeader: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "exclamationmark.triangle.fill", size: 15, weight: .semibold, color: Signal.caution, width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("已卸载应用登录项与自启死链治理")
                    .font(Typo.title)
                    .foregroundStyle(Ink.primary)
                Text("排查 LaunchAgents 与 LaunchDaemons 中宿主 App 已被删除的幽灵启动项，消除开机报错与资源空耗")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
            }

            Spacer()

            Toggle("仅看死链", isOn: $showOrphansOnly)
                .toggleStyle(.switch)
                .controlSize(.mini)

            Button {
                loadData()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isScanning || isCleaning)

            if let onClose = onClose {
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
    }

    // MARK: - 子组件：指标面板

    private var metricsSummaryBar: some View {
        HStack(spacing: Space.sm) {
            metricItem(title: "发现死链自启项", value: "\(summary.orphanCount)", detail: "宿主已卸载", color: summary.orphanCount > 0 ? Signal.caution : Signal.positive)
            Divider().frame(height: 28)
            metricItem(title: "扫描总启动项", value: "\(summary.items.count)", detail: "三大自启目录", color: Ink.primary)
            Divider().frame(height: 28)
            metricItem(title: "可清理项", value: "\(selectedCount) 项", detail: "已勾选", color: selectedCount > 0 ? Accent.tint : Ink.secondary)
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
                        Text("正在排查系统自启动配置与死链…")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                        Spacer()
                    }
                    .padding(.vertical, Space.lg)
                } else if displayedItems.isEmpty {
                    Text(showOrphansOnly ? "未发现死链自启动项（系统启动项健康）" : "未发现任何自启动项")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.vertical, Space.lg)
                } else {
                    ForEach(displayedItems) { item in
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
                                .foregroundStyle(item.issue.isOrphan ? Signal.caution : Accent.tint)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Space.xs) {
                                    Text(item.name)
                                        .font(Typo.rowStrong)
                                        .foregroundStyle(Ink.primary)

                                    if item.issue.isOrphan {
                                        Text("死链残留")
                                            .font(Typo.micro)
                                            .foregroundStyle(Signal.caution)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Signal.caution.opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                    }

                                    Text(item.kind.rawValue)
                                        .font(Typo.micro)
                                        .foregroundStyle(Ink.quaternary)
                                }

                                if let target = item.targetPath {
                                    Text("指向程序: \(target)")
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(item.issue.isOrphan ? Signal.caution : Ink.quaternary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                } else {
                                    Text(item.path)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Ink.quaternary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }

                            Spacer()

                            Button {
                                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                            } label: {
                                Image(systemName: "folder")
                                    .font(.system(size: 11))
                            }
                            .buttonStyle(.borderless)
                            .help("在访达中显示配置文件")
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
            Button(selectedCount == displayedItems.count ? "取消全选" : "全部选中") {
                toggleSelectAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(displayedItems.isEmpty || isCleaning)

            Spacer()

            Text("已选 \(selectedCount) 项")
                .font(Typo.caption)
                .foregroundStyle(Ink.tertiary)

            Button {
                showConfirmClean = true
            } label: {
                Label("安全清除死链", systemImage: "trash")
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
            let res = LoginItemCleaner.shared.scan()
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
        let target = selectedCount != displayedItems.count
        for i in 0..<summary.items.count {
            if showOrphansOnly {
                if summary.items[i].issue.isOrphan {
                    summary.items[i].isSelected = target
                }
            } else {
                summary.items[i].isSelected = target
            }
        }
    }

    private func executeClean(toTrash: Bool) {
        isCleaning = true
        let targets = displayedItems.filter(\.isSelected)

        DispatchQueue.global(qos: .userInitiated).async {
            let res = LoginItemCleaner.shared.clean(items: targets, toTrash: toTrash)
            DispatchQueue.main.async {
                self.isCleaning = false
                let mode = toTrash ? "移入废纸篓" : "彻底删除"
                self.bannerFeedback = "已成功注销并\(mode) \(res.cleanedCount) 项死链自启动配置"
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }
}
