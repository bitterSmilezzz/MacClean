import Foundation

// MARK: - 系统底层存储深度治理引擎 (v1.74.0 安全加固)
//
// 本模块会调用 `tmutil` / `pmset` 这类**真会影响系统状态**的外部命令，
// 原实现有三处必须修：
// ① 三处裸 `Process()`：`waitUntilExit()` 之后才读管道（输出超约 64 KB 即双向死锁）、
//    完全没有超时、`try? process.run()` 失败后照样往下读；
// ② 快照判据把"命令失败"读成"没有快照"：`listlocalsnapshots` 非 0 退出或压根没跑起来时
//    返回 `[]`，卡片于是显示绿色"当前没有残留的本地 APFS 快照"；
// ③ **整批静默删除**：`deleteAllLocalSnapshots(snapshots:)` 把当时列表里的每个快照
//    逐个 `tmutil deletelocalsnapshots`，既不逐条确认，也不复核快照是否真的消失，
//    命令返回 0 就说"已删除"。
//
// 现在：命令一律 `SafeProcess`（先排空管道 + 超时 + 真实退出码），
// 读不到即产出 `GovernanceEvidenceIssue` 并把结论降级，
// 删除只接受**用户点名的快照**且逐条执行、逐条复核。

// MARK: - APFS 本地时间机器快照数据模型

public struct APFSSnapshot: Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let dateString: String
    public let date: Date?
    public let volume: String

    public init(name: String, dateString: String, date: Date? = nil, volume: String = "/") {
        self.id = name
        self.name = name
        self.dateString = dateString
        self.date = date
        self.volume = volume
    }

    /// 传给 `tmutil deletelocalsnapshots` 的日期后缀（必须是纯时间戳，不接受任意字符串）
    public var deleteArgument: String { dateString }

    /// 时间戳形态是否合法（`yyyy-MM-dd-HHmmss`）——不合法就绝不拼进命令行
    public var hasValidDateSuffix: Bool {
        let pattern = "^[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}$"
        return dateString.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - 快照清单（带证据源状态）

/// 一轮 `tmutil listlocalsnapshots` 的结论。
///
/// `issues` 非空即**不知道**有没有快照：视图必须显示"结果不完整"，
/// 绝不能因为 `snapshots.isEmpty` 就说"没有幽灵空间"。
public struct SnapshotInventory: Equatable {
    public var snapshots: [APFSSnapshot]
    public var issues: [GovernanceEvidenceIssue]
    /// 命令是否真的跑成功过（false = 一次都没拿到可信输出）
    public var commandSucceeded: Bool

    public init(snapshots: [APFSSnapshot] = [], issues: [GovernanceEvidenceIssue] = [],
                commandSucceeded: Bool = false) {
        self.snapshots = snapshots
        self.issues = issues
        self.commandSucceeded = commandSucceeded
    }

    public var isResultComplete: Bool { issues.isEmpty && commandSucceeded }

    public var incompletenessBanner: String? {
        if isResultComplete { return nil }
        if issues.isEmpty {
            return "本次结果不完整：未能取得快照清单，以下结论不代表没有幽灵空间。"
        }
        return GovernanceEvidenceIssue.incompleteBanner(issues)
    }
}

// MARK: - 快照批量删除结果

/// 逐条删除的逐项结论。**只有复核确认快照已消失的**才算成功。
public struct SnapshotDeleteOutcome {
    /// 已删除并复核通过
    public var succeeded: [String] = []
    /// 命令失败 / 超时 / 复核后仍在
    public var failed: [(name: String, message: String)] = []
    /// 未经确认或不在清单里 → 一条命令都没执行
    public var skipped: [(name: String, reason: String)] = []

    public init() {}

    public var succeededCount: Int { succeeded.count }
    public var failedCount: Int { failed.count }

    /// 一句如实的结论（绝不在有失败/跳过时说"已全部清理"）
    public var summary: String {
        var parts: [String] = []
        if !succeeded.isEmpty { parts.append("已删除并复核 \(succeeded.count) 个快照") }
        if !failed.isEmpty { parts.append("\(failed.count) 个删除未成功") }
        if !skipped.isEmpty { parts.append("\(skipped.count) 个未执行") }
        return parts.isEmpty ? "未执行任何快照删除" : parts.joined(separator: "；")
    }
}

// MARK: - 休眠映像与虚拟内存 Swap 数据模型

public struct VMMemoryInfo: Equatable {
    public var sleepimageExists: Bool = false
    public var sleepimageSize: Int64 = 0
    public var swapFilesCount: Int = 0
    public var totalSwapSize: Int64 = 0
    public var hibernateMode: Int? = nil
    public var isDesktopMac: Bool = false
    public var recommendedHibernateMode: Int = 0
    /// 休眠模式没读到时的**真实原因**（命令不存在 / 失败 / 超时），nil = 读到了
    public var hibernateModeUnavailableReason: String? = nil
    /// `/var/vm` 是否真的读到了（root 所有，普通进程通常读不到）
    public var vmDirectoryReadable: Bool = true
    /// 本轮读到的所有问题；非空即结论不完整
    public var issues: [GovernanceEvidenceIssue] = []

    public init(
        sleepimageExists: Bool = false,
        sleepimageSize: Int64 = 0,
        swapFilesCount: Int = 0,
        totalSwapSize: Int64 = 0,
        hibernateMode: Int? = nil,
        isDesktopMac: Bool = false,
        recommendedHibernateMode: Int = 0,
        hibernateModeUnavailableReason: String? = nil,
        vmDirectoryReadable: Bool = true,
        issues: [GovernanceEvidenceIssue] = []
    ) {
        self.sleepimageExists = sleepimageExists
        self.sleepimageSize = sleepimageSize
        self.swapFilesCount = swapFilesCount
        self.totalSwapSize = totalSwapSize
        self.hibernateMode = hibernateMode
        self.isDesktopMac = isDesktopMac
        self.recommendedHibernateMode = recommendedHibernateMode
        self.hibernateModeUnavailableReason = hibernateModeUnavailableReason
        self.issues = issues
        self.vmDirectoryReadable = vmDirectoryReadable
    }

    /// 本轮结论是否完整（读不到的部分不得渲染成"0 B / 无压力"）
    public var isResultComplete: Bool { issues.isEmpty && hibernateMode != nil }

    public var incompletenessBanner: String? {
        isResultComplete ? nil : GovernanceEvidenceIssue.incompleteBanner(issues)
    }

    /// 智能分析建议说明
    public var suggestionText: String {
        // 读不到就是读不到：不给"最省存储模式"这类结论，也不劝人改设置
        if let mode = hibernateMode {
            if mode == 0 {
                return "当前已是 Mode 0 (RAM 休眠，不占用 SSD 磁盘空间)，处于最省存储模式。"
            }
            if isDesktopMac {
                return "当前检测为台式 Mac (无需防电池耗尽断电)，建议切换为 Mode 0 释放 \(sleepimageSize.byteStringCN) 的 SSD 物理占用。"
            }
            if mode == 3 {
                return "当前为 SafeSleep (Mode 3: RAM + 磁盘双重备份)。若为常插电办公，可切换为 Mode 0 释放 \(sleepimageSize.byteStringCN) 存储空间。"
            }
            return "当前模式为 Mode \(mode)。"
        }
        return "未能获取当前休眠模式（\(hibernateModeUnavailableReason ?? "pmset 无输出")）："
            + "本轮不提供任何修改建议，也不代表睡眠设置正常。"
    }
}

// MARK: - 系统底层存储深度治理引擎

public enum SystemDeepStorageInspector {

    // MARK: - APFS 本地快照检测与清理

    /// 解析 `tmutil listlocalsnapshots /` 的标准输出
    public static func parseSnapshots(from output: String, volume: String = "/") -> [APFSSnapshot] {
        var snapshots: [APFSSnapshot] = []
        let lines = output.components(separatedBy: .newlines)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // 示例格式: com.apple.TimeMachine.2026-09-19-140000.local
            if trimmed.contains("com.apple.TimeMachine.") {
                let name = trimmed
                // 提取时间戳字符串
                let parts = trimmed.components(separatedBy: "com.apple.TimeMachine.")
                if let suffix = parts.last {
                    let datePart = suffix.replacingOccurrences(of: ".local", with: "")
                    let parsedDate = formatter.date(from: datePart)
                    snapshots.append(
                        APFSSnapshot(
                            name: name,
                            dateString: datePart,
                            date: parsedDate,
                            volume: volume
                        )
                    )
                }
            }
        }
        return snapshots.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// 系统工具路径（自检一律通过 `SafeProcess.runner` 拦截，**绝不真跑 tmutil/pmset**）。
    /// 声明为 `var` 是为了让自检能把它指向不存在的路径，演练"工具不可用"这条分支。
    public static var tmutilPath = "/usr/bin/tmutil"
    public static var pmsetPath = "/usr/bin/pmset"
    public static let diskutilPath = "/usr/sbin/diskutil"

    /// 列出指定宗卷上的所有 APFS 本地快照（兼容旧调用方：只要列表）。
    ///
    /// 注意：拿不到清单时这里返回 `[]`，与"真的没有快照"同形 ——
    /// 需要区分二者的调用方请用 `snapshotInventory(volume:)`。
    public static func listLocalSnapshots(volume: String = "/") -> [APFSSnapshot] {
        snapshotInventory(volume: volume).snapshots
    }

    /// 取快照清单，并把"命令没跑成 / 读不到"作为显式记录交出去。
    public static func snapshotInventory(
        volume: String = "/",
        timeout: TimeInterval = 20
    ) -> SnapshotInventory {
        guard !volume.trimmingCharacters(in: .whitespaces).isEmpty else {
            return SnapshotInventory(issues: [GovernanceEvidenceIssue(
                kind: .unreadable, subject: "volume", message: "卷路径为空，未执行 tmutil。")])
        }
        guard SafeProcess.isAvailable(tmutilPath) else {
            return SnapshotInventory(issues: [GovernanceEvidenceIssue(
                kind: .toolUnavailable, subject: tmutilPath,
                message: "本机找不到 \(tmutilPath)，无法确认是否存在本地快照。")])
        }
        guard let result = SafeProcess.run(tmutilPath, ["listlocalsnapshots", volume],
                                           timeout: timeout) else {
            return SnapshotInventory(issues: [GovernanceEvidenceIssue(
                kind: .commandFailed, subject: "\(tmutilPath) listlocalsnapshots \(volume)",
                message: "tmutil 未能启动，无法确认是否存在本地快照。")])
        }
        if result.timedOut {
            return SnapshotInventory(issues: [GovernanceEvidenceIssue(
                kind: .commandFailed, subject: "\(tmutilPath) listlocalsnapshots \(volume)",
                message: "查询本地快照超时（\(Int(timeout)) 秒），无法确认是否存在快照。")])
        }
        if result.exitCode != 0 {
            // 真机常见：该卷由 root 管理 / 需要管理员授权 —— 这**不是**"没有快照"
            return SnapshotInventory(issues: [GovernanceEvidenceIssue(
                kind: .commandFailed, subject: "\(tmutilPath) listlocalsnapshots \(volume)",
                message: "查询本地快照未成功（退出码 \(result.exitCode)）："
                    + "\(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
                    + " 无法确认是否存在快照。")])
        }
        return SnapshotInventory(snapshots: parseSnapshots(from: result.output, volume: volume),
                                 issues: [], commandSucceeded: true)
    }

    /// 安全删除**单个**本地快照。
    ///
    /// - Parameter confirmed: 必须是用户对这一条名字点过的头。
    ///   `false` 时一条命令都不执行 —— 本模块不接受"顺手全删"。
    /// - Returns: `success` 只在 `tmutil` 真实退出码 0、未超时**且复核后快照确实消失**时为 true。
    public static func deleteLocalSnapshot(snapshotName: String,
                                           confirmed: Bool,
                                           volume: String = "/",
                                           knownSnapshots: [APFSSnapshot]? = nil,
                                           timeout: TimeInterval = 30,
                                           verify: Bool = true) -> (success: Bool, message: String) {
        let outcome = deleteLocalSnapshots(
            [snapshotName], confirmed: confirmed, volume: volume,
            knownSnapshots: knownSnapshots, timeout: timeout, verify: verify)
        if let fail = outcome.failed.first { return (false, fail.message) }
        if let skip = outcome.skipped.first { return (false, skip.reason) }
        if outcome.succeeded.first == snapshotName {
            return (true, "已删除并复核本地快照：\(snapshotName)")
        }
        return (false, "未确认删除结果，未报告为已删除：\(snapshotName)")
    }

    /// 逐条删除用户**点名**的本地快照。
    ///
    /// 三条硬约束：
    /// ① `confirmed` 必须为 true，且名字必须出现在本轮 `tmutil` 列出的快照里
    ///    （防止把任意字符串拼进命令行、也防止删掉列表之外的东西）；
    /// ② 一个名字一次命令，绝不"整批静默执行"；
    /// ③ 只有命令成功**且复核后已不在清单里**才计入 `succeeded`；
    ///    命令返回 0 但快照仍在 → 记为失败，如实说明。
    public static func deleteLocalSnapshots(
        _ names: [String],
        confirmed: Bool,
        volume: String = "/",
        knownSnapshots: [APFSSnapshot]? = nil,
        timeout: TimeInterval = 30,
        verify: Bool = true
    ) -> SnapshotDeleteOutcome {
        var out = SnapshotDeleteOutcome()
        guard confirmed else {
            for name in names {
                out.skipped.append((name, "未经逐条确认，未执行任何 tmutil 调用。"))
            }
            return out
        }
        let known = knownSnapshots ?? snapshotInventory(volume: volume).snapshots
        let knownByName = Dictionary(uniqueKeysWithValues: known.map { ($0.name, $0) })

        for rawName in names {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let snapshot = knownByName[name] else {
                out.skipped.append((rawName, "不在本轮列出的快照清单里，拒绝执行。"))
                continue
            }
            guard snapshot.hasValidDateSuffix else {
                out.skipped.append((name, "快照时间戳形态异常，拒绝拼入命令行：\(snapshot.dateString)"))
                continue
            }
            guard SafeProcess.isAvailable(tmutilPath) else {
                out.failed.append((name, "本机找不到 \(tmutilPath)，未执行删除。"))
                continue
            }
            guard let result = SafeProcess.run(tmutilPath, ["deletelocalsnapshots", snapshot.deleteArgument],
                                               timeout: timeout) else {
                out.failed.append((name, "tmutil 未能启动，未执行删除。"))
                continue
            }
            let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if result.timedOut {
                out.failed.append((name, "删除超时（\(Int(timeout)) 秒），结果未知：请勿重复触发。"))
                continue
            }
            if result.exitCode != 0 {
                out.failed.append((name, "删除未成功（tmutil 退出码 \(result.exitCode)）："
                                    + "\(detail.isEmpty ? "无输出" : detail)"))
                continue
            }
            guard verify else {
                out.succeeded.append(name)
                continue
            }
            // 复核：命令说成功不算成功，快照真的从清单里消失才算
            let stillThere = snapshotInventory(volume: volume).snapshots.contains { $0.name == name }
            if stillThere {
                out.failed.append((name, "tmutil 返回 0 但快照仍在清单里，未报告为已删除。"))
            } else {
                out.succeeded.append(name)
            }
        }
        return out
    }

    /// 旧调用方（菜单栏的"释放"按钮）仍在用的批量入口。
    ///
    /// 保留这个形状，但语义已经收紧：
    /// ① 只处理**传进来的这些名字**，且每个名字都必须在**重新取得**的清单里存在
    ///    （不在清单里 → 计入 skipped，一条命令都不发）；
    /// ② 一个名字一条 `tmutil deletelocalsnapshots <日期>`，带超时，绝不拼通配；
    /// ③ 每条都要复核"是否真的从清单里消失"，没消失一律算失败，
    ///    **命令返回 0 也不再报"已删除"**。
    ///
    /// 注意：新视图（`SystemDeepStorageView`）已改为"用户逐条勾选 + 二次确认"，
    /// 这个入口只服务于仍在一键触发的老调用方，其 `confirmed` 由调用方的点击代表。
    public static func deleteAllLocalSnapshots(
        snapshots: [APFSSnapshot],
        volume: String = "/"
    ) -> (succeededCount: Int, failedCount: Int) {
        let out = deleteLocalSnapshots(snapshots.map { $0.name }, confirmed: true, volume: volume)
        return (out.succeededCount, out.failedCount + out.skipped.count)
    }

    // MARK: - 休眠映像与虚拟内存 Swap 检测

    /// 解析 `pmset -g` 输出中的 `hibernatemode`
    public static func parseHibernateMode(from output: String) -> Int? {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("hibernatemode") {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 2, let mode = Int(parts[1]) {
                    return mode
                }
            }
        }
        return nil
    }

    /// 深度检测 `/var/vm` 中的休眠映像与 Swap 交换文件
    public static func inspectVMMemory(pmsetOutputTimeout: TimeInterval = 10) -> VMMemoryInfo {
        var info = VMMemoryInfo()
        let fm = FileManager.default

        // 1. 检查 sleepimage
        let sleepimagePath = "/var/vm/sleepimage"
        if fm.fileExists(atPath: sleepimagePath) {
            info.sleepimageExists = true
            if let attrs = try? fm.attributesOfItem(atPath: sleepimagePath),
               let size = attrs[.size] as? NSNumber {
                info.sleepimageSize = size.int64Value
            } else {
                info.issues.append(GovernanceEvidenceIssue(
                    kind: .unreadable, subject: sleepimagePath,
                    message: "休眠映像存在但读不到大小，释放量无法估算。"))
            }
        }

        // 2. 检查 swapfile
        //    `/var/vm` 是 root 所有：读不到时**不能**显示"0 个 / 0 B (无压力)"
        let vmDir = "/var/vm"
        if FileSystem.isPermissionDenied(vmDir) {
            info.vmDirectoryReadable = false
            info.issues.append(GovernanceEvidenceIssue(
                kind: .permissionDenied, subject: vmDir,
                message: "虚拟内存目录由 root 管理，当前用户读不到：Swap 数量与占用均未知。"))
        } else if let contents = try? fm.contentsOfDirectory(atPath: vmDir) {
            for file in contents where file.hasPrefix("swapfile") {
                info.swapFilesCount += 1
                let filePath = (vmDir as NSString).appendingPathComponent(file)
                if let attrs = try? fm.attributesOfItem(atPath: filePath),
                   let size = attrs[.size] as? NSNumber {
                    info.totalSwapSize += size.int64Value
                }
            }
        } else {
            info.vmDirectoryReadable = false
            info.issues.append(GovernanceEvidenceIssue(
                kind: .unreadable, subject: vmDir,
                message: "无法枚举虚拟内存目录：Swap 数量与占用均未知。"))
        }

        // 3. 读取当前休眠模式（只读命令，一律走 SafeProcess：超时 + 先排空管道）
        if !SafeProcess.isAvailable(pmsetPath) {
            info.hibernateModeUnavailableReason = "本机找不到 \(pmsetPath)"
            info.issues.append(GovernanceEvidenceIssue(
                kind: .toolUnavailable, subject: pmsetPath,
                message: "本机找不到 \(pmsetPath)，无法读取当前休眠设置。"))
        } else if let result = SafeProcess.run(pmsetPath, ["-g"], timeout: pmsetOutputTimeout) {
            if result.timedOut {
                info.hibernateModeUnavailableReason = "pmset -g 超时"
                info.issues.append(GovernanceEvidenceIssue(
                    kind: .commandFailed, subject: "\(pmsetPath) -g",
                    message: "pmset -g 超时（\(Int(pmsetOutputTimeout)) 秒），当前休眠设置未知。"))
            } else if result.exitCode != 0 {
                info.hibernateModeUnavailableReason = "pmset -g 退出码 \(result.exitCode)"
                info.issues.append(GovernanceEvidenceIssue(
                    kind: .commandFailed, subject: "\(pmsetPath) -g",
                    message: "读取休眠设置未成功（退出码 \(result.exitCode)）。"))
            } else {
                info.hibernateMode = parseHibernateMode(from: result.output)
                if info.hibernateMode == nil {
                    info.hibernateModeUnavailableReason = "输出里没有 hibernatemode 字段"
                    info.issues.append(GovernanceEvidenceIssue(
                        kind: .unreadable, subject: "\(pmsetPath) -g",
                        message: "pmset 输出里没有 hibernatemode 字段，无法判断当前休眠模式。"))
                }
            }
        } else {
            info.hibernateModeUnavailableReason = "pmset 未能启动"
            info.issues.append(GovernanceEvidenceIssue(
                kind: .commandFailed, subject: "\(pmsetPath) -g",
                message: "pmset 未能启动，无法读取当前休眠设置。"))
        }

        // 4. 判断是否为台式 Mac (Mac mini, Mac Studio, Mac Pro, iMac)
        info.isDesktopMac = isCurrentMachineDesktop()
        info.recommendedHibernateMode = info.isDesktopMac ? 0 : 3

        return info
    }

    /// 改休眠模式的**代价**：卡片必须与"释放空间"同时出现。
    public static let hibernateRiskText =
        "Mode 0 会彻底不再写 sleepimage：笔记本因此失去休眠（SafeSleep），"
        + "合盖后电量耗尽会直接断电，未保存内容可能丢失。命令需要 sudo，由你在终端自行执行。"

    private static func isCurrentMachineDesktop() -> Bool {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelString = String(cString: model).lowercased()

        return modelString.contains("mini") ||
            modelString.contains("studio") ||
            modelString.contains("pro") && !modelString.contains("book") ||
            modelString.contains("imac")
    }

    /// 生成安全的休眠模式优化与 sleepimage 释放 Shell 脚本命令
    ///
    /// 本工具**不执行**这些命令（全部需要 sudo）：只生成文本交给人自己在终端跑，
    /// 并把代价一起写进脚本头，避免用户只看到"释放数十 GB"。
    public static func generateHibernateOptimizationScript(targetMode: Int = 0) -> String {
        return """
        # --- MacClean 休眠镜像与物理存储释放命令（需管理员权限，请自行核对后执行）---
        # 代价提示：\(hibernateRiskText)
        # 复核现状：pmset -g | grep hibernatemode
        #
        # 1. 设置休眠模式为 \(targetMode) (0: 纯内存休眠不写磁盘)
        sudo pmset -a hibernatemode \(targetMode)

        # 2. 安全删除当前的 sleepimage 物理镜像文件
        sudo rm -f /var/vm/sleepimage

        # 3. 创建空的 0 字节只读占位文件，防止 macOS 再次自动生成
        sudo touch /var/vm/sleepimage
        sudo chflags uchg /var/vm/sleepimage

        # 回退（恢复 SafeSleep 并解除占位）：
        #   sudo chflags nouchg /var/vm/sleepimage
        #   sudo pmset -a hibernatemode 3
        echo "✅ 休眠镜像瘦身命令执行完毕（请复核 pmset -g 输出）"
        """
    }
}
