import SwiftUI
import AppKit

/// 「空间审计」：只报告、不删除（规则 v2 步骤 7 / 决策 D-3）。
///
/// 这一页存在的理由是一条**边界**，不是一个功能：判据只是"它很大 / 它很久没动"的项，
/// 与"它是垃圾"之间没有因果关系。把它们放进清理页——带勾选框、带「清理已选项」按钮——
/// 等于用界面语言替用户下了一个工具并没有依据下的结论。
/// 所以同样的数据搬到这里，只保留三样东西：**是什么、多大、多久没动**，
/// 加上"为什么它出现在这里"和"要处理的话该走哪条路"，**不给删除按钮**。
struct SpaceAuditView: View {
    @EnvironmentObject private var app: AppState

    private struct AuditSection {
        let ruleID: String
        let title: String
        /// 判据本身——用户最该看到的一句话
        let basis: String
        /// 真要处理时更合适的去处；nil 表示没有更好的办法，只能自己判断
        let betterWay: String?
        let items: [CleanItem]
    }

    private var sections: [AuditSection] {
        let byRule = Dictionary(grouping: app.allAuditItems) { $0.rule ?? "?" }
        let meta: [(String, String, String, String?)] = [
            ("T2", "下载目录里的大文件与旧文件",
             "判据：>500 MB，或 >180 天没被访问过",
             "多数能重新下载，但「别人发给你」「临时链接」这两类拿不回来——先确认再动手"),
            ("T3", "占用最大的文件",
             "判据：体积 >1 GB（从常见根目录向下最多两层）",
             "大 ≠ 可删。虚拟机镜像、工程素材、视频都很大，也都可能是不可替代的"),
            ("T4", "长期未用的模拟器设备",
             "判据：>90 天没有改动",
             "用 Xcode → Settings → Platforms 删除更干净：会一并清掉注册信息，只删目录会留下悬空引用"),
            ("T5", "iPhone / iPad 本地备份",
             "判据：备份时间 >180 天",
             "这里很可能躺着某台设备唯一一份备份。要在「访达 / iPhone 镜像」的备份管理里删，别直接删目录"),
        ]
        return meta.compactMap { id, title, basis, better in
            let items = (byRule[id] ?? []).sorted { $0.size > $1.size }
            return items.isEmpty ? nil : AuditSection(ruleID: id, title: title, basis: basis,
                                                  betterWay: better, items: items)
        }
    }

    private var totalBytes: Int64 { app.auditTotalBytes }
    private var hasScanned: Bool { app.categories.contains { $0.isScanned } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Hairline()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Surface.window)
    }

    // MARK: - 页头

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("空间审计")
                        .font(Typo.title)
                        .foregroundColor(Ink.primary)
                    Text("这些项目只是占地方——工具没有依据说它们可以删")
                        .font(Typo.caption)
                        .foregroundColor(Ink.secondary)
                }
                Spacer()
                Text("\(app.allAuditItems.count) 项 · \(totalBytes.byteStringCN)")
                    .font(Typo.rowStrong)
                    .foregroundColor(Ink.secondary)
                Button("扫描全部分类") { app.scanAll() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(app.isScanningAll)
            }
            // 为什么把这句话单独占一行：用户已经习惯"列表 = 待删清单"，
            // 不显式否定，他还是会去找勾选框。
            HStack(spacing: 6) {
                Image(systemName: "nosign")
                    .font(.system(size: 11))
                    .foregroundColor(Signal.caution)
                Text("这一页没有删除按钮，也不提供勾选框。要清的是缓存、日志与临时文件——在左侧「清理」里。")
                    .font(Typo.caption)
                    .foregroundColor(Ink.secondary)
            }
            .padding(.horizontal, Space.sm)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Signal.caution.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
    }

    // MARK: - 正文

    @ViewBuilder
    private var content: some View {
        if app.allAuditItems.isEmpty {
            EmptyState(
                icon: "chart.bar.doc.horizontal",
                title: hasScanned ? "没有需要审计的空间占用" : "还没有审计数据",
                message: hasScanned
                    ? "扫描过的位置里没有发现「很大或很久没动」的项。"
                    : "审计结果来自各分类扫描——先扫一次。",
                actionTitle: hasScanned ? nil : "开始扫描"
            ) {
                if !hasScanned { app.scanAll() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Space.lg) {
                    ForEach(sections, id: \.ruleID) { section in
                        sectionView(section)
                    }
                }
                .padding(.horizontal, Space.gutter)
                .padding(.vertical, Space.sm)
            }
        }
    }

    private func sectionView(_ section: AuditSection) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Space.xs) {
                Text(section.title)
                    .font(Typo.section)
                    .foregroundColor(Ink.primary)
                Text("规则 \(section.ruleID)")
                    .font(Typo.micro)
                    .foregroundColor(Ink.tertiary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Surface.sunken)
                    .clipShape(Capsule())
                Spacer()
                Text("\(section.items.count) 项 · \(section.items.reduce(Int64(0)) { $0 + $1.size }.byteStringCN)")
                    .font(Typo.caption)
                    .foregroundColor(Ink.secondary)
            }
            Text(section.basis)
                .font(Typo.caption)
                .foregroundColor(Ink.tertiary)
            if let better = section.betterWay {
                Label {
                    Text(better).font(Typo.caption).foregroundColor(Ink.secondary)
                } icon: {
                    Image(systemName: "arrow.turn.down.right").font(.system(size: 10))
                        .foregroundColor(Signal.caution)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().overlay(Surface.hairline) }
                    auditRow(item)
                }
            }
            .background(Surface.window)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Surface.hairline, lineWidth: 1))
        }
    }

    private func auditRow(_ item: CleanItem) -> some View {
        HStack(alignment: .top, spacing: Space.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name)
                    .font(Typo.rowStrong)
                    .foregroundColor(Ink.primary)
                    .lineLimit(1)
                Text(item.path)
                    .font(Typo.micro)
                    .foregroundColor(Ink.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let lastUsed = item.lastUsed {
                    Text("最后修改于 \(lastUsed.relativeUsage)")
                        .font(Typo.micro)
                        .foregroundColor(Ink.tertiary)
                }
            }
            Spacer(minLength: Space.sm)
            Text(item.size.byteStringCN)
                .font(.mcNumeric(12))
                .foregroundColor(Ink.primary)
            Button("在访达中显示") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
            }
            .buttonStyle(.borderless)
            .font(Typo.caption)
            .foregroundColor(Accent.tint)
            .accessibilityIdentifier("spaceAuditReveal_\(item.rule ?? "")")
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, Space.xs)
    }
}
