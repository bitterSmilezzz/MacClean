import Foundation
import AppKit

// MARK: - 系统崩溃与诊断报告智能排查扫描器 (v1.58.0 / v1.74.0 安全加固)
//
// 真机实测：`/Library/Logs/DiagnosticReports` 权限是 `drwxrwx--- root:_analyticsusers`，
// 普通用户进程**根本读不到**。而原实现清一色 `guard let enumerator = ... else { continue }`，
// 于是"读不到"和"这里真的没有报告"在结果上完全一样 —— 都是 0 项，
// 卡片把那 0 项渲染成"暂无匹配的崩溃或诊断日志残留"（一个绿色对勾）。
// 用户看到的结论正好是他最需要知道的那部分被隐藏了。
//
// 现在：
// ① 每个根目录先用 `FileSystem.isPermissionDenied` 区分"读不到"与"真的空"，
//    读不到就产出一条 `GovernanceEvidenceIssue`，结论降级为"本次结果不完整"；
// ② 全局报告目录的删除走 `.diagnosticReportsGlobal` 治理域 —— 会得到 `needsPrivilege`，
//    UI 如实说明"该位置由 root 管理，本工具不提权，仅提供定位与建议"；
//    用户域 `~/Library/Logs/DiagnosticReports` 走主目录护栏 + 网关；
// ③ 已安装 bundle id 集合不再自建（原来 3 个 `try?` + `continue` 会得到"看起来合法的空集合"，
//    把所有崩溃都判成"宿主已卸载"），改用 `AppInventory.current()`；
//    清单不完整时一律降级为"需确认"，既不默选也不断言孤儿。

public final class DiagnosticReportScanner: ObservableObject {
    public static let shared = DiagnosticReportScanner()

    @Published public var reports: [DiagnosticReportItem] = []
    @Published public var isScanning: Bool = false
    /// 本轮扫描读不到/判不准的证据源。**非空即结论不完整**，卡片不得渲染成"没有异常报告"。
    @Published public var issues: [GovernanceEvidenceIssue] = []
    /// 最近一次批量清理被护栏拦下的原因（卡片如实展示，而不是笼统一句"清理失败"）
    /// internal：`ResidueDeletionGate.Rejection` 是内部类型，不能挂 public 属性
    @Published var lastRejections: [ResidueDeletionGate.Rejection] = []

    /// 本轮结论是否完整可信
    public var isResultComplete: Bool { issues.isEmpty }

    /// 用户可见的不完整提示；完整时为 nil
    public var incompletenessBanner: String? {
        issues.isEmpty ? nil : GovernanceEvidenceIssue.incompleteBanner(issues)
    }

    /// 允许清理的诊断报告文件扩展名白名单（防误删非诊断文件）
    public static let allowedExtensions: Set<String> = [
        "ips", "crash", "spin", "hang", "diag", "trace", "synced", "core", "dmp", "beta"
    ]

    /// 全局（root 管理）报告目录：只授权定位与建议
    public static let globalReportsDir = "/Library/Logs/DiagnosticReports"

    /// 允许扫描的诊断日志根目录
    public static var defaultReportDirs: [String] {
        [
            CleanPaths.expand(CleanPaths.diagnosticReports),
            CleanPaths.expand(CleanPaths.diagnosticReportsRetired),
            CleanPaths.expand("~/Library/Application Support/CrashReporter"),
            Self.globalReportsDir
        ]
    }

    private let scanQueue = DispatchQueue(label: "com.macclean.diagnosticreport.scanner", qos: .userInitiated)

    public init() {}

    // MARK: - 主扫描入口

    /// 异步扫描系统与用户目录下的所有崩溃报告与核心转储
    public func scan(customDirs: [String]? = nil, completion: (([DiagnosticReportItem]) -> Void)? = nil) {
        isScanning = true
        let dirsToScan = customDirs ?? Self.defaultReportDirs

        scanQueue.async {
            let found = self.scanReport(dirs: dirsToScan)
            DispatchQueue.main.async {
                self.reports = found.items
                self.issues = found.issues
                self.isScanning = false
                completion?(found.items)
            }
        }
    }

    /// 遍历指定目录搜集并深度解析报告，同时把"哪个根没读到"交出来。
    func scanReport(dirs: [String], inventory: AppInventory.Snapshot? = nil)
        -> (items: [DiagnosticReportItem], issues: [GovernanceEvidenceIssue]) {
        let fm = FileManager.default
        var results: [DiagnosticReportItem] = []
        var issues: [GovernanceEvidenceIssue] = []
        var visitedPaths = Set<String>()
        let snapshot = inventory ?? AppInventory.current()

        for dir in dirs {
            let exp = CleanPaths.expand(dir)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: exp, isDirectory: &isDirectory) else {
                continue   // 根不存在：这台机器确实没有这个目录，不算读失败
            }
            guard isDirectory.boolValue else { continue }

            // 「读不到」≠「没有异常报告」：全局目录在真机上就是 root:_analyticsusers
            if FileSystem.isPermissionDenied(exp) {
                issues.append(GovernanceEvidenceIssue(
                    kind: .permissionDenied, subject: exp,
                    message: "权限不足，当前用户读不到该诊断目录（可能需要管理员或完全磁盘访问权限）：\(exp)"))
                continue
            }
            guard let enumerator = fm.enumerator(atPath: exp) else {
                issues.append(GovernanceEvidenceIssue(
                    kind: .unreadable, subject: exp, message: "无法枚举诊断目录：\(exp)"))
                continue
            }

            var rootFailed = false
            while let file = enumerator.nextObject() as? String {
                let fullPath = (exp as NSString).appendingPathComponent(file)
                guard !visitedPaths.contains(fullPath) else { continue }

                var isSubDir: ObjCBool = false
                guard fm.fileExists(atPath: fullPath, isDirectory: &isSubDir), !isSubDir.boolValue else {
                    continue
                }

                let ext = (fullPath as NSString).pathExtension.lowercased()
                guard Self.allowedExtensions.contains(ext) else { continue }

                visitedPaths.insert(fullPath)

                if let item = parseReport(at: fullPath, inventory: snapshot) {
                    results.append(item)
                } else {
                    rootFailed = true
                }
            }
            if rootFailed {
                issues.append(GovernanceEvidenceIssue(
                    kind: .unreadable, subject: exp,
                    message: "目录内部分报告读不到内容，元数据判定不完整：\(exp)"))
            }
        }

        // 按创建时间倒序排（最新报告排在最前）
        results.sort { $0.creationDate > $1.creationDate }
        return (results, issues)
    }

    // MARK: - 深度解析单个诊断报告文件

    /// 解析诊断日志文件头并提取核心元数据
    public func parseReportFile(at path: String, installedBundles: Set<String>? = nil) -> DiagnosticReportItem? {
        if let installed = installedBundles {
            return parseReport(at: path, inventory: Self.snapshot(from: installed))
        }
        return parseReport(at: path, inventory: AppInventory.current())
    }

    /// 把一个纯 bundle id 集合包成"完整可信"的清单（兼容显式传集合的旧调用方）。
    static func snapshot(from bundleIDs: Set<String>) -> AppInventory.Snapshot {
        let prefixes = Set(bundleIDs.compactMap { bid -> String? in
            let parts = bid.lowercased().split(separator: ".")
            return parts.count >= 2 ? "\(parts[0]).\(parts[1])" : nil
        })
        return AppInventory.Snapshot(bundleIDs: Set(bundleIDs.map { $0.lowercased() }),
                                     bundlePrefixes: prefixes, normalizedNames: [],
                                     executableNames: [], runningBundleIDs: [], appPaths: [],
                                     unreadableRoots: [])
    }

    /// 内部解析：判定依据全部来自注入过的清单，读不到即降级为"需确认"。
    func parseReport(at path: String, inventory: AppInventory.Snapshot) -> DiagnosticReportItem? {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let creationDate = (attrs[.creationDate] as? Date) ?? (attrs[.modificationDate] as? Date) ?? Date()
        let ageDays = max(0, Int(Date().timeIntervalSince(creationDate) / 86400))

        let fileName = (path as NSString).lastPathComponent
        let ext = (path as NSString).pathExtension.lowercased()

        var appName = deriveAppNameFromFileName(fileName)
        var bundleID: String? = nil
        var kind: DiagnosticReportKind = .crash
        var exceptionSummary: String? = nil

        // 根据后缀初步定型
        if ext == "spin" || ext == "hang" || fileName.contains(".spin") || fileName.contains(".hang") {
            kind = .spinHang
        } else if ext == "core" || ext == "dmp" || fileName.hasPrefix("core.") {
            kind = .coreDump
        } else if ext == "diag" || ext == "trace" || ext == "synced" {
            kind = .diagnostics
        }

        // 读取文件前 8KB 文本解析内部元数据
        // 读不到内容 ≠ 没有归属信息：下面据此降级为"需确认"
        var headerReadable = false
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            let headerData = handle.readData(ofLength: 8192)
            headerReadable = !headerData.isEmpty
            if let headerText = String(data: headerData, encoding: .utf8) ?? String(data: headerData, encoding: .ascii) {
                parseHeaderMetadata(
                    headerText: headerText,
                    ext: ext,
                    appName: &appName,
                    bundleID: &bundleID,
                    kind: &kind,
                    exceptionSummary: &exceptionSummary
                )
            }
        }

        let judgement = evaluateOrphan(appName: appName, bundleID: bundleID, inventory: inventory)
        // 报告头读不到、又拿不到 bundle id：归属完全无从判断
        let needsConfirmation = judgement.needsConfirmation
            || (!headerReadable && bundleID == nil && !judgement.isOrphan)
        let isGlobal = Self.isGlobalScopePath(path)

        // 默认勾选：只勾**确证**的孤儿或确证陈旧的非全局报告。
        // 需确认项与 root 管理项一律不默选（前者证据不足，后者本工具删不掉）。
        let isSelected = !needsConfirmation && !isGlobal
            && (judgement.isOrphan || ageDays > 30)

        return DiagnosticReportItem(
            id: path,
            fileName: fileName,
            path: path,
            size: size,
            creationDate: creationDate,
            ageDays: ageDays,
            appName: appName,
            bundleID: bundleID,
            kind: kind,
            exceptionSummary: exceptionSummary,
            isOrphan: judgement.isOrphan,
            isSelected: isSelected,
            needsConfirmation: needsConfirmation,
            isGlobalScope: isGlobal,
            note: needsConfirmation
                ? "已安装应用清单或报告内容读不到，无法判断宿主是否已卸载：请人工确认后再删。"
                : (isGlobal ? "该目录由 root 管理（root:_analyticsusers），MacClean 不提权，仅定位与建议。" : nil)
        )
    }

    /// 是否属于 root 管理的全局报告位置
    static func isGlobalScopePath(_ path: String) -> Bool {
        let real = FileSystem.normalizePath(FileSystem.realPath(path))
        let root = FileSystem.normalizePath(FileSystem.realPath(globalReportsDir))
        return real == root || real.hasPrefix(root + "/")
    }

    // MARK: - 元数据提取细节

    /// 解析文件头文本提取 AppName, BundleID, Kind 与异常原因
    public func parseHeaderMetadata(headerText: String,
                                    ext: String,
                                    appName: inout String,
                                    bundleID: inout String?,
                                    kind: inout DiagnosticReportKind,
                                    exceptionSummary: inout String?) {
        let lines = headerText.components(separatedBy: .newlines)

        // 1. 尝试按现代 macOS IPS JSON 首行解析
        if let firstLine = lines.first, firstLine.hasPrefix("{") {
            if let data = firstLine.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let name = json["app_name"] as? String, !name.isEmpty {
                    appName = name
                } else if let proc = json["name"] as? String, !proc.isEmpty {
                    appName = proc
                }

                if let bugType = json["bug_type"] as? String {
                    // 309: Crash, 301/313: Hang/Spin, 288: Microstackshots
                    if bugType == "301" || bugType == "313" {
                        kind = .spinHang
                    } else if bugType == "309" {
                        kind = .crash
                    }
                }
            }
        }

        // 2. 逐行匹配典型崩溃与诊断字段
        for line in lines.prefix(80) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // IPS JSON 内部结构识别
            if trimmed.contains("\"procName\" :") {
                let parts = trimmed.components(separatedBy: ":")
                if parts.count >= 2 {
                    let cleaned = parts[1].replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: ",", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if !cleaned.isEmpty { appName = cleaned }
                }
            }
            if trimmed.contains("\"coalitionName\" :") {
                let parts = trimmed.components(separatedBy: ":")
                if parts.count >= 2 {
                    let cleaned = parts[1].replacingOccurrences(of: "\"", with: "")
                        .replacingOccurrences(of: ",", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    if cleaned.contains(".") { bundleID = cleaned }
                }
            }
            if trimmed.contains("\"type\" : \"EXC_") || trimmed.contains("\"type\":\"EXC_") {
                let regex = try? NSRegularExpression(pattern: "\"type\"\\s*:\\s*\"([^\"]+)\"")
                if let match = regex?.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
                   let range = Range(match.range(at: 1), in: trimmed) {
                    exceptionSummary = String(trimmed[range])
                }
            }

            // 经典 .crash 格式解析
            if trimmed.hasPrefix("Process:") {
                let parts = trimmed.components(separatedBy: ":")
                if parts.count >= 2 {
                    let procPart = parts[1].components(separatedBy: "[").first ?? parts[1]
                    let cleaned = procPart.trimmingCharacters(in: .whitespaces)
                    if !cleaned.isEmpty { appName = cleaned }
                }
            } else if trimmed.hasPrefix("Identifier:") {
                let parts = trimmed.components(separatedBy: ":")
                if parts.count >= 2 {
                    let cleaned = parts[1].trimmingCharacters(in: .whitespaces)
                    if !cleaned.isEmpty { bundleID = cleaned }
                }
            } else if trimmed.hasPrefix("Exception Type:") {
                let parts = trimmed.components(separatedBy: ":")
                if parts.count >= 2 {
                    exceptionSummary = parts[1].trimmingCharacters(in: .whitespaces)
                }
            } else if trimmed.hasPrefix("Termination Reason:") {
                let parts = trimmed.components(separatedBy: ":")
                if parts.count >= 2 && exceptionSummary == nil {
                    exceptionSummary = parts[1].trimmingCharacters(in: .whitespaces)
                }
            }
        }
    }

    /// 从文件名中推断进程名或应用名（例如 "Xcode_2026-03-01-120000.ips" -> "Xcode"）
    public func deriveAppNameFromFileName(_ fileName: String) -> String {
        let base = (fileName as NSString).deletingPathExtension
        if let idx = base.range(of: "_20")?.lowerBound {
            return String(base[..<idx])
        }
        if let idx = base.range(of: "-20")?.lowerBound {
            return String(base[..<idx])
        }
        if let first = base.components(separatedBy: "_").first, !first.isEmpty {
            return first
        }
        if let first = base.components(separatedBy: "-").first, !first.isEmpty {
            return first
        }
        return base
    }

    // MARK: - 孤儿应用研判

    /// Apple 官方组件前缀：永不作为孤儿
    static let appleBundlePrefixes = ["com.apple.", "apple.", "system."]

    /// 常见系统进程名（无 bundle id 时的兜底保护）
    static let systemProcessNames: Set<String> = [
        "kernel", "launchd", "WindowServer", "loginwindow", "Finder", "Dock",
        "Spotlight", "SystemUIServer", "kernel_task",
    ]

    /// 研判崩溃所属应用是否已被卸载，**并区分"确证孤儿"与"证据不足"**。
    func evaluateOrphan(appName: String, bundleID: String?, inventory: AppInventory.Snapshot)
        -> (isOrphan: Bool, needsConfirmation: Bool) {
        if let bid = bundleID {
            let lower = bid.lowercased()
            if Self.appleBundlePrefixes.contains(where: { lower.hasPrefix($0) }) { return (false, false) }
            if inventory.contains(bundleID: lower) { return (false, false) }
            // 清单不可信时，"不在清单里"推不出"宿主已卸载"
            guard inventory.isComplete else { return (false, true) }
            return (true, false)
        }

        // 无 BundleID：先看系统进程兜底名单，再看已安装应用名
        if Self.systemProcessNames.contains(appName) { return (false, false) }
        if inventory.matchesInstalledName(appName) { return (false, false) }
        // 开发/测试跑出来的产物不归为常规孤儿应用
        if appName.contains("Test") || appName.contains("Runner") { return (false, false) }
        guard inventory.isComplete else { return (false, true) }
        return (true, false)
    }

    /// 研判崩溃所属应用是否已被卸载（兼容旧调用方：只回答是/否）。
    public func evaluateOrphanStatus(appName: String, bundleID: String?,
                                     installedBundles: Set<String>?) -> Bool {
        let inventory: AppInventory.Snapshot = installedBundles.map(Self.snapshot(from:))
            ?? AppInventory.current()
        return evaluateOrphan(appName: appName, bundleID: bundleID, inventory: inventory).isOrphan
    }

    // MARK: - 安全清理逻辑

    /// 授权范围内的诊断报告根（越界一律拒）
    static var allowedRootPrefixes: [String] {
        [
            FileSystem.normalizePath(CleanPaths.expand(CleanPaths.diagnosticReports)),
            FileSystem.normalizePath(CleanPaths.expand(CleanPaths.diagnosticReportsRetired)),
            FileSystem.normalizePath(CleanPaths.expand("~/Library/Application Support/CrashReporter")),
            FileSystem.normalizePath(Self.globalReportsDir),
            "/tmp", "/private/tmp",
        ]
    }

    static func candidates(_ items: [DiagnosticReportItem]) -> [ResidueDeletionGate.Candidate] {
        items.map {
            ResidueDeletionGate.Candidate($0.fileName, path: $0.path, domain: $0.governanceDomain)
        }
    }

    /// 真正的删除入口：唯一护栏是 `ResidueDeletionGate`
    /// （软链防跳板 + G8 + G6 + 用户白名单 + 治理域/主目录护栏 + 真实 unlink 权限
    ///  + 删除前实测体积 + 废纸篓撤销快照 + 历史记录）。
    @discardableResult
    func cleanOutcome(_ items: [DiagnosticReportItem], permanently: Bool = false,
                      journal: ResidueDeletionGate.Journal = .module(categoryName: "诊断报告"))
        -> ResidueDeletionGate.Outcome {
        var byPath: [String: DiagnosticReportItem] = [:]
        for item in items { byPath[item.path] = item }

        let roots = Self.allowedRootPrefixes
        let outcome = ResidueDeletionGate.execute(
            Self.candidates(items),
            toTrash: !permanently,
            journal: journal,
            policy: { candidate in
                guard let item = byPath[candidate.path] else {
                    return .make(candidate, reason: .notDeletable, message: "该路径不在本轮选定清单里，未删除")
                }
                // ① 后缀白名单：非诊断产物（.swift/.png…）永不在此删除
                let ext = (candidate.path as NSString).pathExtension.lowercased()
                guard Self.allowedExtensions.contains(ext) else {
                    return .make(candidate, reason: .notDeletable,
                                 message: ".\(ext) 不是诊断报告产物，本模块不清理")
                }
                // ② 必须是文件：本模块不递归删目录
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
                      !isDir.boolValue else {
                    return .make(candidate, reason: .notDeletable,
                                 message: "不是报告文件本体（目录不递归删），未删除")
                }
                // ③ 必须落在授权的诊断根内（软链逃逸也在这里被解析后再判）
                let real = FileSystem.normalizePath(FileSystem.realPath(candidate.path))
                guard roots.contains(where: { real == $0 || real.hasPrefix($0 + "/") }) else {
                    return .make(candidate, reason: .outsideDomain,
                                 message: "解析后的真实位置 \(real) 不在已登记的诊断报告根内，未删除")
                }
                // ④ 证据不足（清单不完整 / 报告头读不到）→ 不删，交人工确认
                if item.needsConfirmation {
                    return .make(candidate, reason: .blockedByBaseGate,
                                 message: "证据不足（\(item.note ?? "无法确认宿主")），需你手动确认后再处理")
                }
                return nil
            })

        lastRejections = outcome.rejected
        if outcome.cleanedCount > 0 {
            let cleaned = Set(outcome.cleanedPaths)
            DispatchQueue.main.async {
                self.reports.removeAll { cleaned.contains($0.path) || cleaned.contains($0.id) }
            }
        }
        return outcome
    }

    /// 清理单个报告
    public func cleanReport(_ report: DiagnosticReportItem, permanently: Bool = false)
        -> (success: Bool, freedBytes: Int64) {
        let outcome = cleanOutcome([report], permanently: permanently)
        return (outcome.cleanedCount > 0, outcome.freedBytes)
    }

    /// 批量清理报告
    public func cleanReports(_ reportsToClean: [DiagnosticReportItem], permanently: Bool = false)
        -> (successCount: Int, freedBytes: Int64) {
        let outcome = cleanOutcome(reportsToClean, permanently: permanently)
        return (outcome.cleanedCount, outcome.freedBytes)
    }

    /// 一句如实的批量结论（含被拦原因），卡片直接展示。
    func cleanSummary(_ reportsToClean: [DiagnosticReportItem], permanently: Bool = false)
        -> ResidueDeletionGate.Outcome {
        cleanOutcome(reportsToClean, permanently: permanently)
    }
}
