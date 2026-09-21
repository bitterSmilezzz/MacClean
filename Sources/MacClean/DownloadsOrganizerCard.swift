import SwiftUI
import AppKit

// MARK: - 下载目录智能时效归档与治理面板卡片 (v1.62.0)

public struct DownloadsOrganizerCard: View {
    public var onClose: () -> Void
    public var onTriggerClean: (() -> Void)?

    @State private var summary: DownloadsSummary = DownloadsSummary()
    @State private var isScanning: Bool = false
    @State private var isCleaning: Bool = false
    @State private var searchKeyword: String = ""
    @State private var selectedKind: DownloadKindFilter = .all
    @State private var selectedAge: DownloadAgeFilter = .all
    @State private var bannerFeedback: String? = nil
    @State private var showConfirmClean: Bool = false

    public enum DownloadKindFilter: String, CaseIterable, Identifiable {
        case all = "全部类型"
        case installer = "💿 安装包"
        case archive = "📦 压缩包"
        case media = "🎬 视音频"
        case document = "📄 文档"

        public var id: String { rawValue }
    }

    public enum DownloadAgeFilter: String, CaseIterable, Identifiable {
        case all = "全部时效"
        case week = "⏱️ >7天"
        case month = "📅 >30天"
        case quarter = "🍂 >90天"

        public var id: String { rawValue }
    }

    public init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
    }

    // MARK: - 过滤计算

    private var filteredItems: [DownloadItem] {
        summary.items.filter { item in
            // 类型筛选
            switch selectedKind {
            case .all: break
            case .installer:
                guard item.kind == .installer else { return false }
            case .archive:
                guard item.kind == .archive else { return false }
            case .media:
                guard item.kind == .media else { return false }
            case .document:
                guard item.kind == .document else { return false }
            }

            // 时效筛选
            switch selectedAge {
            case .all: break
            case .week:
                guard item.ageDays >= 7 else { return false }
            case .month:
                guard item.ageDays >= 30 else { return false }
            case .quarter:
                guard item.ageDays >= 90 else { return false }
            }

            // 搜索关键字
            if !searchKeyword.isEmpty {
                let kw = searchKeyword.lowercased()
                return item.fileName.lowercased().contains(kw)
            }

            return true
        }
    }

    private var selectedCount: Int {
        summary.items.filter(\.isSelected).count
    }

    private var selectedSize: Int64 {
        summary.items.filter(\.isSelected).reduce(0) { $0 + $1.size }
    }

    // MARK: - 主视图

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            topHeader
            metricsSummaryBar
            filterAndSearchControls
            contentListContainer
            if let feedback = bannerFeedback {
                bannerBar(feedback)
            }
            actionFooterBar
        }
        .padding(Space.md)
        .background(Surface.group)
        .clipShape(RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
        .onAppear {
            loadData()
        }
        .confirmationDialog("确认清理选中的下载文件", isPresented: $showConfirmClean, titleVisibility: .visible) {
            Button("安全移入废纸篓", role: .destructive) {
                executeClean(toTrash: true)
            }
            Button("彻底删除", role: .destructive) {
                executeClean(toTrash: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清理选中的 \(selectedCount) 个下载文件（\(selectedSize.byteStringCN)）。建议优先使用「移入废纸篓」。")
        }
    }

    // MARK: - 子组件：顶部栏

    private var topHeader: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "arrow.down.circle", size: 15, weight: .semibold, color: Accent.tint, width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("下载目录（~/Downloads）时效治理")
                    .font(Typo.title)
                    .foregroundStyle(Ink.primary)
                Text("排查过期安装镜像、压缩包与闲置大文件，支持一键归档与瘦身")
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
            metricItem(title: "下载总计", value: summary.totalSize.byteStringCN, detail: "\(summary.items.count) 个文件", color: Ink.primary)
            Divider().frame(height: 28)
            metricItem(title: "安装包 (DMG/PKG)", value: summary.installerSize.byteStringCN, detail: "\(summary.installerCount) 个", color: summary.installerCount > 0 ? Signal.caution : Ink.secondary)
            Divider().frame(height: 28)
            metricItem(title: "压缩包 (ZIP/RAR)", value: summary.archiveSize.byteStringCN, detail: "\(summary.archiveCount) 个", color: Ink.secondary)
            Divider().frame(height: 28)
            metricItem(title: "陈旧文件 (>30天)", value: summary.staleSize.byteStringCN, detail: "\(summary.staleCount) 个", color: summary.staleCount > 0 ? Signal.positive : Ink.secondary)
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

    // MARK: - 子组件：筛选与搜索

    private var filterAndSearchControls: some View {
        HStack(spacing: Space.sm) {
            Picker("类型", selection: $selectedKind) {
                ForEach(DownloadKindFilter.allCases) { opt in
                    Text(opt.rawValue).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            Picker("时效", selection: $selectedAge) {
                ForEach(DownloadAgeFilter.allCases) { opt in
                    Text(opt.rawValue).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 240)

            Spacer()

            SearchField(placeholder: "搜索下载文件名...", text: $searchKeyword)
                .frame(maxWidth: 180)
        }
    }

    // MARK: - 子组件：列表容器

    private var contentListContainer: some View {
        ScrollView {
            VStack(spacing: 2) {
                if filteredItems.isEmpty {
                    Text("未发现符合条件的下载文件")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.vertical, Space.lg)
                } else {
                    ForEach(filteredItems) { item in
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
                                .foregroundStyle(Accent.tint)
                                .frame(width: 18)

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: Space.xs) {
                                    Text(item.fileName)
                                        .font(Typo.rowStrong)
                                        .foregroundStyle(Ink.primary)
                                        .lineLimit(1)

                                    if item.isHighlyRecommendedToClean {
                                        Text("建议清理")
                                            .font(Typo.micro)
                                            .foregroundStyle(Signal.caution)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Signal.caution.opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                    }
                                }

                                HStack(spacing: Space.xs) {
                                    Text("闲置 \(item.ageDays) 天")
                                        .font(.mcNumeric(10))
                                        .foregroundStyle(Ink.tertiary)

                                    Text("·")
                                        .font(.mcNumeric(10))
                                        .foregroundStyle(Ink.quaternary)

                                    Text(item.path)
                                        .font(.system(size: 10, design: .monospaced))
                                        .foregroundStyle(Ink.quaternary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                            }

                            Spacer()

                            Text(item.size.byteStringCN)
                                .font(.mcNumeric(12, weight: .medium))
                                .foregroundStyle(Ink.primary)
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
        .frame(minHeight: 220, maxHeight: 320)
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
            Button("智能归档到子目录 (Archived_Downloads)") {
                executeArchive()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(selectedCount == 0 || isCleaning)

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
            let res = DownloadsOrganizerScanner.shared.scan()
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

    private func executeClean(toTrash: Bool) {
        isCleaning = true
        let targets = summary.items.filter(\.isSelected)

        DispatchQueue.global(qos: .userInitiated).async {
            let res = DownloadsOrganizerScanner.shared.clean(items: targets, toTrash: toTrash)
            DispatchQueue.main.async {
                self.isCleaning = false
                let mode = toTrash ? "移入废纸篓" : "彻底删除"
                self.bannerFeedback = "已安全\(mode) \(res.cleanedCount) 个下载文件，"
                    + "实测释放 \(res.freedBytes.byteStringCN)"
                    + (res.errorCount > 0 ? "；\(res.rejectedCount) 项被护栏拦下、\(res.failedCount) 项失败" : "")
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }

    private func executeArchive() {
        isCleaning = true
        let targets = summary.items.filter(\.isSelected)
        let targetDir = (NSString(string: "~/Downloads").expandingTildeInPath as NSString).appendingPathComponent("Archived_Downloads")

        DispatchQueue.global(qos: .userInitiated).async {
            let res = DownloadsOrganizerScanner.shared.archive(items: targets, targetDirectory: targetDir)
            DispatchQueue.main.async {
                self.isCleaning = false
                var text = "已成功将 \(res.movedCount) 个文件归档移动至 ~/Downloads/Archived_Downloads"
                if res.errorCount > 0 { text += "；\(res.errorCount) 项未移动：\(res.firstFailure ?? "被安全护栏拦下")" }
                self.bannerFeedback = text
                self.loadData()
            }
        }
    }
}
