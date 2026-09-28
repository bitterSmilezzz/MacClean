import SwiftUI
import AppKit

// MARK: - 文件粉碎器（工具页，v1.73.14）
//
// 与扫描-清理链路的关系：粉碎只对用户**逐条点名**的路径生效（这里的手动添加 /
// NSOpenPanel 选择，以及分类页清理项右键「粉碎…」），扫描结果永远不会默认勾选粉碎。
// 删除走 `ShredderService` → 覆写 → `ResidueDeletionGate`，不可恢复、无撤销快照，
// 历史照落、撤销不落。

/// 粉碎器页面状态。列表与结果放外部 ObservableObject 而不是 View 的 @State：
/// RELEASE-CHECKLIST 的教训——@State 里的可变选中/列表态 ViewInspector 读不回，
/// 放外部对象才能被自检真正读到（方法本身也不依赖渲染即可测）。
final class ShredderModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let id: UUID
        let path: String
        let size: Int64?
        let readable: Bool
        let kind: Kind

        enum Kind: Equatable {
            case file, directory, symlink, other
        }

        var name: String { (path as NSString).lastPathComponent }
        var kindText: String {
            switch kind {
            case .file: return "文件"
            case .directory: return "文件夹"
            case .symlink: return "符号链接"
            case .other: return "其他"
            }
        }
        /// nil = 读不全，不给一个编出来的数
        var sizeText: String? {
            guard readable else { return nil }
            return size.map { $0.byteStringCN }
        }
    }

    @Published var entries: [Entry] = []
    @Published var manualPath: String = ""
    @Published var confirmRequested = false
    @Published var outcome: ShredderService.Outcome?
    @Published var isShredding = false
    /// 添加路径被拒时的即时反馈（非空即显示）
    @Published var inputError: String?

    init(seedPaths: [String] = []) {
        for p in seedPaths { add(path: p) }
    }

    /// 添加一条点名路径。返回是否真的加进来了（重复 / 不存在 / 空路径都拒绝并给出原因）。
    @discardableResult
    func add(path raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            inputError = "请先输入或选择一个路径"
            return false
        }
        let expanded = CleanPaths.expand(trimmed)
        let normalized = FileSystem.normalizePath(expanded)
        if entries.contains(where: { $0.path == normalized }) {
            inputError = "该路径已在列表里"
            return false
        }
        var st = stat()
        guard lstat(normalized, &st) == 0 else {
            inputError = "路径不存在：\(normalized)"
            return false
        }
        let type = st.st_mode & S_IFMT
        let kind: Entry.Kind
        switch type {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        // 目录体积用模块级统一 walker：读不全时 readable=false，界面不报一个编出来的数
        var size: Int64?
        var readable = true
        if kind == .file {
            size = Int64(st.st_size)
        } else if kind == .directory {
            let stats = FileSystem.directoryStats(at: normalized)
            size = stats.size
            readable = stats.readable
        } else {
            readable = false
        }
        entries.append(Entry(id: UUID(), path: normalized, size: size,
                             readable: readable, kind: kind))
        inputError = nil
        return true
    }

    /// 手动输入框的「添加」；成功后清空输入框
    func addFromManualInput() {
        let text = manualPath
        if add(path: text) {
            manualPath = ""
        }
    }

    func remove(_ id: UUID) {
        entries.removeAll { $0.id == id }
    }

    func requestConfirm() {
        guard !entries.isEmpty, !isShredding else { return }
        inputError = nil
        confirmRequested = true
    }

    func cancelConfirm() {
        confirmRequested = false
    }

    /// 执行粉碎。覆写 + 删除是阻塞操作，放后台队列；结果回主线程。
    /// 不撤销确认态之前先锁 isShredding，避免二次触发。
    func confirmAndShred() {
        guard !isShredding, !entries.isEmpty else { return }
        isShredding = true
        let paths = entries.map(\.path)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = ShredderService.shred(paths: paths)
            DispatchQueue.main.async {
                guard let self else { return }
                self.outcome = out
                self.entries = []
                self.isShredding = false
            }
        }
    }
}

// MARK: - 工具页

struct ShredderView: View {
    @StateObject private var model = ShredderModel()

    var body: some View {
        VStack(spacing: 0) {
            addControls
            Divider().overlay(Surface.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: Space.md) {
                    if let outcome = model.outcome {
                        ShredderResultSection(outcome: outcome)
                    }
                    if model.entries.isEmpty {
                        EmptyState(
                            icon: "flame",
                            title: "还没有要粉碎的文件",
                            message: "粉碎只对你在这里逐条点名的文件生效，扫描结果永远不会默认勾选粉碎。"
                                + "文件粉碎后不可恢复，请逐条确认路径。"
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        entryList
                    }
                }
                .padding(Space.gutter)
            }
            footer
        }
        .background(Surface.window)
        // present 挂在有尺寸的根容器上（RELEASE-CHECKLIST：EmptyView 上挂 sheet 不弹的坑）
        .sheet(isPresented: $model.confirmRequested) {
            ShredderConfirmSheet(model: model)
        }
    }

    // MARK: 添加控件

    private var addControls: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: 6) {
                IconSlot(systemName: "flame", color: Ink.secondary)
                Text("文件粉碎器").font(Typo.title).foregroundColor(Ink.primary)
                Text("多遍覆写后彻底删除，不可恢复").font(Typo.caption).foregroundColor(Ink.tertiary)
                Spacer()
                Button {
                    pickFiles()
                } label: {
                    Label("选择文件或文件夹…", systemImage: "folder.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.isShredding)
                .accessibilityIdentifier("shredPickButton")
            }
            HStack(spacing: Space.xs) {
                TextField("/路径/到/文件（支持拖入与 ~）", text: $model.manualPath)
                    .textFieldStyle(.roundedBorder)
                    .font(Typo.row)
                    .disabled(model.isShredding)
                    .onSubmit { model.addFromManualInput() }
                    .accessibilityIdentifier("shredPathInput")
                Button("添加") {
                    model.addFromManualInput()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(model.manualPath.trimmingCharacters(in: .whitespaces).isEmpty || model.isShredding)
                .accessibilityIdentifier("shredAddButton")
            }
            if let inputError = model.inputError {
                Text(inputError)
                    .font(Typo.caption)
                    .foregroundColor(Signal.caution)
            }
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "添加"
        panel.message = "选择要粉碎的文件或文件夹（粉碎后不可恢复）"
        if panel.runModal() == .OK {
            for url in panel.urls {
                model.add(path: url.path)
            }
        }
    }

    // MARK: 点名列表

    private var entryList: some View {
        GroupBox {
            VStack(spacing: 0) {
                ForEach(model.entries) { entry in
                    GroupedRow(isLast: entry.id == model.entries.last?.id) {
                        HStack(spacing: 10) {
                            IconSlot(systemName: icon(for: entry.kind), color: Ink.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.name)
                                    .font(Typo.rowStrong)
                                    .foregroundColor(Ink.primary)
                                    .lineLimit(1)
                                    .textSelection(.enabled)
                                Text(entry.path)
                                    .font(Font.mcNumeric(11))
                                    .foregroundColor(Ink.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                            Spacer()
                            Text(entry.kindText)
                                .font(Typo.caption)
                                .foregroundColor(Ink.tertiary)
                            if let sizeText = entry.sizeText {
                                Text(sizeText)
                                    .font(.mcNumeric(12))
                                    .foregroundColor(Ink.secondary)
                            } else {
                                Text("大小未知（读不全）")
                                    .font(Typo.caption)
                                    .foregroundColor(Signal.caution)
                            }
                            RowActionButton(
                                systemName: "minus.circle",
                                identifier: "shredRemoveButton",
                                accessibilityText: "移除 \(entry.name)",
                                help: "从列表移除（不删除文件）"
                            ) {
                                model.remove(entry.id)
                            }
                        }
                    }
                }
            }
        }
    }

    private func icon(for kind: ShredderModel.Entry.Kind) -> String {
        switch kind {
        case .file: return "doc"
        case .directory: return "folder"
        case .symlink: return "link"
        case .other: return "questionmark.folder"
        }
    }

    // MARK: 底栏

    private var footer: some View {
        HStack {
            Text(model.entries.isEmpty
                 ? "在上方逐条点名要粉碎的文件"
                 : "已点名 \(model.entries.count) 项，粉碎前会再次逐批确认")
                .font(Typo.caption)
                .foregroundColor(Ink.tertiary)
                .monospacedDigit()
            Spacer()
            Button {
                model.requestConfirm()
            } label: {
                Label(model.entries.isEmpty ? "粉碎…" : "粉碎 \(model.entries.count) 项…（不可恢复）",
                      systemImage: "flame")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.entries.isEmpty || model.isShredding)
            .accessibilityIdentifier("shredConfirmButton")
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .barSurface()
        .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - 逐批二次确认弹窗（工具页与右键入口共用）

struct ShredderConfirmSheet: View {
    @ObservedObject var model: ShredderModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if let outcome = model.outcome {
                resultBody(outcome)
            } else {
                confirmBody
            }
        }
        .padding(Space.lg)
        .frame(width: 560)
    }

    // MARK: 确认态

    private var confirmBody: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("确认粉碎（不可恢复）")
                .font(Typo.title)
                .foregroundColor(Ink.primary)

            VStack(alignment: .leading, spacing: Space.xs) {
                warningRow("trash.slash",
                           "粉碎不可恢复：没有撤销快照，删除后无法找回。")
                warningRow("exclamationmark.triangle",
                           "覆写会破坏文件内容；覆写中途失败会让文件损坏（可能仍占空间）。")
                warningRow("internaldrive",
                           ShredderService.apfsDisclosure)
            }

            GroupBox {
                VStack(spacing: 0) {
                    ForEach(model.entries) { entry in
                        GroupedRow(isLast: entry.id == model.entries.last?.id, padding: 6) {
                            HStack(spacing: 8) {
                                IconSlot(systemName: "doc", color: Ink.secondary)
                                Text(entry.path)
                                    .font(Font.mcNumeric(11))
                                    .foregroundColor(Ink.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Spacer()
                                if let sizeText = entry.sizeText {
                                    Text(sizeText).font(.mcNumeric(11)).foregroundColor(Ink.tertiary)
                                }
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") {
                    model.cancelConfirm()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("shredSheetCancelButton")
                if model.isShredding {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在粉碎…")
                        .font(Typo.caption)
                        .foregroundColor(Ink.tertiary)
                } else {
                    Button(role: .destructive) {
                        model.confirmAndShred()
                    } label: {
                        Label("粉碎 \(model.entries.count) 项", systemImage: "flame")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.entries.isEmpty)
                    .accessibilityIdentifier("shredSheetShredButton")
                }
            }
        }
    }

    private func warningRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            IconSlot(systemName: icon, color: Signal.caution, width: 16)
            Text(text)
                .font(Typo.caption)
                .foregroundColor(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 结果态（弹窗内逐条如实分组展示）

    private func resultBody(_ outcome: ShredderService.Outcome) -> some View {
        VStack(alignment: .leading, spacing: Space.md) {
            Text("粉碎完成")
                .font(Typo.title)
                .foregroundColor(Ink.primary)
            Text(outcome.summary)
                .font(Typo.row)
                .foregroundColor(Ink.secondary)
            ShredderResultSection(outcome: outcome)
            HStack {
                Spacer()
                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("shredSheetDoneButton")
            }
        }
    }
}

// MARK: - 结果分组（成功 / 拒绝 / 失败，逐条带原因）

struct ShredderResultSection: View {
    let outcome: ShredderService.Outcome

    var body: some View {
        VStack(alignment: .leading, spacing: Space.md) {
            if !outcome.shredded.isEmpty {
                group("已粉碎（不可恢复）", systemImage: "flame.fill", tint: Signal.positive) {
                    ForEach(Array(outcome.shredded.enumerated()), id: \.offset) { _, entry in
                        GroupedRow(isLast: entry == outcome.shredded.last, padding: 6) {
                            HStack(spacing: 8) {
                                Text(entry.name).font(Typo.rowStrong).foregroundColor(Ink.primary)
                                Text(entry.path).font(Font.mcNumeric(11)).foregroundColor(Ink.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("覆写 \(entry.fileCount) 个文件")
                                    .font(Typo.caption).foregroundColor(Ink.tertiary).monospacedDigit()
                            }
                        }
                    }
                }
            }
            if !outcome.rejected.isEmpty {
                group("被拒绝", systemImage: "hand.raised", tint: Signal.caution) {
                    ForEach(Array(outcome.rejected.enumerated()), id: \.offset) { _, rejection in
                        GroupedRow(isLast: rejection == outcome.rejected.last, padding: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(rejection.path)
                                    .font(Font.mcNumeric(11))
                                    .foregroundColor(Ink.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Text(rejection.message)
                                    .font(Typo.caption)
                                    .foregroundColor(Signal.caution)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            if !outcome.failed.isEmpty {
                group("失败", systemImage: "xmark.octagon", tint: Signal.critical) {
                    ForEach(Array(outcome.failed.enumerated()), id: \.offset) { _, failure in
                        GroupedRow(isLast: failure == outcome.failed.last, padding: 6) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(failure.path)
                                    .font(Font.mcNumeric(11))
                                    .foregroundColor(Ink.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                                Text(failure.message)
                                    .font(Typo.caption)
                                    .foregroundColor(Signal.critical)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func group<Content: View>(_ title: String, systemImage: String,
                                      tint: Color, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: 5) {
                IconSlot(systemName: systemImage, size: 11, color: tint, width: 14)
                Text(title).font(Typo.section).foregroundColor(Ink.secondary)
            }
            GroupBox { VStack(spacing: 0) { content() } }
        }
    }
}

// MARK: - 右键入口的弹窗宿主（CategoryDetailView 用）
//
// 分类页只持有一个 `String?` 状态；这个宿主在每次 present 时新建一份
// 以点名路径播种的 model，确认与结果展示复用同一个 `ShredderConfirmSheet`。

struct ShredderSheetHost: View {
    @StateObject private var model: ShredderModel

    init(seedPath: String) {
        _model = StateObject(wrappedValue: ShredderModel(seedPaths: [seedPath]))
    }

    var body: some View {
        ShredderConfirmSheet(model: model)
    }
}
