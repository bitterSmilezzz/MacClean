import SwiftUI

// MARK: - 浏览器隐私痕迹（工具页，v1.73.15）
//
// (浏览器族 × 数据类) 开关矩阵：每族一组、每行一个数据类，行内给出类型名、体积、
// 状态与勾选框。呈现红线（RELEASE-CHECKLIST §1 / docs/DESIGN.md）：
// · 体积与年龄只是**呈现信息**，默认全不选——勾选只来自用户点选；
// · danger 格（savedLogins / sessionRestore）配警示色与固定警示文案，不进「全选」，
//   删除前在确认弹窗里逐条列出警示；
// · 读不到 ≠ 空（G9）：三态呈现，TCC 读不到时给 G13 口径的授权引导；
// · 状态放外部 ObservableObject（@State 里的选中态 ViewInspector 读不回，v1.73.10 教训）。

/// 页面状态。列表与选中态在 model（外部对象）里，方法不依赖渲染即可测。
final class BrowserPrivacyModel: ObservableObject {
    @Published var isScanning = false
    @Published var summary: BrowserPrivacySummary?
    @Published var isCleaning = false
    @Published var confirmRequested = false
    @Published var outcome: ResidueDeletionGate.Outcome?
    private var hasScannedOnce = false

    /// 首次进入页面自动取数一次；之后由「重新扫描」驱动。
    func scanIfNeeded() {
        guard !hasScannedOnce, !isScanning else { return }
        scan()
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = BrowserPrivacyScanner.scan()
            DispatchQueue.main.async {
                guard let self else { return }
                self.summary = result
                self.isScanning = false
                self.hasScannedOnce = true
            }
        }
    }

    // MARK: 勾选（与「全选」判据同源：BrowserPrivacyCell.isCleanable / selectAllCleanableTargets）

    /// 单格勾选。勾选框只对可清理格子开放：读不到/没试/缺席的格子没有可背书的删除事实。
    func toggle(cellID: String) {
        guard var snapshot = summary else { return }
        for i in snapshot.blocks.indices {
            for j in snapshot.blocks[i].cells.indices where snapshot.blocks[i].cells[j].id == cellID {
                guard snapshot.blocks[i].cells[j].isCleanable else { return }
                snapshot.blocks[i].cells[j].isSelected.toggle()
                summary = snapshot
                return
            }
        }
    }

    /// 「全选可清理项」：只选非 danger 且可读的格子（判据唯一出处：
    /// `selectAllCleanableTargets()`）。danger 格必须用户逐格勾选。
    func selectAllCleanable() {
        guard var snapshot = summary else { return }
        let targets = Set(snapshot.allCells.selectAllCleanableTargets())
        for i in snapshot.blocks.indices {
            for j in snapshot.blocks[i].cells.indices
            where targets.contains(snapshot.blocks[i].cells[j].id) {
                snapshot.blocks[i].cells[j].isSelected = true
            }
        }
        summary = snapshot
    }

    func clearSelection() {
        guard var snapshot = summary else { return }
        for i in snapshot.blocks.indices {
            for j in snapshot.blocks[i].cells.indices {
                snapshot.blocks[i].cells[j].isSelected = false
            }
        }
        summary = snapshot
    }

    // MARK: 汇总（格子总量 ≤ 6 族 × 7 类，逐次计算可忽略；列表分组在 body 里算一次向下传）

    var selectedCells: [BrowserPrivacyCell] { summary?.allCells.filter(\.isSelected) ?? [] }
    var selectedDangerCells: [BrowserPrivacyCell] { selectedCells.filter { $0.kind.danger } }
    var selectedSize: Int64 { selectedCells.reduce(0) { $0 + $1.size } }
    var cleanableCount: Int { summary?.allCells.filter(\.isCleanable).count ?? 0 }
    var selectAllTargetCount: Int { summary?.allCells.selectAllCleanableTargets().count ?? 0 }

    // MARK: 清理

    func requestClean() {
        guard !selectedCells.isEmpty, !isCleaning, !isScanning else { return }
        confirmRequested = true
    }

    func cancelClean() {
        confirmRequested = false
    }

    /// 确认弹窗里逐条列出了危险项警示——按下确认即是对 danger 格的独立确认
    /// （`confirmedDanger: true` 只从这条路径发出）。
    func confirmClean() {
        let targets = selectedCells
        guard !targets.isEmpty, !isCleaning else { return }
        confirmRequested = false
        isCleaning = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let out = BrowserPrivacyScanner.clean(cells: targets, confirmedDanger: true)
            DispatchQueue.main.async {
                guard let self else { return }
                self.outcome = out
                self.isCleaning = false
                self.scan()   // 清完重扫，矩阵回到当前事实
            }
        }
    }
}

struct BrowserPrivacyView: View {
    @StateObject private var model = BrowserPrivacyModel()

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Surface.hairline)
            listBody
            footer
        }
        .background(Surface.window)
        .onAppear { model.scanIfNeeded() }
        // present 必须挂在有尺寸的容器上（RELEASE-CHECKLIST：EmptyView 上挂 sheet 不弹的坑）
        .sheet(isPresented: $model.confirmRequested) {
            BrowserPrivacyConfirmSheet(model: model)
        }
    }

    // MARK: 页头

    private var header: some View {
        HStack(spacing: 6) {
            IconSlot(systemName: "globe", color: Ink.secondary)
            Text("浏览器隐私").font(Typo.title).foregroundColor(Ink.primary)
            Text("按浏览器与数据类逐项清理隐私痕迹；默认全不选，体积仅作呈现")
                .font(Typo.caption).foregroundColor(Ink.tertiary)
            Spacer()
            if model.isScanning {
                ProgressView().controlSize(.small)
            }
            Button {
                model.scan()
            } label: {
                Label("重新扫描", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(model.isScanning)
            .accessibilityIdentifier("bpScanButton")
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
    }

    // MARK: 列表

    private var listBody: some View {
        ScrollView {
            // 分组一次算好再向下传（大列表 body 性能条目）
            let blocks = model.summary?.blocks ?? []
            VStack(alignment: .leading, spacing: Space.md) {
                if let summary = model.summary {
                    if !summary.issues.isEmpty {
                        issuesBanner(summary.issues)
                    }
                    if blocks.isEmpty {
                        EmptyState(
                            icon: "globe",
                            title: "没有发现浏览器数据",
                            message: "本机没有已安装浏览器的用户数据，或数据目录还没有产生。"
                                + "已卸载浏览器留下的残留不在本页，请到「清理」的分类里查看。"
                        )
                        .frame(maxWidth: .infinity)
                    } else {
                        ForEach(blocks) { block in
                            familyBlock(block)
                        }
                        if !summary.installedWithoutData.isEmpty {
                            Text("已安装但还没有产生用户数据："
                                + summary.installedWithoutData.map(\.displayName).joined(separator: "、"))
                                .font(Typo.caption)
                                .foregroundColor(Ink.tertiary)
                        }
                    }
                } else if model.isScanning {
                    HStack(spacing: Space.xs) {
                        ProgressView().controlSize(.small)
                        Text("正在读取浏览器数据…").font(Typo.caption).foregroundColor(Ink.tertiary)
                    }
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, Space.xl)
                }
                if let outcome = model.outcome {
                    resultSection(outcome)
                }
            }
            .padding(Space.gutter)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 证据缺口横幅（G16 清单降级等）。只说量到的东西，不给"全局干净"式的绝对化结论。
    private func issuesBanner(_ issues: [String]) -> some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                HStack(alignment: .top, spacing: 6) {
                    IconSlot(systemName: "exclamationmark.triangle", size: 11,
                             color: Signal.caution, width: 14)
                    Text(issue)
                        .font(Typo.caption)
                        .foregroundColor(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(Surface.sunken))
    }

    private func familyBlock(_ block: BrowserPrivacySummary.FamilyBlock) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: 6) {
                IconSlot(systemName: block.family.iconName, color: Ink.secondary)
                Text(block.family.displayName).font(Typo.rowStrong).foregroundColor(Ink.primary)
                if block.profiles.isEmpty {
                    Text("固定位置").font(Typo.caption).foregroundColor(Ink.tertiary)
                } else {
                    Text("\(block.profiles.count) 个用户 profile")
                        .font(Typo.caption).foregroundColor(Ink.tertiary).monospacedDigit()
                }
            }
            .padding(.leading, Space.xxs)
            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(block.cells.enumerated()), id: \.element.id) { index, cell in
                        BrowserPrivacyCellRow(cell: cell, isLast: index == block.cells.count - 1) {
                            model.toggle(cellID: cell.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: 结果（逐条如实呈现，含拒绝原因）

    private func resultSection(_ outcome: ResidueDeletionGate.Outcome) -> some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            HStack(spacing: 5) {
                IconSlot(systemName: outcome.errorCount == 0 ? "checkmark.circle" : "hand.raised",
                         size: 11, color: outcome.errorCount == 0 ? Signal.positive : Signal.caution,
                         width: 14)
                Text(outcome.summary).font(Typo.rowStrong).foregroundColor(Ink.primary)
            }
            ForEach(Array(outcome.rejected.enumerated()), id: \.offset) { _, rejection in
                VStack(alignment: .leading, spacing: 1) {
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
            ForEach(Array(outcome.failed.enumerated()), id: \.offset) { _, failure in
                VStack(alignment: .leading, spacing: 1) {
                    Text(failure.path)
                        .font(Font.mcNumeric(11))
                        .foregroundColor(Ink.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(failure.message)
                        .font(Typo.caption)
                        .foregroundColor(Signal.critical)
                }
            }
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
            .fill(Surface.sunken))
    }

    // MARK: 底栏

    private var footer: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("已选 \(model.selectedCells.count) 项 · \(model.selectedSize.byteStringCN)"
                    + "（可清理 \(model.cleanableCount) 项，全选覆盖 \(model.selectAllTargetCount) 项）")
                    .font(Typo.caption)
                    .foregroundColor(Ink.secondary)
                    .monospacedDigit()
                Text("「全选可清理项」只选非危险且读得到的格子；危险项需逐格勾选并在弹窗里确认")
                    .font(Typo.micro)
                    .foregroundColor(Ink.tertiary)
            }
            Spacer()
            Button("全选可清理项") {
                model.selectAllCleanable()
            }
            .disabled(model.selectAllTargetCount == 0 || model.isScanning)
            .accessibilityIdentifier("bpSelectAllButton")
            Button {
                model.requestClean()
            } label: {
                Label("清理…", systemImage: "trash")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.selectedCells.isEmpty || model.isCleaning || model.isScanning)
            .accessibilityIdentifier("bpCleanButton")
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .barSurface()
        .overlay(alignment: .top) { Hairline() }
    }
}

// MARK: - 矩阵的一行

private struct BrowserPrivacyCellRow: View {
    let cell: BrowserPrivacyCell
    let isLast: Bool
    let onToggle: () -> Void

    private static let mtimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    private var sizeText: String {
        switch cell.status {
        case .readable: return cell.size.byteStringCN
        case .unreadable, .deferred: return "—"
        case .absent: return "—"
        }
    }

    private var statusText: String {
        switch cell.status {
        case .readable:
            if let newest = cell.newestModification {
                return "最近写入 \(Self.mtimeFormatter.string(from: newest))"
            }
            return "可读"
        case .unreadable: return "读不到（权限不足）"
        case .deferred: return "本轮未读取，稍后重新扫描"
        case .absent: return "本机没有该数据"
        }
    }

    private var statusColor: Color {
        switch cell.status {
        case .readable: return Ink.tertiary
        case .unreadable: return Signal.caution
        case .deferred: return Ink.tertiary
        case .absent: return Ink.quaternary
        }
    }

    /// TCC「读不到」的授权引导（G13 口径，复用 PermissionGuide 的措辞与权限探针）
    private var remedyText: String? {
        guard cell.status == .unreadable else { return nil }
        let blocked = cell.paths.first { $0.state == .unreadable }?.path
            ?? cell.paths.first?.path ?? ""
        return PermissionGuide.remedy(path: blocked, needsFDA: PermissionGuide.hasFullDiskAccess)
    }

    private var protectionText: String? {
        cell.paths.compactMap(\.protection).first
    }

    var body: some View {
        GroupedRow(isLast: isLast, padding: 8) {
            HStack(alignment: .top, spacing: Space.sm) {
                Toggle("", isOn: Binding(
                    get: { cell.isSelected },
                    set: { _ in onToggle() }
                ))
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(!cell.isCleanable)
                .accessibilityIdentifier("bpCellToggle-\(cell.id)")

                IconSlot(systemName: cell.kind.iconName,
                         color: cell.kind.danger ? Signal.caution : Ink.secondary)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(cell.kind.displayName)
                            .font(Typo.rowStrong)
                            .foregroundColor(cell.isCleanable ? Ink.primary : Ink.tertiary)
                        if cell.kind.danger {
                            IconSlot(systemName: "exclamationmark.triangle.fill", size: 10,
                                     color: Signal.caution, width: 12)
                        }
                        if let protection = protectionText {
                            Text(protection)
                                .font(Typo.micro)
                                .foregroundColor(Ink.tertiary)
                        }
                    }
                    Text(cell.kind.danger ? (cell.kind.warning ?? cell.kind.note) : cell.kind.note)
                        .font(Typo.caption)
                        .foregroundColor(cell.kind.danger ? Signal.caution : Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let remedy = remedyText {
                        Text(remedy)
                            .font(Typo.caption)
                            .foregroundColor(Signal.caution)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 2) {
                    Text(sizeText)
                        .font(.mcNumeric(12))
                        .foregroundColor(cell.status == .readable ? Ink.primary : Ink.tertiary)
                    Text(statusText)
                        .font(Typo.caption)
                        .foregroundColor(statusColor)
                }
            }
            .contentShape(Rectangle())
        }
    }
}

// MARK: - 清理确认弹窗（danger 项逐条列警示）

struct BrowserPrivacyConfirmSheet: View {
    @ObservedObject var model: BrowserPrivacyModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        // 打开弹窗时以当前选中为准（一次性快照，避免中途状态变化）
        let selected = model.selectedCells
        let danger = selected.filter { $0.kind.danger }
        return VStack(alignment: .leading, spacing: Space.md) {
            Text("确认清理选中的浏览器数据")
                .font(Typo.title)
                .foregroundColor(Ink.primary)

            VStack(alignment: .leading, spacing: Space.xs) {
                warningRow("trash",
                           "默认移入废纸篓，可在清理历史里放回。")
                if !danger.isEmpty {
                    ForEach(Array(danger.enumerated()), id: \.offset) { _, cell in
                        warningRow("exclamationmark.triangle.fill",
                                   "\(cell.family.displayName) · \(cell.kind.displayName)："
                                   + (cell.kind.warning ?? "这是危险项，删除会造成不可自动恢复的状态丢失"))
                    }
                }
            }

            GroupBox {
                VStack(spacing: 0) {
                    ForEach(Array(selected.enumerated()), id: \.element.id) { index, cell in
                        GroupedRow(isLast: index == selected.count - 1, padding: 6) {
                            HStack(spacing: 8) {
                                IconSlot(systemName: cell.kind.iconName,
                                         color: cell.kind.danger ? Signal.caution : Ink.secondary,
                                         width: 16)
                                Text("\(cell.family.displayName) · \(cell.kind.displayName)")
                                    .font(Typo.row)
                                    .foregroundColor(Ink.primary)
                                Spacer()
                                Text(cell.size.byteStringCN)
                                    .font(.mcNumeric(11))
                                    .foregroundColor(Ink.tertiary)
                            }
                        }
                    }
                }
            }

            HStack {
                Spacer()
                Button("取消") {
                    model.cancelClean()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .accessibilityIdentifier("bpSheetCancelButton")
                Button(role: .destructive) {
                    model.confirmClean()
                    dismiss()
                } label: {
                    Label(danger.isEmpty ? "清理 \(selected.count) 项"
                          : "确认，清理 \(selected.count) 项（含 \(danger.count) 项危险数据）",
                          systemImage: "trash")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selected.isEmpty)
                .accessibilityIdentifier("bpSheetConfirmButton")
            }
        }
        .padding(Space.lg)
        .frame(width: 560)
    }

    private func warningRow(_ icon: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            IconSlot(systemName: icon, size: 11, color: Signal.caution, width: 16)
            Text(text)
                .font(Typo.caption)
                .foregroundColor(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
