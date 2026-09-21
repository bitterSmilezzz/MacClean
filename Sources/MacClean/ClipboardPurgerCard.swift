import SwiftUI
import AppKit

// MARK: - 剪贴板历史与大文件临时缓冲区治理卡片 (v1.63.0)

public struct ClipboardPurgerCard: View {
    public var onClose: () -> Void
    public var onTriggerClean: (() -> Void)?

    @State private var report: ClipboardReport = ClipboardReport()
    @State private var isScanning: Bool = false
    @State private var isCleaning: Bool = false
    @State private var bannerFeedback: String? = nil
    /// 两个会删文件的动作必须先确认：`~/Library/TemporaryItems` 里混着 Office /
    /// 编辑器**自动恢复草稿**，原先点一下就立刻执行。
    @State private var pendingAction: PurgeAction? = nil

    enum PurgeAction: String, Identifiable {
        case caches, all
        var id: String { rawValue }
    }

    public init(onClose: @escaping () -> Void, onTriggerClean: (() -> Void)? = nil) {
        self.onClose = onClose
        self.onTriggerClean = onTriggerClean
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            topHeader
            metricsSummaryBar
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
        // 确认弹窗挂在卡片根容器上。先前写成 `EmptyView().confirmationDialog(...)`
        // 再塞进 VStack：SwiftUI 对零尺寸视图上的 present 修饰符不可靠，实测点
        // 「全量净化」后弹窗根本不出现——自检里 isPresented 会翻转所以照样通过，
        // 真机上却等于没有确认。
        .confirmationDialog(
            pendingAction == .all ? "确认全量净化剪贴板与临时缓存" : "确认清理剪贴板临时缓存",
            isPresented: Binding(
                get: { pendingAction != nil },
                set: { if !$0 { pendingAction = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingAction
        ) { action in
            Button(action == .all ? "清空并移入废纸篓" : "移入废纸篓", role: .destructive) {
                if action == .all { executePurgeAll() } else { executeCleanCaches() }
            }
            Button("取消", role: .cancel) {}
        } message: { action in
            Text(action == .all
                 ? "将清空系统剪贴板内容，并把 \(report.cacheItems.count) 项临时缓存移入废纸篓（可放回）。这里可能包含正在编辑文档的自动恢复草稿，请确认你没有未保存的工作。"
                 : "将把 \(report.cacheItems.count) 项临时缓存移入废纸篓（可放回）。归属不可识别或仍然新鲜的条目不会被处理。")
        }
    }

    // MARK: - 顶部栏

    private var topHeader: some View {
        HStack(spacing: Space.xs) {
            IconSlot(systemName: "doc.on.clipboard", size: 15, weight: .semibold, color: Accent.tint, width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text("剪贴板与临时缓冲区治理")
                    .font(Typo.title)
                    .foregroundStyle(Ink.primary)
                Text("排查内存剪贴板大对象、敏感凭据与系统临时置换文件")
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

    // MARK: - 指标看板

    private var metricsSummaryBar: some View {
        HStack(spacing: Space.sm) {
            metricItem(
                title: "剪贴板内存占用",
                value: report.totalMemorySize.byteStringCN,
                detail: "\(report.items.count) 种格式",
                color: report.totalMemorySize > 5 * 1024 * 1024 ? Signal.caution : Ink.primary
            )
            Divider().frame(height: 28)
            metricItem(
                title: "磁盘临时缓存",
                value: report.totalCacheSize.byteStringCN,
                detail: "\(report.cacheItems.count) 项",
                color: Signal.positive
            )
            Divider().frame(height: 28)
            metricItem(
                title: "隐私安全状态",
                value: report.hasSensitiveData ? "⚠️ 存在敏感凭据" : "安全",
                detail: report.hasSensitiveData ? "建议立即清空" : "无凭据泄露",
                color: report.hasSensitiveData ? Signal.critical : Signal.positive
            )
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

    // MARK: - 内容列表

    private var contentListContainer: some View {
        ScrollView {
            VStack(spacing: Space.xs) {
                if report.isEmpty {
                    Text("当前剪贴板为空，且未发现临时缓存文件")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.tertiary)
                        .padding(.vertical, Space.lg)
                } else {
                    if !report.items.isEmpty {
                        HStack {
                            Text("📋 剪贴板格式明细 (\(report.items.count))")
                                .font(Typo.section)
                                .foregroundStyle(Ink.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)

                        VStack(spacing: 2) {
                            ForEach(report.items) { item in
                                HStack(spacing: Space.sm) {
                                    Image(systemName: item.dataType.icon)
                                        .font(.system(size: 13))
                                        .foregroundStyle(item.isSensitive ? Signal.critical : Accent.tint)
                                        .frame(width: 18)

                                    VStack(alignment: .leading, spacing: 2) {
                                        HStack(spacing: Space.xs) {
                                            Text(item.dataType.rawValue)
                                                .font(Typo.rowStrong)
                                                .foregroundStyle(Ink.primary)

                                            Text(item.typeName)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(Ink.quaternary)

                                            if item.isSensitive {
                                                Text("敏感数据")
                                                    .font(Typo.micro)
                                                    .foregroundStyle(Signal.critical)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(Signal.critical.opacity(0.12))
                                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                            }

                                            if item.isLarge {
                                                Text("大对象")
                                                    .font(Typo.micro)
                                                    .foregroundStyle(Signal.caution)
                                                    .padding(.horizontal, 4)
                                                    .padding(.vertical, 1)
                                                    .background(Signal.caution.opacity(0.12))
                                                    .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                                            }
                                        }

                                        Text(item.preview)
                                            .font(Typo.caption)
                                            .foregroundStyle(Ink.tertiary)
                                            .lineLimit(1)
                                    }

                                    Spacer()

                                    Text(item.size.byteStringCN)
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

                    if !report.cacheItems.isEmpty {
                        HStack {
                            Text("⚡️ 临时缓冲区文件 (\(report.cacheItems.count))")
                                .font(Typo.section)
                                .foregroundStyle(Ink.secondary)
                            Spacer()
                        }
                        .padding(.horizontal, 4)
                        .padding(.top, 4)

                        VStack(spacing: 2) {
                            ForEach(report.cacheItems) { cache in
                                HStack(spacing: Space.sm) {
                                    Image(systemName: "shippingbox.fill")
                                        .font(.system(size: 13))
                                        .foregroundStyle(Ink.secondary)
                                        .frame(width: 18)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(cache.name)
                                            .font(Typo.rowStrong)
                                            .foregroundStyle(Ink.primary)
                                        Text(cache.note)
                                            .font(Typo.caption)
                                            .foregroundStyle(Ink.quaternary)
                                        Text("依据：\(cache.sizeAndAgeEvidence)")
                                            .font(Typo.micro)
                                            .foregroundStyle(cache.isReadable ? Ink.tertiary : Signal.caution)
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
                }
            }
            .padding(.vertical, 2)
        }
        .frame(minHeight: 180, maxHeight: 260)
    }

    // MARK: - 反馈条

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

    // MARK: - 底栏

    private var actionFooterBar: some View {
        HStack(spacing: Space.sm) {
            Button("清空剪贴板") {
                executeClearMemory()
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .disabled(report.items.isEmpty || isCleaning)

            if !report.cacheItems.isEmpty {
                Button("清理临时缓存") {
                    pendingAction = .caches
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .disabled(isCleaning)
            }

            Spacer()

            Button {
                pendingAction = .all
            } label: {
                Label("全量净化 (Purge All)", systemImage: "trash.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .disabled(report.isEmpty || isCleaning)
        }
        .padding(.top, 4)
    }

    // MARK: - 逻辑

    private func loadData() {
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = ClipboardPurger.shared.inspect()
            DispatchQueue.main.async {
                self.report = res
                self.isScanning = false
            }
        }
    }

    private func executeClearMemory() {
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let cleared = ClipboardPurger.shared.clearPasteboard()
            DispatchQueue.main.async {
                self.isCleaning = false
                self.bannerFeedback = cleared
                    ? "已清空系统剪贴板（changeCount 已前进，内存驻留已释放）"
                    : "系统拒绝清空剪贴板：内容可能仍在剪贴板里，未计为成功"
                self.loadData()
            }
        }
    }

    private func executeCleanCaches() {
        isCleaning = true
        let targets = report.cacheItems
        DispatchQueue.global(qos: .userInitiated).async {
            let res = ClipboardPurger.shared.cleanClipboardCaches(items: targets)
            DispatchQueue.main.async {
                self.isCleaning = false
                self.bannerFeedback = res.summary
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }

    private func executePurgeAll() {
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let res = ClipboardPurger.shared.purgeAll()
            DispatchQueue.main.async {
                self.isCleaning = false
                var text = res.clearedMemory
                    ? "已清空剪贴板内存内容"
                    : "剪贴板内存内容未清空（\(res.memoryFailure ?? "系统拒绝")）"
                text += "；临时缓存：\(res.cacheResult.summary)"
                self.bannerFeedback = text
                self.loadData()
                self.onTriggerClean?()
            }
        }
    }
}
