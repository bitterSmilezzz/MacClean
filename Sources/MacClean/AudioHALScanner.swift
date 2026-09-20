import Foundation
import AppKit

// MARK: - 系统音频 HAL 插件与残存驱动排查治理引擎 (v1.70.0)

public final class AudioHALScanner {
    public static let shared = AudioHALScanner()

    private init() {}

    /// Apple 官方核心音频驱动白名单（严禁清理）
    public static let appleOfficialDrivers: Set<String> = [
        "AppleTimeSyncAudioClock.driver",
        "BluetoothAudioPlugIn.driver",
        "AirPodsAudioPlugIn.driver",
        "AppleAVBAudio.driver"
    ]

    /// Apple 官方 Bundle ID 前缀白名单
    public static let appleBundlePrefixes: Set<String> = [
        "com.apple.",
        "apple."
    ]

    /// 获取本地所有已安装应用的 Bundle Identifier 集合
    public static func getInstalledBundleIDs() -> Set<String> {
        var bundleIDs = Set<String>()
        let appDirs = [
            "/Applications",
            "/System/Applications",
            NSString(string: "~/Applications").expandingTildeInPath
        ]

        let fm = FileManager.default
        for appDir in appDirs {
            guard let contents = try? fm.contentsOfDirectory(atPath: appDir) else { continue }
            for item in contents where item.hasSuffix(".app") {
                let fullPath = (appDir as NSString).appendingPathComponent(item)
                if let bundle = Bundle(path: fullPath), let bid = bundle.bundleIdentifier {
                    bundleIDs.insert(bid.lowercased())
                }
            }
        }
        return bundleIDs
    }

    /// 扫描指定目录或系统默认音频驱动目录
    public func scan(
        customHALDirs: [String]? = nil,
        customComponentDirs: [String]? = nil,
        customCacheDirs: [String]? = nil
    ) -> AudioPluginSummary {
        let fm = FileManager.default
        let installedBIDs = Self.getInstalledBundleIDs()

        var items: [AudioPluginItem] = []
        var totalSize: Int64 = 0
        var orphanCount = 0
        var orphanSize: Int64 = 0
        var activeCount = 0

        // 1. 扫描 HAL 驱动目录
        let halDirs: [String] = customHALDirs ?? [
            "/Library/Audio/Plug-Ins/HAL",
            NSString(string: "~/Library/Audio/Plug-Ins/HAL").expandingTildeInPath
        ]

        for halDir in halDirs {
            scanPluginDirectory(
                dirPath: halDir,
                defaultKind: .halDriver,
                installedBIDs: installedBIDs,
                items: &items,
                totalSize: &totalSize,
                orphanCount: &orphanCount,
                orphanSize: &orphanSize,
                activeCount: &activeCount
            )
        }

        // 2. 扫描 AudioUnit 组件目录
        let compDirs: [String] = customComponentDirs ?? [
            "/Library/Audio/Plug-Ins/Components",
            NSString(string: "~/Library/Audio/Plug-Ins/Components").expandingTildeInPath
        ]

        for compDir in compDirs {
            scanPluginDirectory(
                dirPath: compDir,
                defaultKind: .audioUnit,
                installedBIDs: installedBIDs,
                items: &items,
                totalSize: &totalSize,
                orphanCount: &orphanCount,
                orphanSize: &orphanSize,
                activeCount: &activeCount
            )
        }

        // 3. 扫描 CoreAudio 运行缓存
        let cacheDirs: [String] = customCacheDirs ?? [
            NSString(string: "~/Library/Caches/com.apple.audio.coreaudiod").expandingTildeInPath
        ]

        for cDir in cacheDirs {
            guard fm.fileExists(atPath: cDir) else { continue }
            let (cSize, fCount, mtime) = calculateDirectoryMetrics(at: cDir)
            if cSize > 0 {
                orphanCount += 1
                orphanSize += cSize

                let cacheItem = AudioPluginItem(
                    id: cDir,
                    name: "com.apple.audio.coreaudiod (音频服务缓存)",
                    path: cDir,
                    kind: .coreAudioCache,
                    status: .orphanResidue,
                    bundleID: "com.apple.audio.coreaudiod",
                    size: cSize,
                    fileCount: fCount,
                    modificationDate: mtime,
                    isSelected: true
                )
                items.append(cacheItem)
                totalSize += cSize
            }
        }

        // 排序：优先将建议清理的孤儿/损坏项排在前面
        let sorted = items.sorted { a, b in
            if a.status.isOrphanOrCorrupted != b.status.isOrphanOrCorrupted {
                return a.status.isOrphanOrCorrupted
            }
            return a.size > b.size
        }

        return AudioPluginSummary(
            items: sorted,
            totalSize: totalSize,
            orphanCount: orphanCount,
            orphanSize: orphanSize,
            activeCount: activeCount
        )
    }

    private func scanPluginDirectory(
        dirPath: String,
        defaultKind: AudioPluginKind,
        installedBIDs: Set<String>,
        items: inout [AudioPluginItem],
        totalSize: inout Int64,
        orphanCount: inout Int,
        orphanSize: inout Int64,
        activeCount: inout Int
    ) {
        let fm = FileManager.default
        // 安全防线：绝对不扫描系统只读目录
        if dirPath.hasPrefix("/System") { return }

        guard fm.fileExists(atPath: dirPath),
              let contents = try? fm.contentsOfDirectory(atPath: dirPath) else {
            return
        }

        for item in contents {
            guard !item.hasPrefix(".") else { continue }
            let fullPath = (dirPath as NSString).appendingPathComponent(item)

            let (dirSize, fileCount, mtime) = calculateDirectoryMetrics(at: fullPath)
            let (bundleID, kind, status) = Self.evaluateAudioPlugin(
                name: item,
                path: fullPath,
                defaultKind: defaultKind,
                size: dirSize,
                installedBIDs: installedBIDs
            )

            let isOrphan = status.isOrphanOrCorrupted
            if isOrphan {
                orphanCount += 1
                orphanSize += dirSize
            } else if status == .activeInUse || status == .appleOfficial {
                activeCount += 1
            }

            let pluginItem = AudioPluginItem(
                id: fullPath,
                name: item,
                path: fullPath,
                kind: kind,
                status: status,
                bundleID: bundleID,
                size: dirSize,
                fileCount: fileCount,
                modificationDate: mtime,
                isSelected: isOrphan
            )
            items.append(pluginItem)
            totalSize += dirSize
        }
    }

    /// 评估音频插件与驱动的健康状态与宿主归属
    public static func evaluateAudioPlugin(
        name: String,
        path: String,
        defaultKind: AudioPluginKind,
        size: Int64,
        installedBIDs: Set<String>
    ) -> (bundleID: String?, kind: AudioPluginKind, status: AudioPluginStatus) {
        // 1. 系统核心白名单保护
        if path.hasPrefix("/System") || appleOfficialDrivers.contains(name) {
            return (nil, defaultKind, .appleOfficial)
        }

        // 2. 损坏驱动（0 字节或缺少关键文件）
        if size == 0 {
            return (nil, defaultKind, .corrupted)
        }

        // 3. 读取 Contents/Info.plist 提取 Bundle ID
        var bundleID: String? = nil
        let plistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
        if let dict = NSDictionary(contentsOfFile: plistPath) {
            bundleID = dict["CFBundleIdentifier"] as? String
        }

        if let bid = bundleID?.lowercased() {
            // Apple 官方前缀保护
            for prefix in appleBundlePrefixes {
                if bid.hasPrefix(prefix) {
                    return (bundleID, defaultKind, .appleOfficial)
                }
            }

            // 匹配已安装应用
            if installedBIDs.contains(bid) {
                return (bundleID, defaultKind, .activeInUse)
            }

            // 尝试从 Bundle ID 中提取宿主名称前缀比对
            let parts = bid.split(separator: ".")
            if parts.count >= 2 {
                let vendorPrefix = "\(parts[0]).\(parts[1])"
                if installedBIDs.contains(where: { $0.hasPrefix(vendorPrefix) }) {
                    return (bundleID, defaultKind, .activeInUse)
                }
            }
        }

        // 4. 未匹配到宿主的第三方驱动，判定为已卸载应用残留
        return (bundleID, defaultKind, .orphanResidue)
    }

    /// 清理选中的音频孤儿驱动与缓存
    public func clean(
        items: [AudioPluginItem],
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
            if item.status == .appleOfficial || item.status == .activeInUse {
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

    /// 重载 CoreAudio 系统音频服务
    public func restartCoreAudioService() -> (success: Bool, message: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        process.arguments = ["-9", "coreaudiod"]

        do {
            try process.run()
            process.waitUntilExit()
            if process.terminationStatus == 0 {
                return (true, "已成功重启 coreaudiod 服务，音频硬件堆栈已自动重载生效。")
            } else {
                return (false, "重启 coreaudiod 返回码 \(process.terminationStatus)，可能需要管理员权限。可尝试在终端运行: sudo killall coreaudiod")
            }
        } catch {
            return (false, "执行 killall 失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 辅助：递归统计目录指标
    private func calculateDirectoryMetrics(at path: String) -> (size: Int64, fileCount: Int, modificationDate: Date) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return (0, 0, Date.distantPast)
        }

        if !isDir.boolValue {
            let attr = try? fm.attributesOfItem(atPath: path)
            let sz = Int64(attr?[.size] as? UInt64 ?? 0)
            let mtime = attr?[.modificationDate] as? Date ?? Date.distantPast
            return (sz, 1, mtime)
        }

        var totalSize: Int64 = 0
        var fileCount = 0
        var latestMTime = Date.distantPast

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0, latestMTime)
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else {
                continue
            }

            if values.isDirectory == false {
                totalSize += Int64(values.fileSize ?? 0)
                fileCount += 1
            }
            if let mtime = values.contentModificationDate, mtime > latestMTime {
                latestMTime = mtime
            }
        }

        return (totalSize, fileCount, latestMTime)
    }
}
