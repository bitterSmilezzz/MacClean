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
    @State private var showConfirmClean: Bool = false
    @State private var showConfirmRebuild: Bool = false
    @State private var showOrphansOnly: Bool = true

    public init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
    }

    private var displayedItems: [SpotlightStoreItem] {
        if showOrphansOnly {
            return summary.items.filter { $0.status.isOrphanOrCorrupted }
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
        .confirmationDialog("确认清理选中的 Spotlight 索引与缓存", isPresented: $showConfirmClean, titleVisibility: .visible) {
            Button("安全移入废纸篓", role: .destructive) {
                executeClean(toTrash: true)
            }
            Button("彻底删除", role: .destructive) {
                executeClean(toTrash: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清理选中的 \(selectedCount) 项索引数据（\(selectedSize.byteStringCN)）。系统核心索引受严格保护，绝不误删。")
        }
        .confirmationDialog("确认重建系统 Spotlight 索引", isPresented: $showConfirmRebuild, titleVisibility: .visible) {
            Button("开始安全重建 (mdutil -E /)", role: .none) {
                executeRebuild()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将向系统发送 mdutil -E / 指令，清除现有搜索数据库并重新建立索引。该操作可解决搜索无结果、迟钝或 mdworker 进程占用高 CPU 问题。重建期间 Spotlight 搜索可能暂时受限。")
        }
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
                        Text(showOrphansOnly ? "未发现已卸载应用残留的 CoreSpotlight 索引或废弃缓存" : "未发现任何 Spotlight 存储库")
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
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(item.size.byteStringCN)
                    .font(Typo.rowStrong)
                    .foregroundStyle(Ink.primary)
                Text("\(item.fileCount) 个文件")
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

            Button("全不选") {
                selectAll(false)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(selectedCount == 0)

            Spacer()

            Button {
                showConfirmRebuild = true
            } label: {
                HStack(spacing: 4) {
                    if isRebuilding {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text("安全重建系统索引 (mdutil -E)")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isScanning || isCleaning || isRebuilding)

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
        let targets = summary.items.filter { $0.isSelected && $0.status.isOrphanOrCorrupted }

        DispatchQueue.global(qos: .userInitiated).async {
            let result = SpotlightScanner.shared.clean(items: targets, toTrash: toTrash)
            DispatchQueue.main.async {
                self.isCleaning = false
                self.bannerFeedback = "成功清理 \(result.cleanedCount) 项数据，释放 \(result.freedBytes.byteStringCN)" + (result.errorCount > 0 ? "（\(result.errorCount) 项受保护未清理）" : "")
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }

    private func executeRebuild() {
        guard !isRebuilding else { return }
        isRebuilding = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = SpotlightScanner.shared.rebuildVolumeIndex(volumePath: "/")
            DispatchQueue.main.async {
                self.isRebuilding = false
                self.bannerFeedback = result.message
            }
        }
    }
}
