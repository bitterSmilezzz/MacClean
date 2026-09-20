import Foundation

// MARK: - 应用程序多语言本地化资源扫描与瘦身引擎

public enum AppLocalizationScanner {

    /// 扫描指定目录下的应用多语言包
    public static func scan(
        directories: [String] = [
            "/Applications",
            NSString(string: "~/Applications").expandingTildeInPath
        ]
    ) -> [AppLocalizationBundle] {
        let fm = FileManager.default
        var bundles: [AppLocalizationBundle] = []

        for baseDir in directories {
            // 安全防线：绝不扫描系统目录
            if baseDir.hasPrefix("/System") { continue }

            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: baseDir),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else { continue }

            while let fileURL = enumerator.nextObject() as? URL {
                guard fileURL.pathExtension == "app" else { continue }

                // 排除当前运行的 MacClean 自身
                let appName = fileURL.deletingPathExtension().lastPathComponent
                if appName == "MacClean" { continue }

                if let bundle = inspectAppBundle(at: fileURL.path) {
                    // 仅收录包含至少 1 个可清理且总语言包数 >= 2 的应用
                    if bundle.removablePackCount > 0 && bundle.totalPackCount >= 2 {
                        bundles.append(bundle)
                    }
                }
            }
        }

        // 按可释放空间从大到小排序
        return bundles.sorted { $0.totalReclaimablePotential > $1.totalReclaimablePotential }
    }

    /// 检查指定 App 包内部的语言资源
    public static func inspectAppBundle(at appPath: String) -> AppLocalizationBundle? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appPath) else { return nil }

        // 安全检查：严禁触碰 /System
        if appPath.hasPrefix("/System") { return nil }

        // 必须为 .app 目录
        guard appPath.hasSuffix(".app") else { return nil }

        let resourcesPath = (appPath as NSString).appendingPathComponent("Contents/Resources")
        guard fm.fileExists(atPath: resourcesPath) else { return nil }

        // 读取 Info.plist 获取元信息
        let infoPlistPath = (appPath as NSString).appendingPathComponent("Contents/Info.plist")
        var appName = (appPath as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        var bundleID: String? = nil

        if let dict = NSDictionary(contentsOfFile: infoPlistPath) {
            if let displayName = dict["CFBundleDisplayName"] as? String, !displayName.isEmpty {
                appName = displayName
            } else if let name = dict["CFBundleName"] as? String, !name.isEmpty {
                appName = name
            }
            bundleID = dict["CFBundleIdentifier"] as? String
        }

        // 寻找 Resources 目录下的所有 *.lproj 目录
        guard let items = try? fm.contentsOfDirectory(atPath: resourcesPath) else { return nil }
        var packs: [LanguagePackItem] = []

        for item in items where item.hasSuffix(".lproj") {
            let lprojPath = (resourcesPath as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: lprojPath, isDirectory: &isDir), isDir.boolValue else { continue }

            let code = LocalizationHelper.extractLanguageCode(from: item)
            let isProt = LocalizationHelper.isProtected(code: code)
            let displayName = LocalizationHelper.displayName(for: code)
            let packSize = directorySize(at: lprojPath)

            // 构造语言包项：非保护语言默认预选（方便一键瘦身）
            let pack = LanguagePackItem(
                id: lprojPath,
                code: code,
                displayName: displayName,
                path: lprojPath,
                size: packSize,
                isProtected: isProt,
                isSelected: !isProt
            )
            packs.append(pack)
        }

        // 计算 App 总大小（非昂贵模式下可快速评估或按需统计）
        let totalSize = directorySize(at: appPath)

        return AppLocalizationBundle(
            id: appPath,
            appName: appName,
            bundleID: bundleID,
            appPath: appPath,
            appTotalSize: totalSize,
            languagePacks: packs.sorted {
                // 排序：保护语言排前面，其余按占用大小降序
                if $0.isProtected != $1.isProtected {
                    return $0.isProtected && !$1.isProtected
                }
                return $0.size > $1.size
            }
        )
    }

    /// 计算目录大小
    public static func directorySize(at path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey],
            options: [],
            errorHandler: nil
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            if let resourceValues = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]) {
                let size = resourceValues.totalFileAllocatedSize
                    ?? resourceValues.fileAllocatedSize
                    ?? resourceValues.fileSize
                    ?? 0
                total += Int64(size)
            }
        }
        return total
    }

    /// 执行选定语言包的安全清理
    public static func clean(
        bundle: AppLocalizationBundle,
        selectedItemIDs: Set<String>,
        permanently: Bool = false
    ) -> (cleanedCount: Int, cleanedBytes: Int64, errorCount: Int) {
        let fm = FileManager.default
        var cleanedCount = 0
        var cleanedBytes: Int64 = 0
        var errorCount = 0

        // 验证 App 路径安全防线
        if bundle.appPath.hasPrefix("/System") {
            return (0, 0, 1)
        }

        for item in bundle.languagePacks {
            guard selectedItemIDs.contains(item.id) else { continue }

            // 严格安全边界：
            // 1. 保护语言绝不清理
            if item.isProtected || LocalizationHelper.isProtected(code: item.code) {
                continue
            }

            // 2. 路径必须包含在 App 的 Contents/Resources/ 下且必须以 .lproj 结尾
            let expectedPrefix = (bundle.appPath as NSString).appendingPathComponent("Contents/Resources")
            guard item.path.hasPrefix(expectedPrefix) && item.path.hasSuffix(".lproj") else {
                errorCount += 1
                continue
            }

            guard fm.fileExists(atPath: item.path) else { continue }

            do {
                if permanently {
                    try fm.removeItem(atPath: item.path)
                } else {
                    let fileURL = URL(fileURLWithPath: item.path)
                    try fm.trashItem(at: fileURL, resultingItemURL: nil)
                }
                cleanedCount += 1
                cleanedBytes += item.size
            } catch {
                errorCount += 1
            }
        }

        return (cleanedCount, cleanedBytes, errorCount)
    }
}
