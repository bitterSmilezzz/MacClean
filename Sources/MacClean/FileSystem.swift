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
