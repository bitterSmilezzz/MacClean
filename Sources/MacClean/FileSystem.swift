import Foundation
import AppKit

/// 文件系统工具：目录大小、枚举、安全检查
enum FileSystem {

    /// 计算目录/文件大小（递归，跳过符号链接避免循环，遇权限错误跳过不中断）
    static func size(at path: String) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { return 0 }
        if !isDir.boolValue {
            return (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0
        }
        return directorySize(URL(fileURLWithPath: path, isDirectory: true))
    }

    private static func directorySize(_ url: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .totalFileAllocatedSizeKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                              options: [.skipsPackageDescendants],
                                                              errorHandler: { _, _ in true }) else { return 0 }
        var total: Int64 = 0
        var count = 0
        for case let fileURL as URL in enumerator {
            count += 1
            // N10：autoreleasepool 应包住资源读取，而非空调用
            let values = autoreleasepool { () -> URLResourceValues? in
                try? fileURL.resourceValues(forKeys: Set(keys))
            }
            guard let values else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isRegularFile == true {
                total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
            }
            if count > 200_000 { break } // 防御：超大目录只估算前 20 万文件
        }
        return total
    }

    /// 目录下的直接子项（不含 . 开头隐藏项，除非 keepHidden）
    static func children(of path: String, keepHidden: Bool = false) -> [String] {
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return items.filter { keepHidden || !$0.hasPrefix(".") }
            .map { (path as NSString).appendingPathComponent($0) }
    }

    /// 目录下的直接子目录
    static func subdirs(of path: String) -> [String] {
        children(of: path).filter { isDir($0) }
    }

    static func isDir(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return isDir.boolValue
    }

    /// 文件/目录最后修改时间
    static func modificationDate(_ path: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
    }

    /// 文件/目录访问时间
    static func accessDate(_ path: String) -> Date? {
        let url = URL(fileURLWithPath: path)
        return (try? url.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate)
    }

    // MARK: - 使用频率检测（用户诉求：最近使用时间 + 使用频率，判断值不值得删）

    /// 轻量使用检测结果
    struct UsageInfo {
        var lastUsed: Date?      // 最近使用时间（文件 accessDate/mtime 较新者；目录为样本内最新）
        var level: UsageLevel    // 使用频率分级
    }

    /// 检测路径最近使用情况。
    /// - 单文件：取 accessDate 与 mtime 较新者，按距今天数分级。
    /// - 目录：先看目录自身 mtime（快速路径）；较旧时抽样枚举内部文件（限深度 3、样本 2000，
    ///   找到近期修改文件即提前终止），统计最新修改时间与近期文件数来分级。
    /// 性能约束：最坏情况枚举 2000 个文件元数据，远轻于 directorySize 的 20 万上限。
    static func usage(of path: String) -> UsageInfo {
        let now = Date()
        let day: TimeInterval = 86400

        func level(for age: TimeInterval) -> UsageLevel {
            switch age {
            case ..<(7 * day): return .active
            case ..<(30 * day): return .recent
            case ..<(90 * day): return .occasional
            default: return .dormant
            }
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else {
            return UsageInfo(lastUsed: nil, level: .unknown)
        }

        // 单文件：以修改时间为主判据（macOS atime 默认 lazy 更新，不可靠）
        if !isDir.boolValue {
            guard let m = modificationDate(path) else { return UsageInfo(lastUsed: nil, level: .unknown) }
            return UsageInfo(lastUsed: m, level: level(for: now.timeIntervalSince(m)))
        }

        // 目录：快速路径——目录自身 mtime 距今 < 7 天直接判活跃
        if let dm = modificationDate(path), now.timeIntervalSince(dm) < 7 * day {
            return UsageInfo(lastUsed: dm, level: .active)
        }

        // 抽样路径：枚举内部文件（限深度 3、样本 2000）
        let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(
            at: URL(fileURLWithPath: path, isDirectory: true),
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return UsageInfo(lastUsed: nil, level: .unknown) }

        var newest: Date?
        var sampleCount = 0
        var recent7 = 0   // 7 天内修改过的文件数（活跃度信号）
        for case let url as URL in enumerator {
            sampleCount += 1
            if sampleCount > 2000 { break }
            if let values = try? url.resourceValues(forKeys: Set(keys)) {
                if let m = values.contentModificationDate {
                    newest = max(newest ?? m, m)
                    if now.timeIntervalSince(m) < 7 * day { recent7 += 1 }
                }
            }
            if recent7 >= 5 { break }   // 已确认活跃，提前终止
        }
        guard let newest else {
            // 空目录：退化为目录自身 mtime
            if let dm = modificationDate(path) {
                return UsageInfo(lastUsed: dm, level: level(for: now.timeIntervalSince(dm)))
            }
            return UsageInfo(lastUsed: nil, level: .unknown)
        }
        return UsageInfo(lastUsed: newest, level: level(for: now.timeIntervalSince(newest)))
    }

    /// 安全检查：路径是否允许操作（G1/G6）
    static func isSafeToClean(_ path: String) -> Bool {
        let home = NSHomeDirectory()
        let expanded = CleanPaths.expand(path)
        // 绝对禁止删除用户主目录本身
        guard expanded != home, expanded != "/" else { return false }

        // 特殊放行：Homebrew Cellar 具体版本目录（Cellar/<formula>/<version>，至少三层）
        // D12 规则专用——只允许删除某个 formula 的某个具体版本，不允许整 Cellar 或整 formula
        // 先归一化路径（解析 ./ 与 ../ 段），防止 "../.." 穿越绕过护栏
        let normalized = (expanded as NSString).standardizingPath
        for cellar in [CleanPaths.homebrewCellar, CleanPaths.homebrewCellarIntel] {
            let cellarPath = (CleanPaths.expand(cellar) as NSString).standardizingPath
            let prefix = cellarPath + "/"
            guard normalized.hasPrefix(prefix) else { continue }
            let rel = normalized.dropFirst(prefix.count)
            let parts = rel.split(separator: "/")
            // 需要 formula 名 + 版本号（≥2 段，且版本段以数字/v 开头防误删目录）
            if parts.count >= 2, !parts[0].isEmpty, parts[0].first != "." {
                let version = parts[1]
                if version.first?.isNumber == true || version.hasPrefix("v") {
                    return true
                }
            }
            return false
        }

        // 只允许操作主目录内 或 /private/tmp /private/var/tmp
        let allowedRoots = [home, "/private/tmp", "/private/var/tmp"]
        guard allowedRoots.contains(where: { expanded == $0 || expanded.hasPrefix($0 + "/") }) else { return false }
        // 硬排除白名单（G6）
        for ex in CleanPaths.hardExclude {
            let exPath = CleanPaths.expand(ex)
            if expanded == exPath || expanded.hasPrefix(exPath + "/") { return false }
        }
        // 禁止删除关键系统位置
        let never = ["/System", "/Library", "/usr", "/bin", "/sbin", "/etc", "/var/db", "/Volumes"]
        for n in never {
            if expanded.hasPrefix(n + "/") || expanded == n { return false }
        }
        return true
    }
}
