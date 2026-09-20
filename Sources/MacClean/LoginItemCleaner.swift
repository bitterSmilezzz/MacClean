import Foundation

// MARK: - 已卸载应用登录项与自启残存清理引擎 (v1.67.0)

public final class LoginItemCleaner {
    public static let shared = LoginItemCleaner()

    private init() {}

    /// Apple 官方系统服务前缀白名单（严禁清理）
    private static let systemProtectedPrefixes = [
        "com.apple.",
        "/System/Library",
        "/usr/libexec"
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
        var totalSize: Int64 = 0

        for candidate in candidateFolders {
            let dirPath = candidate.dir

            // 安全防线：绝对不扫描系统关键只读目录
            if dirPath.hasPrefix("/System") {
                continue
            }

            guard fm.fileExists(atPath: dirPath) else { continue }
            guard let fileNames = try? fm.contentsOfDirectory(atPath: dirPath) else { continue }

            for fileName in fileNames where fileName.hasSuffix(".plist") {
                let filePath = (dirPath as NSString).appendingPathComponent(fileName)
                let name = (fileName as NSString).deletingPathExtension

                guard let attrs = try? fm.attributesOfItem(atPath: filePath) else { continue }
                let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0

                let (targetPath, isOrphan) = Self.inspectPlist(at: filePath, name: name)

                // 仅统计存在问题的死链项，或者全量展示
                let issue: LoginItemIssue = isOrphan ? .executableMissing : .validActive
                if isOrphan {
                    orphanCount += 1
                }

                let entry = LoginItemEntry(
                    id: filePath,
                    name: name,
                    path: filePath,
                    targetPath: targetPath,
                    kind: candidate.kind,
                    issue: issue,
                    size: size,
                    isSelected: isOrphan
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
            totalSize: totalSize
        )
    }

    /// 检查指定 plist 文件对应的目标可执行程序是否存在
    public static func inspectPlist(at path: String, name: String) -> (targetPath: String?, isOrphan: Bool) {
        let fm = FileManager.default

        // Apple 官方服务白名单保护
        if systemProtectedPrefixes.contains(where: { name.hasPrefix($0) }) {
            return (nil, false)
        }

        guard let dict = NSDictionary(contentsOfFile: path) else {
            return (nil, false)
        }

        var targetExecutable: String? = nil

        if let program = dict["Program"] as? String, !program.isEmpty {
            targetExecutable = program
        } else if let args = dict["ProgramArguments"] as? [String], let first = args.first, !first.isEmpty {
            targetExecutable = first
        }

        guard let executable = targetExecutable else {
            return (nil, false)
        }

        // 如果可执行文件不存在，判定为孤儿死链
        let exists = fm.fileExists(atPath: executable)
        return (executable, !exists)
    }

    /// 清理选中的死链登录项与后台守护
    public func clean(
        items: [LoginItemEntry],
        toTrash: Bool = true
    ) -> (cleanedCount: Int, freedBytes: Int64, errorCount: Int) {
        let fm = FileManager.default
        var cleanedCount = 0
        var freedBytes: Int64 = 0
        var errorCount = 0

        for item in items {
            let path = item.path

            // 安全防线 1：系统核心目录拦截
            if path.hasPrefix("/System") {
                errorCount += 1
                continue
            }

            // 安全防线 2：Apple 官方白名单拦截
            if Self.systemProtectedPrefixes.contains(where: { item.name.hasPrefix($0) }) {
                errorCount += 1
                continue
            }

            guard fm.fileExists(atPath: path) else { continue }

            // 尝试卸载当前守护
            Self.unloadService(at: path)

            do {
                if toTrash {
                    try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
                } else {
                    try fm.removeItem(atPath: path)
                }
                cleanedCount += 1
                freedBytes += item.size
            } catch {
                errorCount += 1
            }
        }

        return (cleanedCount, freedBytes, errorCount)
    }

    /// 尝试调用 launchctl 卸载服务
    private static func unloadService(at path: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["unload", "-w", path]
        try? p.run()
        p.waitUntilExit()
    }
}
