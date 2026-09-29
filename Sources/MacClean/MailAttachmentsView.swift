import SwiftUI

// MARK: - Mail 附件清理页 (v1.73.15)
//
// 附件是用户数据：页面上没有「全选可清理」档，所有行零默认勾选、清理前逐批确认；
// 根读不到时横幅明示并给授权引导（G13：读不到 ≠ 这里没有附件）。

/// 页面状态放外部对象（ViewInspector 在 macOS 27 上读不回 @State 的选中态）。
final class MailAttachmentsModel: ObservableObject {
    @Published var summary: MailAttachmentsScanner.Summary = .init()
    @Published var isScanning = false
    @Published var isCleaning = false
    @Published var bannerFeedback: String? = nil

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let s = MailAttachmentsScanner.scan()
            DispatchQueue.main.async {
                self?.summary = s
                self?.isScanning = false
            }
        }
    }

    func toggle(_ item: MailAttachmentsScanner.AttachmentItem) {
        guard let idx = summary.items.firstIndex(where: { $0.id == item.id }) else { return }
        summary.items[idx].isSelected.toggle()
    }

    /// 确认弹窗只带用户勾选的条目；默认移入废纸篓（可撤销）。**不提供「彻底删除」按钮**——
    /// 永久删除走废纸篓的清空链路，避免这里多一条需要人工点验的确认路径（复审 P3-3）。
    func clean(_ items: [MailAttachmentsScanner.AttachmentItem], toTrash: Bool) {
        guard !items.isEmpty, !isCleaning else { return }
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = MailAttachmentsScanner.clean(items: items, toTrash: toTrash)
            DispatchQueue.main.async {
                self?.isCleaning = false
                var lines = ["已处理 \(outcome.cleanedCount) 项，\(outcome.space.claim())"]
                if !outcome.rejected.isEmpty {
                    lines.append("被安全护栏拦下 \(outcome.rejected.count) 项")
                    lines.append(contentsOf: outcome.rejected.prefix(5).map { "\($0.name)：\($0.message)" })
                }
                if !outcome.failed.isEmpty {
                    lines.append("失败 \(outcome.failed.count) 项")
                    lines.append(contentsOf: outcome.failed.prefix(5).map { "\($0.name)：\($0.message)" })
                }
                self?.bannerFeedback = lines.joined(separator: "\n")
                self?.scan()
            }
        }
    }
}

struct MailAttachmentsView: View {
    @StateObject private var model = MailAttachmentsModel()
    @State private var showConfirm = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            header
            if let banner = model.bannerFeedback {
                Text(banner)
                    .font(Typo.caption)
                    .foregroundStyle(Ink.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.xs)
                    .background(Surface.raised)
                    .cornerRadius(6)
            }
            incompleteBanner
            contentList
            footer
        }
        .padding(Space.gutter)
        .onAppear { model.scan() }
        .sheet(isPresented: $showConfirm) { confirmSheet }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("邮件附件").font(Typo.title)
                Text("附件是邮件的数据本体：体积大或年代久不等于可以删。删除后若邮件仍在服务器，附件可重新下载。所有条目默认不勾选。")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.secondary)
            }
            Spacer()
            Button("重新扫描") { model.scan() }
                .disabled(model.isScanning)
        }
    }

    @ViewBuilder
    private var incompleteBanner: some View {
        if !model.summary.isResultComplete {
            VStack(alignment: .leading, spacing: Space.xxs) {
                ForEach(model.summary.unreadableRoots, id: \.self) { root in
                    Label {
                        Text("读不到（需要完全磁盘访问权限）：\(root)")
                            .font(Typo.caption)
                            .textSelection(.enabled)
                    } icon: {
                        Image(systemName: "lock")
                    }
                }
                ForEach(model.summary.deferredRoots, id: \.self) { root in
                    Text("本轮没能读取（请稍后重扫）：\(root)")
                        .font(Typo.caption)
                        .foregroundStyle(Ink.secondary)
                }
                ForEach(model.summary.issues, id: \.self) { issue in
                    Text(issue).font(Typo.caption).foregroundStyle(Ink.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Space.xs)
            .background(Surface.raised)
            .cornerRadius(6)
        }
    }

    @ViewBuilder
    private var contentList: some View {
        if model.summary.items.isEmpty {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(model.summary.isResultComplete
                     ? "没有找到 Mail 附件缓存"
                     : "结果不完整——先解决上方的读取问题，再重扫一次")
                    .font(Typo.body)
                    .foregroundStyle(Ink.secondary)
                Text("注意：「没有找到」只有在结果完整时才成立。")
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.summary.items) { item in
                        MailAttachmentRow(item: item) { model.toggle(item) }
                        Divider()
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text("已选 \(model.summary.selectedCount) 项 · \(model.summary.selectedSize.byteStringCN)")
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)
            Spacer()
            Button("清理已选…") { showConfirm = true }
                .disabled(model.summary.selectedCount == 0 || model.isCleaning)
        }
    }

    private var confirmSheet: some View {
        VStack(alignment: .leading, spacing: Space.sm) {
            Text("清理 \(model.summary.selectedCount) 个邮件附件（\(model.summary.selectedSize.byteStringCN)）")
                .font(Typo.title)
            Text("附件会移入废纸篓，可从清理历史一键放回。删除后若邮件仍在服务器，附件可重新下载；若邮件本体已从服务器删除，附件将无法找回。")
                .font(Typo.body)
                .foregroundStyle(Ink.secondary)
            if model.summary.items.contains(where: { $0.isSelected && !$0.readable }) {
                Text("选中有本轮未读全的条目，显示的体积只是下限。")
                    .font(Typo.caption)
                    .foregroundStyle(Signal.caution)
            }
            HStack {
                Spacer()
                Button("取消") { showConfirm = false }
                Button("移入废纸篓") {
                    showConfirm = false
                    model.clean(model.summary.items.filter(\.isSelected), toTrash: true)
                }
            }
        }
        .padding(Space.gutter)
        .frame(width: 460)
    }
}

private struct MailAttachmentRow: View {
    let item: MailAttachmentsScanner.AttachmentItem
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: Space.sm) {
            Toggle("", isOn: Binding(
                get: { item.isSelected },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(Typo.body).lineLimit(1)
                Text(item.path).font(Typo.caption).foregroundStyle(Ink.tertiary).lineLimit(1)
                if !item.readable {
                    Text("本轮未读全，体积为下限").font(Typo.caption).foregroundStyle(Signal.caution)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(item.size.byteStringCN).font(.mcNumeric(13))
                if let m = item.modifiedAt {
                    Text(Self.ageText(from: m)).font(Typo.caption).foregroundStyle(Ink.tertiary)
                }
            }
        }
        .padding(.vertical, Space.xxs)
        .contentShape(Rectangle())
        .onTapGesture { onToggle() }
    }

    /// 年龄只说量到的 mtime，不推断"多久没用的附件"
    static func ageText(from date: Date) -> String {
        let days = Int(Date().timeIntervalSince(date) / 86400)
        if days <= 0 { return "今天修改" }
        if days < 30 { return "修改于 \(days) 天前" }
        if days < 365 { return "修改于 \(days / 30) 个月前" }
        return "修改于 \(days / 365) 年前"
    }
}
