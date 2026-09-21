import SwiftUI
import AppKit

// MARK: - 废弃打印机驱动与 PPD 描述文件治理卡片 (v1.71.0)

public struct PrinterDriverOptimizerCard: View {
    public var onClose: () -> Void
    public var onTriggerClean: (() -> Void)?

    @State private var summary: PrinterDriverSummary = PrinterDriverSummary()
    @State private var isScanning: Bool = false
    @State private var isCleaning: Bool = false
    @State private var bannerFeedback: String? = nil
    @State private var showConfirmClean: Bool = false
    @State private var showOrphansOnly: Bool = true

    public init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
    }

    /// 自检注入口：卡片状态是 `@State`，只能从 init 播种才能在内存里驱动 UI 断言
    /// （不触发 `onAppear`，因此绝不会因为自检手滑去扫真盘）。生产调用方走上面那个 init。
    internal init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil,
                  initialSummary: PrinterDriverSummary,
                  initiallyCleaning: Bool = false,
                  initiallyConfirming: Bool = false) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
        _summary = State(initialValue: initialSummary)
        _isCleaning = State(initialValue: initiallyCleaning)
        _showConfirmClean = State(initialValue: initiallyConfirming)
    }

    private var displayedItems: [PrinterDriverItem] {
        if showOrphansOnly {
            // 「需确认」项一并列出：它们不可删，但用户需要看到"为什么没被判定为可清理"
            return summary.items.filter { $0.status.isOrphanOrCorrupted || $0.status == .needsConfirmation }
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
            evidenceBanner
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
        .confirmationDialog("确认清理选中的打印机驱动与 PPD 描述文件", isPresented: $showConfirmClean, titleVisibility: .visible) {
            Button("安全移入废纸篓", role: .destructive) {
                executeClean(toTrash: true)
            }
            Button("彻底删除", role: .destructive) {
                executeClean(toTrash: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清理选中的 \(selectedCount) 项驱动数据（\(selectedSize.byteStringCN)）。"
                 + "PPD 厂商分组只删除其成员 PPD 文件，绝不删除共享资源目录；在用配置与系统核心配置受保护。")
        }
    }

    // MARK: - 证据可信度横幅（读不到 CUPS 时必须显式降级）

    @ViewBuilder
    private var evidenceBanner: some View {
        if !summary.cupsEvidenceReadable {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Signal.caution)
                VStack(alignment: .leading, spacing: 1) {
                    Text("无法读取 CUPS 打印机配置（需 root），本模块仅提供定位与建议")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.primary)
                    if !summary.unreadableSources.isEmpty {
                        Text("读不到的证据源：\(summary.unreadableSources.joined(separator: "、"))")
                            .font(Typo.micro)
                            .foregroundStyle(Ink.tertiary)
                    }
                    Text("因此没有一项被判定为废弃驱动，也没有任何一项被默认勾选。")
                        .font(Typo.micro)
                        .foregroundStyle(Ink.tertiary)
                }
                Spacer()
            }
            .padding(8)
            .background(Signal.caution.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        }
    }

    // MARK: - 顶部栏

    private var topHeader: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "printer.fill", size: 15, weight: .semibold, color: Accent.tint, width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("废弃打印机驱动与 PPD 描述文件治理")
                    .font(Typo.title)
                    .foregroundStyle(Ink.primary)
                Text("排查未连接打印机的臃肿厂商驱动包与废弃 PPD 描述文件，释放数 GB 驱动空间")
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
            .disabled(isScanning || isCleaning)
            .accessibilityIdentifier("printerReloadButton")

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
            metricBlock(title: "总驱动体积", value: summary.totalSize.byteStringCN, color: Ink.primary)
            Divider().frame(height: 20)
            metricBlock(title: "废弃/孤儿驱动", value: "\(summary.orphanSize.byteStringCN) (\(summary.orphanCount)项)", color: Accent.tint)
            Divider().frame(height: 20)
            metricBlock(title: "在用受保护项", value: "\(summary.activeCount) 项", color: Signal.positive)
            Divider().frame(height: 20)
            metricBlock(title: "证据不足需确认", value: "\(summary.needsConfirmationCount) 项", color: summary.needsConfirmationCount > 0 ? Signal.caution : Ink.tertiary)
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
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(Accent.tint)
            Text(message)
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)
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
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(Signal.positive)
                        Text(showOrphansOnly ? "未发现废弃或未使用的打印机驱动与 PPD 描述文件" : "未发现任何打印机驱动")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
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

    private func itemRow(_ item: PrinterDriverItem) -> some View {
        HStack(spacing: Space.xs) {
            if item.status.isOrphanOrCorrupted {
                Toggle("", isOn: Binding(
                    get: { item.isSelected },
                    set: { val in toggleItem(item.id, selected: val) }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .controlSize(.small)
                .accessibilityIdentifier("printerRowToggle")
            } else {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(item.status == .needsConfirmation ? Signal.caution : Signal.positive)
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
                    vendorBadge(item.vendor)
                    statusBadge(item.status)
                    if item.kind == .ppdResource {
                        // 分组只删成员文件，把数量摊给用户看，避免"整棵资源树"的误解
                        Text("仅删 \(item.memberPaths.count) 个 PPD 文件")
                            .font(Typo.micro)
                            .foregroundStyle(Ink.tertiary)
                    }
                }

                Text(item.path)
                    .font(Typo.micro)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let note = item.evidenceNote, !note.isEmpty {
                    Text(note)
                        .font(Typo.micro)
                        .foregroundStyle(item.status == .needsConfirmation ? Signal.caution : Ink.quaternary)
                        .lineLimit(2)
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.size.byteStringCN)
                    .font(Typo.rowStrong)
                    .foregroundStyle(Ink.primary)
                HStack(spacing: 4) {
                    Text("\(item.fileCount) 个文件")
                        .font(Typo.micro)
                        .foregroundStyle(Ink.tertiary)
                    Button {
                        NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
                    } label: {
                        Image(systemName: "folder")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.borderless)
                    .help("在访达中显示（无删除权限时的定位手段）")
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(item.isSelected ? Accent.tint.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    private func vendorBadge(_ vendor: String) -> some View {
        Text(vendor)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Surface.sunken)
            .foregroundStyle(Ink.secondary)
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private func statusBadge(_ status: PrinterDriverStatus) -> some View {
        let (title, bg, fg): (String, Color, Color) = {
            switch status {
            case .activeConfigured:
                return ("在用配置", Signal.positive.opacity(0.12), Signal.positive)
            case .orphanUnused:
                return ("废弃未用", Signal.caution.opacity(0.12), Signal.caution)
            case .corrupted:
                return ("损坏驱动", Signal.critical.opacity(0.12), Signal.critical)
            case .systemProtected:
                return ("系统核心", Color.blue.opacity(0.12), Color.blue)
            case .needsConfirmation:
                return ("需确认", Ink.tertiary.opacity(0.16), Ink.secondary)
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
            Button("全选") {
                selectAll(true)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(displayedItems.filter(\.status.isOrphanOrCorrupted).isEmpty)
            .accessibilityIdentifier("printerSelectAllButton")

            Button("全不选") {
                selectAll(false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedCount == 0)
            .accessibilityIdentifier("printerClearAllButton")

            Spacer()

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
            .disabled(selectedCount == 0 || isScanning || isCleaning)
            .accessibilityIdentifier("printerCleanButton")
        }
    }

    // MARK: - 逻辑处理

    private func loadData() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = PrinterDriverScanner.shared.scan()
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

    private func selectAll(_ select: Bool) {
        for i in 0..<summary.items.count {
            if summary.items[i].status.isOrphanOrCorrupted {
                summary.items[i].isSelected = select
            }
        }
    }

    private func executeClean(toTrash: Bool) {
        guard !isCleaning else { return }
        isCleaning = true
        // 只把"确证孤儿/损坏"的项交给网关；网关内部还会再过一遍治理域 + 软链 + 白名单护栏，
        // 并用 policy 兜住同一条业务判据（视图这条只是第一道）。
        let targets = summary.items.filter { $0.isSelected && $0.status.isOrphanOrCorrupted }
        let protectedSkipped = summary.items.filter { $0.isSelected && !$0.status.isOrphanOrCorrupted }.count

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = PrinterDriverScanner.shared.clean(items: targets, toTrash: toTrash)
            var lines: [String] = [outcome.summary]
            if protectedSkipped > 0 {
                lines.append("\(protectedSkipped) 项受保护未提交删除")
            }
            // root 管理的位置：不提权，只给定位手段——绝不含糊地说"清理失败"
            if !outcome.needsPrivilege.isEmpty {
                let first = outcome.needsPrivilege.first?.message ?? GovernanceVerdict.rejected(.needsPrivilege).message
                lines.append("\(outcome.needsPrivilege.count) 项无法删除：\(first)"
                    + " 已为它们在列表中保留，可用行尾的访达按钮自行定位。")
            }
            let others = outcome.rejected.filter { $0.reason != .needsPrivilege }
            if !others.isEmpty {
                lines.append("\(others.count) 项被安全护栏拦下（\(others.first?.message ?? "")）")
            }
            if !outcome.failed.isEmpty {
                lines.append("\(outcome.failed.count) 项删除失败（\(outcome.failed.first?.message ?? "")）")
            }
            // 真删掉了东西才去请 CUPS 重载，且结果如实上报
            if outcome.cleanedCount > 0 {
                let refresh = PrinterDriverScanner.shared.refreshCUPS()
                lines.append(refresh.success ? "CUPS 已重载：\(refresh.message)"
                                             : "CUPS 未确认重载：\(refresh.message)")
            }
            let feedback = lines.joined(separator: "；")
            DispatchQueue.main.async {
                self.isCleaning = false
                self.bannerFeedback = feedback
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }
}
