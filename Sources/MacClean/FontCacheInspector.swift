import Foundation
import CoreText

// MARK: - 字体缓存与孤儿系统字体残存治理引擎 (v1.61.0)

public final class FontCacheInspector {
    public static let shared = FontCacheInspector()

    private init() {}

    /// 执行全景扫描：用户字体排查 + 字体缓存审计
    public func scan() -> FontInspectionReport {
        let fonts = scanUserFonts()
        let caches = scanFontCaches()

        let totalFontSize = fonts.reduce(0) { $0 + $1.size }
        let totalCacheSize = caches.reduce(0) { $0 + $1.size }

        return FontInspectionReport(
            userFonts: fonts,
            cacheItems: caches,
            totalFontSize: totalFontSize,
            totalCacheSize: totalCacheSize
        )
    }

    /// 扫描用户字体目录 ~/Library/Fonts
    public func scanUserFonts(customDirectory: String? = nil) -> [FontItem] {
        let userFontsDir = customDirectory ?? NSString(string: "~/Library/Fonts").expandingTildeInPath
        let fm = FileManager.default

        // 安全防线：绝对不扫描 /System/Library/Fonts 或 /Library/Fonts
        if userFontsDir.hasPrefix("/System") || userFontsDir == "/Library/Fonts" {
            return []
        }

        guard fm.fileExists(atPath: userFontsDir) else { return [] }
        guard let files = try? fm.contentsOfDirectory(atPath: userFontsDir) else { return [] }

        var items: [FontItem] = []
        var seenPostscriptNames: Set<String> = []

        let supportedExts: Set<String> = ["ttf", "otf", "ttc", "dfont", "woff", "woff2"]

        for file in files {
            if file.hasPrefix(".") { continue }
            let ext = (file as NSString).pathExtension.lowercased()
            guard supportedExts.contains(ext) else { continue }

            let filePath = (userFontsDir as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: filePath, isDirectory: &isDir), !isDir.boolValue else { continue }

            let size = (try? fm.attributesOfItem(atPath: filePath)[.size] as? Int64) ?? 0
            let format = FontFormat.from(path: filePath)

            // 使用 CoreText 进行字体有效性校验与元数据解析
            let fileURL = URL(fileURLWithPath: filePath) as CFURL
            if let descriptors = CTFontManagerCreateFontDescriptorsFromURL(fileURL) as? [CTFontDescriptor],
               let firstDesc = descriptors.first {

                let family = CTFontDescriptorCopyAttribute(firstDesc, kCTFontFamilyNameAttribute) as? String
                let psName = CTFontDescriptorCopyAttribute(firstDesc, kCTFontNameAttribute) as? String

                var status: FontItemStatus = .valid
                if let ps = psName, !ps.isEmpty {
                    if seenPostscriptNames.contains(ps) {
                        status = .duplicate
                    } else {
                        seenPostscriptNames.insert(ps)
                    }
                }

                let shouldSelect = (status == .duplicate)
                items.append(FontItem(
                    id: filePath,
                    fileName: file,
                    path: filePath,
                    size: size,
                    format: format,
                    familyName: family,
                    postscriptName: psName,
                    status: status,
                    isSystemProtected: false,
                    isSelected: shouldSelect
                ))
            } else {
                // CoreText 无法解析，判定为损坏字体
                items.append(FontItem(
                    id: filePath,
                    fileName: file,
                    path: filePath,
                    size: size,
                    format: format,
                    familyName: nil,
                    postscriptName: nil,
                    status: .corrupted,
                    isSystemProtected: false,
                    isSelected: true
                ))
            }
        }

        // 排序：损坏与重复字体排在前面，其余按体积降序
        return items.sorted {
            if $0.status != $1.status {
                if $0.status == .corrupted { return true }
                if $1.status == .corrupted { return false }
                if $0.status == .duplicate { return true }
                if $1.status == .duplicate { return false }
            }
            return $0.size > $1.size
        }
    }

    /// 扫描字体缓存目录
    public func scanFontCaches() -> [FontCacheItem] {
        let home = NSHomeDirectory()
        let fm = FileManager.default

        let candidatePaths: [(path: String, name: String, note: String)] = [
            ("\(home)/Library/Caches/com.apple.FontRegistry", "CoreText 字体注册表缓存", "包含系统字形度量、字体家族映射与渲染位图索引"),
            ("\(home)/Library/Caches/fontd", "系统 fontd 字体守护进程缓存", "字体守护进程产生的本地化字形预加载与状态缓存"),
            ("\(home)/Library/Caches/Adobe/TypeSupport", "Adobe TypeSupport 字体渲染缓存", "Adobe 创意套件生成的字体度量与历史渲染缓存")
        ]

        var results: [FontCacheItem] = []

        for candidate in candidatePaths {
            guard fm.fileExists(atPath: candidate.path) else { continue }
            let size = AppLocalizationScanner.directorySize(at: candidate.path)
            if size > 0 {
                results.append(FontCacheItem(
                    id: candidate.path,
                    name: candidate.name,
                    path: candidate.path,
                    size: size,
                    note: candidate.note,
                    isSelected: true
                ))
            }
        }

        return results
    }

    /// 安全清理字体文件
    public func cleanFonts(
        items: [FontItem],
        toTrash: Bool = true
    ) -> (cleanedCount: Int, freedBytes: Int64, errorCount: Int) {
        let fm = FileManager.default
        var cleanedCount = 0
        var freedBytes: Int64 = 0
        var errorCount = 0

        for item in items {
            // 安全防线：绝对不删除系统字体或受保护字体
            if item.isSystemProtected || item.path.hasPrefix("/System") || item.path.hasPrefix("/Library/Fonts") {
                errorCount += 1
                continue
            }

            guard fm.fileExists(atPath: item.path) else { continue }

            do {
                if toTrash {
                    try fm.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
                } else {
                    try fm.removeItem(atPath: item.path)
                }
                cleanedCount += 1
                freedBytes += item.size
            } catch {
                errorCount += 1
            }
        }

        return (cleanedCount, freedBytes, errorCount)
    }

    /// 安全清理字体缓存
    public func cleanCaches(
        items: [FontCacheItem]
    ) -> (cleanedCount: Int, freedBytes: Int64, errorCount: Int) {
        let fm = FileManager.default
        var cleanedCount = 0
        var freedBytes: Int64 = 0
        var errorCount = 0

        for item in items {
            // 安全防线：必须在用户 Caches 目录下
            let userCachesPrefix = NSString(string: "~/Library/Caches").expandingTildeInPath
            guard item.path.hasPrefix(userCachesPrefix) else {
                errorCount += 1
                continue
            }

            guard fm.fileExists(atPath: item.path) else { continue }

            do {
                let contents = (try? fm.contentsOfDirectory(atPath: item.path)) ?? []
                for child in contents {
                    let childPath = (item.path as NSString).appendingPathComponent(child)
                    try fm.removeItem(atPath: childPath)
                }
                cleanedCount += 1
                freedBytes += item.size
            } catch {
                errorCount += 1
            }
        }

        return (cleanedCount, freedBytes, errorCount)
    }

    /// 重置用户 ATS 字体数据库
    @discardableResult
    public func resetUserAtsDatabases() -> Bool {
        let task = Process()
        task.launchPath = "/usr/bin/atsutil"
        task.arguments = ["databases", "-removeUser"]

        do {
            try task.run()
            task.waitUntilExit()
            return task.terminationStatus == 0
        } catch {
            return false
        }
    }
}
