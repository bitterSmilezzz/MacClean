import Foundation
import Darwin

// MARK: - 已卸载应用登录项与自启残存清理引擎 (v1.67.0 · v1.73.0 安全加固)
//
// 本轮修掉四处真实缺陷：
//
// ① **白名单是死代码**。旧 `systemProtectedPrefixes` 把 `/System/Library`、`/usr/libexec`
//    当成**文件名**的 `hasPrefix` 来比（`name.hasPrefix("/System/Library")`，而 name 是
//    `com.apple.metadata.mdworker` 这种 label），实测永远不命中。现在改成：
//    从 plist 的 `Program` / `ProgramArguments[0]` 解析出**真实可执行路径**再做前缀判定。
//
// ② **先卸载再删除，撤销后仍是禁用态**。旧 `clean` 先 `launchctl unload -w`
//    （`-w` 会把禁用写进 override 数据库），再把 plist 移进废纸篓；用户从废纸篓还原后
//    文件回到原位却仍被禁用，等于"恢复了个寂寞"。现在**先删成功、再 unload**，
//    删除失败或被判据拦下就完全不碰 launchd。
//
// ③ **launchctl 手写 Process**：`try? p.run()` 之后无条件 `waitUntilExit()`，
//    进程没起来也会等（崩溃形状），且退出码被丢弃。现在走 `SafeProcess` 并逐项上报。
//
// ④ **`/Library/LaunchAgents`、`/Library/LaunchDaemons` 无护栏**。真机实测这两处 root 只读
//    （`drwxr-xr-x root:wheel`），旧代码却照抄 `hasPrefix("/System")` 一条字符串护栏就删。
//    现在逐个声明治理域，网关会给出 `needsPrivilege`，卡片如实说"本工具不提权"。

public final class LoginItemCleaner {
    public static let shared = LoginItemCleaner()

    /// `launchctl` 路径可覆盖：自检据此断言命令与参数，不会真的动 launchd。
    static var launchctlPath = "/bin/launchctl"

    private init() {}

    /// Apple 自启项的**可执行文件**前缀：解析出的真实路径落在这些前缀下即官方托管。
    /// 注意比的是可执行路径，不是 plist 文件名——旧实现错在后者上。
    static let appleExecutablePrefixes: [String] = [
        "/System/Library", "/System/Volumes", "/usr/libexec",
        "/usr/sbin", "/sbin", "/usr/bin", "/bin",
    ]

    /// 裸命令名的解析路径（`ProgramArguments[0]` 常写成 `sleep` 这类不带 `/` 的名字）
    static let executableSearchDirs: [String] = [
        "/bin", "/usr/bin", "/sbin", "/usr/sbin", "/usr/libexec",
    ]

    /// 扫描系统与用户目录中的登录项与自启守护
    public func scan(customDirectories: [LoginItemKind: [String]]? = nil) -> LoginItemSummary {
        let fm = FileManager.default
        var candidateFolders: [(dir: String, kind: LoginItemKind)] = []

        if let custom = customDirectories {
            for (kind, dirs) in custom {
                for d in dirs {
                    candidateFolders.append((d, kind))
                }
            }
        } else {
            let userAgents = NSString(string: "~/Library/LaunchAgents").expandingTildeInPath
            candidateFolders.append((userAgents, .launchAgent))
            candidateFolders.append(("/Library/LaunchAgents", .globalAgent))
            candidateFolders.append(("/Library/LaunchDaemons", .globalDaemon))
        }

        var items: [LoginItemEntry] = []
        var orphanCount = 0
        var reviewCount = 0
        var rootManaged = 0
        var totalSize: Int64 = 0

        for candidate in candidateFolders {
            let dirPath = candidate.dir

            // 安全防线：G8 系统硬保护位置根本不扫（不再用 hasPrefix("/System") 字符串比较）
            if FileSystem.isSystemProtected(FileSystem.normalizePath(dirPath)) { continue }

            guard fm.fileExists(atPath: dirPath) else { continue }
            // 读不到目录内容 → 这一根下什么都不列（而不是"里面的都能删"）
            guard let fileNames = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }

            for fileName in fileNames.sorted() where fileName.hasSuffix(".plist") {
                let filePath = (dirPath as NSString).appendingPathComponent(fileName)
                let name = (fileName as NSString).deletingPathExtension

                guard let attrs = try? fm.attributesOfItem(atPath: filePath) else {
                    reviewCount += 1
                    continue
                }
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
                let inspection = Self.inspectPlist(at: filePath, name: name)
                if inspection.issue.isOrphan { orphanCount += 1 }
                if inspection.issue == .needsReview { reviewCount += 1 }

                let rootManagedHere = Self.governanceDomain(forPath: filePath) != nil
                if rootManagedHere { rootManaged += 1 }

                // 默认勾选：只有"声明的绝对可执行路径确实不存在"、且这份配置**真的删得动**
                // 的条目才预选。root 管理位置预选等于给用户一个注定失败的勾。
                let shouldSelect = inspection.issue.providesDeletionEvidence && !rootManagedHere

                let entry = LoginItemEntry(
                    id: filePath,
                    name: name,
                    path: filePath,
                    targetPath: inspection.targetPath,
                    kind: candidate.kind,
                    issue: inspection.issue,
                    size: size,
                    isSelected: shouldSelect,
                    serviceLabel: inspection.label,
                    note: rootManagedHere
                        ? LoginItemCleaner.rootManagedMessage(inspection: inspection)
                        : inspection.note
                )
                items.append(entry)
                totalSize += size
            }
        }

        // 优先将死链项排在最前
        let sorted = items.sorted { a, b in
            if a.issue.isOrphan != b.issue.isOrphan {
                return a.issue.isOrphan
            }
            return a.name < b.name
        }

        return LoginItemSummary(
            items: sorted,
            orphanCount: orphanCount,
            totalSize: totalSize,
            needsReviewCount: reviewCount,
            rootManagedCount: rootManaged
        )
    }

    private static func rootManagedMessage(inspection: LoginItemInspection) -> String {
        var text = "该位置由 root 管理，本工具不提权"
        if let note = inspection.note, !note.isEmpty { text += "（\(note)）" }
        return text
    }

    // MARK: - plist 研判

    /// 检查指定 plist 对应的目标可执行程序是否存在，并给出**带证据**的问题分类。
    ///
    /// 关键：Apple 托管判定作用在 `Program`/`ProgramArguments[0]` 解析出的真实路径上。
    public static func inspectPlist(at path: String, name: String) -> LoginItemInspection {
        // 1. label 本身就是 Apple 的（这条以前就有效，保留）
        if name.lowercased().hasPrefix("com.apple.") {
            return LoginItemInspection(targetPath: nil, label: name, issue: .appleManaged,
                                       note: "标签为 com.apple.* 的官方自启项")
        }

        // 2. plist 读不到：证据缺失，绝不判孤儿（旧实现回 (nil,false) 但卡片仍可能勾选）
        guard let dict = NSDictionary(contentsOfFile: path) as? [String: Any] else {
            return LoginItemInspection(targetPath: nil, label: name, issue: .needsReview,
                                       note: "无法读取 plist 内容，证据不足")
        }

        let label = (dict["Label"] as? String) ?? name

        // 3. 解析真实可执行路径
        guard let raw = declaredProgram(in: dict) else {
            return LoginItemInspection(targetPath: nil, label: label, issue: .needsReview,
                                       note: "plist 未声明 Program/ProgramArguments，宿主由 launchd 内建机制决定")
        }
        guard let resolved = resolveExecutable(raw) else {
            return LoginItemInspection(targetPath: raw, label: label, issue: .needsReview,
                                       note: "可执行命令「\(raw)」无法解析为绝对路径，证据不足")
        }

        // 4. Apple 托管：按**真实可执行路径**做前缀判定
        let normalized = FileSystem.normalizePath(resolved)
        if appleManagedExecutable(normalized) {
            return LoginItemInspection(targetPath: normalized, label: label, issue: .appleManaged,
                                       note: "可执行文件位于 Apple 托管位置 \(normalized)")
        }
        if FileSystem.isSystemProtected(normalized) {
            return LoginItemInspection(targetPath: normalized, label: label, issue: .appleManaged,
                                       note: "可执行文件位于 G8 系统硬保护位置")
        }

        // 5. 正向证据：声明的绝对路径不存在 → 死链
        if FileManager.default.fileExists(atPath: normalized) {
            return LoginItemInspection(targetPath: normalized, label: label, issue: .validActive, note: nil)
        }
        return LoginItemInspection(targetPath: normalized, label: label, issue: .executableMissing,
                                   note: "plist 声明的可执行文件不存在：\(normalized)")
    }

    /// 取 plist 声明的启动命令：`Program` 优先，其次 `ProgramArguments[0]`。
    static func declaredProgram(in dict: [String: Any]) -> String? {
        if let program = dict["Program"] as? String, !program.isEmpty { return program }
        if let args = dict["ProgramArguments"] as? [String], let first = args.first, !first.isEmpty {
            return first
        }
        if let args = dict["ProgramArguments"] as? [Any], let first = args.first as? String, !first.isEmpty {
            return first
        }
        return nil
    }

    /// 把声明的命令解析成绝对路径。裸名按 `executableSearchDirs` 查找；解析不出返回 nil。
    static func resolveExecutable(_ raw: String) -> String? {
        if raw.hasPrefix("/") { return raw }
        guard !raw.contains("/") else { return nil }   // 相对路径：不确定基准，不猜
        for dir in executableSearchDirs {
            let candidate = (dir as NSString).appendingPathComponent(raw)
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
        }
        return nil
    }

    static func appleManagedExecutable(_ normalizedPath: String) -> Bool {
        appleExecutablePrefixes.contains { prefix in
            let p = FileSystem.normalizePath(prefix)
            return normalizedPath == p || normalizedPath.hasPrefix(p + "/")
        }
    }

    // MARK: - 治理域声明

    /// `/Library/LaunchAgents`、`/Library/LaunchDaemons` 必须声明对应治理域；
    /// 用户 `~/Library/LaunchAgents` 内的传 nil 走主目录护栏。
    static func governanceDomain(forPath path: String) -> GovernanceDomain? {
        GovernanceDomain.domain(forPath: path)
    }

    /// launchd 服务寻址目标：`gui/<uid>/<label>`。
    ///
    /// 用 target 而不是 plist 路径，是因为**删除之后 plist 已不在原位**（进废纸篓了），
    /// `launchctl unload -w <path>` 那时必然失败；而 `-w` 会把禁用写进 override 数据库，
    /// 让"从废纸篓还原"变成还原一个仍被禁用的启动项。
    static func launchTarget(for label: String, uid: uid_t = getuid()) -> String {
        "gui/\(uid)/\(label)"
    }

    // MARK: - 清理（先删成功，再卸载）

    /// 一次清理的完整结果：网关裁决 + 逐项 launchd 卸载结论。
    struct LoginItemCleanOutcome {
        var gate = ResidueDeletionGate.Outcome()
        /// 删除成功后真正执行的卸载结论
        var unloadResults: [LaunchctlUnloadResult] = []

        var cleanedCount: Int { gate.cleanedCount }
        var freedBytes: Int64 { gate.freedBytes }
        var errorCount: Int { gate.errorCount + unloadResults.filter { !$0.succeeded }.count }
        var needsPrivilege: [ResidueDeletionGate.Rejection] { gate.needsPrivilege }
        var summary: String { gate.summary }

        /// 卸载失败提示（文件已删但服务没停 → 必须让用户知道）
        var unloadWarnings: [String] {
            unloadResults.filter { !$0.succeeded }.map { "「\($0.label)」文件已移除但 launchd 卸载失败：\($0.message)" }
        }
    }

    /// 清理选中的死链登录项与后台守护。
    ///
    /// 顺序即安全：**逐项过网关删除 → 只对删除成功的那一项去 unload**。
    /// 删除被拦或失败时绝不触碰 launchd，避免"配置还在、服务已被永久禁用"。
    func clean(
        items: [LoginItemEntry],
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: "自启残存治理")
    ) -> LoginItemCleanOutcome {
        var outcome = LoginItemCleanOutcome()
        guard !items.isEmpty else { return outcome }

        var candidates: [ResidueDeletionGate.Candidate] = []
        var labelByPath: [String: String] = [:]

        for item in items {
            if let blocked = blockVerdict(for: item) {
                outcome.gate.rejected.append(.make(name: item.name, path: item.path,
                                                   reason: blocked.reason, message: blocked.message))
                continue
            }
            candidates.append(.init(item.name, path: item.path,
                                    domain: Self.governanceDomain(forPath: item.path)))
            labelByPath[FileSystem.normalizePath(item.path)] = item.serviceLabel ?? item.name
        }

        // 合并而不是覆盖：网关之前被模块判据拦下的项必须留在结果里
        let gate = ResidueDeletionGate.execute(candidates, toTrash: toTrash, journal: journal)
        outcome.gate.merge(gate)

        // 只有真的删掉了的，才去让 launchd 忘掉这个服务
        for deleted in gate.cleanedPaths {
            let normalized = FileSystem.normalizePath(deleted)
            let label = labelByPath[normalized] ?? (deleted as NSString).lastPathComponent
            outcome.unloadResults.append(Self.unloadService(label: label))
        }
        return outcome
    }

    /// 模块级判据：返回「拒绝原因 + 中文说明」，nil 表示可以进网关。
    ///
    /// reason 不再一律借 `.systemProtected`：官方自启项/证据不足属"不是可清理对象"
    /// （`.notDeletable`），可执行文件仍在的活跃服务属"在用"（`.inUse`）。
    func blockVerdict(for item: LoginItemEntry) -> (reason: GovernanceVerdict.Reason, message: String)? {
        switch item.issue {
        case .appleManaged:
            return (.notDeletable, "Apple 官方自启项，绝不清理")
        case .needsReview:
            return (.notDeletable, "证据不足（\(item.note ?? "无法读取配置")），需你手动确认")
        case .validActive:
            return (.inUse, "目标可执行文件仍在，不是死链残留")
        case .executableMissing:
            break
        }
        if item.name.lowercased().hasPrefix("com.apple.") {
            return (.notDeletable, "标签为 com.apple.* 的官方自启项")
        }
        if let target = item.targetPath,
           LoginItemCleaner.appleManagedExecutable(FileSystem.normalizePath(target)) {
            return (.notDeletable, "可执行文件位于 Apple 托管位置 \(target)")
        }
        // 其余情形（软链跳板 / 域外 / root 只读 / 白名单）交给网关给真实原因
        return nil
    }

    /// 卸载 launchd 服务：走 `SafeProcess`，返回真实退出码结论。
    @discardableResult
    static func unloadService(label: String, uid: uid_t = getuid()) -> LaunchctlUnloadResult {
        let target = launchTarget(for: label, uid: uid)
        let path = launchctlPath
        guard SafeProcess.isAvailable(path) else {
            return LaunchctlUnloadResult(label: label, target: target, attempted: false,
                                         succeeded: false, exitCode: nil,
                                         message: "本机没有可用的 launchctl，未做任何改动")
        }
        guard let result = SafeProcess.run(path, ["bootout", target], timeout: 10) else {
            return LaunchctlUnloadResult(label: label, target: target, attempted: false,
                                         succeeded: false, exitCode: nil, message: "launchctl 未能启动")
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.succeeded {
            return LaunchctlUnloadResult(label: label, target: target, attempted: true,
                                         succeeded: true, exitCode: 0, message: "已卸载")
        }
        // 3 = ESRCH（服务本来就没在跑）：文件已删，这不算问题，但也不能说"已卸载"
        if result.exitCode == 3 {
            return LaunchctlUnloadResult(label: label, target: target, attempted: true,
                                         succeeded: true, exitCode: result.exitCode,
                                         message: "服务未在运行中，无需卸载")
        }
        return LaunchctlUnloadResult(label: label, target: target, attempted: true,
                                     succeeded: false, exitCode: result.exitCode,
                                     message: output.isEmpty ? "launchctl 退出码 \(result.exitCode)" : output)
    }
}
