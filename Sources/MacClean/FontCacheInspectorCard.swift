import SwiftUI
import AppKit

// MARK: - 字体缓存与孤儿系统字体残存治理面板 (v1.61.0)

public struct FontCacheInspectorCard: View {
    public var onClose: () -> Void
    public var onTriggerClean: (() -> Void)?

    @State private var report: FontInspectionReport = FontInspectionReport()
    @State private var isScanning: Bool = false
    @State private var isCleaning: Bool = false
    @State private var searchKeyword: String = ""
    @State private var selectedTab: FontTabOption = .all
    @State private var bannerFeedback: String? = nil
    @State private var showConfirmClean: Bool = false

    public enum FontTabOption: String, CaseIterable, Identifiable {
        case all = "全部字体"
        case corrupted = "⚠️ 损坏字体"
        case duplicate = "📄 重复副本"
        case caches = "⚡️ 渲染缓存"

        public var id: String { rawValue }
    }

    public init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
    }

    // MARK: - 过滤计算

    private var filteredFonts: [FontItem] {
        report.userFonts.filter { item in
            switch selectedTab {
            case .all: break
            case .corrupted:
                guard item.status == .corrupted else { return false }
            case .duplicate:
                guard item.status == .duplicate else { return false }
            case .caches:
                return false
            }

            if !searchKeyword.isEmpty {
                let kw = searchKeyword.lowercased()
                let matchName = item.fileName.lowercased().contains(kw)
                let matchFamily = (item.familyName ?? "").lowercased().contains(kw)
                let matchPS = (item.postscriptName ?? "").lowercased().contains(kw)
                return matchName || matchFamily || matchPS
            }

            return true
        }
    }

    private var filteredCaches: [FontCacheItem] {
        guard selectedTab == .all || selectedTab == .caches else { return [] }
        if searchKeyword.isEmpty { return report.cacheItems }
        let kw = searchKeyword.lowercased()
        return report.cacheItems.filter {
            $0.name.lowercased().contains(kw) || $0.path.lowercased().contains(kw)
        }
    }

    private var selectedFontCount: Int {
        report.userFonts.filter { $0.isSelected }.count
    }

    private var selectedCacheCount: Int {
        report.cacheItems.filter { $0.isSelected }.count
    }

    // MARK: - 主视图

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            topHeader
            metricsSummaryBar
            tabAndSearchControls
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
        .confirmationDialog("确认清理字体与字体缓存", isPresented: $showConfirmClean, titleVisibility: .visible) {
            Button("安全移入废纸篓", role: .destructive) {
                executeClean(toTrash: true)
            }
            Button("彻底删除", role: .destructive) {
                executeClean(toTrash: false)
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将清理选中的 \(selectedFontCount) 个字体文件（\(report.reclaimableFontSize.byteStringCN)）与 \(selectedCacheCount) 项字体渲染缓存（\(report.reclaimableCacheSize.byteStringCN)）。")
        }
    }

    // MARK: - 子组件：顶部栏

    private var topHeader: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "textformat.size", size: 15, weight: .semibold, color: Accent.tint, width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("字体与渲染缓存治理")
                    .font(Typo.title)
                    .foregroundStyle(Ink.primary)
                Text("排查损坏字体、重复副本与系统 CoreText / fontd 渲染缓存")
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
            metricItem(title: "已安装字体", value: "\(report.userFonts.count) 款", detail: report.totalFontSize.byteStringCN, color: Ink.primary)
            Divider().frame(height: 28)
            metricItem(title: "损坏字体", value: "\(report.corruptedFonts.count) 款", detail: report.corruptedFonts.isEmpty ? "健康" : "无法解析", color: report.corruptedFonts.isEmpty ? Signal.positive : Signal.critical)
            Divider().frame(height: 28)
            metricItem(title: "重复副本", value: "\(report.duplicateFonts.count) 款", detail: report.duplicateFonts.isEmpty ? "无重复" : "可去重", color: report.duplicateFonts.isEmpty ? Ink.tertiary : Signal.caution)
            Divider().frame(height: 28)
            metricItem(title: "渲染缓存", value: report.totalCacheSize.byteStringCN, detail: "\(report.cacheItems.count) 项", color: Signal.positive)
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

    // MARK: - 子组件：Tab 与搜索

    private var tabAndSearchControls: some View {
        HStack(spacing: Space.sm) {
            Picker("分类", selection: $selectedTab) {
                ForEach(FontTabOption.allCases) { opt in
                    Text(opt.rawValue).tag(opt)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 320)

            Spacer()

            SearchField(placeholder: "搜索字体名称 / PostScript...", text: $searchKeyword)
                .frame(maxWidth: 220)
        }
    }

    // MARK: - 子组件：列表容器

    private var contentListContainer: some View {
        ScrollView {
            VStack(spacing: Space.xs) {
                if selectedTab == .caches {
                    cachesListView
                } else if selectedTab == .all {
                    if !report.cacheItems.isEmpty {
                        cachesSectionHeader
                        cachesListView
                    }
                    fontsSectionHeader
                    fontsListView
                } else {
                    fontsListView
                }
            }
            .padding(.vertical, 2)
        }
        .frame(minHeight: 220, maxHeight: 320)
    }

    private var cachesSectionHeader: some View {
        HStack {
            Text("⚡️ 字体渲染缓存 (\(report.cacheItems.count))")
                .font(Typo.section)
                .foregroundStyle(Ink.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var fontsSectionHeader: some View {
        HStack {
            Text("🔤 用户字体列表 (\(filteredFonts.count))")
                .font(Typo.section)
                .foregroundStyle(Ink.secondary)
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var cachesListView: some View {
        VStack(spacing: 2) {
            ForEach(filteredCaches) { cache in
                HStack(spacing: Space.sm) {
                    Button(action: {
                        toggleCacheSelection(id: cache.id)
                    }) {
                        Image(systemName: cache.isSelected ? "checkmark.square.fill" : "square")
                            .font(.system(size: 13))
                            .foregroundStyle(cache.isSelected ? Accent.tint : Ink.tertiary)
                    }
                    .buttonStyle(.plain)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(cache.name)
                            .font(Typo.rowStrong)
                            .foregroundStyle(Ink.primary)
                        Text(cache.note)
                            .font(Typo.caption)
                            .foregroundStyle(Ink.quaternary)
                    }

                    Spacer()

                    Text(cache.size.byteStringCN)
                        .font(.mcNumeric(12, weight: .medium))
                        .foregroundStyle(Signal.positive)
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, 6)
                .background(Surface.raised)
                .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            }
        }
    }

    private var fontsListView: some View {
        VStack(spacing: 2) {
            if filteredFonts.isEmpty {
                Text("未发现符合条件的字体文件")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .padding(.vertical, Space.lg)
            } else {
                ForEach(filteredFonts) { font in
                    HStack(spacing: Space.sm) {
                        Button(action: {
                            toggleFontSelection(id: font.id)
                        }) {
                            Image(systemName: font.isSelected ? "checkmark.square.fill" : "square")
                                .font(.system(size: 13))
                                .foregroundStyle(font.isSelected ? Accent.tint : Ink.tertiary)
                        }
                        .buttonStyle(.plain)

                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: Space.xs) {
                                Text(font.familyName ?? font.fileName)
                                    .font(Typo.rowStrong)
                                    .foregroundStyle(Ink.primary)

                                Text(font.format.rawValue)
                                    .font(Typo.micro)
                                    .foregroundStyle(Ink.quaternary)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(Surface.sunken)
                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

                                if font.status == .corrupted {
                                    Text("损坏/无法解析")
                                        .font(Typo.micro)
                                        .foregroundStyle(Signal.critical)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Signal.critical.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                } else if font.status == .duplicate {
                                    Text("重复副本")
                                        .font(Typo.micro)
                                        .foregroundStyle(Signal.caution)
                                        .padding(.horizontal, 4)
                                        .padding(.vertical, 1)
                                        .background(Signal.caution.opacity(0.12))
                                        .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                }
                            }

                            if let ps = font.postscriptName {
                                Text("PS: \(ps) · \(font.path)")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Ink.quaternary)
                                    .lineLimit(1)
                            } else {
                                Text(font.path)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(Ink.quaternary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer()

                        Text(font.size.byteStringCN)
                            .font(.mcNumeric(12, weight: .medium))
                            .foregroundStyle(Ink.secondary)
                    }
                    .padding(.horizontal, Space.sm)
                    .padding(.vertical, 6)
                    .background(Surface.raised)
                    .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                }
            }
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
            Button("重置系统字体数据库 (atsutil)") {
                resetAtsDatabase()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(isCleaning)

            Spacer()

            VStack(alignment: .trailing, spacing: 0) {
                Text("已选 \(selectedFontCount) 字体 / \(selectedCacheCount) 缓存")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                Text(report.totalReclaimableSize.byteStringCN)
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
            .disabled(selectedFontCount == 0 && selectedCacheCount == 0 || isCleaning)
        }
        .padding(.top, 4)
    }

    // MARK: - 逻辑方法

    private func loadData() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = FontCacheInspector.shared.scan()
            DispatchQueue.main.async {
                self.report = res
                self.isScanning = false
            }
        }
    }

    private func toggleFontSelection(id: String) {
        guard let idx = report.userFonts.firstIndex(where: { $0.id == id }) else { return }
        report.userFonts[idx].isSelected.toggle()
    }

    private func toggleCacheSelection(id: String) {
        guard let idx = report.cacheItems.firstIndex(where: { $0.id == id }) else { return }
        report.cacheItems[idx].isSelected.toggle()
    }

    private func executeClean(toTrash: Bool) {
        isCleaning = true
        let fontsToClean = report.userFonts.filter { $0.isSelected }
        let cachesToClean = report.cacheItems.filter { $0.isSelected }

        DispatchQueue.global(qos: .userInitiated).async {
            let fRes = FontCacheInspector.shared.cleanFonts(items: fontsToClean, toTrash: toTrash)
            let cRes = FontCacheInspector.shared.cleanCaches(items: cachesToClean)
            let totalFreed = fRes.freedBytes + cRes.freedBytes

            DispatchQueue.main.async {
                self.isCleaning = false
                self.bannerFeedback = "已清理 \(fRes.cleanedCount) 款字体与 \(cRes.cleanedCount) 项缓存，释放 \(totalFreed.byteStringCN)"
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }

    private func resetAtsDatabase() {
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let success = FontCacheInspector.shared.resetUserAtsDatabases()
            DispatchQueue.main.async {
                self.isCleaning = false
                self.bannerFeedback = success ? "已成功重置用户字体注册表数据库 (atsutil)" : "重置命令执行完成"
                self.loadData()
            }
        }
    }
}
