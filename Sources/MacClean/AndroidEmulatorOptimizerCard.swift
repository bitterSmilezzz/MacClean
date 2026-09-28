import SwiftUI

// MARK: - Android 模拟器 AVD 与 SDK 镜像孤儿治理卡片 (v1.73.10)

public struct AndroidEmulatorOptimizerCard: View {
    public var onClose: () -> Void
    public var onTriggerClean: (() -> Void)?

    @State private var summary: AndroidEmulatorSummary = AndroidEmulatorSummary()
    @State private var isScanning: Bool = false
    @State private var isCleaning: Bool = false
    /// 本轮**有没有拿到过一次扫描结果**。没有它，界面刚起来时空清单会被渲染成「未发现孤儿 AVD」，
    /// 把"还没看"说成"看了、没有"（v1.73.10 三次复审 P1-3）。
    @State private var hasLoaded: Bool = false
    @State private var bannerFeedback: String? = nil
    @State private var showConfirmClean: Bool = false
    @State private var showOrphansOnly: Bool = true

    public init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
    }

    /// 自检注入口：卡片状态是 `@State`，只能从 init 播种才能在内存里驱动 UI 断言
    /// （不触发 `onAppear`，因此绝不因自检去扫真盘）。
    internal init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil,
                  initialSummary: AndroidEmulatorSummary,
                  initiallyCleaning: Bool = false,
                  initiallyConfirming: Bool = false,
                  initiallyShowingAll: Bool = false,
                  initiallyScanning: Bool = false,
                  initiallyLoaded: Bool = true) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
        _summary = State(initialValue: initialSummary)
        _isCleaning = State(initialValue: initiallyCleaning)
        _showConfirmClean = State(initialValue: initiallyConfirming)
        _showOrphansOnly = State(initialValue: !initiallyShowingAll)
        _isScanning = State(initialValue: initiallyScanning)
        _hasLoaded = State(initialValue: initiallyLoaded)
    }

    private var displayedItems: [AndroidEmulatorItem] {
        if showOrphansOnly {
            return summary.items.filter {
                $0.status.isProvenOrphan
                    || $0.status == .brokenImageNeedsConfirm
                    || $0.status == .needsConfirmation
            }
        }
        return summary.items
    }

    // MARK: - 可用性判据（单一真值来源）
    //
    // 抽成纯函数不是为了复用好看：macOS 27 上 ViewInspector 枚举不到 `Button`/`Toggle`
    // （docs/RELEASE-CHECKLIST.md §0.2 的 34 条环境失败就是这一类），于是「按钮该不该禁用」
    // 这条删除安全契约在本机**断言不到**——断言永远红的检查抓不到任何回归。判据落地成
    // 能在本机跑起来的函数，同一契约才有执法点。

    /// 计入可选额度 = 「确证孤儿」**且**「本轮真的读全」（`readable`）**且**「这根落在网关的
    /// 常规放行面里」。行勾选框给不给、「全选」能不能点、`selectAll` 赋值三处必须共用这一条
    /// （v1.73.10 二次复审 P2-10 / 三次复审 P1-2）：只判孤儿会让用户手工勾上残缺项、再点
    /// 「全选」时被静默取消；不判根则外接盘上的条目会被默认勾上，而界面写的是「只列示、不删」。
    static func isSelectable(_ item: AndroidEmulatorItem, root: String) -> Bool {
        item.status.isProvenOrphan && item.readable && isWithinDeletableFace(root)
    }

    /// 有任意一项够得上可选额度，「全选」才有意义；否则按钮只能禁用（残缺项不构成额度）。
    static func isSelectAllEnabled(_ items: [AndroidEmulatorItem], root: String) -> Bool {
        items.contains { isSelectable($0, root: root) }
    }

    /// 「清理选中」的可用性：真有勾选项，且既不在扫描也不在清理中（防重复提交）。
    static func isCleanEnabled(_ items: [AndroidEmulatorItem], isScanning: Bool, isCleaning: Bool) -> Bool {
        items.contains(where: \.isSelected) && !isScanning && !isCleaning
    }

    /// 指标头条该显示什么。三档互斥，且**不许把"还没看"报成"没有"**（三次复审 C-P1：
    /// 空态分句修了列表，指标条四行仍在结论未出时报 0，而「可释放潜力 0 B」读起来就是
    /// "这台机器没东西可清"；放行面外的根更矛盾——一边写"一条都不勾"，一边报"可释放 5 GB"）。
    static func headlineMetric(hasLoaded: Bool, isScanning: Bool, summary: AndroidEmulatorSummary)
        -> (value: String, detail: String) {
        if !hasLoaded || isScanning { return ("—", "扫描中·结论未出") }
        if !isWithinDeletableFace(summary.avdRoot) { return ("不删", "根不在放行面·只列示") }
        return (summary.orphanSize.byteStringCN, "孤儿 \(summary.orphanCount) 项")
    }

    /// 根能不能落在网关的常规放行面里。判据只此一处，`isSelectable` 与指标头条共用，
    /// 免得两边各写一遍然后哪天不同步（那正是"承诺与行为相反"的成因）。
    static func isWithinDeletableFace(_ root: String) -> Bool {
        FileSystem.isWithinGuardedRoot(FileSystem.normalizePath(root))
    }

    public var body: some View {
        // 派生量在 body 里**算一次再向下传**（v1.73.10 待议 #4）：此前 `displayedItems` 这个
        // 计算属性在一帧里被读 5 次，每次都把同一份 filter 重跑一遍；selectedCount/selectedSize/
        // selectableCount 又各自再过滤一遍。现在全部收敛为 body 局部量，经参数传给各子视图。
        let items = displayedItems
        let selected = items.filter(\.isSelected)
        let selectedCount = selected.count
        let selectedSize = selected.reduce(0) { $0 + $1.size }
        // 全选作用域：可默勾（孤儿）**且本轮真的读全了**的项，判据在 `Self.isSelectable`——
        // 行勾选框、「全选」禁用、`selectAll` 赋值三处都调它，不再各写一遍条件。
        let selectableCount = items.filter { Self.isSelectable($0, root: summary.avdRoot) }.count
        let selectAllEnabled = Self.isSelectAllEnabled(items, root: summary.avdRoot)
        let cleanEnabled = Self.isCleanEnabled(items, isScanning: isScanning, isCleaning: isCleaning)
        return VStack(alignment: .leading, spacing: Space.sm) {
            topHeader
            evidenceBanner(selectedCount: selectedCount)
            metricsSummaryBar
            if let feedback = bannerFeedback { bannerBar(feedback) }
            contentListContainer(items)
            actionFooterBar(selectedCount: selectedCount, selectedSize: selectedSize,
                            selectableCount: selectableCount, selectAllEnabled: selectAllEnabled,
                            cleanEnabled: cleanEnabled)
        }
        .padding(Space.md)
        .background(Surface.group)
        .clipShape(RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
        .onAppear { loadData() }
        // present 修饰符挂在**有尺寸的容器**上（`.background`+`padding` 的这层卡片），
        // 不挂 EmptyView——见 docs/RELEASE-CHECKLIST.md「新增确认弹窗不能只信自检」。
        .confirmationDialog("确认清理选中的孤儿 AVD 数据目录", isPresented: $showConfirmClean, titleVisibility: .visible) {
            Button("安全移入废纸篓", role: .destructive) { executeClean(toTrash: true) }
            Button("彻底删除", role: .destructive) { executeClean(toTrash: false) }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将把选中的 \(selectedCount) 项孤儿 AVD（\(selectedSize.byteStringCN)）移入回收，"
                 + "之后可从「清理历史」放回。选择「彻底删除」则**不进废纸篓、不可恢复**。"
                 + "『镜像已删』与『需确认』的 AVD 不会被默认勾选，也不经此按钮删除——它们可能仍有你想保留的数据盘。")
        }
    }

    // MARK: - 证据可信度横幅（AVD 根读不到时显式降级）

    @ViewBuilder
    private func evidenceBanner(selectedCount: Int) -> some View {
        if !summary.isResultComplete {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Signal.caution)
                VStack(alignment: .leading, spacing: 1) {
                    Text("AVD 目录未能完整读取，下面的列表可能不完整")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.primary)
                    ForEach(Array(summary.issues.enumerated()), id: \.offset) { _, issue in
                        Text(issue.message).font(Typo.micro).foregroundStyle(Ink.tertiary)
                    }
                    // 这句必须跟着**实际勾选态**走：一条 issue 也不能把"下面已经勾了 3 项"
                    // 说成"没有任何一项被默认勾选"（v1.73.10 复审 P1-5）。
                    if selectedCount == 0 {
                        Text("因此没有一项被判定为可清理孤儿，也没有任何一项被默认勾选。")
                            .font(Typo.micro).foregroundStyle(Ink.tertiary)
                    } else {
                        Text("下面仍有 \(selectedCount) 项被默认勾选为确证孤儿——它们各自的判据都成立，"
                             + "但整份清单可能不完整。")
                            .font(Typo.micro).foregroundStyle(Ink.tertiary)
                    }
                }
                Spacer()
            }
            .padding(8)
            .background(Signal.caution.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
    }

    private var topHeader: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "iphone.genesis", size: 15, weight: .semibold, color: Accent.tint, width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text("Android 模拟器与 SDK 镜像").font(Typo.section).foregroundStyle(Ink.primary)
                Text("清理无描述符指向的孤儿 AVD 数据目录").font(Typo.micro).foregroundStyle(Ink.tertiary)
            }
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Ink.tertiary)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("androidEmulatorCloseButton")
        }
    }

    private var metricsSummaryBar: some View {
        // 三格都走 `headlineMetric`/`pendingMetric`：结论未出时是"— + 扫描中·结论未出"，
        // 而不是四个 0——四个 0 读起来等于"这台机器没东西可清"（三次复审 C-P1）。
        let headline = Self.headlineMetric(hasLoaded: hasLoaded, isScanning: isScanning, summary: summary)
        let pending = !hasLoaded || isScanning
        return HStack(spacing: Space.md) {
            metric(title: "可释放潜力", value: headline.value, detail: headline.detail)
            metric(title: "镜像已删", value: pending ? "—" : "\(summary.brokenImageCount)",
                   detail: pending ? "结论未出" : "需确认·不默删")
            metric(title: "健康 AVD", value: pending ? "—" : "\(summary.liveCount)",
                   detail: pending ? "结论未出" : "勿动")
            Spacer()
        }
    }

    private func metric(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(Typo.micro).foregroundStyle(Ink.tertiary)
            Text(value).font(.mcNumeric(16, weight: .semibold)).foregroundStyle(Ink.primary)
            Text(detail).font(Typo.micro).foregroundStyle(Ink.tertiary)
        }
    }

    private func bannerBar(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal").font(.system(size: 12)).foregroundStyle(Signal.positive)
            Text(text).font(Typo.caption).foregroundStyle(Ink.primary)
            Spacer()
        }
        .padding(8)
        .background(Signal.positive.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func contentListContainer(_ items: [AndroidEmulatorItem]) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                if items.isEmpty {
                    // 「没扫完」和「扫完且没有」必须是两句话（三次复审 P1-3）。
                    if isScanning || !hasLoaded {
                        Text("正在扫描 AVD 目录，结论未出")
                            .font(Typo.caption).foregroundStyle(Ink.tertiary)
                            .padding(.vertical, Space.lg)
                    } else {
                        Text(summary.isResultComplete ? "未发现孤儿 AVD 或已删镜像" : "本轮未能确认")
                            .font(Typo.caption).foregroundStyle(Ink.tertiary)
                            .padding(.vertical, Space.lg)
                    }
                } else {
                    ForEach(items) { item in itemRow(item) }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 220)
    }

    @ViewBuilder
    private func itemRow(_ item: AndroidEmulatorItem) -> some View {
        HStack(spacing: Space.xs) {
            // 勾选框只给"确证孤儿**且本轮读全了**"的行——和 `selectableCount`、「全选」同一个判据
            // （判据本体在 `Self.isSelectable`）。只判孤儿会让用户手工勾上一个残缺项，再点
            // 「全选」时被静默取消：一个写着「全选」的按钮做了反选的事（二次复审 P2-10）。
            if Self.isSelectable(item, root: summary.avdRoot) {
                Toggle("", isOn: Binding(
                    get: { item.isSelected },
                    set: { val in toggleItem(item.id, selected: val) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden().controlSize(.small)
                .accessibilityIdentifier("androidEmulatorRowToggle")
            } else {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(item.status == .liveHealthy ? Signal.positive : Signal.caution)
                    .frame(width: 16)
            }
            // 图标按**状态**取，不按 kind：`.needsConfirmation` 的 kind 是 `.liveAVD`，
            // 用 kind.icon 会给一行「证据不足（需确认）」戴上"健康 AVD"的对勾（二次复审 P3-15a）。
            Image(systemName: item.status.icon).font(.system(size: 13))
                .foregroundStyle(Accent.tint).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.name).font(Typo.rowStrong).foregroundStyle(Ink.primary).lineLimit(1)
                    Text(item.status.rawValue).font(Typo.micro).foregroundStyle(Ink.tertiary)
                }
                if let note = item.note {
                    Text(note).font(Typo.micro).foregroundStyle(Ink.tertiary).lineLimit(2)
                }
            }
            Spacer()
            // 残缺项不能只"没勾上"——用户点全选后还是没勾，得看得见原因（v1.73.7 P1-E 一族）。
            if !item.readable {
                Text("体积为下限").font(Typo.micro).foregroundStyle(Signal.caution)
            }
            Text(item.size.byteStringCN).font(.mcNumeric(12, weight: .medium)).foregroundStyle(Ink.primary)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 6)
        .background(Surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func actionFooterBar(selectedCount: Int, selectedSize: Int64,
                                 selectableCount: Int, selectAllEnabled: Bool,
                                 cleanEnabled: Bool) -> some View {
        HStack(spacing: Space.xs) {
            Toggle("只看孤儿", isOn: $showOrphansOnly)
                .toggleStyle(.button).controlSize(.small)
            Button(selectedCount == selectableCount && selectableCount > 0 ? "取消全选" : "全选") {
                selectAll(!(selectedCount == selectableCount && selectableCount > 0))
            }
            .buttonStyle(.bordered).controlSize(.small)
            .disabled(!selectAllEnabled)
            .accessibilityIdentifier("androidEmulatorSelectAllButton")
            Spacer()
            Button(role: .destructive) { showConfirmClean = true } label: {
                HStack(spacing: 4) {
                    if isCleaning { ProgressView().controlSize(.mini) }
                    else { Image(systemName: "trash") }
                    Text("清理选中 (\(selectedSize.byteStringCN))")
                }
            }
            .buttonStyle(.borderedProminent).controlSize(.small)
            .disabled(!cleanEnabled)
            .accessibilityIdentifier("androidEmulatorCleanButton")
        }
    }

    // MARK: - 逻辑

    private func loadData() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let s = AndroidEmulatorScanner.shared.scan()
            DispatchQueue.main.async { summary = s; isScanning = false; hasLoaded = true }
        }
    }

    private func toggleItem(_ id: String, selected: Bool) {
        guard let idx = summary.items.firstIndex(where: { $0.id == id }) else { return }
        summary.items[idx].isSelected = selected
    }

    private func selectAll(_ select: Bool) {
        // 这里是第三个消费点，所以按**赋值**而不是「只挑够得上的行」来写：
        // `取消全选` 必须能把任何残留勾选抹掉（含本轮变得残缺的项），
        // 而 `全选` 绝不把残缺项勾上——v1.73.7 契约，判据与勾选框同源（`Self.isSelectable`）。
        for i in 0..<summary.items.count {
            summary.items[i].isSelected = select && Self.isSelectable(summary.items[i],
                                                                      root: summary.avdRoot)
        }
    }

    private func executeClean(toTrash: Bool) {
        isCleaning = true
        let targets = summary.items.filter(\.isSelected)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = AndroidEmulatorScanner.shared.clean(items: targets, toTrash: toTrash)
            DispatchQueue.main.async {
                isCleaning = false
                var lines = ["已清理 \(outcome.cleanedCount) 项，释放 \(outcome.freedBytes.byteStringCN)"]
                lines.append(contentsOf: outcome.rejected.map { "\($0.name)：\($0.message)" })
                bannerFeedback = lines.joined(separator: "\n")
                loadData()
                onTriggerClean?()
            }
        }
    }
}
