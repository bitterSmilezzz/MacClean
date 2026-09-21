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
    @State private var bannerIsWarning: Bool = false
    @State private var gateNotes: [String] = []
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
            if !gateNotes.isEmpty {
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
        .confirmationDialog("确认清理选中的死链自启项", isPresented: $showConfirmClean, titleVisibility: .visible) {
            Button("安全移入废纸篓（删除成功后才卸载）", role: .destructive) {
                executeClean(toTrash: true)
            }
            Button("彻底删除（删除成功后才卸载）", role: .destructive) {
                executeClean(toTrash: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将移除选中的 \(selectedCount) 个死链自启项（目标应用程序均已卸载）。顺序是先删除配置、删除成功的那一项才向 launchd 卸载；删除被拦或失败的项目**完全不碰 launchd**，因此从废纸篓还原后仍然是可用状态。")
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
            Divider().frame(height: 28)
            metricItem(title: "证据不足", value: "\(summary.needsReviewCount)", detail: "需确认", color: summary.needsReviewCount > 0 ? Signal.caution : Ink.tertiary)
            Divider().frame(height: 28)
            metricItem(title: "root 托管", value: "\(summary.rootManagedCount)", detail: "本工具不提权", color: summary.rootManagedCount > 0 ? Signal.caution : Ink.tertiary)
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

    private func statusTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(Typo.micro)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    /// 网关与被拦项的真实原因（含"该位置由 root 管理，本工具不提权"）
    private var gateNotesPanel: some View {
        VStack(alignment: .leading, spacing: 2) {
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
                                        statusTag("死链残留", color: Signal.caution)
                                    } else if item.issue == .appleManaged {
                                        statusTag("Apple 官方", color: Signal.positive)
                                    } else if item.issue == .needsReview {
                                        statusTag("需确认", color: Signal.caution)
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

                                if let note = item.note {
                                    Text(note)
                                        .font(Typo.caption)
                                        .foregroundStyle(Ink.tertiary)
                                        .lineLimit(2)
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
            let showable = showOrphansOnly ? summary.items[i].issue.isOrphan : true
            // 只勾"有死链判据且位置删得动"的项；root 托管位置预选等于给个注定失败的勾
            guard showable, summary.items[i].issue.providesDeletionEvidence,
                  LoginItemCleaner.governanceDomain(forPath: summary.items[i].path) == nil else {
                if target { summary.items[i].isSelected = false }
                continue
            }
            summary.items[i].isSelected = target
        }
    }

    private func executeClean(toTrash: Bool) {
        isCleaning = true
        gateNotes = []
        let targets = displayedItems.filter(\.isSelected)

        DispatchQueue.global(qos: .userInitiated).async {
            let res = LoginItemCleaner.shared.clean(items: targets, toTrash: toTrash)
            let notes = LoginItemCleanerCard.explanationNotes(from: res)
            let cleaned = res.cleanedCount
            let blocked = res.errorCount

            DispatchQueue.main.async {
                self.isCleaning = false
                self.gateNotes = notes
                self.bannerIsWarning = (cleaned == 0 && blocked > 0) || !notes.isEmpty
                let mode = toTrash ? "移入废纸篓" : "彻底删除"
                self.bannerFeedback = cleaned == 0
                    ? "未删除任何自启配置（\(blocked) 项被拒或失败）：\(notes.joined(separator: "；"))"
                    : "已\(mode) \(cleaned) 项死链自启动配置，并按需向 launchd 卸载"
                    + (blocked > 0 ? "；另有 \(blocked) 项未通过网关" : "")
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }

    /// 把网关拦截项与 launchd 卸载失败整理成给用户看的条目
    static func explanationNotes(from outcome: LoginItemCleaner.LoginItemCleanOutcome) -> [String] {
        var notes: [String] = []
        for priv in outcome.needsPrivilege {
            notes.append("「\(priv.name)」未删除：该位置由 root 管理，本工具不提权")
        }
        for rejection in outcome.gate.rejected where rejection.reason != .needsPrivilege {
            notes.append("「\(rejection.name)」未删除：\(rejection.message)")
        }
        for failure in outcome.gate.failed {
            notes.append("「\(failure.name)」删除失败：\(failure.message)（未向 launchd 卸载）")
        }
        notes.append(contentsOf: outcome.unloadWarnings)
        return Array(notes.prefix(6))
    }
}
