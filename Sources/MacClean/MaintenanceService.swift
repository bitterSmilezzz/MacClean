import Foundation
import Combine

// MARK: - 系统维护服务（v1.73.15，对标 CleanMyMac X「Maintenance」）
//
// 本模块只聚合三类**系统级**维护动作，全部走 `SafeProcess`（超时 + 先排空管道 +
// 启动失败不 wait），结果三态：「未执行 / 成功 / 失败」必须分得开——
// 可用性预判失败不是命令失败，命令失败也不是成功。
//
// ## 复用纪律（v1.73.15 轮硬约束）
// * **DNS 刷新**：转发 `NetworkPrivacyInspector.shared.flushDNSCache()`，
//   命令路径注入缝（`dscacheutilPath`）也在那边——本文件**不写第二份** dscacheutil 调用。
// * **Spotlight 重建**：转发 `SpotlightScanner.shared.rebuildVolumeIndex`，
//   mdutil 的命令构造/判据只此一份（v1.73.0 加固过的那套）。
// * **磁盘 First Aid**：`diskutil` 是本模块新引入的受控命令，路径常量开 `static var`
//   注入缝，自检据此断言「调的是哪个命令、带哪些参数、timeout 多少」。
//
// ## repair 为什么不是按钮而是引导卡（2026-09-28 本机实测，见 docs/RELEASE-CHECKLIST.md）
// * `diskutil verifyVolume` 对**普通用户**即可执行（实测 181 GB Data 卷 33.6 s、
//   启动卷快照 6.6 s，均 exit 0，无需管理员）；
// * `diskutil repairVolume` 对**可写**挂载卷同样无需管理员（64 MB 一次性盘实测 exit 0）；
// * 但根卷在运行态解析出来的是**封存只读快照**（`diskutil info /`：
//   `Volume Read-Only: Yes`、`Sealed: Yes`）。对只读挂载卷做 repair，
//   fsck 在打开设备写这一步就失败（一次性只读盘实测：
//   `failed to open with error: Permission denied`、`Error: -69845`）——
//   这是挂载态的墙，管理员提权改变不了。**因此运行态修复启动卷的唯一官方路径
//   是重启进恢复模式跑磁盘工具急救**，面板如实给指引，不假装能修。

final class MaintenanceService: ObservableObject {

    // MARK: - 结果模型

    /// 维护动作标识（也是结果区的键）。
    enum Action: String, CaseIterable, Hashable {
        case firstAid
        case dnsFlush
        case spotlightRebuild
    }

    /// 三态：「未执行」与「执行失败」分得开（G 规则：可用性预判失败 ≠ 命令非零退出）。
    enum OutcomeStatus: Equatable {
        case notExecuted
        case succeeded
        case failed
    }

    struct Outcome: Equatable {
        let action: Action
        let status: OutcomeStatus
        /// 用户可读结论。未执行时说明为什么没执行。
        let message: String
        /// 命令输出摘录（尾部若干非空行，原样播报，不做美化）。
        let outputExcerpt: String?
        let duration: TimeInterval
        let timedOut: Bool

        static func notExecuted(_ action: Action, _ reason: String) -> Outcome {
            Outcome(action: action, status: .notExecuted, message: reason,
                    outputExcerpt: nil, duration: 0, timedOut: false)
        }
    }

    // MARK: - 超时常量（按真实耗时显式设，见 RELEASE-CHECKLIST「迁移到 SafeProcess」条）

    /// `diskutil info /`：本机实测毫秒级；30 s 已是十倍余量。
    static let volumeProbeTimeout: TimeInterval = 30
    /// `diskutil verifyVolume`：实测 181 GB Data 卷 33.6 s、启动卷快照 6.6 s；
    /// 大盘/慢盘/碎片盘没有上界，留到 15 分钟。
    static let verifyTimeout: TimeInterval = 15 * 60
    /// `mdutil -E /`（经 SpotlightScanner.rebuildVolumeIndex）：擦除索引本身可到分钟级，
    /// 完整重建在后台进行、不受这条超时约束。
    static let spotlightRebuildTimeout: TimeInterval = 15 * 60
    /// 输出摘录最多保留的尾部非空行数。
    static let excerptMaxLines = 12

    // MARK: - 自检注入缝（生产路径不改）

    /// `diskutil` 路径可覆盖：自检据此断言命令形状与模拟「命令不存在」。
    static var diskutilPath = "/usr/sbin/diskutil"

    /// Spotlight 重建前可用性预判。
    ///
    /// 之所以是闭包缝而不是路径变量：`SpotlightScanner.mdutilPath` 是 `let`
    /// （那边的房子，不改别人的文件），自检需要一条路模拟「mdutil 不存在」。
    /// 默认实现就是标准的 `SafeProcess.isAvailable` 预判。
    static var spotlightToolAvailable: () -> Bool = {
        SafeProcess.isAvailable(SpotlightScanner.mdutilPath)
    }

    /// 卷设备标识白名单形状：`disk3s1`，或启动卷快照形态 `disk3s1s1`
    /// （实测 `diskutil info /` 报的就是快照形态，`diskutil verifyVolume` 能正确解析它）。
    /// 解析结果必须命中这个形状才允许拼进命令参数——解析出什么就信什么是要不得的。
    static let volumeIDPattern = "^disk[0-9]+s[0-9]+(s[0-9]+)?$"

    // MARK: - 纯解析（自检直接喂夹具）

    /// 从 `diskutil info <路径>` 文本输出解析卷设备标识。
    ///
    /// 只认 `Device Identifier:` 一行的值，且必须命中白名单形状；
    /// 空输出、缺行、形状不对（包括空串、`diskX`、带分号/空白的花哨值）一律返回 nil，
    /// 调用方据此如实报「无法确定系统卷」，**绝不**把没把握的值传给 verifyVolume。
    static func parseVolumeIdentifier(fromInfoOutput output: String) -> String? {
        guard !output.isEmpty else { return nil }
        for rawLine in output.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("Device Identifier:") else { continue }
            let value = line.dropFirst("Device Identifier:".count)
                .trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty,
                  value.range(of: volumeIDPattern, options: .regularExpression) != nil
            else { return nil }
            return value
        }
        return nil
    }

    /// 命令输出摘录：取尾部最多 `excerptMaxLines` 行非空原文。
    /// verify 的结论（warning / appears to be OK / exit code）都在尾部，原样给用户。
    static func excerptTail(of output: String, maxLines: Int = excerptMaxLines) -> String {
        let nonEmpty = output
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard nonEmpty.count > maxLines else {
            return nonEmpty.joined(separator: "\n")
        }
        return nonEmpty.suffix(maxLines).joined(separator: "\n")
    }

    // MARK: - 运行状态（ViewInspector 可读：状态在服务对象上，不埋在视图 @State 里）

    @Published private(set) var outcomes: [Action: Outcome] = [:]
    @Published private(set) var runningActions: Set<Action> = []
    /// 待确认的动作（确认弹窗的数据源，外部对象状态）。
    @Published var pendingConfirmation: Action?

    func requestRun(_ action: Action) {
        guard runningActions.contains(action) == false else { return }
        pendingConfirmation = action
    }

    func cancelConfirmation() {
        pendingConfirmation = nil
    }

    /// 确认后才真正执行。执行在后台线程，结果回主线程落地。
    func confirmRun() {
        guard let action = pendingConfirmation else { return }
        pendingConfirmation = nil
        guard runningActions.contains(action) == false else { return }
        runningActions.insert(action)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let outcome = self.perform(action)
            DispatchQueue.main.async {
                self.outcomes[action] = outcome
                self.runningActions.remove(action)
            }
        }
    }

    var isBusy: Bool { !runningActions.isEmpty }

    // MARK: - 执行（同步、可注入、自检直接调用）

    /// 同步执行一个动作并返回结果。`confirmRun` 的后台路径与自检共用这一份判据。
    func perform(_ action: Action) -> Outcome {
        switch action {
        case .firstAid: return performFirstAid()
        case .dnsFlush: return performDNSFlush()
        case .spotlightRebuild: return performSpotlightRebuild()
        }
    }

    /// 磁盘 First Aid：`diskutil info /` 解析系统卷 → `diskutil verifyVolume <卷>`（只读）。
    func performFirstAid() -> Outcome {
        let start = Date()
        // 可用性预判：工具不存在就如实说「未执行」，不把启动失败谎报成验证结果
        guard SafeProcess.isAvailable(Self.diskutilPath) else {
            return .notExecuted(.firstAid,
                                "本机找不到 \(Self.diskutilPath)，未执行任何验证，文件系统未受影响。")
        }
        // 先解析当前根卷的设备标识。解析失败不得瞎猜（不许传 "/" 字面或空参给 verifyVolume）。
        guard let info = SafeProcess.run(Self.diskutilPath, ["info", "/"],
                                         timeout: Self.volumeProbeTimeout) else {
            return .notExecuted(.firstAid, "未能启动 diskutil info，无法确定系统卷，验证未执行。")
        }
        guard info.succeeded else {
            let detail = info.timedOut ? "diskutil info 超时" : "diskutil info 退出码 \(info.exitCode)"
            return .notExecuted(.firstAid, "无法确定系统卷（\(detail)），验证未执行。")
        }
        guard let volumeID = Self.parseVolumeIdentifier(fromInfoOutput: info.output) else {
            return .notExecuted(.firstAid,
                                "无法确定系统卷：diskutil info / 的输出里没有可识别的卷设备标识，"
                                + "验证未执行。请在磁盘工具里手动选择卷宗执行急救。")
        }

        guard let result = SafeProcess.run(Self.diskutilPath, ["verifyVolume", volumeID],
                                           timeout: Self.verifyTimeout) else {
            // run() 只在注入 runner 返回 nil 时才可能是 nil；生产路径到不了这里，仍如实分类
            return .notExecuted(.firstAid, "diskutil verifyVolume 未能启动，验证未执行。")
        }
        let duration = Date().timeIntervalSince(start)
        let excerpt = Self.excerptTail(of: result.output)

        if result.timedOut {
            return Outcome(action: .firstAid, status: .failed,
                           message: "验证超时：超过 \(Int(Self.verifyTimeout / 60)) 分钟未返回，已强制终止；"
                                   + "卷宗状态未知，请勿重复触发，可重启后到磁盘工具复查。",
                           outputExcerpt: excerpt.isEmpty ? nil : excerpt,
                           duration: duration, timedOut: true)
        }
        guard result.exitCode == 0 else {
            return Outcome(action: .firstAid, status: .failed,
                           message: "卷 \(volumeID) 验证未通过（diskutil 退出码 \(result.exitCode)）。"
                                   + "输出摘录如下（原样播报）；如需修复，启动卷请重启进恢复模式执行急救。",
                           outputExcerpt: excerpt.isEmpty ? nil : excerpt,
                           duration: duration, timedOut: false)
        }
        // exit 0 也可能有 warning / "minor issues"——结论以摘录为准，面板原样展示
        return Outcome(action: .firstAid, status: .succeeded,
                       message: "卷 \(volumeID) 验证完成（diskutil 退出码 0）。"
                               + "这是只读验证，未改动文件系统；输出摘录如包含 warning 请据实评估。",
                       outputExcerpt: excerpt.isEmpty ? nil : excerpt,
                       duration: duration, timedOut: false)
    }

    /// DNS 缓存刷新：转发 `NetworkPrivacyInspector`（dscacheutil 注入缝在那边）。
    func performDNSFlush() -> Outcome {
        let start = Date()
        // 预判与转发用的是同一条注入缝（dscacheutilPath）：工具不存在 → 未执行
        guard SafeProcess.isAvailable(NetworkPrivacyInspector.dscacheutilPath) else {
            return .notExecuted(.dnsFlush,
                                "本机找不到 \(NetworkPrivacyInspector.dscacheutilPath)，未执行刷新。")
        }
        let (success, message) = NetworkPrivacyInspector.shared.flushDNSCache()
        return Outcome(action: .dnsFlush,
                       status: success ? .succeeded : .failed,
                       message: message,
                       outputExcerpt: nil,
                       duration: Date().timeIntervalSince(start),
                       timedOut: false)
    }

    /// Spotlight 索引重建：转发 `SpotlightScanner.rebuildVolumeIndex`（mdutil 只此一份）。
    func performSpotlightRebuild() -> Outcome {
        let start = Date()
        guard Self.spotlightToolAvailable() else {
            return .notExecuted(.spotlightRebuild,
                                "本机找不到 \(SpotlightScanner.mdutilPath)，"
                                + "未执行任何索引重建，现有搜索数据库未受影响。")
        }
        let (success, message) = SpotlightScanner.shared
            .rebuildVolumeIndex(volumePath: "/", timeout: Self.spotlightRebuildTimeout)
        return Outcome(action: .spotlightRebuild,
                       status: success ? .succeeded : .failed,
                       message: message,
                       outputExcerpt: nil,
                       duration: Date().timeIntervalSince(start),
                       timedOut: false)
    }
}
