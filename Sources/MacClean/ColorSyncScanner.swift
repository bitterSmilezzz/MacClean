import Foundation
import AppKit

// MARK: - 系统多显示器色彩描述与 ICC Profile 残存治理引擎 (v1.68.0)

public final class ColorSyncScanner {
    public static let shared = ColorSyncScanner()

    private init() {}

    /// Apple 官方核心色彩描述文件白名单（严禁清理）
    public static let systemProtectedProfiles = [
        "sRGB Profile.icc",
        "Display P3.icc",
        "Generic RGB Profile.icc",
        "Generic Gray Profile.icc",
        "Generic CMYK Profile.icc",
        "AdobeRGB1998.icc",
        "Apple RGB.icc",
        "Color LCD.icc"
    ]

    /// 获取当前所有活动连接屏幕的名称与特征关键字
    public static func getActiveScreenKeywords() -> Set<String> {
        var keywords = Set<String>()
        keywords.insert("color lcd")
        keywords.insert("built-in")
        keywords.insert("retina")

        for screen in NSScreen.screens {
            let name = screen.localizedName.lowercased()
            keywords.insert(name)
            // 提取词组片段
            let parts = name.split(separator: " ")
            for p in parts where p.count > 2 {
                keywords.insert(String(p))
            }
        }
        return keywords
    }

    /// 扫描指定的或系统的 ColorSync 配置文件目录
    public func scan(customDirectories: [String]? = nil) -> ColorSyncSummary {
        let fm = FileManager.default
        let activeKeywords = Self.getActiveScreenKeywords()

        let searchDirs: [String]
        if let custom = customDirectories {
            searchDirs = custom
        } else {
            let userProfiles = NSString(string: "~/Library/ColorSync/Profiles").expandingTildeInPath
            let globalProfiles = "/Library/ColorSync/Profiles"
            let colorSyncCache = NSString(string: "~/Library/Caches/com.apple.ColorSync").expandingTildeInPath
            searchDirs = [userProfiles, globalProfiles, colorSyncCache]
        }

        var items: [ICCProfileItem] = []
        var totalSize: Int64 = 0
        var orphanCount = 0
        var orphanSize: Int64 = 0
        var activeCount = 0

        for dirPath in searchDirs {
            // 安全防线：绝对不扫描系统只读目录
            if dirPath.hasPrefix("/System") {
                continue
            }

            guard fm.fileExists(atPath: dirPath) else { continue }
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: dirPath),
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let path = fileURL.path
                let fileName = fileURL.lastPathComponent
                let ext = fileURL.pathExtension.lowercased()

                guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]),
                      values.isDirectory == false else {
                    continue
                }

                // 仅扫描 .icc, .icm, 或 ColorSync 缓存文件
                let isProfile = ext == "icc" || ext == "icm"
                let isCache = path.contains("com.apple.ColorSync")
                guard isProfile || isCache else { continue }

                let size = Int64(values.fileSize ?? 0)
                let mtime = values.contentModificationDate ?? Date.distantPast

                let (kind, status) = Self.evaluateProfile(
                    fileName: fileName,
                    path: path,
                    size: size,
                    activeKeywords: activeKeywords
                )

                let isOrphan = status.isOrphanOrCorrupted
                if isOrphan {
                    orphanCount += 1
                    orphanSize += size
                } else if status == .activeConnected {
                    activeCount += 1
                }

                let item = ICCProfileItem(
                    id: path,
                    name: fileName,
                    path: path,
                    kind: kind,
                    status: status,
                    size: size,
                    modificationDate: mtime,
                    isSelected: isOrphan
                )

                items.append(item)
                totalSize += size
            }
        }

        // 优先将建议清理的孤儿/损坏项排在最前
        let sorted = items.sorted { a, b in
            if a.status.isOrphanOrCorrupted != b.status.isOrphanOrCorrupted {
                return a.status.isOrphanOrCorrupted
            }
            return a.size > b.size
        }

        return ColorSyncSummary(
            items: sorted,
            totalSize: totalSize,
            orphanCount: orphanCount,
            orphanSize: orphanSize,
            activeCount: activeCount
        )
    }

    /// 研判单个配置文件的类型与状态
    public static func evaluateProfile(
        fileName: String,
        path: String,
        size: Int64,
        activeKeywords: Set<String>
    ) -> (kind: ICCProfileKind, status: ICCProfileStatus) {
        // 1. 系统核心白名单保护
        if path.hasPrefix("/System") || systemProtectedProfiles.contains(fileName) {
            return (.displayProfile, .systemProtected)
        }

        // 2. 损坏文件（0 字节）
        if size == 0 {
            return (.displayProfile, .corrupted)
        }

        // 3. 缓存文件
        if path.contains("com.apple.ColorSync") {
            return (.colorSyncCache, .disconnectedOrphan)
        }

        // 4. 显示器配置文件研判
        let lowerName = fileName.lowercased()
        let isDisplayProfile = lowerName.contains("display") ||
            lowerName.contains("monitor") ||
            lowerName.contains("lcd") ||
            lowerName.contains("dell") ||
            lowerName.contains("lg") ||
            lowerName.contains("samsung") ||
            path.contains("/Displays/")

        if isDisplayProfile {
            // 检查是否与当前活动连接屏幕匹配
            let isConnected = activeKeywords.contains(where: { lowerName.contains($0) })
            if isConnected {
                return (.displayProfile, .activeConnected)
            } else {
                return (.displayProfile, .disconnectedOrphan)
            }
        }

        // 5. 打印机配置
        if lowerName.contains("print") || lowerName.contains("epson") || lowerName.contains("canon") || lowerName.contains("hp") {
            return (.printerProfile, .disconnectedOrphan)
        }

        // 6. 其他用户自定义校准配置
        return (.customProfile, .disconnectedOrphan)
    }

    /// 清理选中的 ICC 配置文件与缓存
    public func clean(
        items: [ICCProfileItem],
        toTrash: Bool = true
    ) -> (cleanedCount: Int, freedBytes: Int64, errorCount: Int) {
        let fm = FileManager.default
        var cleanedCount = 0
        var freedBytes: Int64 = 0
        var errorCount = 0

        for item in items {
            let path = item.path

            // 安全防线 1：系统目录拦截
            if path.hasPrefix("/System") {
                errorCount += 1
                continue
            }

            // 安全防线 2：受保护状态拦截
            if item.status == .systemProtected || item.status == .activeConnected {
                errorCount += 1
                continue
            }

            guard fm.fileExists(atPath: path) else { continue }

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
}
