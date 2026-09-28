import Combine
import Foundation

/// 「体验优化」页的状态。
///
/// 与清理侧的状态对象（`CategoryState`）刻意不同：
///  · **没有"全选"、没有"一键优化全部"** —— 每条改动都是独立、可撤销的一次动作；
///  · **每次改动前先确认**（`pendingApply`），改的是系统设置而不是临时缓存；
///  · **被拒绝也要说话**：读不到旧值 / 撤销记录落不了盘 / 系统拒绝写入，
///    三种情况各有一句明确的说明，绝不静默失败（静默失败会让用户以为"改好了"）。
final class SystemTweakState: ObservableObject {

    @Published private(set) var findings: [TweakFinding] = []
    /// 只读的系统状态体检（SIP / 门禁 / 加密 / 防火墙 / 备份 / 索引）。
    /// 与 `findings` 分开：这一组**没有动作按钮**，工具不代改。
    @Published private(set) var statusFindings: [StatusFinding] = []
    @Published private(set) var records: [SystemTweakStore.ChangeRecord] = []
    @Published private(set) var isInspecting = false
    /// 正在处理哪一条（防重复提交）
    @Published private(set) var busyTweakID: String?
    /// 最近一次动作的结果。**含失败与拒绝的原因**，直接展示。
    @Published var lastOutcome: String?
    /// 有一条改动需要重启某个进程才生效；界面据此给出显式的「重启」按钮。
    @Published var pendingRestart: String?
    /// 待用户确认的改动（二次确认在这一层，因为它改的是系统设置）
    @Published var pendingApply: SystemTweak?

    /// 可优化条数（当前与推荐值不一致的）
    var deviates: [TweakFinding] { findings.filter { $0.status == .deviates } }
    /// 读不到的条数——必须说出来，不能混进"已是推荐值"
    var unreadable: [TweakFinding] { findings.filter { $0.status == .unreadable } }

    var summaryText: String {
        if isInspecting { return "正在读取当前设置…" }
        if findings.isEmpty { return "尚未读取。点「重新读取」看当前设置。" }
        var parts = ["可优化 \(deviates.count) 项 / 共 \(findings.count) 项"]
        if !unreadable.isEmpty { parts.append("其中 \(unreadable.count) 项读不到，未计入") }
        return parts.joined(separator: "；")
    }

    // MARK: - 读

    /// 重新读取全部现状。**只读**，不写任何设置。
    func refresh() {
        guard !isInspecting else { return }
        isInspecting = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = SystemTweakStore.inspect()
            let undo = SystemTweakStore.loadRecords() ?? []
            let status = SystemStatusStore.inspect()
            DispatchQueue.main.async {
                guard let self else { return }
                self.findings = result
                self.records = undo
                self.statusFindings = status
                self.isInspecting = false
            }
        }
    }

    // MARK: - 写（必须能还原）

    /// 把 store 的原始结果翻译成给用户看的一句话。
    ///
    /// 抽成**纯函数**的理由：这四句话是用户唯一能看到的结果反馈，必须能被穷举测试；
    /// 而把它们留在异步闭包里就永远测不到（自检跑在主线程上，一旦阻塞等主队列回调就会死锁）。
    ///
    /// 三种"没有改动"各有一句明确说法——**静默失败最危险**：
    /// 用户会以为改好了，然后觉得"这功能没用"或者"改了没效果"，而实际上一次都没写成。
    static func outcomeMessage(for tweak: SystemTweak,
                               outcome: SystemTweakStore.ApplyOutcome) -> String {
        switch outcome {
        case .applied:
            var message = "已应用：\(tweak.title)"
            if let process = tweak.restartProcess {
                message += "（需重启 \(process) 才生效）"
            } else if tweak.needsRelogin {
                message += "（部分应用需重新登录后才读取）"
            }
            return message
        case .refusedReadingFailed:
            return "**没有改动**：读不到这条设置的当前值。"
                + "读不到旧值就没有真正的撤销，所以工具不写。"
        case .refusedUndoNotPersisted:
            return "**没有改动**：撤销记录没能落盘。宁可什么都不做，"
                + "也不留下一笔无法还原的修改。"
        case .writeFailed:
            return "写入被系统拒绝，设置保持原样。"
        }
    }

    /// 还原结果的一句话。同样抽成纯函数以便穷举。
    static func revertMessage(for record: SystemTweakStore.ChangeRecord, succeeded: Bool) -> String {
        succeeded
            ? "已还原：\(record.key) 回到改动前的状态"
            : "还原失败：系统拒绝了这次写入，记录已保留，可以再试一次"
    }

    /// 重启结果的一句话。
    static func restartMessage(process: String, succeeded: Bool) -> String {
        succeeded
            ? "已重启 \(process)，改动已生效"
            : "重启 \(process) 失败；改动已写入，下次它自行重启时会生效"
    }

    func requestApply(_ tweak: SystemTweak) {
        pendingApply = tweak
    }

    func confirmApply() {
        guard let tweak = pendingApply else { return }
        pendingApply = nil
        guard busyTweakID == nil else { return }
        busyTweakID = tweak.id
        lastOutcome = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = SystemTweakStore.apply(tweak)
            let undo = SystemTweakStore.loadRecords() ?? []
            let fresh = SystemTweakStore.inspect()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busyTweakID = nil
                self.records = undo
                self.findings = fresh
                self.lastOutcome = Self.outcomeMessage(for: tweak, outcome: outcome)
                if case .applied = outcome {
                    self.pendingRestart = tweak.restartProcess
                }
            }
        }
    }

    func cancelApply() { pendingApply = nil }

    func revert(_ record: SystemTweakStore.ChangeRecord) {
        guard busyTweakID == nil else { return }
        busyTweakID = record.tweakID
        lastOutcome = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = SystemTweakStore.revert(record)
            let undo = SystemTweakStore.loadRecords() ?? []
            let fresh = SystemTweakStore.inspect()
            DispatchQueue.main.async {
                guard let self else { return }
                self.busyTweakID = nil
                self.records = undo
                self.findings = fresh
                self.lastOutcome = Self.revertMessage(for: record, succeeded: ok)
            }
        }
    }

    /// 重启进程让偏好生效。**必须由用户显式触发**——重启 Dock 会闪一下，
    /// 重启 Finder 会关掉所有访达窗口，工具不替用户决定。
    func restart(_ process: String) {
        lastOutcome = nil
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let ok = SystemTweakStore.restart(process: process)
            DispatchQueue.main.async {
                guard let self else { return }
                self.pendingRestart = nil
                self.lastOutcome = Self.restartMessage(process: process, succeeded: ok)
            }
        }
    }

    /// 撤销记录的展示名（把 domain/key 折算回目录里的可读标题）。
    func title(for record: SystemTweakStore.ChangeRecord) -> String {
        SystemTweak.catalog.first { $0.id == record.tweakID }?.title ?? record.key
    }

    /// 自检用：直接注入体检结果。
    ///
    /// 界面文案与过滤逻辑（尤其"读不到要说出来"）必须能被穷举验证，
    /// 而穷举时不该真去读系统设置，更不该在自检里阻塞主线程等异步回调。
    func injectFindingsForSelftest(_ list: [TweakFinding]) {
        findings = list
    }
}
