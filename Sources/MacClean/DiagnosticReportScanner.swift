import Foundation
import AppKit

// MARK: - 系统崩溃与诊断报告智能排查扫描器

public final class DiagnosticReportScanner: ObservableObject {
    public static let shared = DiagnosticReportScanner()

    @Published public var reports: [DiagnosticReportItem] = []
    @Published public var isScanning: Bool = false

    /// 允许清理的诊断报告文件扩展名白名单（防误删非诊断文件）
    public static let allowedExtensions: Set<String> = [
        "ips", "crash", "spin", "hang", "diag", "trace", "synced", "core", "dmp", "beta"
    ]

    /// 允许扫描的诊断日志根目录
    public static var defaultReportDirs: [String] {
        [
            CleanPaths.expand(CleanPaths.diagnosticReports),
            CleanPaths.expand(CleanPaths.diagnosticReportsRetired),
            CleanPaths.expand("~/Library/Application Support/CrashReporter"),
            "/Library/Logs/DiagnosticReports"
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
            let discovered = self.scanDirectories(dirsToScan)
            DispatchQueue.main.async {
                self.reports = discovered
                self.isScanning = false
                completion?(discovered)
            }
        }
    }

    /// 遍历指定目录搜集并深度解析报告
    public func scanDirectories(_ dirs: [String]) -> [DiagnosticReportItem] {
        var results: [DiagnosticReportItem] = []
        var visitedPaths = Set<String>()
        let installedBundles = fetchInstalledAppBundles()

        for dir in dirs {
            let exp = CleanPaths.expand(dir)
            guard FileManager.default.fileExists(atPath: exp) else { continue }

            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: exp, isDirectory: &isDirectory), isDirectory.boolValue else { continue }

            guard let enumerator = FileManager.default.enumerator(atPath: exp) else { continue }

            while let file = enumerator.nextObject() as? String {
                let fullPath = (exp as NSString).appendingPathComponent(file)
                guard !visitedPaths.contains(fullPath) else { continue }

                var isSubDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isSubDir), !isSubDir.boolValue else {
                    continue
                }

                let ext = (fullPath as NSString).pathExtension.lowercased()
                guard Self.allowedExtensions.contains(ext) else { continue }

                visitedPaths.insert(fullPath)

                if let item = parseReportFile(at: fullPath, installedBundles: installedBundles) {
                    results.append(item)
                }
            }
        }

        // 按创建时间倒序排（最新报告排在最前）
        results.sort { $0.creationDate > $1.creationDate }
        return results
    }

    // MARK: - 深度解析单个诊断报告文件

    /// 解析诊断日志文件头并提取核心元数据
    public func parseReportFile(at path: String, installedBundles: Set<String>? = nil) -> DiagnosticReportItem? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
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
        if let handle = FileHandle(forReadingAtPath: path) {
            defer { try? handle.close() }
            let headerData = handle.readData(ofLength: 8192)
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

        // 判定是否为孤儿应用
        let isOrphan = evaluateOrphanStatus(appName: appName, bundleID: bundleID, installedBundles: installedBundles)

        // 默认勾选：孤儿报告 或 >30天陈旧报告
        let isSelected = isOrphan || ageDays > 30

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
            isOrphan: isOrphan,
            isSelected: isSelected
        )
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

    /// 快速缓存系统已安装 App 的 bundle ID
    public func fetchInstalledAppBundles() -> Set<String> {
        var set = Set<String>()
        let appDirs = ["/Applications", "/System/Applications", CleanPaths.expand("~/Applications")]
        for appDir in appDirs {
            guard let contents = try? FileManager.default.contentsOfDirectory(atPath: appDir) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let fullPath = (appDir as NSString).appendingPathComponent(item)
                let plistPath = (fullPath as NSString).appendingPathComponent("Contents/Info.plist")
                if let dict = NSDictionary(contentsOfFile: plistPath),
                   let bid = dict["CFBundleIdentifier"] as? String {
                    set.insert(bid)
                }
            }
        }
        return set
    }

    /// 研判崩溃所属应用是否已被卸载
    public func evaluateOrphanStatus(appName: String, bundleID: String?, installedBundles: Set<String>?) -> Bool {
        // 1. 系统核心组件、守护进程或 Apple 官方服务永不作为孤儿
        if let bid = bundleID {
            if bid.hasPrefix("com.apple.") {
                return false
            }
            if let installed = installedBundles {
                return !installed.contains(bid)
            } else {
                return NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) == nil
            }
        }

        // 2. 无 BundleID 时，检查系统级常见进程名
        let systemProcesses: Set<String> = [
            "kernel", "launchd", "WindowServer", "loginwindow", "Finder", "Dock", "Spotlight", "SystemUIServer"
        ]
        if systemProcesses.contains(appName) {
            return false
        }

        // 3. 检查 /Applications 中是否存在同名应用
        let checkPath1 = "/Applications/\(appName).app"
        let checkPath2 = CleanPaths.expand("~/Applications/\(appName).app")
        if FileManager.default.fileExists(atPath: checkPath1) || FileManager.default.fileExists(atPath: checkPath2) {
            return false
        }

        // 4. 若名称包含 "Tests" 或 "Test" 或 "Runner"，视作开发调试运行产物，不归为常规孤儿应用
        if appName.contains("Test") || appName.contains("Runner") {
            return false
        }

        return true
    }

    // MARK: - 安全清理逻辑

    /// 清理单个报告
    public func cleanReport(_ report: DiagnosticReportItem, permanently: Bool = false) -> (success: Bool, freedBytes: Int64) {
        let path = report.path
        let ext = (path as NSString).pathExtension.lowercased()

        // 安全防线 1：后缀白名单
        guard Self.allowedExtensions.contains(ext) else {
            return (false, 0)
        }

        // 安全防线 2：必须位于诊断目录内
        let normalized = FileSystem.normalizePath(path)
        let allowedRootPrefixes = [
            FileSystem.normalizePath(CleanPaths.expand(CleanPaths.diagnosticReports)),
            FileSystem.normalizePath(CleanPaths.expand(CleanPaths.diagnosticReportsRetired)),
            FileSystem.normalizePath(CleanPaths.expand("~/Library/Application Support/CrashReporter")),
            "/Library/Logs/DiagnosticReports",
            "/tmp",
            "/private/tmp"
        ]
        guard allowedRootPrefixes.contains(where: { normalized.hasPrefix($0) }) else {
            return (false, 0)
        }

        // 安全防线 3：通用底层安全护栏
        guard FileSystem.isSafeToClean(path) else {
            return (false, 0)
        }

        let size = FileSystem.size(at: path)
        var ok = false

        if permanently {
            do {
                try FileManager.default.removeItem(atPath: path)
                ok = true
            } catch {
                ok = false
            }
        } else {
            do {
                try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                ok = true
            } catch {
                ok = false
            }
        }

        if ok {
            DispatchQueue.main.async {
                self.reports.removeAll(where: { $0.id == report.id })
            }
            return (true, size)
        }
        return (false, 0)
    }

    /// 批量清理报告
    public func cleanReports(_ reportsToClean: [DiagnosticReportItem], permanently: Bool = false) -> (successCount: Int, freedBytes: Int64) {
        var successCount = 0
        var totalFreed: Int64 = 0

        for r in reportsToClean {
            let res = cleanReport(r, permanently: permanently)
            if res.success {
                successCount += 1
                totalFreed += res.freedBytes
            }
        }

        return (successCount, totalFreed)
    }
}
