import SwiftUI
import AppKit

// MARK: - Spotlight 废弃索引与搜索数据库深度重建治理卡片 (v1.69.0)

public struct SpotlightOptimizerCard: View {
    public var onClose: () -> Void
    public var onTriggerClean: (() -> Void)?

    @State private var summary: SpotlightSummary = SpotlightSummary()
    @State private var isScanning: Bool = false
    @State private var isCleaning: Bool = false
    @State private var isRebuilding: Bool = false
    @State private var bannerFeedback: String? = nil
    @State private var bannerIsWarning: Bool = false
    @State private var showConfirmClean: Bool = false
    @State private var showConfirmRebuild: Bool = false
    @State private var showOrphansOnly: Bool = true

    public init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
    }

    private var displayedItems: [SpotlightStoreItem] {
        if showOrphansOnly {
            // "需确认"项一并显示：它们可能正是残留，只是证据不足，必须让用户看见
            return summary.items.filter { $0.status.isOrphanOrCorrupted || $0.status == .needsConfirmation }
        }
        return summary.items
    }

    private var selectedCount: Int {
        displayedItems.filter(\.isSelected).count
    }

    /// 全选作用域：孤儿/损坏 **且** 本轮真的读全了（`readable == true`）的项。
    /// 之前 disabled 只看孤儿数、label 是常量「全选」——当孤儿项全被权限掐断时，
    /// 按钮可点但点了什么都不发生（v1.73.7 二次复审 P1-E）。
    private var selectableCount: Int {
        displayedItems.filter { $0.status.isOrphanOrCorrupted && $0.readable }.count
    }

    private var selectedSize: Int64 {
        displayedItems.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            topHeader
            metricsSummaryBar

            // 「读不到」必须显式说出来，绝不能被渲染成"没有残留"
            if let incomplete = summary.incompletenessBanner {
                warningBanner(incomplete)
            }

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
        .confirmationDialog("确认清理选中的 Spotlight 索引与缓存", isPresented: $showConfirmClean, titleVisibility: .visible) {
            Button("安全移入废纸篓", role: .destructive) {
                executeClean(toTrash: true)
            }
            Button("彻底删除", role: .destructive) {
                executeClean(toTrash: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清理选中的 \(selectedCount) 项索引数据（\(selectedSize.byteStringCN)）。"
                 + "系统核心索引、卷索引与证据不足的条目不会被删除；删除请求仍会经统一安全网关复核，"
                 + "无权限或受保护的条目会如实报告为失败。")
        }
        .confirmationDialog(rebuildDialogTitle, isPresented: $showConfirmRebuild, titleVisibility: .visible) {
            Button("确认重建（\(rebuildTargets.count) 个卷）", role: .destructive) {
                executeRebuild(of: rebuildTargets)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(rebuildConsequenceText)
        }
    }

    // MARK: - 索引重建目标（只认用户显式勾选的卷）

    /// 用户逐卷勾选后要重建的卷。**没有任何隐式默认**：一个都没勾 → 空数组 → 不执行。
    private var rebuildTargets: [SpotlightStoreItem] {
        summary.volumesSelectedForRebuild
    }

    private var rebuildDialogTitle: String {
        rebuildTargets.isEmpty
            ? "未勾选任何卷"
            : "确认重建 \(rebuildTargets.count) 个卷的 Spotlight 索引？"
    }

    /// 后果必须写清：这是本卡片唯一会改动系统状态的操作。
    private var rebuildConsequenceText: String {
        let names = rebuildTargets.map { $0.path }.joined(separator: "\n")
        return "将对以下卷逐条执行 mdutil -E：\n\(names)\n\n"
            + "后果：重建会先**清空该卷现有搜索数据库**，重建期间 Spotlight 搜索无结果或明显变慢；"
            + "大容量卷（数百 GB 以上）可能耗时数十分钟甚至更久，期间 CPU 与磁盘占用升高。"
            + "无管理员权限的卷会直接失败，MacClean 不做提权。"
    }

    // MARK: - 顶部栏

    private var topHeader: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "magnifyingglass", size: 15, weight: .semibold, color: Accent.tint, width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("Spotlight 废弃索引与搜索数据库深度重建")
                    .font(Typo.title)
                    .foregroundStyle(Ink.primary)
                Text("排查已卸载应用 CoreSpotlight 索引残留与搜索临时缓存，支持一键安全重建索引以解决搜索卡顿与高 CPU 占用")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
            }

            Spacer()

            Toggle("仅看残留", isOn: $showOrphansOnly)
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
            .disabled(isScanning || isCleaning || isRebuilding)

            Button {
                onClose()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Ink.secondary)
            }
            .buttonStyle(.plain)
            .padding(.leading, Space.xs)
        }
    }

    // MARK: - 指标概览栏

    private var metricsSummaryBar: some View {
        HStack(spacing: Space.md) {
            metricBlock(title: "总索引体积", value: summary.totalSize.byteStringCN, color: Ink.primary)
            Divider().frame(height: 20)
            metricBlock(title: "孤儿/缓存残留", value: "\(summary.orphanSize.byteStringCN) (\(summary.orphanCount)项)", color: Accent.tint)
            Divider().frame(height: 20)
            metricBlock(title: "活动受保护项", value: "\(summary.activeCount) 项", color: Signal.positive)
            Divider().frame(height: 20)
            metricBlock(title: "证据不足待确认",
                        value: "\(summary.needsConfirmationCount) 项",
                        color: summary.needsConfirmationCount > 0 ? Signal.caution : Ink.tertiary)
            Divider().frame(height: 20)
            metricBlock(title: "已选待释放", value: selectedSize.byteStringCN, color: selectedSize > 0 ? Signal.caution : Ink.tertiary)
            Spacer()
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 6)
        .background(Surface.sunken)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func metricBlock(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Typo.micro)
                .foregroundStyle(Ink.tertiary)
            Text(value)
                .font(Typo.rowStrong)
                .foregroundStyle(color)
        }
    }

    // MARK: - 提示栏

    private func bannerBar(_ message: String) -> some View {
        bannerBar(message, icon: "info.circle.fill",
                  tint: bannerIsWarning ? Signal.caution : Accent.tint)
    }

    /// 不完整结果专用告警条：不可关闭掉"不完整"这个事实的语义
    private func warningBanner(_ message: String) -> some View {
        bannerBar(message, icon: "exclamationmark.triangle.fill", tint: Signal.caution)
    }

    private func bannerBar(_ message: String, icon: String, tint: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(tint)
            Text(message)
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button {
                withAnimation { bannerFeedback = nil }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.tertiary)
            }
            .buttonStyle(.plain)
        }
        .padding(8)
        .background(Surface.sunken)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    // MARK: - 列表展示区

    private var contentListContainer: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if displayedItems.isEmpty {
                    VStack(spacing: 6) {
                        // 结果不完整时**绝不**显示"未发现残留"这种结论
                        if !summary.isResultComplete {
                            Image(systemName: "questionmark.folder.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(Signal.caution)
                            Text("有位置没读到，无法判断是否存在残留")
                                .font(Typo.caption)
                                .foregroundStyle(Ink.secondary)
                        } else {
                            Image(systemName: "checkmark.seal.fill")
                                .font(.system(size: 28))
                                .foregroundStyle(Signal.positive)
                            Text(showOrphansOnly ? "未发现已卸载应用残留的 CoreSpotlight 索引或废弃缓存" : "未发现任何 Spotlight 存储库")
                                .font(Typo.caption)
                                .foregroundStyle(Ink.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Space.lg)
                } else {
                    ForEach(displayedItems) { item in
                        itemRow(item)
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 220)
    }

    private func itemRow(_ item: SpotlightStoreItem) -> some View {
        HStack(spacing: Space.xs) {
            if item.status.isOrphanOrCorrupted {
                Toggle("", isOn: Binding(
                    get: { item.isSelected },
                    set: { val in toggleItem(item.id, selected: val) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
            } else if item.kind == .volumeIndex {
                // 卷索引只能靠 mdutil 重建，且**必须由用户逐卷显式勾选**
                Toggle("", isOn: Binding(
                    get: { item.isSelectedForRebuild },
                    set: { val in toggleRebuild(item.id, selected: val) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
                .help("勾选后才会对该卷执行 mdutil -E；不勾选则永远不碰这个卷")
            } else {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Signal.positive)
                    .frame(width: 16)
            }

            Image(systemName: item.kind.icon)
                .font(.system(size: 13))
                .foregroundStyle(Accent.tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name)
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    statusBadge(item.status)
                }

                Text(item.path)
                    .font(Typo.micro)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let note = item.note {
                    Text(note)
                        .font(Typo.micro)
                        .foregroundStyle(Signal.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.size.byteStringCN)
                    .font(Typo.rowStrong)
                    .foregroundStyle(Ink.primary)
                Text(item.status == .needsConfirmation && item.size == 0
                     ? "未读到内容"
                     : "\(item.fileCount) 个文件")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.tertiary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(item.isSelected ? Accent.tint.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func statusBadge(_ status: SpotlightIndexStatus) -> some View {
        let (title, bg, fg): (String, Color, Color) = {
            switch status {
            case .activeHealthy:
                return ("在用应用", Signal.positive.opacity(0.12), Signal.positive)
            case .orphanAppResidue:
                return ("已卸载残留", Signal.caution.opacity(0.12), Signal.caution)
            case .bloatedOrCorrupted:
                return ("建议清理", Accent.tint.opacity(0.12), Accent.tint)
            case .systemProtected:
                return ("系统保护", Color.blue.opacity(0.12), Color.blue)
            case .needsConfirmation:
                return ("需确认", Signal.caution.opacity(0.12), Signal.caution)
            }
        }()

        return Text(title)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(bg)
            .foregroundStyle(fg)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    // MARK: - 底部操作栏

    private var actionFooterBar: some View {
        HStack(spacing: Space.xs) {
            Button(selectedCount == selectableCount && selectableCount > 0 ? "取消全选" : "全选") {
                selectAll(!(selectedCount == selectableCount && selectableCount > 0))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectableCount == 0)

            Button("全不选") {
                selectAll(false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedCount == 0)

            Spacer()

            Button {
                guard !rebuildTargets.isEmpty else {
                    bannerIsWarning = true
                    bannerFeedback = "没有勾选任何卷，未执行 mdutil -E。索引重建只对**你逐卷勾选**的卷生效。"
                    return
                }
                showConfirmRebuild = true
            } label: {
                HStack(spacing: 4) {
                    if isRebuilding {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("重建勾选的卷索引 (\(rebuildTargets.count))")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isScanning || isCleaning || isRebuilding)
            .help("仅对你逐卷勾选的卷执行 mdutil -E；未勾选的卷一律不动")

            Button(role: .destructive) {
                showConfirmClean = true
            } label: {
                HStack(spacing: 4) {
                    if isCleaning {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "trash")
                    }
                    Text("清理选中 (\(selectedSize.byteStringCN))")
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
            .disabled(selectedCount == 0 || isScanning || isCleaning || isRebuilding)
        }
    }

    // MARK: - 逻辑处理

    private func loadData() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = SpotlightScanner.shared.scan()
            DispatchQueue.main.async {
                self.summary = res
                self.isScanning = false
            }
        }
    }

    private func toggleItem(_ id: String, selected: Bool) {
        if let idx = summary.items.firstIndex(where: { $0.id == id }) {
            summary.items[idx].isSelected = selected
        }
    }

    /// 逐卷勾选重建目标（默认全不勾）
    private func toggleRebuild(_ id: String, selected: Bool) {
        if let idx = summary.items.firstIndex(where: { $0.id == id }) {
            summary.items[idx].isSelectedForRebuild = selected
        }
    }

    private func selectAll(_ select: Bool) {
        for i in 0..<summary.items.count {
            if summary.items[i].status.isOrphanOrCorrupted {
                // 残缺项不能被全选重新勾上（v1.73.7 复审 P1-1）：scan 阶段 `isSelected: isOrphan && readable`
                // 只是把默认关到位，用户点一次全选就得走同一道闸。
                summary.items[i].isSelected = select && summary.items[i].readable
            }
        }
    }

    private func executeClean(toTrash: Bool) {
        guard !isCleaning else { return }
        isCleaning = true
        let targets = summary.items.filter { $0.isSelected && $0.status.isOrphanOrCorrupted }

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = SpotlightScanner.shared.cleanOutcome(items: targets, toTrash: toTrash)
            let rejected = outcome.rejected.map { "\($0.name)：\($0.message)" }
            let failed = outcome.failed.map { "\($0.name)：\($0.message)" }
            DispatchQueue.main.async {
                self.isCleaning = false
                var lines: [String] = []
                lines.append("成功清理 \(outcome.cleanedCount) 项数据，实测释放 \(outcome.freedBytes.byteStringCN)")
                lines.append(contentsOf: rejected + failed)
                self.bannerIsWarning = !rejected.isEmpty || !failed.isEmpty || outcome.cleanedCount == 0
                self.bannerFeedback = lines.joined(separator: "\n")
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }

    /// 只对**用户显式勾选**的卷逐条执行 mdutil -E，并按真实退出码汇报。
    private func executeRebuild(of volumes: [SpotlightStoreItem]) {
        guard !isRebuilding else { return }
        guard !volumes.isEmpty else { return }
        isRebuilding = true

        DispatchQueue.global(qos: .userInitiated).async {
            var lines: [String] = []
            for volume in volumes {
                let result = SpotlightScanner.shared.rebuildVolumeIndex(volumePath: volume.path)
                lines.append("\(volume.path) — \(result.message)")
            }
            DispatchQueue.main.async {
                self.isRebuilding = false
                self.bannerIsWarning = lines.contains { $0.contains("未成功") || $0.contains("超时") || $0.contains("找不到") }
                self.bannerFeedback = lines.joined(separator: "\n")
                // 重建指令已发出 → 勾选状态清空，避免同一卷被重复触发
                for i in 0..<self.summary.items.count where self.summary.items[i].kind == .volumeIndex {
                    self.summary.items[i].isSelectedForRebuild = false
                }
            }
        }
    }
}
