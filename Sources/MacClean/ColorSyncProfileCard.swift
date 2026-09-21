import SwiftUI
import AppKit

// MARK: - 多显示器色彩描述与 ICC Profile 治理卡片 (v1.68.0)

public struct ColorSyncProfileCard: View {
    public var onClose: () -> Void
    public var onTriggerClean: (() -> Void)?

    @State private var summary: ColorSyncSummary = ColorSyncSummary()
    @State private var isScanning: Bool = false
    @State private var isCleaning: Bool = false
    @State private var bannerFeedback: String? = nil
    @State private var showConfirmClean: Bool = false
    @State private var showOrphansOnly: Bool = true

    public init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
    }

    private var displayedItems: [ICCProfileItem] {
        if showOrphansOnly {
            // 证据不足项也列出（不可删），让用户看到"为什么没被判成残留"
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
        .confirmationDialog("确认清理选中的 ICC 色彩配置", isPresented: $showConfirmClean, titleVisibility: .visible) {
            Button("安全移入废纸篓", role: .destructive) {
                executeClean(toTrash: true)
            }
            Button("彻底删除", role: .destructive) {
                executeClean(toTrash: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清理选中的 \(selectedCount) 项色彩配置文件（\(selectedSize.byteStringCN)）。"
                 + "当前接驳显示器的配置、近 30 天内写过的配置与 Apple 内置核心配置都受保护；证据不足的项不会被勾选。")
        }
    }

    // MARK: - 证据可信度横幅

    /// 接驳显示器列表读不到、或 ColorSync 偏好解析失败时必须说明：
    /// 此时"没有引用记录"不代表"没在用"，一项都不会被判定为残留。
    @ViewBuilder
    private var evidenceBanner: some View {
        if !summary.evidenceTrustworthy {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Signal.caution)
                VStack(alignment: .leading, spacing: 1) {
                    Text("无法读全「当前接驳显示器 / ColorSync 偏好引用」，本模块仅提供定位与建议")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.primary)
                    if !summary.unreadableSources.isEmpty {
                        Text("读不到的证据源：\(summary.unreadableSources.joined(separator: "、"))")
                            .font(Typo.micro)
                            .foregroundStyle(Ink.tertiary)
                    }
                    Text("\(summary.needsConfirmationCount) 项证据不足，全部未勾选。")
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

    // MARK: - 子组件：顶部栏

    private var topHeader: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "display.2", size: 15, weight: .semibold, color: Accent.tint, width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("多显示器色彩描述与 ICC Profile 治理")
                    .font(Typo.title)
                    .foregroundStyle(Ink.primary)
                Text("排查外接显示器断开后残留的废弃色彩校准配置与 ColorSync 缓存，加速屏幕唤醒与色彩匹配")
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
            metricItem(title: "发现孤儿配置", value: "\(summary.orphanCount)", detail: summary.orphanSize.byteStringCN, color: summary.orphanCount > 0 ? Signal.caution : Signal.positive)
            Divider().frame(height: 28)
            metricItem(title: "活跃屏幕保护", value: "\(summary.activeCount)", detail: "当前连接中", color: Signal.positive)
            Divider().frame(height: 28)
            metricItem(title: "可释放潜力", value: selectedSize.byteStringCN, detail: "\(selectedCount) 项已选", color: selectedSize > 0 ? Accent.tint : Ink.secondary)
            Divider().frame(height: 28)
            metricItem(title: "证据不足需确认", value: "\(summary.needsConfirmationCount)", detail: "未勾选", color: summary.needsConfirmationCount > 0 ? Signal.caution : Ink.tertiary)
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
                        Text("正在排查 ColorSync 色彩配置文件与显示器状态…")
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                        Spacer()
                    }
                    .padding(.vertical, Space.lg)
                } else if displayedItems.isEmpty {
                    Text(showOrphansOnly ? "未发现废弃的 ICC 色彩配置（系统非常整洁）" : "未发现任何色彩配置文件")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.vertical, Space.lg)
                } else {
                    ForEach(displayedItems) { item in
                        HStack(spacing: Space.sm) {
                            if item.status.isOrphanOrCorrupted {
                                Button(action: {
                                    toggleItemSelection(id: item.id)
                                }) {
                                    Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                                        .font(.system(size: 13))
                                        .foregroundStyle(item.isSelected ? Accent.tint : Ink.tertiary)
                                }
                                .buttonStyle(.plain)
                            } else {
                                Image(systemName: "lock.shield.fill")
                                    .font(.system(size: 13))
                                    .foregroundStyle(item.status == .needsConfirmation ? Signal.caution : Signal.positive)
                            }

                            Image(systemName: item.kind.icon)
                                .font(.system(size: 14))
                                .foregroundStyle(item.status.isOrphanOrCorrupted ? Accent.tint : Signal.positive)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Space.xs) {
                                    Text(item.name)
                                        .font(Typo.rowStrong)
                                        .foregroundStyle(Ink.primary)

                                    statusBadge(for: item.status)
                                }

                                Text(item.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Ink.quaternary)
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

    private func statusBadge(for status: ICCProfileStatus) -> some View {
        let (title, color) = badgeInfo(for: status)
        return Text(title)
            .font(Typo.micro)
            .foregroundStyle(color)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
    }

    private func badgeInfo(for status: ICCProfileStatus) -> (String, Color) {
        switch status {
        case .activeConnected: return ("活跃显示器", Signal.positive)
        case .disconnectedOrphan: return ("已断开残留", Signal.caution)
        case .corrupted: return ("损坏配置", Signal.critical)
        case .systemProtected: return ("系统受保护", Ink.tertiary)
        case .recentlyActive: return ("近期写过·在用", Signal.positive)
        case .needsConfirmation: return ("需确认", Ink.tertiary)
        }
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
            Button(selectedCount == selectableItems.count ? "取消全选" : "全部选中") {
                toggleSelectAll()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(selectableItems.isEmpty || isCleaning)

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
                Label("安全清理", systemImage: "trash")
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
            let res = ColorSyncScanner.shared.scan()
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

    private var selectableItems: [ICCProfileItem] {
        displayedItems.filter { $0.status.isOrphanOrCorrupted }
    }

    private func toggleSelectAll() {
        let target = selectedCount != selectableItems.count
        for i in 0..<summary.items.count {
            if summary.items[i].status.isOrphanOrCorrupted {
                summary.items[i].isSelected = target
            }
        }
    }

    private func executeClean(toTrash: Bool) {
        guard !isCleaning else { return }
        isCleaning = true
        let targets = displayedItems.filter(\.isSelected)

        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = ColorSyncScanner.shared.clean(items: targets, toTrash: toTrash)
            var lines: [String] = [outcome.summary]
            if !outcome.needsPrivilege.isEmpty {
                let first = outcome.needsPrivilege.first?.message
                    ?? GovernanceVerdict.rejected(.needsPrivilege).message
                lines.append("\(outcome.needsPrivilege.count) 项无法删除：\(first)"
                    + " 已保留在列表中，可用行尾的访达按钮定位后在终端手动处理。")
            }
            let others = outcome.rejected.filter { $0.reason != .needsPrivilege }
            if !others.isEmpty {
                lines.append("\(others.count) 项被安全护栏拦下（\(others.first?.message ?? "")）")
            }
            if !outcome.failed.isEmpty {
                lines.append("\(outcome.failed.count) 项删除失败（\(outcome.failed.first?.message ?? "")）")
            }
            DispatchQueue.main.async {
                self.isCleaning = false
                self.bannerFeedback = lines.joined(separator: "；")
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }
}
