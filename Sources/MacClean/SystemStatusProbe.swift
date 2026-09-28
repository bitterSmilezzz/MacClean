import Foundation

// MARK: - 系统状态：只读体检（工具不改这些）
//
// 与「可改的优化项」（`SystemTweak`）是**两组东西**，必须分开：
//
//  · `SystemTweak`：用户域、可逆、改了更顺手 → 工具可以代改（逐条确认 + 撤销记录）；
//  · `SystemStatusCheck`：要么需要管理员权限，要么动的是**安全边界**
//    （SIP / 全盘加密 / 门禁 / 防火墙）→ 工具**只读现状**，绝不代改。
//
// 为什么后者不给按钮：这些项的默认值本身就是安全设计的一部分。一个"帮你把 SIP 关掉
// 更自由"的按钮，和清理软件的定位是冲突的——清理软件不该碰操作系统安全边界。
// 工具能做的是把现状读**准**、说清它意味着什么、告诉你去哪儿改。
//
// 三条纪律（与偏好那条链路同源）：
//   ① **三态**：开启 / 未开启 / **读不到**。"读不到"不许被折叠成任何一个具体状态；
//   ② **退出码不算答案**：`tmutil latestbackup` 在本机**退出码 0** 却只打印
//      "Failed to mount backup destination"——只看退出码就会把一次挂载失败
//      当成"最近备份时间"。所以判据一律落在**输出内容**上；
//   ③ **命令只读**：所有探针的参数里不许出现 write / delete / set / enable / disable，
//      自检里有断言钉住这一点。

/// 一条探针命令。
struct StatusCommand: Equatable {
    let path: String
    let args: [String]

    /// 这条命令是否是只读的。**唯一裁决**，自检与运行期都走它。
    ///
    /// 判据是"参数里不许出现会改状态的动词"，而不是"我们知道哪些命令安全"——
    /// 后者会随新增探针而失效。
    var isReadOnly: Bool {
        let banned = ["write", "delete", "set", "enable", "disable", "on", "off", "remove", "reset"]
        return args.allSatisfy { arg in
            let lowered = arg.lowercased()
            // `--getglobalstate` / `-s` / `status` 这类是查询；
            // 逐字比较避免把 "on" 误判成 "--getglobalstate" 里的子串。
            return !banned.contains(lowered)
        }
    }
}

/// 一项系统状态检查。
struct SystemStatusCheck: Identifiable, Equatable {
    enum Kind: String, CaseIterable {
        case sip, gatekeeper, fileVault, firewall, timeMachine, spotlight
    }

    let kind: Kind
    let title: String
    /// 这一项在管什么（一句话，别写空话）
    let whatItDoes: String
    /// 去哪儿改。**工具不代改**，所以这里必须是可执行的指路。
    let whereToChange: String
    /// 读命令。第一个是主探针；第二个可选，用于补充信息（例如"最近一次备份时间"）。
    let commands: [StatusCommand]

    var id: String { kind.rawValue }
}

/// 一项状态的读数。**三态**，"读不到"是一等公民。
enum StatusReading: Equatable {
    case on(evidence: String)
    case off(evidence: String)
    case unknown(reason: String)

    var label: String {
        switch self {
        case .on: return "已开启"
        case .off: return "未开启"
        case .unknown: return "读不到"
        }
    }

    /// 给界面看的一句话（含原始证据，便于用户自己去核对）
    var evidence: String {
        switch self {
        case .on(let e), .off(let e): return e
        case .unknown(let reason): return reason
        }
    }
}

/// 一项检查的结果。
struct StatusFinding: Identifiable, Equatable {
    let check: SystemStatusCheck
    let reading: StatusReading
    /// 补充信息（例如"最近一次备份：2026-09-27 05:12"）。
    /// 拿不到就是 nil——**不许拿"主探针成功"去外推一个补读数**。
    let detail: String?

    var id: String { check.id }
}

extension SystemStatusCheck {
    /// 检查项目录。
    ///
    /// 取值依据全部来自**本机实测的输出措辞**，不是照着文档猜的：
    ///  `csrutil status` → `System Integrity Protection status: enabled.`
    ///  `spctl --status` → `assessments enabled`
    ///  `fdesetup status` → `FileVault is On.`
    ///  `socketfilterfw --getglobalstate` → `Firewall is enabled. (State = 1)`
    ///  `tmutil destinationinfo` → `tmutil: No destinations configured.`
    ///  `mdutil -s /` → `\tIndexing enabled. `
    ///
    /// 防火墙刻意**不用** `defaults read /Library/Preferences/com.apple.alf globalstate`：
    /// 本机实测那个域**不存在**（`Domain 'com.apple.alf' not found.`），而
    /// `socketfilterfw --getglobalstate` 不需要 root 就能给出明确状态。
    static let catalog: [SystemStatusCheck] = [
        SystemStatusCheck(
            kind: .sip,
            title: "系统完整性保护（SIP）",
            whatItDoes: "阻止任何进程（包括 root）修改系统文件与内核扩展。关掉它，恶意软件改系统文件就没有拦路的了。",
            whereToChange: "要改需重启进恢复模式执行 csrutil——正常使用**不建议关**。",
            commands: [StatusCommand(path: "/usr/bin/csrutil", args: ["status"])]),

        SystemStatusCheck(
            kind: .gatekeeper,
            title: "门禁（Gatekeeper）",
            whatItDoes: "检查下载来的 App 是否经过签名与公证。关掉它，双击任意来源的 App 都能直接运行。",
            whereToChange: "系统设置 → 隐私与安全性 → 「允许从以下位置下载的应用程序」。",
            commands: [StatusCommand(path: "/usr/sbin/spctl", args: ["--status"])]),

        SystemStatusCheck(
            kind: .fileVault,
            title: "文件保险箱（全盘加密）",
            whatItDoes: "整盘加密。笔记本丢了或磁盘被拆走时，没有密码就读不出数据。",
            whereToChange: "系统设置 → 隐私与安全性 → 文件保险箱。",
            commands: [StatusCommand(path: "/usr/bin/fdesetup", args: ["status"])]),

        SystemStatusCheck(
            kind: .firewall,
            title: "应用防火墙",
            whatItDoes: "控制外部连接能否主动接入本机上的程序。",
            whereToChange: "系统设置 → 网络 → 防火墙。",
            commands: [StatusCommand(path: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                                     args: ["--getglobalstate"])]),

        SystemStatusCheck(
            kind: .timeMachine,
            title: "时间机器备份",
            whatItDoes: "是否有备份目标，以及最近一次备份是什么时候。**「有目标」不等于「在备份」**——"
                + "备份盘长期没接，最后一次备份可能已经是几个月前。",
            whereToChange: "系统设置 → 通用 → 时间机器。",
            commands: [
                StatusCommand(path: "/usr/bin/tmutil", args: ["destinationinfo"]),
                // 补读数。**注意它会在失败时仍然退出码 0**，所以判据只能落在输出上。
                StatusCommand(path: "/usr/bin/tmutil", args: ["latestbackup"]),
            ]),

        SystemStatusCheck(
            kind: .spotlight,
            title: "Spotlight 索引",
            whatItDoes: "影响聚焦搜索、邮件/文件搜索与部分 App 的检索。关掉后搜索会大面积失效。",
            whereToChange: "系统设置 → 聚焦（Siri 与聚焦）→ 搜索隐私；或命令行 mdutil。",
            commands: [StatusCommand(path: "/usr/bin/mdutil", args: ["-s", "/"])]),
    ]
}

// MARK: - 纯解析
//
// 解析与执行分开，是为了让"措辞变了怎么办"这件事能被穷举测试——
// 偏好那边的 `defaults` 措辞就在三个版本上各变过一次，这里用同一套办法防。

enum SystemStatusParser {
    /// 把探针输出解析成三态读数。**纯函数**。
    ///
    /// `results` 与 `check.commands` 一一对应；缺项表示那条命令没跑起来。
    static func parse(kind: SystemStatusCheck.Kind,
                      results: [StatusCommandResult?]) -> StatusReading {
        guard let primary = results.first ?? nil else {
            return .unknown(reason: "探针没能执行（命令起不来或超时）")
        }
        let text = primary.output.lowercased()
        switch kind {
        case .sip:
            if text.contains("status: enabled") { return .on(evidence: primary.shortOutput) }
            if text.contains("status: disabled") { return .off(evidence: primary.shortOutput) }
            return .unknown(reason: "认不出 csrutil 的输出：\(primary.shortOutput)")
        case .gatekeeper:
            if text.contains("assessments enabled") { return .on(evidence: primary.shortOutput) }
            if text.contains("assessments disabled") { return .off(evidence: primary.shortOutput) }
            return .unknown(reason: "认不出 spctl 的输出：\(primary.shortOutput)")
        case .fileVault:
            if text.contains("filevault is on") { return .on(evidence: primary.shortOutput) }
            if text.contains("filevault is off") { return .off(evidence: primary.shortOutput) }
            return .unknown(reason: "认不出 fdesetup 的输出：\(primary.shortOutput)")
        case .firewall:
            if text.contains("disabled") { return .off(evidence: primary.shortOutput) }
            if text.contains("enabled") { return .on(evidence: primary.shortOutput) }
            return .unknown(reason: "认不出防火墙探针的输出：\(primary.shortOutput)")
        case .spotlight:
            if text.contains("indexing enabled") { return .on(evidence: primary.shortOutput) }
            if text.contains("indexing disabled") { return .off(evidence: primary.shortOutput) }
            return .unknown(reason: "认不出 mdutil 的输出：\(primary.shortOutput)")
        case .timeMachine:
            if text.contains("no destinations configured") {
                return .off(evidence: primary.shortOutput)
            }
            // 有目标时会列 Name / Kind / URL / Mount Point
            if text.contains("name") || text.contains("kind") || text.contains("url") {
                return .on(evidence: primary.shortOutput)
            }
            return .unknown(reason: "认不出 tmutil destinationinfo 的输出：\(primary.shortOutput)")
        }
    }

    /// 补读数：最近一次备份时间。**拿不到就返回 nil**。
    ///
    /// 这条单独抽出来，是因为 `tmutil latestbackup` 在本机实测**退出码 0**
    /// 却只打印 `Failed to mount backup destination, error: ...`。
    /// 只看退出码就会把一次挂载失败当成"最近备份时间"——
    /// 所以判据是"输出看起来像一个备份路径"：必须以 `/` 开头。
    static func lastBackupDetail(from result: StatusCommandResult?) -> String? {
        guard let result else { return nil }
        let trimmed = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        return "最近一次备份：\(trimmed)"
    }
}

/// 一条探针命令的执行结果。
struct StatusCommandResult: Equatable {
    let exitCode: Int32
    let output: String

    /// 截断后的输出，供"认不出"时的报错里带上原始证据。
    var shortOutput: String {
        let one = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        return one.count > 120 ? String(one.prefix(120)) + "…" : one
    }
}
