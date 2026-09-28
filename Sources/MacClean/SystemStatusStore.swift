import Foundation

/// 系统状态只读探针的**执行层**。
///
/// 与 `SystemTweakStore` 一样不碰文件、不走删除网关；与它不同的是这里**没有任何写路径**：
/// 只有 `read`。这一点不靠"调用方自觉"，而是两道机械保证：
///  ① 执行前先过 `StatusCommand.isReadOnly`——参数里出现 write/delete/set 之类动词就**拒绝执行**；
///  ② 自检里有真机断言：跑完全部状态探针后，`SafeProcess` 记录里不许出现任何写类命令。
enum SystemStatusStore {

    /// 读一项检查。
    ///
    /// 缺项（命令被拒执行 / 起不来 / 超时）在结果里是 `nil`，解析层据此判「读不到」——
    /// **不许**用"命令没跑成"去外推一个具体状态。
    static func read(_ check: SystemStatusCheck) -> StatusFinding {
        let results: [StatusCommandResult?] = check.commands.map { command in
            guard command.isReadOnly else { return nil }
            guard let result = SafeProcess.run(command.path, command.args, timeout: 8) else {
                return nil
            }
            return StatusCommandResult(exitCode: result.exitCode, output: result.output)
        }
        let reading = SystemStatusParser.parse(kind: check.kind, results: results)
        var detail: String?
        if check.kind == .timeMachine, results.count > 1 {
            detail = SystemStatusParser.lastBackupDetail(from: results[1])
        }
        return StatusFinding(check: check, reading: reading, detail: detail)
    }

    /// 全部检查。**只读，绝不写。**
    static func inspect(_ checks: [SystemStatusCheck] = SystemStatusCheck.catalog) -> [StatusFinding] {
        checks.map(read)
    }
}
