import SwiftUI
import AppKit

// MARK: - 系统崩溃与诊断报告治理悬浮抽屉卡片

public struct DiagnosticReportCard: View {
    @ObservedObject private var scanner = DiagnosticReportScanner.shared
    @EnvironmentObject private var app: AppState

    public var onClose: () -> Void
    public var onTriggerClean: (() -> Void)?

    @State private var filterKind: ReportFilterOption = .all
    @State private var searchKeyword: String = ""
    @State private var showConfirmClean: Bool = false
    @State private var previewItem: DiagnosticReportItem? = nil
    @State private var previewContent: String = ""
    @State private var bannerFeedback: String? = nil
    @State private var isCleaning: Bool = false

    public enum ReportFilterOption: String, CaseIterable, Identifiable {
        case all = "全部报告"
        case orphan = "👻 孤儿转储"
        case stale = "🍂 陈旧 (>30天)"
        case crash = "💥 应用崩溃"
        case spinHang = "⏳ 卡死/Spin"
        case coreDump = "💾 核心转储"

        public var id: String { rawValue }
    }

    public init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
    }

    // MARK: - 过滤计算

    private var filteredReports: [DiagnosticReportItem] {
        scanner.reports.filter { item in
            // 类别筛选
            switch filterKind {
            case .all: break
            case .orphan:
                guard item.isOrphan else { return false }
            case .stale:
                guard item.isStale else { return false }
            case .crash:
                guard item.kind == .crash else { return false }
            case .spinHang:
                guard item.kind == .spinHang else { return false }
            case .coreDump:
                guard item.kind == .coreDump else { return false }
            }

            // 搜索关键字
            if !searchKeyword.isEmpty {
                let kw = searchKeyword.lowercased()
                let matchName = item.appName.lowercased().contains(kw)
                let matchFile = item.fileName.lowercased().contains(kw)
                let matchBid = (item.bundleID ?? "").lowercased().contains(kw)
                let matchEx = (item.exceptionSummary ?? "").lowercased().contains(kw)
                return matchName || matchFile || matchBid || matchEx
            }

            return true
        }
    }

    private var totalSize: Int64 {
        scanner.reports.reduce(0) { $0 + $1.size }
    }

    private var selectedReports: [DiagnosticReportItem] {
        filteredReports.filter { $0.isSelected }
    }

    private var selectedSize: Int64 {
        selectedReports.reduce(0) { $0 + $1.size }
    }

    private var orphanCount: Int {
        scanner.reports.filter { $0.isOrphan }.count
    }

    private var staleCount: Int {
        scanner.reports.filter { $0.isStale }.count
    }

    /// 空列表时那句结论：读不全的时候只能说"读不全"，不能说"没有残留"
    private var emptyStateText: String {
        if scanner.isScanning { return "正在深入排查系统诊断目录..." }
        if !scanner.isResultComplete {
            return "有 \(scanner.issues.count) 个诊断目录读不到，无法判断是否存在异常报告"
        }
        return "已读到的目录里没有匹配的崩溃或诊断日志"
    }

    // MARK: - 主视图构成

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            topHeader
            metricsSummaryBar
            incompleteNotice
            filterAndActionControls
            reportListContainer
            if let feedback = bannerFeedback {
                bannerBar(feedback)
            }
        }
        .padding(Space.sm)
        .background(Surface.group)
        .clipShape(RoundedRectangle(cornerRadius: Radius.group, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Radius.group, style: .continuous)
                .stroke(Surface.hairline, lineWidth: 1)
        )
        .onAppear {
            if scanner.reports.isEmpty && !scanner.isScanning {
                scanner.scan()
            }
        }
        .sheet(item: $previewItem) { item in
            logPreviewSheet(item)
        }
        .confirmationDialog(
            "确认批量释放 \(selectedReports.count) 份诊断报告（\(selectedSize.byteStringCN)）？",
            isPresented: $showConfirmClean,
            titleVisibility: .visible
        ) {
            Button("移入系统废纸篓 (推荐)", role: .none) {
                performClean(permanently: false)
            }
            Button("永久删除", role: .destructive) {
                performClean(permanently: true)
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 顶部标题与关闭

    private var topHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Accent.tint)

            Text("系统崩溃与诊断报告治理透视")
                .font(Typo.title)
                .foregroundStyle(Ink.primary)

            if scanner.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .padding(.leading, 4)
                Text("深度解析中...")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.tertiary)
            }

            Spacer()

            Button(action: {
                scanner.scan()
            }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Ink.secondary)
            }
            .buttonStyle(.plain)
            .help("重新扫描诊断报告目录")

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Ink.tertiary)
                    .padding(4)
            }
            .buttonStyle(.plain)
            .help("关闭面板")
        }
    }

    // MARK: - 统计摘要条

    private var metricsSummaryBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Text("总文件数:")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.secondary)
                Text("\(scanner.reports.count)")
                    .font(.mcNumeric(11, weight: .semibold))
                    .foregroundStyle(Ink.primary)
            }

            HStack(spacing: 4) {
                Text("总占用:")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.secondary)
                Text(totalSize.byteStringCN)
                    .font(.mcNumeric(11, weight: .semibold))
                    .foregroundStyle(Accent.tint)
            }

            HStack(spacing: 4) {
                Text("已卸载孤儿:")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.secondary)
                Text("\(orphanCount) 个")
                    .font(.mcNumeric(11, weight: .semibold))
                    .foregroundStyle(Color.purple)
            }

            HStack(spacing: 4) {
                Text("陈旧超30天:")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.secondary)
                Text("\(staleCount) 个")
                    .font(.mcNumeric(11, weight: .semibold))
                    .foregroundStyle(Signal.caution)
            }

            Spacer()
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 6)
        .background(Surface.sunken)
        .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
    }

    // MARK: - 结果不完整提示（「读不到」绝不当成「没有异常报告」）

    /// 只要 `scanner.issues` 非空，这里就常驻一条橙警示，逐条点名读不到的位置。
    /// 列表为空时也不再渲染"绿色对勾 + 暂无残留"，而是"覆盖不全，无法判断"。
    @ViewBuilder
    private var incompleteNotice: some View {
        if let banner = scanner.incompletenessBanner {
            VStack(alignment: .leading, spacing: Space.xxs) {
                HStack(spacing: Space.xs) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Signal.caution)
                    Text(banner)
                        .font(Typo.caption)
                        .foregroundStyle(Ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(scanner.issues) { issue in
                    HStack(alignment: .top, spacing: Space.xs) {
                        Image(systemName: issue.icon)
                            .font(.system(size: 10))
                            .foregroundStyle(issue.kind == .permissionDenied ? Signal.caution : Ink.tertiary)
                        Text(issue.message)
                            .font(Typo.micro)
                            .foregroundStyle(Ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if scanner.issues.contains(where: { $0.kind == .permissionDenied }) {
                    Text("全局报告目录由 root:_analyticsusers 管理，MacClean 不做提权：该位置只能定位与给建议，删除请求会被网关拒为「无权限」。")
                        .font(Typo.micro)
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Signal.caution.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .stroke(Signal.caution.opacity(0.35), lineWidth: 1)
            )
            .accessibilityIdentifier("diagnostic-report-incomplete-notice")
        }
    }

    // MARK: - 过滤标签与快捷操作

    private var filterAndActionControls: some View {
        HStack(spacing: 8) {
            // 分类胶囊
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: Space.xxs) {
                    ForEach(ReportFilterOption.allCases) { opt in
                        let isSel = filterKind == opt
                        Button {
                            withAnimation(Motion.micro) { filterKind = opt }
                        } label: {
                            Text(opt.rawValue)
                                .font(isSel ? Typo.rowStrong : Typo.row)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(isSel ? Accent.tint : Surface.sunken)
                                .foregroundStyle(isSel ? Color.white : Ink.secondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Spacer(minLength: 4)

            // 搜索框
            HStack(spacing: 4) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.tertiary)
                TextField("搜索应用或错误...", text: $searchKeyword)
                    .font(Typo.micro)
                    .textFieldStyle(.plain)
                    .frame(width: 120)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Surface.sunken)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            // 批量勾选与释放
            batchActionButtons
        }
    }

    private var batchActionButtons: some View {
        HStack(spacing: 6) {
            Menu {
                Button("勾选全部孤儿转储") {
                    selectByCondition { $0.isOrphan && !$0.needsConfirmation }
                }
                Button("勾选全部陈旧报告 (>30天)") {
                    selectByCondition { $0.isStale && !$0.needsConfirmation && !$0.isGlobalScope }
                }
                Button("勾选当前列表全部") {
                    // "需确认"与 root 管理的位置不进批量勾选：证据不足与删不动的都不该被顺手勾上
                    selectByCondition { !$0.needsConfirmation && !$0.isGlobalScope }
                }
                Divider()
                Button("全部反选 / 清除勾选") {
                    selectByCondition { _ in false }
                }
            } label: {
                Text("快捷勾选 ▾")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 76)

            Button {
                showConfirmClean = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "trash")
                        .font(.system(size: 10))
                    Text("释放选中 (\(selectedSize.byteStringCN))")
                        .font(Typo.micro)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(selectedReports.isEmpty ? Surface.sunken : Signal.critical)
                .foregroundStyle(selectedReports.isEmpty ? Ink.tertiary : Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(selectedReports.isEmpty || isCleaning)
        }
    }

    // MARK: - 报告列表容器

    private var reportListContainer: some View {
        ScrollView {
            LazyVStack(spacing: 4) {
                if filteredReports.isEmpty {
                    VStack(spacing: 8) {
                        // 结论不完整时**不给绿色对勾**：0 项可能只是"没读到"
                        Image(systemName: scanner.isResultComplete
                              ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(scanner.isResultComplete ? Signal.positive : Signal.caution)
                        Text(emptyStateText)
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                            .multilineTextAlignment(.center)
                        if !scanner.isResultComplete {
                            Text("以上结论仅覆盖读到的部分，不代表系统没有异常报告。")
                                .font(Typo.micro)
                                .foregroundStyle(Ink.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(filteredReports) { item in
                        DiagnosticReportRow(
                            item: item,
                            onToggleSelect: { toggleSelect(item) },
                            onPreview: { openPreview(item) },
                            onCopyPath: { copyPath(item.path) },
                            onClean: { cleanSingle(item) }
                        )
                    }
                }
            }
            .padding(.vertical, 2)
        }
        .frame(maxHeight: 280)
    }

    // MARK: - 辅助操作与清理执行

    private func toggleSelect(_ item: DiagnosticReportItem) {
        if let idx = scanner.reports.firstIndex(where: { $0.id == item.id }) {
            scanner.reports[idx].isSelected.toggle()
        }
    }

    private func selectByCondition(_ condition: (DiagnosticReportItem) -> Bool) {
        withAnimation(Motion.micro) {
            for i in 0..<scanner.reports.count {
                if filteredReports.contains(where: { $0.id == scanner.reports[i].id }) {
                    scanner.reports[i].isSelected = condition(scanner.reports[i])
                }
            }
        }
    }

    private func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        showBanner("已拷贝报告路径至剪贴板")
    }

    private func openPreview(_ item: DiagnosticReportItem) {
        previewItem = item
        if let handle = FileHandle(forReadingAtPath: item.path) {
            defer { try? handle.close() }
            let data = handle.readData(ofLength: 4096)
            previewContent = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .ascii) ?? "无法读取文件内容"
        } else {
            previewContent = "无法打开日志文件"
        }
    }

    private func cleanSingle(_ item: DiagnosticReportItem) {
        let res = scanner.cleanReport(item, permanently: false)
        if res.success {
            showBanner("已移入废纸篓，释放 \(res.freedBytes.byteStringCN)")
            onTriggerClean?()
        } else {
            // 失败/被拦必须说清是哪一条护栏，不能只报"清理失败"
            let reason = scanner.lastRejections.first?.message ?? "未执行删除"
            showBanner("未删除：\(reason)")
        }
    }

    private func performClean(permanently: Bool) {
        isCleaning = true
        let toClean = selectedReports
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = scanner.cleanSummary(toClean, permanently: permanently)
            DispatchQueue.main.async {
                self.isCleaning = false
                // 网关的 summary 已经区分"清了几项 / 几项被护栏拦下 / 几项无权限 / 几项失败"，
                // 绝不在有拦截时只报"批量清理完成"
                self.showBanner(outcome.summary)
                if outcome.cleanedCount > 0 { self.onTriggerClean?() }
            }
        }
    }

    private func showBanner(_ message: String) {
        withAnimation(Motion.standard) {
            bannerFeedback = message
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            withAnimation {
                self.bannerFeedback = nil
            }
        }
    }

    private func bannerBar(_ text: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Signal.positive)
                .font(.system(size: 11))
            Text(text)
                .font(Typo.caption)
                .foregroundStyle(Ink.primary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Signal.positive.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    // MARK: - 预览抽屉弹窗

    private func logPreviewSheet(_ item: DiagnosticReportItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: item.kind.iconName)
                    .foregroundStyle(item.kind.badgeColor)
                Text("诊断日志摘要：\(item.appName)")
                    .font(Typo.title)
                Spacer()
                Button("关闭") { previewItem = nil }
                    .buttonStyle(.plain)
            }

            Text(item.path)
                .font(Typo.micro)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)

            ScrollView {
                Text(previewContent)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Ink.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(Surface.raised)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }
            .frame(height: 320)
        }
        .padding(16)
        .frame(width: 580, height: 420)
    }
}

// MARK: - 子视图拆分：单个诊断报告条目行

struct DiagnosticReportRow: View {
    let item: DiagnosticReportItem
    let onToggleSelect: () -> Void
    let onPreview: () -> Void
    let onCopyPath: () -> Void
    let onClean: () -> Void

    private var selectCheckbox: some View {
        Button(action: onToggleSelect) {
            Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                .font(.system(size: 12))
                .foregroundStyle(item.isSelected ? Accent.tint : Ink.quaternary)
        }
        .buttonStyle(.plain)
    }

    private var reportHeader: some View {
        HStack(spacing: 5) {
            Image(systemName: item.kind.iconName)
                .font(.system(size: 11))
                .foregroundStyle(item.kind.badgeColor)

            Text(item.appName)
                .font(Typo.rowStrong)
                .foregroundStyle(Ink.primary)

            Text(item.statusBadgeText)
                .font(Typo.micro)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(item.statusBadgeColor.opacity(0.12))
                .foregroundStyle(item.statusBadgeColor)
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))

            if let bid = item.bundleID {
                Text(bid)
                    .font(Typo.micro)
                    .foregroundStyle(Ink.quaternary)
                    .lineLimit(1)
            }
        }
    }

    private var exceptionDetails: some View {
        HStack(spacing: 4) {
            if let ex = item.exceptionSummary {
                Text(ex)
                    .font(Typo.micro)
                    .foregroundStyle(Signal.critical)
                    .lineLimit(1)
            } else {
                Text(item.fileName)
                    .font(Typo.micro)
                    .foregroundStyle(Ink.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var actionsRow: some View {
        HStack(spacing: 6) {
            Text(item.size.byteStringCN)
                .font(.mcNumeric(11, weight: .medium))
                .foregroundStyle(Ink.primary)

            Button(action: onPreview) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.secondary)
            }
            .buttonStyle(.plain)
            .help("预览日志关键信息")

            Button(action: onCopyPath) {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.secondary)
            }
            .buttonStyle(.plain)
            .help("拷贝绝对路径")

            Button {
                NSWorkspace.shared.selectFile(item.path, inFileViewerRootedAtPath: "")
            } label: {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(Ink.secondary)
            }
            .buttonStyle(.plain)
            .help("在访达中定位")

            Button(action: onClean) {
                Image(systemName: "trash")
                    .font(.system(size: 10))
                    .foregroundStyle(Signal.critical)
            }
            .buttonStyle(.plain)
            .help("移入废纸篓")
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            selectCheckbox

            VStack(alignment: .leading, spacing: 2) {
                reportHeader
                exceptionDetails
            }

            Spacer()

            actionsRow
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Surface.raised)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
