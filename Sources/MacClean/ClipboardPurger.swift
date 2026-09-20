import Foundation
import AppKit

// MARK: - 剪贴板历史与大文件临时缓冲区治理引擎 (v1.63.0)

public final class ClipboardPurger {
    public static let shared = ClipboardPurger()

    private init() {}

    /// 敏感信息正则表达式模式（API Key、Token、私钥等）
    private static let sensitivePatterns: [String] = [
        "sk-[a-zA-Z0-9_\\-]{20,}",              // OpenAI API Key
        "ghp_[a-zA-Z0-9]{36}",                  // GitHub Personal Token
        "AKIA[0-9A-Z]{16}",                     // AWS Access Key
        "bearer\\s+[a-zA-Z0-9_\\-\\.]{20,}",    // Bearer Token
        "-----BEGIN[ A-Z0-9_-]+PRIVATE KEY-----", // Private Key
        "password\\s*[:=]\\s*\\S+",             // Password 文本
        "passwd\\s*[:=]\\s*\\S+"
    ]

    /// 探测当前剪贴板状态与临时缓存
    public func inspect() -> ClipboardReport {
        let pb = NSPasteboard.general
        let changeCount = pb.changeCount
        var summaries: [PasteboardItemSummary] = []
        var totalMem: Int64 = 0
        var hasSensitive = false

        if let types = pb.types {
            for type in types {
                let typeStr = type.rawValue
                let data = pb.data(forType: type)
                let size = Int64(data?.count ?? 0)
                totalMem += size

                let (dataType, isSens, preview) = analyzeData(forType: type, data: data)
                if isSens { hasSensitive = true }

                summaries.append(PasteboardItemSummary(
                    id: typeStr,
                    typeName: typeStr,
                    dataType: dataType,
                    size: size,
                    preview: preview,
                    isLarge: size > 5 * 1024 * 1024,
                    isSensitive: isSens
                ))
            }
        }

        let caches = scanClipboardCaches()
        let totalCache = caches.reduce(0) { $0 + $1.size }

        return ClipboardReport(
            items: summaries,
            cacheItems: caches,
            totalMemorySize: totalMem,
            totalCacheSize: totalCache,
            hasSensitiveData: hasSensitive,
            changeCount: changeCount
        )
    }

    /// 分析数据类型与敏感性
    private func analyzeData(forType type: NSPasteboard.PasteboardType, data: Data?) -> (PasteboardDataType, Bool, String) {
        let typeStr = type.rawValue.lowercased()
        guard let data = data, !data.isEmpty else {
            return (.binary, false, "空数据")
        }

        // 1. 文本分析
        if type == .string || typeStr.contains("text") || typeStr.contains("utf8") {
            if let str = String(data: data, encoding: .utf8) {
                let trimmed = str.trimmingCharacters(in: .whitespacesAndNewlines)
                let isSens = checkSensitivity(text: trimmed)
                let preview = isSens ? "•••••••• (已脱敏敏感凭据)" : String(trimmed.prefix(60))
                let kind: PasteboardDataType = isSens ? .sensitiveCredential : .text
                return (kind, isSens, preview)
            }
        }

        // 2. 富文本
        if type == .rtf || typeStr.contains("rtf") {
            return (.rtf, false, "富文本数据 (\(data.count) 字节)")
        }

        // 3. 图像
        if type == .tiff || type == .png || typeStr.contains("image") || typeStr.contains("tiff") || typeStr.contains("png") {
            return (.image, false, "位图图像 (\(Int64(data.count).byteStringCN))")
        }

        // 4. 文件 URL
        if type == .fileURL || typeStr.contains("file-url") {
            if let urlStr = String(data: data, encoding: .utf8) {
                return (.fileURL, false, urlStr)
            }
            return (.fileURL, false, "文件引用对象")
        }

        return (.binary, false, "二进制对象 (\(type.rawValue))")
    }

    /// 校验是否包含敏感凭据
    public func checkSensitivity(text: String) -> Bool {
        for pattern in Self.sensitivePatterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let range = NSRange(location: 0, length: text.utf16.count)
                if regex.firstMatch(in: text, options: [], range: range) != nil {
                    return true
                }
            }
        }
        return false
    }

    /// 扫描系统剪贴板临时缓存文件
    public func scanClipboardCaches() -> [ClipboardCacheItem] {
        let fm = FileManager.default
        var results: [ClipboardCacheItem] = []

        // 1. NSTemporaryDirectory 下的 Pasteboard 相关临时文件
        let tmpDir = NSTemporaryDirectory()
        if let items = try? fm.contentsOfDirectory(atPath: tmpDir) {
            for item in items {
                let lower = item.lowercased()
                if lower.contains("pasteboard") || lower.contains("pboard") || lower.contains("cliptemp") {
                    let path = (tmpDir as NSString).appendingPathComponent(item)
                    let size = AppLocalizationScanner.directorySize(at: path)
                    if size > 0 {
                        results.append(ClipboardCacheItem(
                            id: path,
                            name: item,
                            path: path,
                            size: size,
                            note: "系统剪贴板临时缓存文件"
                        ))
                    }
                }
            }
        }

        // 2. ~/Library/Caches/TemporaryItems 下的剪贴板溢出文件
        let home = NSHomeDirectory()
        let tempItemsDir = "\(home)/Library/Caches/TemporaryItems"
        if fm.fileExists(atPath: tempItemsDir) {
            let size = AppLocalizationScanner.directorySize(at: tempItemsDir)
            if size > 0 {
                results.append(ClipboardCacheItem(
                    id: tempItemsDir,
                    name: "TemporaryItems (剪贴板与拖拽溢出缓存)",
                    path: tempItemsDir,
                    size: size,
                    note: "包含跨应用大文件/图像拖拽与剪贴板生成的临时置换文件"
                ))
            }
        }

        return results
    }

    /// 清空当前系统剪贴板
    @discardableResult
    public func clearPasteboard() -> Bool {
        let pb = NSPasteboard.general
        pb.clearContents()
        return true
    }

    /// 安全清理剪贴板临时缓存文件
    public func cleanClipboardCaches(items: [ClipboardCacheItem]) -> (cleanedCount: Int, freedBytes: Int64) {
        let fm = FileManager.default
        var count = 0
        var freed: Int64 = 0

        for item in items {
            // 安全防线：绝对不删除系统关键目录
            if item.path.hasPrefix("/System") || item.path == "/Library" { continue }

            guard fm.fileExists(atPath: item.path) else { continue }
            do {
                if item.path.hasSuffix("TemporaryItems") {
                    // 清理其子内容，避免删除根目录
                    let children = (try? fm.contentsOfDirectory(atPath: item.path)) ?? []
                    for child in children {
                        let childPath = (item.path as NSString).appendingPathComponent(child)
                        try? fm.removeItem(atPath: childPath)
                    }
                } else {
                    try fm.removeItem(atPath: item.path)
                }
                count += 1
                freed += item.size
            } catch {
                // 忽略单个文件的清理失败
            }
        }

        return (count, freed)
    }

    /// 一键彻底清除剪贴板并清空临时缓存
    public func purgeAll() -> (clearedMemory: Bool, cleanedCacheCount: Int, freedCacheBytes: Int64) {
        let memOk = clearPasteboard()
        let caches = scanClipboardCaches()
        let cacheRes = cleanClipboardCaches(items: caches)
        return (memOk, cacheRes.cleanedCount, cacheRes.freedBytes)
    }
}
