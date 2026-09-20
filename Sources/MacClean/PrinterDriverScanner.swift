import Foundation
import AppKit

// MARK: - 废弃打印机驱动与 PPD 描述文件治理引擎 (v1.71.0)

public final class PrinterDriverScanner {
    public static let shared = PrinterDriverScanner()

    private init() {}

    /// 常见主流打印机厂商关键词表
    public static let knownVendors: [String: String] = [
        "hp": "惠普 (HP)",
        "hewlett-packard": "惠普 (HP)",
        "canon": "佳能 (Canon)",
        "epson": "爱普生 (Epson)",
        "brother": "兄弟 (Brother)",
        "xerox": "施乐 (Xerox)",
        "ricoh": "理光 (Ricoh)",
        "samsung": "三星 (Samsung)",
        "lexmark": "利盟 (Lexmark)",
        "kyocera": "京瓷 (Kyocera)",
        "konica": "柯尼卡美能达 (Konica)",
        "fuji": "富士 (Fuji)"
    ]

    /// 获取当前系统正在配置/在用的打印机名称与关联关键字
    public static func getActiveConfiguredKeywords(customCupsDir: String? = nil) -> Set<String> {
        var keywords = Set<String>()
        let cupsPPDDir = customCupsDir ?? "/etc/cups/ppd"
        let fm = FileManager.default

        if let files = try? fm.contentsOfDirectory(atPath: cupsPPDDir) {
            for f in files where f.hasSuffix(".ppd") {
                let name = (f as NSString).deletingPathExtension.lowercased()
                keywords.insert(name)
                for part in name.split(separator: "_") {
                    keywords.insert(String(part))
                }
            }
        }

        // 读取 printers.conf
        let confPath = customCupsDir != nil ? (customCupsDir! as NSString).appendingPathComponent("printers.conf") : "/etc/cups/printers.conf"
        if let content = try? String(contentsOfFile: confPath, encoding: .utf8) {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("<Printer ") || trimmed.hasPrefix("<DefaultPrinter ") {
                    let parts = trimmed.split(separator: " ")
                    if parts.count >= 2 {
                        let rawName = parts[1].replacingOccurrences(of: ">", with: "").lowercased()
                        keywords.insert(rawName)
                    }
                }
            }
        }

        return keywords
    }

    /// 扫描指定目录或系统默认打印机驱动库
    public func scan(
        customPrinterDirs: [String]? = nil,
        customUserPrinterDirs: [String]? = nil,
        customCupsDir: String? = nil
    ) -> PrinterDriverSummary {
        let fm = FileManager.default
        let activeKeywords = Self.getActiveConfiguredKeywords(customCupsDir: customCupsDir)

        var items: [PrinterDriverItem] = []
        var totalSize: Int64 = 0
        var orphanCount = 0
        var orphanSize: Int64 = 0
        var activeCount = 0

        // 1. 扫描系统全局打印机目录 (/Library/Printers)
        let globalPrinterDirs = customPrinterDirs ?? ["/Library/Printers"]
        for gDir in globalPrinterDirs {
            // 安全防线：绝对不触碰 /System
            if gDir.hasPrefix("/System") { continue }
            guard fm.fileExists(atPath: gDir) else { continue }

            if let contents = try? fm.contentsOfDirectory(atPath: gDir) {
                for entry in contents {
                    guard !entry.hasPrefix(".") else { continue }
                    let entryPath = (gDir as NSString).appendingPathComponent(entry)
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: entryPath, isDirectory: &isDir) else { continue }

                    // PPDs 目录做下钻单独评估
                    if entry.lowercased() == "ppds" {
                        scanPPDsDirectory(
                            ppdsPath: entryPath,
                            activeKeywords: activeKeywords,
                            items: &items,
                            totalSize: &totalSize,
                            orphanCount: &orphanCount,
                            orphanSize: &orphanSize,
                            activeCount: &activeCount
                        )
                        continue
                    }

                    let (dirSize, fileCount, mtime) = calculateDirectoryMetrics(at: entryPath)
                    guard dirSize > 0 || fileCount > 0 else { continue }

                    let (vendor, kind, status) = Self.evaluateDriverEntry(
                        name: entry,
                        path: entryPath,
                        size: dirSize,
                        activeKeywords: activeKeywords
                    )

                    let isOrphan = status.isOrphanOrCorrupted
                    if isOrphan {
                        orphanCount += 1
                        orphanSize += dirSize
                    } else if status == .activeConfigured {
                        activeCount += 1
                    }

                    let item = PrinterDriverItem(
                        id: entryPath,
                        name: entry,
                        vendor: vendor,
                        path: entryPath,
                        kind: kind,
                        status: status,
                        size: dirSize,
                        fileCount: fileCount,
                        modificationDate: mtime,
                        isSelected: isOrphan
                    )
                    items.append(item)
                    totalSize += dirSize
                }
            }
        }

        // 2. 扫描用户个人打印机队列 (~/Library/Printers)
        let userPrinterDirs = customUserPrinterDirs ?? [
            NSString(string: "~/Library/Printers").expandingTildeInPath
        ]
        for uDir in userPrinterDirs {
            guard fm.fileExists(atPath: uDir) else { continue }
            if let contents = try? fm.contentsOfDirectory(atPath: uDir) {
                for queue in contents {
                    guard !queue.hasPrefix(".") else { continue }
                    let qPath = (uDir as NSString).appendingPathComponent(queue)
                    let (qSize, fCount, mtime) = calculateDirectoryMetrics(at: qPath)

                    let lower = queue.lowercased()
                    let isConfigured = activeKeywords.contains(where: { lower.contains($0) })
                    let status: PrinterDriverStatus = isConfigured ? .activeConfigured : .orphanUnused

                    if status == .orphanUnused {
                        orphanCount += 1
                        orphanSize += qSize
                    } else {
                        activeCount += 1
                    }

                    let qItem = PrinterDriverItem(
                        id: qPath,
                        name: queue,
                        vendor: "自定义打印队列",
                        path: qPath,
                        kind: .cupsQueue,
                        status: status,
                        size: qSize,
                        fileCount: fCount,
                        modificationDate: mtime,
                        isSelected: status == .orphanUnused
                    )
                    items.append(qItem)
                    totalSize += qSize
                }
            }
        }

        // 排序：建议清理的排在前
        let sorted = items.sorted { a, b in
            if a.status.isOrphanOrCorrupted != b.status.isOrphanOrCorrupted {
                return a.status.isOrphanOrCorrupted
            }
            return a.size > b.size
        }

        return PrinterDriverSummary(
            items: sorted,
            totalSize: totalSize,
            orphanCount: orphanCount,
            orphanSize: orphanSize,
            activeCount: activeCount
        )
    }

    private func scanPPDsDirectory(
        ppdsPath: String,
        activeKeywords: Set<String>,
        items: inout [PrinterDriverItem],
        totalSize: inout Int64,
        orphanCount: inout Int,
        orphanSize: inout Int64,
        activeCount: inout Int
    ) {
        let fm = FileManager.default
        let resources = (ppdsPath as NSString).appendingPathComponent("Contents/Resources")
        let scanPath = fm.fileExists(atPath: resources) ? resources : ppdsPath

        guard let contents = try? fm.contentsOfDirectory(atPath: scanPath) else { return }

        // 按厂商前缀聚合 PPD 文件或子目录
        var vendorGroups: [String: (size: Int64, count: Int, path: String, mtime: Date)] = [:]

        for file in contents {
            guard !file.hasPrefix(".") else { continue }
            let filePath = (scanPath as NSString).appendingPathComponent(file)
            let (sz, fc, mt) = calculateDirectoryMetrics(at: filePath)

            let vendorKey = Self.inferVendor(from: file)
            var current = vendorGroups[vendorKey] ?? (0, 0, filePath, Date.distantPast)
            current.size += sz
            current.count += fc
            if mt > current.mtime { current.mtime = mt }
            vendorGroups[vendorKey] = current
        }

        for (vendor, val) in vendorGroups {
            guard val.size > 0 || val.count > 0 else { continue }
            let lowerVendor = vendor.lowercased()
            let isConfigured = activeKeywords.contains(where: { lowerVendor.contains($0) })
            let status: PrinterDriverStatus = isConfigured ? .activeConfigured : .orphanUnused

            if status == .orphanUnused {
                orphanCount += 1
                orphanSize += val.size
            } else {
                activeCount += 1
            }

            let item = PrinterDriverItem(
                id: (scanPath as NSString).appendingPathComponent(vendor),
                name: "\(vendor) PPD 描述文件库 (\(val.count) 个文件)",
                vendor: vendor,
                path: scanPath,
                kind: .ppdResource,
                status: status,
                size: val.size,
                fileCount: val.count,
                modificationDate: val.mtime,
                isSelected: status == .orphanUnused
            )
            items.append(item)
            totalSize += val.size
        }
    }

    /// 评估驱动条目的类型与健康状态
    public static func evaluateDriverEntry(
        name: String,
        path: String,
        size: Int64,
        activeKeywords: Set<String>
    ) -> (vendor: String, kind: PrinterDriverKind, status: PrinterDriverStatus) {
        // 1. 系统受保护核心
        if path.hasPrefix("/System") {
            return ("Apple", .vendorDriverBundle, .systemProtected)
        }

        // 2. 损坏条目
        if size == 0 {
            return (inferVendor(from: name), .vendorDriverBundle, .corrupted)
        }

        let vendor = inferVendor(from: name)
        let lowerName = name.lowercased()

        // 3. 扫描仪类型判定
        let kind: PrinterDriverKind = lowerName.contains("scan") ? .scannerDriver : .vendorDriverBundle

        // 4. 比对当前活动打印机配置
        let isConfigured = activeKeywords.contains(where: { keyword in
            lowerName.contains(keyword) || vendor.lowercased().contains(keyword)
        })

        if isConfigured {
            return (vendor, kind, .activeConfigured)
        } else {
            return (vendor, kind, .orphanUnused)
        }
    }

    /// 从名称推导所属打印机厂商
    public static func inferVendor(from text: String) -> String {
        let lower = text.lowercased()
        for (key, display) in knownVendors {
            if lower.contains(key) {
                return display
            }
        }
        return "通用/第三方厂商"
    }

    /// 清理选中的打印机驱动与废弃 PPD
    public func clean(
        items: [PrinterDriverItem],
        toTrash: Bool = true
    ) -> (cleanedCount: Int, freedBytes: Int64, errorCount: Int) {
        let fm = FileManager.default
        var cleanedCount = 0
        var freedBytes: Int64 = 0
        var errorCount = 0

        for item in items {
            let path = item.path

            // 安全防线 1：系统目录与受保护状态拦截
            if path.hasPrefix("/System") || item.status == .systemProtected || item.status == .activeConfigured {
                errorCount += 1
                continue
            }

            guard item.status.isOrphanOrCorrupted else {
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
