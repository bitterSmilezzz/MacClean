import SwiftUI
import AppKit

// MARK: - 系统音频 HAL 插件与残存驱动排查治理卡片 (v1.70.0)

public struct AudioHALOptimizerCard: View {
    public var onClose: () -> Void
    public var onTriggerClean: (() -> Void)?

    @State private var summary: AudioPluginSummary = AudioPluginSummary()
    @State private var isScanning: Bool = false
    @State private var isCleaning: Bool = false
    @State private var isRestarting: Bool = false
    @State private var bannerFeedback: String? = nil
    @State private var showConfirmClean: Bool = false
    @State private var showConfirmRestart: Bool = false
    @State private var showOrphansOnly: Bool = true

    public init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
    }

    private var displayedItems: [AudioPluginItem] {
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
        .confirmationDialog("确认清理选中的音频驱动与插件", isPresented: $showConfirmClean, titleVisibility: .visible) {
            Button("安全移入废纸篓", role: .destructive) {
                executeClean(toTrash: true)
            }
            Button("彻底删除", role: .destructive) {
                executeClean(toTrash: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清理选中的 \(selectedCount) 项音频驱动（\(selectedSize.byteStringCN)）。Apple 官方核心驱动与在用音频驱动已受严格保护，绝不误删。")
        }
        .confirmationDialog("确认重启系统音频守护进程 (coreaudiod)", isPresented: $showConfirmRestart, titleVisibility: .visible) {
            Button("立即重启音频服务", role: .none) {
                executeRestart()
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("该操作将终止并重新拉起 coreaudiod 守护进程，使音频硬件堆栈重新扫描并加载驱动。正在播放的音频可能会中断 1-2 秒。")
        }
    }

    // MARK: - 顶部栏

    private var topHeader: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "speaker.wave.3.fill", size: 15, weight: .semibold, color: Accent.tint, width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("系统音频 HAL 插件与残存驱动排查治理")
                    .font(Typo.title)
                    .foregroundStyle(Ink.primary)
                Text("排查已卸载应用遗留的 HAL 虚拟音频驱动与插件，解决系统无声、音频卡死及 coreaudiod 高 CPU 占用")
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
            .disabled(isScanning || isCleaning || isRestarting)

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
            metricBlock(title: "孤儿/损坏驱动", value: "\(summary.orphanSize.byteStringCN) (\(summary.orphanCount)项)", color: Accent.tint)
            Divider().frame(height: 20)
            metricBlock(title: "活跃受保护项", value: "\(summary.activeCount) 项", color: Signal.positive)
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
                        Text(showOrphansOnly ? "未发现已卸载应用遗留的孤儿音频驱动或损坏插件" : "未发现任何音频驱动或插件")
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

    private func itemRow(_ item: AudioPluginItem) -> some View {
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

                HStack(spacing: 4) {
                    if let bid = item.bundleID {
                        Text(bid)
                            .font(Typo.micro)
                            .foregroundStyle(Ink.secondary)
                    }
                    Text(item.path)
                        .font(Typo.micro)
                        .foregroundStyle(Ink.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
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

    private func statusBadge(_ status: AudioPluginStatus) -> some View {
        let (title, bg, fg): (String, Color, Color) = {
            switch status {
            case .activeInUse:
                return ("在用驱动", Signal.positive.opacity(0.12), Signal.positive)
            case .orphanResidue:
                return ("已卸载残留", Signal.caution.opacity(0.12), Signal.caution)
            case .corrupted:
                return ("损坏驱动", Signal.critical.opacity(0.12), Signal.critical)
            case .appleOfficial:
                return ("Apple 官方核心", Color.blue.opacity(0.12), Color.blue)
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
                showConfirmRestart = true
            } label: {
                HStack(spacing: 4) {
                    if isRestarting {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise.circle")
                    }
                    Text("重启音频服务 (coreaudiod)")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(isScanning || isCleaning || isRestarting)

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
            .disabled(selectedCount == 0 || isScanning || isCleaning || isRestarting)
        }
    }

    // MARK: - 逻辑处理

    private func loadData() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = AudioHALScanner.shared.scan()
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
            let result = AudioHALScanner.shared.clean(items: targets, toTrash: toTrash)
            DispatchQueue.main.async {
                self.isCleaning = false
                self.bannerFeedback = "成功清理 \(result.cleanedCount) 项音频驱动，释放 \(result.freedBytes.byteStringCN)" + (result.errorCount > 0 ? "（\(result.errorCount) 项受保护未清理）" : "")
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }

    private func executeRestart() {
        guard !isRestarting else { return }
        isRestarting = true
        DispatchQueue.global(qos: .userInitiated).async {
            let result = AudioHALScanner.shared.restartCoreAudioService()
            DispatchQueue.main.async {
                self.isRestarting = false
                self.bannerFeedback = result.message
            }
        }
    }
}
