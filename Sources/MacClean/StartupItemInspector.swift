import Foundation

// MARK: - 启动项存储位置

public enum StartupItemLocation: String, CaseIterable, Identifiable {
    case userAgent = "用户自启代理 (LaunchAgents)"
    case globalAgent = "系统自启代理 (/Library/LaunchAgents)"
    case globalDaemon = "系统全局守护 (/Library/LaunchDaemons)"

    public var id: String { rawValue }

    public var shortTitle: String {
        switch self {
        case .userAgent: return "用户代理"
        case .globalAgent: return "全局代理"
        case .globalDaemon: return "系统守护"
        }
    }

    public var icon: String {
        switch self {
        case .userAgent: return "person.crop.circle"
        case .globalAgent: return "globe"
        case .globalDaemon: return "gearshape.2"
        }
    }

    public var requiresAdmin: Bool {
        switch self {
        case .userAgent: return false
        case .globalAgent, .globalDaemon: return true
        }
    }
}

// MARK: - 语义色板（v1.74.0：模型层不再持有 SwiftUI 的 Color）

/// 一个纯语义的颜色角色。
///
/// 原来 `StartupItemStatus.color` 直接返回 SwiftUI 的 `Color`，于是这个**巡检模型**
/// 依赖了整个 UI 框架：它既是分层违规（模型/引擎层被视图层污染），也让自检里
/// "状态判定"这类纯逻辑断言必须链接 SwiftUI。现在模型只说"这是什么语气"，
/// 具体用哪个色由视图（`StartupItemToneUI`）映射到既有 Theme 色板。
public enum StartupItemTone: String, CaseIterable, Codable {
    case positive      // 正常
    case neutral       // 中性/已停用
    case caution       // 需处理
    case accent        // 受系统保护
    case critical      // 危险/不完整
}

// MARK: - launchd 会话证据（v1.74.0）

/// 某个 label 在 launchd 会话里的**实测**状态。
///
/// 关键教训：把 `.plist` 改名成 `.disabled`、甚至把文件移进废纸篓，
/// 都**不等于**服务已停止 —— launchd 已经把定义读进当前会话了，
/// 只有 `launchctl bootout` 成功才会真正卸载。
/// 所以"已停用/已卸载"这类结论必须有命令成功的证据；没有证据就只能报"需确认"。
public enum StartupServiceEvidence: String, Equatable {
    /// 拿不到证据：`launchctl` 不存在、命令失败、超时、runner 未注入
    case unavailable
    /// 命令成功且证明该 label **仍在本会话中加载**
    case loaded
    /// 命令成功且证明该 label **未加载**
    case notLoaded
}

// MARK: - 启动项运行与健康状态

public enum StartupItemStatus: String, CaseIterable, Identifiable {
    case valid = "正常激活"
    case disabled = "已停用"
    case missingExecutable = "幽灵残留 (程序缺失)"
    case orphanedApp = "宿主应用已卸载"
    case systemProtected = "系统受保护"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .valid: return "checkmark.circle.fill"
        case .disabled: return "pause.circle.fill"
        case .missingExecutable: return "exclamationmark.triangle.fill"
        case .orphanedApp: return "trash.circle.fill"
        case .systemProtected: return "shield.fill"
        }
    }

    /// 语义色（视图自行映射到 Theme 色板）
    public var tone: StartupItemTone {
        switch self {
        case .valid: return .positive
        case .disabled: return .neutral
        case .missingExecutable, .orphanedApp: return .caution
        case .systemProtected: return .accent
        }
    }

    public var isDangling: Bool {
        self == .missingExecutable || self == .orphanedApp
    }
}

// MARK: - 启动项数据模型

public struct StartupItem: Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public var path: String
    public let label: String
    public let location: StartupItemLocation
    public let programPath: String?
    public let arguments: [String]
    public let runAtLoad: Bool
    public let keepAlive: Bool
    public var isDisabled: Bool
    public var status: StartupItemStatus
    public let vendor: String
    public let fileSize: Int64
    /// launchd 会话实测证据（`unavailable` = 没证据，**不得**据此宣称已停用/已卸载）
    public var serviceEvidence: StartupServiceEvidence
    /// 给用户的一句话说明（为什么只能报"需确认"）
    public var note: String?

    public init(
        id: String? = nil,
        name: String,
        path: String,
        label: String,
        location: StartupItemLocation,
        programPath: String?,
        arguments: [String] = [],
        runAtLoad: Bool = false,
        keepAlive: Bool = false,
        isDisabled: Bool = false,
        status: StartupItemStatus = .valid,
        vendor: String = "未知开发者",
        fileSize: Int64 = 0,
        serviceEvidence: StartupServiceEvidence = .unavailable,
        note: String? = nil
    ) {
        self.id = id ?? path
        self.name = name
        self.path = path
        self.label = label
        self.location = location
        self.programPath = programPath
        self.arguments = arguments
        self.runAtLoad = runAtLoad
        self.keepAlive = keepAlive
        self.isDisabled = isDisabled
        self.status = status
        self.vendor = vendor
        self.fileSize = fileSize
        self.serviceEvidence = serviceEvidence
        self.note = note
    }

    /// 是否**有证据**表明它已经不再自启。
    /// `isDisabled` 只代表文件层的声明；服务仍在会话里加载时就敢说"已停用"了。
    public var isConfirmedDisabled: Bool {
        isDisabled && serviceEvidence == .notLoaded
    }

    /// 需确认（有停用声明但拿不到会话证据，或服务仍在加载）
    public var needsConfirmation: Bool {
        guard status != .systemProtected else { return false }
        if isDisabled, serviceEvidence != .notLoaded { return true }
        return false
    }

    /// 本条目走的治理域：`/Library` 两处由已登记域裁决（会得到 needsPrivilege），
    /// 用户 LaunchAgents 走主目录护栏。
    /// internal：`GovernanceDomain` 是内部类型，不能出现在 public 属性上。
    var governanceDomain: GovernanceDomain? {
        switch location {
        case .userAgent: return nil
        case .globalAgent: return .launchAgentsGlobal
        case .globalDaemon: return .launchDaemonsGlobal
        }
    }
}

// MARK: - 启动项巡检与管理引擎

public final class StartupItemManager {
    public static let shared = StartupItemManager()

    // 测试注入隔离目录
    public var overrideHomeDirectory: String?
    public var overrideGlobalAgentsDir: String?
    public var overrideGlobalDaemonsDir: String?

    /// 会话证据工具路径（自检通过 `SafeProcess.runner` 拦截，**绝不真跑 launchctl**）
    public static let launchctlPath = "/bin/launchctl"

    /// 本轮巡检读不到的位置。**非空即结论不完整**，视图不得渲染成"没有自启残留"。
    public private(set) var lastScanIssues: [GovernanceEvidenceIssue] = []

    /// 本轮结论是否完整可信
    public var isResultComplete: Bool { lastScanIssues.isEmpty }

    /// 用户可见的不完整提示
    public var incompletenessBanner: String? {
        lastScanIssues.isEmpty ? nil : GovernanceEvidenceIssue.incompleteBanner(lastScanIssues)
    }

    public init() {}

    private var homeDir: String {
        overrideHomeDirectory ?? NSHomeDirectory()
    }

    private var userAgentsDir: String {
        "\(homeDir)/Library/LaunchAgents"
    }

    private var globalAgentsDir: String {
        overrideGlobalAgentsDir ?? "/Library/LaunchAgents"
    }

    private var globalDaemonsDir: String {
        overrideGlobalDaemonsDir ?? "/Library/LaunchDaemons"
    }

    /// 全面扫描所有位置的自启与守护项
    public func scanAll() -> [StartupItem] {
        var results: [StartupItem] = []
        var issues: [GovernanceEvidenceIssue] = []

        results += scanDirectory(path: userAgentsDir, location: .userAgent, issues: &issues)
        results += scanDirectory(path: globalAgentsDir, location: .globalAgent, issues: &issues)
        results += scanDirectory(path: globalDaemonsDir, location: .globalDaemon, issues: &issues)

        lastScanIssues = issues
        return results.sorted { lhs, rhs in
            if lhs.status.isDangling != rhs.status.isDangling {
                return lhs.status.isDangling && !rhs.status.isDangling
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    /// 枚举一个自启目录。
    ///
    /// 读不到时**不再静默返回空**：那会让"没权限看"被渲染成"这台机器没有自启项"。
    private func scanDirectory(path: String, location: StartupItemLocation,
                              issues: inout [GovernanceEvidenceIssue]) -> [StartupItem] {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else { return [] }   // 目录不存在
        guard isDir.boolValue else { return [] }
        if FileSystem.isPermissionDenied(path) {
            issues.append(GovernanceEvidenceIssue(
                kind: .permissionDenied, subject: path,
                message: "自启目录权限不足，当前用户读不到：\(path)"))
            return []
        }
        guard let files = try? fm.contentsOfDirectory(atPath: path) else {
            issues.append(GovernanceEvidenceIssue(
                kind: .unreadable, subject: path, message: "无法枚举自启目录：\(path)"))
            return []
        }

        var items: [StartupItem] = []
        for file in files {
            // 支持 .plist 与 .disabled
            let isPlist = file.hasSuffix(".plist")
            let isDisabledFile = file.hasSuffix(".disabled")
            guard isPlist || isDisabledFile else { continue }

            let fullPath = (path as NSString).appendingPathComponent(file)
            if let item = parseStartupItem(path: fullPath, filename: file, location: location) {
                items.append(item)
            } else {
                issues.append(GovernanceEvidenceIssue(
                    kind: .unreadable, subject: fullPath,
                    message: "定义文件解析失败（内容不可读或不是 plist）：\(fullPath)"))
            }
        }
        return items
    }

    /// 解析单个 Plist 文件
    public func parseStartupItem(path: String, filename: String,
                                location: StartupItemLocation) -> StartupItem? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { return nil }
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any] else {
            return nil
        }

        let label = (plist["Label"] as? String) ?? filename
        let runAtLoad = (plist["RunAtLoad"] as? Bool) ?? false
        let keepAlive = (plist["KeepAlive"] as? Bool) ?? false
        let plistDisabled = (plist["Disabled"] as? Bool) ?? false
        let isFileDisabled = filename.hasSuffix(".disabled")
        let isDisabled = plistDisabled || isFileDisabled

        // 提取可执行文件路径
        var programPath: String?
        var arguments: [String] = []

        if let prog = plist["Program"] as? String {
            programPath = prog
        }
        if let args = plist["ProgramArguments"] as? [String] {
            arguments = args
            if programPath == nil, let first = args.first {
                programPath = first
            }
        }

        // 文件大小
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0

        // 状态判定
        let status = evaluateStatus(
            path: path,
            filename: filename,
            label: label,
            programPath: programPath,
            isDisabled: isDisabled
        )

        let vendor = resolveVendor(label: label, programPath: programPath)
        // 只有"声称已停用"的条目才去问 launchd（一次命令开销不小）
        let evidence = isDisabled ? launchdEvidence(for: label) : .unavailable

        return StartupItem(
            name: filename,
            path: path,
            label: label,
            location: location,
            programPath: programPath,
            arguments: arguments,
            runAtLoad: runAtLoad,
            keepAlive: keepAlive,
            isDisabled: isDisabled,
            status: status,
            vendor: vendor,
            fileSize: size,
            serviceEvidence: evidence,
            note: Self.evidenceNote(isDisabled: isDisabled, evidence: evidence)
        )
    }

    /// "已停用"这句话能不能说：把会话证据翻译成人话
    static func evidenceNote(isDisabled: Bool, evidence: StartupServiceEvidence) -> String? {
        guard isDisabled else { return nil }
        switch evidence {
        case .notLoaded:
            return nil
        case .loaded:
            return "定义文件已停用，但 launchd 当前会话仍加载着该服务：需 launchctl bootout 或重新登录才会真正停止。"
        case .unavailable:
            return "无法确认服务是否已停止（本机拿不到 launchctl 证据）：请勿视为已停用。"
        }
    }

    /// 用 `launchctl print gui/<uid>/<label>` 只读地查该服务是否还在会话里。
    ///
    /// 一律走 `SafeProcess`（带超时、先排空管道、绝不对未启动的进程 wait）。
    /// 命令不存在 / 启动失败 / 超时 / 非 0 退出**都归为 `unavailable`**，
    /// 而不是当成"没在跑"——那是把"不知道"读成"一切正常"。
    public func launchdEvidence(for label: String, timeout: TimeInterval = 5) -> StartupServiceEvidence {
        guard !label.trimmingCharacters(in: .whitespaces).isEmpty else { return .unavailable }
        guard SafeProcess.isAvailable(Self.launchctlPath) else { return .unavailable }
        let target = "gui/\(getuid())/\(label)"
        guard let result = SafeProcess.run(Self.launchctlPath, ["print", target], timeout: timeout) else {
            return .unavailable
        }
        if result.timedOut || result.exitCode < 0 { return .unavailable }
        let output = result.output.lowercased()
        if result.exitCode == 0 {
            // 成功且能打印出服务详情 = 它此刻确实被加载着
            return .loaded
        }
        // 非 0：只有"明确说没找到"才算证据齐；其它失败一律无证据
        if output.contains("could not find service") || output.contains("no such service")
            || output.contains("not found") || output.contains("106") {
            return .notLoaded
        }
        return .unavailable
    }

    /// 状态诊断核心逻辑
    public func evaluateStatus(
        path: String,
        filename: String,
        label: String,
        programPath: String?,
        isDisabled: Bool
    ) -> StartupItemStatus {
        if label.hasPrefix("com.apple.") || path.contains("/System/") {
            return .systemProtected
        }

        // 已声明停用的条目：无论程序在不在，先归到"已停用"，
        // 是否真的停了由 `serviceEvidence` 决定（见 isConfirmedDisabled）
        if isDisabled { return .disabled }

        guard let rawProg = programPath, !rawProg.trimmingCharacters(in: .whitespaces).isEmpty else {
            return .missingExecutable
        }

        let resolvedProg = (rawProg as NSString).expandingTildeInPath
        let fm = FileManager.default

        // 如果可执行文件位于 .app 包内
        if resolvedProg.contains(".app/") {
            let parts = resolvedProg.components(separatedBy: ".app/")
            if let appPart = parts.first {
                let appBundlePath = appPart + ".app"
                if !fm.fileExists(atPath: appBundlePath) {
                    return .orphanedApp
                }
            }
        }

        if !fm.fileExists(atPath: resolvedProg) {
            return .missingExecutable
        }

        return .valid
    }

    /// 厂商识别
    public func resolveVendor(label: String, programPath: String?) -> String {
        let text = "\(label) \(programPath ?? "")".lowercased()
        if text.contains("apple") { return "Apple 原生/系统" }
        if text.contains("google") { return "Google" }
        if text.contains("microsoft") { return "Microsoft" }
        if text.contains("docker") { return "Docker" }
        if text.contains("jetbrains") { return "JetBrains" }
        if text.contains("adobe") { return "Adobe" }
        if text.contains("dropbox") { return "Dropbox" }
        if text.contains("homebrew") || text.contains("/opt/homebrew") || text.contains("/usr/local") {
            return "Homebrew / 开源服务"
        }
        if text.contains("macclean") { return "MacClean 调度服务" }
        return "第三方软件"
    }

    // MARK: - 操作控制（安全停用 / 启用）

    /// 启动项定义文件不可解析 / 权限不足时的错误。
    public enum StartupItemError: LocalizedError {
        case sourceMissing(path: String)
        case renameUnverified(oldPath: String, newPath: String)
        case blocked(path: String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .sourceMissing(let path):
                return "定义文件已不存在，未做任何改动：\(path)"
            case .renameUnverified(let oldPath, let newPath):
                return "改名后复核失败（仍留在 \(oldPath)，新位置 \(newPath) 未确认）：未报告为已停用"
            case .blocked(let path, let reason):
                return "已按安全护栏保留 \(path)：\(reason)"
            }
        }
    }

    /// 切换停用/启用状态（通过重命名 `.disabled` 后缀）。
    ///
    /// 两条硬要求：
    /// ① **改名成功要有复核**——新路径存在且旧路径消失才算数，否则抛错而不是返回"已停用"；
    /// ② **返回的 `serviceEvidence` 才是"停没停"**——launchd 会话证据拿不到时，
    ///    条目状态仍是 `.disabled`（文件层声明），但 `isConfirmedDisabled == false`，
    ///    视图据此只能说"需确认"。
    public func toggleDisabled(item: StartupItem) throws -> StartupItem {
        let fm = FileManager.default
        let oldPath = item.path
        let newPath: String

        if item.path.hasSuffix(".disabled") {
            // 启用：移除 .disabled
            newPath = String(item.path.dropLast(".disabled".count))
        } else {
            // 禁用：增加 .disabled
            newPath = item.path + ".disabled"
        }

        guard fm.fileExists(atPath: oldPath) else {
            throw StartupItemError.sourceMissing(path: oldPath)
        }
        try fm.moveItem(atPath: oldPath, toPath: newPath)
        guard fm.fileExists(atPath: newPath), !fm.fileExists(atPath: oldPath) else {
            throw StartupItemError.renameUnverified(oldPath: oldPath, newPath: newPath)
        }

        let nowDisabled = newPath.hasSuffix(".disabled")
        let evidence = launchdEvidence(for: item.label)
        var updated = item
        updated.path = newPath
        updated.isDisabled = nowDisabled
        updated.serviceEvidence = evidence
        updated.note = Self.evidenceNote(isDisabled: nowDisabled, evidence: evidence)
        updated.status = nowDisabled ? .disabled : evaluateStatus(
            path: newPath,
            filename: (newPath as NSString).lastPathComponent,
            label: item.label,
            programPath: item.programPath,
            isDisabled: false
        )
        return updated
    }

    // MARK: - 删除（唯一入口：ResidueDeletionGate）

    /// 待删候选：位置决定治理域，`/Library` 两处会得到 `needsPrivilege`（本工具不提权）。
    static func candidates(_ items: [StartupItem]) -> [ResidueDeletionGate.Candidate] {
        items.map {
            ResidueDeletionGate.Candidate($0.name, path: $0.path, domain: $0.governanceDomain)
        }
    }

    /// 把启动项定义文件移入废纸篓：走统一网关，不再自己 `trashItem`。
    public func moveToTrash(item: StartupItem) throws {
        let outcome = deleteOutcome([item], toTrash: true)
        if let rejection = outcome.rejected.first {
            throw StartupItemError.blocked(path: item.path, reason: rejection.message)
        }
        if outcome.cleanedCount == 0, let failed = outcome.failed.first {
            throw StartupItemError.blocked(path: item.path, reason: failed.message)
        }
    }

    /// 逐项结果（视图用来如实展示"几项被护栏拦下 / 几项无权限"）。
    /// internal：`ResidueDeletionGate.Outcome` 是内部类型，不能出现在 public 签名上。
    @discardableResult
    func deleteOutcome(_ items: [StartupItem], toTrash: Bool = true,
                       journal: ResidueDeletionGate.Journal = .module(categoryName: "启动项残留"))
        -> ResidueDeletionGate.Outcome {
        var byPath: [String: StartupItem] = [:]
        for item in items { byPath[item.path] = item }
        return ResidueDeletionGate.execute(
            Self.candidates(items),
            toTrash: toTrash,
            journal: journal,
            policy: { candidate in
                guard let item = byPath[candidate.path] else { return .notDeletable }
                // ① 系统受保护项（com.apple.* / /System）永不删
                if item.status == .systemProtected { return .systemProtected }
                // ② 定义文件必须是文件本体，不递归删目录
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
                      !isDir.boolValue else { return .notDeletable }
                // ③ 扩展名白名单：只删 launchd 定义
                let ext = (candidate.path as NSString).pathExtension.lowercased()
                guard ext == "plist" || ext == "disabled" else { return .notDeletable }
                return nil
            })
    }

    /// 一键批量安全清理所有幽灵残留项（**只有网关确认删除的**才计数）
    public func cleanAllDangling(items: [StartupItem]) -> (removedCount: Int, freedBytes: Int64) {
        let dangling = items.filter { $0.status.isDangling }
        let outcome = deleteOutcome(dangling, toTrash: true)
        return (outcome.cleanedCount, outcome.freedBytes)
    }
}
