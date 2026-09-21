import Foundation
import AppKit

// MARK: - 废弃打印机驱动与 PPD 描述文件治理引擎 (v1.71.0，v1.72.0 安全加固)
//
// 本轮改掉的三个真机缺陷：
//
// ① **「读不到」被读成「没配打印机」**。`/etc/cups/printers.conf` 实测
//    `-rw------- root:_cups`，`/etc/cups/ppd` 同样不可读——旧实现在两台证据源都读不到时
//    返回**空集合**，而调用方把空集合当"一台打印机都没配"，于是 `/Library/Printers` 下
//    全部厂商驱动判 `.orphanUnused` 且 `isSelected: true` 默认全勾选。
//    现在证据读取带回可信度：`PrinterEvidence.sourcesReadable == false` 时所有条目降级为
//    `.needsConfirmation`（非孤儿、非损坏，永不进默认可删集合）。
//
// ② **PPD 整目录误删**。`scanPPDsDirectory` 按厂商聚合，但每个分组条目的 `path` 都写成
//    共享的 `scanPath`（整个 Resources 根）。勾任一厂商 → 整棵 PPD 资源树进废纸篓。
//    现在分组条目只携带 `memberPaths`（具体 .ppd 文件），删除按文件粒度进行，
//    分组自身再也不是删除目标。
//
// ③ **护栏各自为政**。旧 `clean()` 里是 `path.hasPrefix("/System")` 式字符串判断，
//    既挡不住软链跳板，也不认用户白名单，删除后还就地累加扫描缓存里的 `item.size` 记账。
//    现在一律交给 `ResidueDeletionGate`（治理域 + 软链防跳板 + G6/G8 + 白名单 +
//    删除前实测真实体积 + 废纸篓可撤销），本模块特有的业务判据通过 `policy` 传入。

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

    /// 系统 CUPS 证据源（可覆盖：自检据此造 fixture，绝不去读真实 /etc/cups）
    public static var cupsConfigPath = "/etc/cups/printers.conf"
    public static var cupsPPDDirectoryPath = "/etc/cups/ppd"
    /// 重载 CUPS 用到的命令（自检注入 `SafeProcess.runner` 后只断言命令与参数）
    public static var killallPath = "/usr/bin/killall"

    // MARK: - 在用证据

    /// 读取当前系统已配置/在用的打印机名称与关联关键字，并如实报告**读没读到**。
    ///
    /// 可信度规则：
    /// · 证据源**不存在**（没配打印机、目录未创建）→ 记为"已读，结论为空"；
    /// · 证据源存在但**打不开/列不了**（EACCES 等）→ `sourcesReadable = false`，
    ///   调用方必须放弃"孤儿"结论。
    public static func collectActivePrinterEvidence(customCupsDir: String? = nil) -> PrinterEvidence {
        var keywords = Set<String>()
        var readable: [String] = []
        var unreadable: [String] = []

        let ppdDir = customCupsDir.map { ($0 as NSString).appendingPathComponent("ppd") }
            ?? cupsPPDDirectoryPath
        switch readDirectory(ppdDir) {
        case .ok(let files):
            readable.append(ppdDir)
            for f in files where f.lowercased().hasSuffix(".ppd") || f.lowercased().hasSuffix(".ppd.gz") {
                let base = ((f as NSString).deletingPathExtension as NSString)
                    .deletingPathExtension.lowercased()
                guard !base.isEmpty else { continue }
                keywords.insert(base)
                for part in base.split(separator: "_") where part.count >= 3 {
                    keywords.insert(String(part))
                }
            }
        case .absent:
            readable.append(ppdDir)          // 目录不存在 = 真的没有队列，不是读不到
        case .unreadable(let why):
            unreadable.append("\(ppdDir)（\(why)）")
        }

        let confPath = customCupsDir.map { ($0 as NSString).appendingPathComponent("printers.conf") }
            ?? cupsConfigPath
        switch readFile(confPath) {
        case .ok(let contents):
            readable.append(confPath)
            for line in contents.joined(separator: "\n").components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("<Printer ") || trimmed.hasPrefix("<DefaultPrinter ") else { continue }
                let parts = trimmed.split(separator: " ")
                guard parts.count >= 2 else { continue }
                let rawName = parts[1].replacingOccurrences(of: ">", with: "").lowercased()
                guard !rawName.isEmpty else { continue }
                keywords.insert(rawName)
                for part in rawName.split(separator: "_") where part.count >= 3 {
                    keywords.insert(String(part))
                }
            }
        case .absent:
            readable.append(confPath)
        case .unreadable(let why):
            unreadable.append("\(confPath)（\(why)）")
        }

        return PrinterEvidence(keywords: keywords,
                               sourcesReadable: unreadable.isEmpty,
                               unreadableSources: unreadable,
                               readableSources: readable)
    }

    private enum SourceOutcome {
        case ok([String])
        case absent
        case unreadable(String)
    }

    private static func readDirectory(_ path: String) -> SourceOutcome {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return .absent
        }
        do {
            return .ok(try FileManager.default.contentsOfDirectory(atPath: path))
        } catch {
            return .unreadable(describe(error))
        }
    }

    private static func readFile(_ path: String) -> SourceOutcome {
        guard FileManager.default.fileExists(atPath: path) else { return .absent }
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return .unreadable("无读取权限")
        }
        defer { try? handle.close() }
        guard let data = try? handle.readToEnd() else { return .unreadable("读取失败") }
        guard let text = String(data: data, encoding: .utf8) else {
            return .unreadable("内容无法按文本解析")
        }
        return .ok([text])
    }

    /// 把 Foundation 的读错误分成「文件不存在」与「真的读不到」两类。
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSCocoaErrorDomain, ns.code == 260 { return "不存在" }
        if let reason = ns.userInfo[NSFilePathErrorKey] as? String, reason.isEmpty {
            return ns.localizedDescription
        }
        return ns.localizedDescription
    }

    /// 队列关键词是否命中文本。
    ///
    /// 短词（如 `MF`、`4700`）只做**全等**匹配，≥4 字符才允许子串命中——
    /// 否则一个两字队列名就能把整目录扫成"在用"或反过来把无关驱动全部误判。
    public static func matchesConfigured(keywords: Set<String>, text: String) -> Bool {
        let lower = text.lowercased()
        guard !lower.isEmpty else { return false }
        for kw in keywords where !kw.isEmpty {
            if lower == kw { return true }
            if kw.count >= 4 && lower.contains(kw) { return true }
        }
        return false
    }

    // MARK: - 扫描

    /// 扫描指定目录或系统默认打印机驱动库。
    /// - Parameters:
    ///   - customPrinterDirs: 覆盖全局驱动根（自检 fixture）
    ///   - customUserPrinterDirs: 覆盖用户队列目录（传 `[]` 表示不扫）
    ///   - customCupsDir: 覆盖 CUPS 证据源目录
    ///   - evidence: 直接注入证据（自检据此覆盖"读不到"分支，不必真去碰 /etc/cups）
    public func scan(
        customPrinterDirs: [String]? = nil,
        customUserPrinterDirs: [String]? = nil,
        customCupsDir: String? = nil,
        evidence injected: PrinterEvidence? = nil
    ) -> PrinterDriverSummary {
        let fm = FileManager.default
        let evidence = injected ?? Self.collectActivePrinterEvidence(customCupsDir: customCupsDir)
        let activeKeywords = evidence.keywords

        var items: [PrinterDriverItem] = []
        var totalSize: Int64 = 0
        var orphanCount = 0
        var orphanSize: Int64 = 0
        var activeCount = 0
        var confirmCount = 0

        // 1. 扫描系统全局打印机目录 (/Library/Printers)
        let globalPrinterDirs = customPrinterDirs ?? ["/Library/Printers"]
        for gDir in globalPrinterDirs {
            guard fm.fileExists(atPath: gDir) else { continue }

            if let contents = try? fm.contentsOfDirectory(atPath: gDir) {
                for entry in contents {
                    guard !entry.hasPrefix(".") else { continue }
                    let entryPath = (gDir as NSString).appendingPathComponent(entry)
                    guard fm.fileExists(atPath: entryPath) else { continue }

                    // PPDs 目录做下钻单独评估
                    if entry.lowercased() == "ppds" {
                        scanPPDsDirectory(
                            ppdsPath: entryPath,
                            evidence: evidence,
                            items: &items,
                            totalSize: &totalSize,
                            orphanCount: &orphanCount,
                            orphanSize: &orphanSize,
                            activeCount: &activeCount,
                            confirmCount: &confirmCount
                        )
                        continue
                    }

                    let metrics = calculateDirectoryMetrics(at: entryPath)
                    if !metrics.readable {
                        // 量不出体积 ≠ 可以删：降级为需确认，且不默认勾选
                        let (vendor, kind) = Self.entryKind(of: entry)
                        items.append(PrinterDriverItem(
                            id: entryPath, name: entry, vendor: vendor, path: entryPath,
                            kind: kind, status: .needsConfirmation,
                            size: metrics.size, fileCount: metrics.fileCount,
                            modificationDate: metrics.mtime,
                            evidenceNote: "无法读取该条目的内容（权限或解析失败），未判定为可清理",
                            isSelected: false))
                        confirmCount += 1
                        totalSize += metrics.size
                        continue
                    }

                    let evaluated = Self.evaluateDriverEntry(
                        name: entry, path: entryPath, size: metrics.size, evidence: evidence)

                    let status = evaluated.status
                    let isOrphan = status.isOrphanOrCorrupted
                    if isOrphan {
                        orphanCount += 1
                        orphanSize += metrics.size
                    } else if status == .activeConfigured || status == .systemProtected {
                        activeCount += 1
                    } else if status == .needsConfirmation {
                        confirmCount += 1
                    }

                    items.append(PrinterDriverItem(
                        id: entryPath,
                        name: entry,
                        vendor: evaluated.vendor,
                        path: entryPath,
                        kind: evaluated.kind,
                        status: status,
                        size: metrics.size,
                        fileCount: metrics.fileCount,
                        modificationDate: metrics.mtime,
                        evidenceNote: evaluated.note,
                        // 只有"确证孤儿/损坏"才默认可删；证据不足一律不勾
                        isSelected: isOrphan))
                    totalSize += metrics.size
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
                    let metrics = calculateDirectoryMetrics(at: qPath)

                    var status: PrinterDriverStatus
                    var note: String?
                    if !evidence.sourcesReadable {
                        status = .needsConfirmation
                        note = "读不到 CUPS 已配置队列，无法判断该队列是否还在使用"
                    } else if !metrics.readable {
                        status = .needsConfirmation
                        note = "无法读取队列内容，未判定为可清理"
                    } else if Self.matchesConfigured(keywords: activeKeywords, text: queue) {
                        status = .activeConfigured
                        note = "命中 CUPS 已配置队列"
                    } else {
                        status = .orphanUnused
                        note = "CUPS 配置中不存在该队列"
                    }

                    let isOrphan = status.isOrphanOrCorrupted
                    if isOrphan {
                        orphanCount += 1
                        orphanSize += metrics.size
                    } else if status == .activeConfigured {
                        activeCount += 1
                    } else {
                        confirmCount += 1
                    }

                    items.append(PrinterDriverItem(
                        id: qPath,
                        name: queue,
                        vendor: "自定义打印队列",
                        path: qPath,
                        kind: .cupsQueue,
                        status: status,
                        size: metrics.size,
                        fileCount: metrics.fileCount,
                        modificationDate: metrics.mtime,
                        evidenceNote: note,
                        isSelected: isOrphan))
                    totalSize += metrics.size
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
            activeCount: activeCount,
            cupsEvidenceReadable: evidence.sourcesReadable,
            needsConfirmationCount: confirmCount,
            unreadableSources: evidence.unreadableSources)
    }

    /// PPD 描述文件库：按厂商聚合，但**只登记成员文件**作为删除目标。
    private func scanPPDsDirectory(
        ppdsPath: String,
        evidence: PrinterEvidence,
        items: inout [PrinterDriverItem],
        totalSize: inout Int64,
        orphanCount: inout Int,
        orphanSize: inout Int64,
        activeCount: inout Int,
        confirmCount: inout Int
    ) {
        let fm = FileManager.default
        let resources = (ppdsPath as NSString).appendingPathComponent("Contents/Resources")
        let scanPath = fm.fileExists(atPath: resources) ? resources : ppdsPath

        guard let contents = try? fm.contentsOfDirectory(atPath: scanPath) else { return }

        // 按厂商前缀聚合：分组只累计「体积/文件数/成员文件路径」，
        // 成员必须是**具体文件**（语言子目录要下钻展开），删除永远按文件粒度进行。
        struct Group {
            var size: Int64 = 0
            var count: Int = 0
            var mtime: Date = Date.distantPast
            var members: [String] = []
            /// 组内出现过的原始文件名/目录名——用于与 CUPS 队列关键词比对
            var rawNames: [String] = []
            var unreadable: Bool = false
        }
        var vendorGroups: [String: Group] = [:]

        for file in contents.sorted() {
            guard !file.hasPrefix(".") else { continue }
            let filePath = (scanPath as NSString).appendingPathComponent(file)
            let vendorKey = Self.inferVendor(from: file)
            var group = vendorGroups[vendorKey] ?? Group()
            group.rawNames.append(file)

            if FileSystem.isRealDir(filePath) {
                // 子目录（多为语言包目录）→ 下钻取其中的 PPD 文件
                let collected = Self.ppdFiles(under: filePath, depth: 0)
                if collected.paths.isEmpty {
                    // 目录里没有可识别的 PPD 文件：不登记删除目标，只累计体积
                    let metrics = calculateDirectoryMetrics(at: filePath)
                    group.size += metrics.size
                    group.count += metrics.fileCount
                    if metrics.mtime > group.mtime { group.mtime = metrics.mtime }
                } else {
                    for f in collected.paths {
                        let metrics = calculateDirectoryMetrics(at: f)
                        group.size += metrics.size
                        group.count += 1
                        if metrics.mtime > group.mtime { group.mtime = metrics.mtime }
                        group.members.append(f)
                        group.rawNames.append((f as NSString).lastPathComponent)
                    }
                }
                group.unreadable = group.unreadable || !collected.readable
            } else {
                let metrics = calculateDirectoryMetrics(at: filePath)
                group.size += metrics.size
                group.count += metrics.fileCount
                if metrics.mtime > group.mtime { group.mtime = metrics.mtime }
                if Self.isPPDFile(file) { group.members.append(filePath) }
                group.unreadable = group.unreadable || !metrics.readable
            }
            vendorGroups[vendorKey] = group
        }

        for (vendor, group) in vendorGroups.sorted(by: { $0.key < $1.key }) {
            guard group.size > 0 || group.count > 0 else { continue }
            // 厂商显示名是中文（"惠普 (HP)"），拿它比对英文队列名没有意义；
            // 真正的在用证据是**组内文件名**命中 CUPS 队列关键词。
            let configured = Self.matchesConfigured(keywords: evidence.keywords, text: vendor)
                || group.rawNames.contains { Self.matchesConfigured(keywords: evidence.keywords, text: $0) }
            var status: PrinterDriverStatus
            var note: String?
            if !evidence.sourcesReadable {
                status = .needsConfirmation
                note = "读不到 CUPS 已配置队列，无法判断该厂商 PPD 是否在用"
            } else if group.unreadable {
                status = .needsConfirmation
                note = "PPD 分组内含读不到的条目，未判定为可清理"
            } else if configured {
                status = .activeConfigured
                note = "组内 PPD 命中 CUPS 已配置队列"
            } else if group.members.isEmpty {
                status = .needsConfirmation
                note = "未发现可归属于该厂商的 PPD 文件，无可删除目标"
            } else {
                status = .orphanUnused
                note = "CUPS 配置中无该厂商队列（删除仅作用于 \(group.members.count) 个 PPD 文件）"
            }

            let isOrphan = status.isOrphanOrCorrupted
            if isOrphan {
                orphanCount += 1
                orphanSize += group.size
            } else if status == .activeConfigured {
                activeCount += 1
            } else {
                confirmCount += 1
            }

            items.append(PrinterDriverItem(
                // id 用「资源根#厂商」保证唯一；path 仅供展示，**绝不作为删除目标**
                id: "\(scanPath)#ppd/\(vendor)",
                name: "\(vendor) PPD 描述文件库 (\(group.count) 个文件)",
                vendor: vendor,
                path: scanPath,
                kind: .ppdResource,
                status: status,
                size: group.size,
                fileCount: group.count,
                modificationDate: group.mtime,
                memberPaths: group.members,
                evidenceNote: note,
                isSelected: isOrphan))
            totalSize += group.size
        }
    }

    /// 递归收集目录内的 PPD 文件。返回 (文件, 是否完整读完)。
    private static func ppdFiles(under path: String, depth: Int) -> (paths: [String], readable: Bool) {
        guard depth < 4 else { return ([], true) }
        var out: [String] = []
        var readable = true
        guard let children = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return ([], false)
        }
        for child in children.sorted() {
            guard !child.hasPrefix(".") else { continue }
            let p = (path as NSString).appendingPathComponent(child)
            if FileSystem.isRealDir(p) {
                let sub = ppdFiles(under: p, depth: depth + 1)
                out.append(contentsOf: sub.paths)
                readable = readable && sub.readable
            } else if isPPDFile(child) {
                out.append(p)
            }
        }
        return (out, readable)
    }

    /// PPD 文件识别：`.ppd` / `.ppd.gz`（CUPS 压缩描述文件）
    public static func isPPDFile(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".ppd") || lower.hasSuffix(".ppd.gz")
    }

    private static func entryKind(of name: String) -> (vendor: String, kind: PrinterDriverKind) {
        let vendor = inferVendor(from: name)
        return (vendor, name.lowercased().contains("scan") ? .scannerDriver : .vendorDriverBundle)
    }

    /// 评估驱动条目的类型与健康状态。
    ///
    /// 关键规则：`evidence.sourcesReadable == false` 时**绝不**返回 `.orphanUnused`。
    public static func evaluateDriverEntry(
        name: String,
        path: String,
        size: Int64,
        evidence: PrinterEvidence,
        metricsReadable: Bool = true
    ) -> (vendor: String, kind: PrinterDriverKind, status: PrinterDriverStatus, note: String?) {
        // 1. 系统受保护核心（与证据无关的硬事实）
        if FileSystem.isSystemProtected(path) || path.hasPrefix("/System") {
            return ("Apple", .vendorDriverBundle, .systemProtected, "位于系统硬保护位置，永不触碰")
        }

        let vendor = inferVendor(from: name)
        let kind: PrinterDriverKind = name.lowercased().contains("scan") ? .scannerDriver : .vendorDriverBundle

        // 2. 量不出来 → 需确认（旧实现把 size==0 一律当损坏，而 size==0 常常是读取失败）
        guard metricsReadable else {
            return (vendor, kind, .needsConfirmation, "无法读取该驱动目录，体积未知")
        }

        // 3. 证据不可信 → **全部**降级为需确认，连"空目录 = 损坏"也不下结论：
        //    真机 /Library/Printers/Icons 就是 root 管的合法空目录，判成"损坏可删"会误删。
        guard evidence.sourcesReadable else {
            return (vendor, kind, .needsConfirmation,
                    "无法读取 CUPS 打印机配置（需 root），本模块仅提供定位与建议")
        }
        if size == 0 {
            return (vendor, kind, .corrupted, "目录为空（0 文件 0 字节），判定为损坏残留")
        }

        // 4. 比对当前活动打印机配置
        if Self.matchesConfigured(keywords: evidence.keywords, text: name)
            || Self.matchesConfigured(keywords: evidence.keywords, text: vendor) {
            return (vendor, kind, .activeConfigured, "命中 CUPS 已配置队列")
        }
        return (vendor, kind, .orphanUnused, "CUPS 配置中未发现该厂商/型号队列")
    }

    /// 从名称推导所属打印机厂商。
    ///
    /// 只在**词边界**上匹配厂商词：命中处的左侧必须是行首或非字母字符。
    /// 于是 `EpsonNet_Config` 仍是爱普生，而 `refuji-studio`（含 fuji）、
    /// `phone-utils`（含 hp 的字母对）都不再被误归到厂商名下。
    public static func inferVendor(from text: String) -> String {
        let lower = text.lowercased()
        for (key, display) in knownVendors where containsAtWordBoundary(lower, key) {
            return display
        }
        return "通用/第三方厂商"
    }

    /// `needle` 是否以词边界（左侧行首或非字母）出现在 `haystack` 里。
    static func containsAtWordBoundary(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty, !haystack.isEmpty else { return false }
        for range in haystack.ranges(of: needle) {
            if range.lowerBound == haystack.startIndex { return true }
            if !haystack[haystack.index(before: range.lowerBound)].isLetter { return true }
        }
        return false
    }

    // MARK: - 删除（统一交给网关）

    /// 该路径归属的治理域。主目录内的用户队列返回 nil（走主目录护栏）。
    /// （返回类型 `GovernanceDomain` 是模块内部类型，故本方法为 internal。）
    static func domain(for path: String) -> GovernanceDomain? {
        guard !path.isEmpty else { return nil }
        let real = FileSystem.normalizePath(FileSystem.realPath(path))
        let ppdRoot = GovernanceDomain.ppdResources.normalizedRoot
        if real.hasPrefix(ppdRoot + "/") { return .ppdResources }
        let printersRoot = GovernanceDomain.printersGlobal.normalizedRoot
        if real.hasPrefix(printersRoot + "/") { return .printersGlobal }
        return nil
    }

    /// 清理选中的打印机驱动与废弃 PPD。
    ///
    /// 护栏、真实体积实测、废纸篓与撤销快照全部由 `ResidueDeletionGate` 负责；
    /// 本模块只负责两件事：把条目翻译成候选（PPD 分组翻译成**成员文件**），
    /// 以及用 `policy` 兜住"状态必须是孤儿或损坏"这条业务判据。
    @discardableResult
    func clean(
        items: [PrinterDriverItem],
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: "打印机驱动与 PPD 治理"),
        domainOverride: GovernanceDomain? = nil
    ) -> ResidueDeletionGate.Outcome {
        var candidates: [ResidueDeletionGate.Candidate] = []
        var origin: [String: PrinterDriverItem] = [:]
        for item in items {
            for target in item.deletionTargets where !target.isEmpty {
                candidates.append(ResidueDeletionGate.Candidate(
                    item.name, path: target, domain: domainOverride ?? Self.domain(for: target)))
                origin[target] = item
            }
        }
        return ResidueDeletionGate.execute(candidates, toTrash: toTrash, journal: journal) { cand in
            guard let item = origin[cand.path], item.status.isOrphanOrCorrupted else {
                return .blockedByBaseGate      // 在用/系统核心/需确认 → 一律拒删
            }
            return nil
        }
    }

    /// 清理后请 CUPS 重载配置。**结果如实上报，绝不假定成功。**
    ///
    /// `cupsd` 由 root 运行，非提权进程发 HUP 必然被拒——过去这类代码会直接
    /// 跳过或谎报"已生效"，现在把真实退出码交给用户。
    public func refreshCUPS() -> (success: Bool, message: String) {
        guard SafeProcess.isAvailable(Self.killallPath) else {
            return (false, "未找到 \(Self.killallPath)，无法重载 CUPS；配置将在重新登录后生效。")
        }
        guard let result = SafeProcess.run(Self.killallPath, ["-HUP", "cupsd"], timeout: 5) else {
            return (false, "重载进程未能启动，CUPS 配置未生效。")
        }
        if result.succeeded {
            return (true, "已向 cupsd 发送 HUP，打印配置已重载。")
        }
        if result.timedOut {
            return (false, "重载 CUPS 超时，配置未确认生效。")
        }
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : "：\(detail)"
        return (false, "cupsd 由 root 管理，MacClean 不提权，无法重载（返回码 \(result.exitCode)\(suffix)）。"
                + "需要立即生效请在终端执行 sudo \(Self.killallPath) -HUP cupsd，或重新登录。")
    }

    // MARK: - 辅助：递归统计目录指标
    /// 返回 `readable`：读不到时必须把结论降级，而不是当成"0 字节 = 损坏"。
    private func calculateDirectoryMetrics(at path: String)
        -> (size: Int64, fileCount: Int, mtime: Date, readable: Bool) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return (0, 0, Date.distantPast, false)
        }

        if !isDir.boolValue {
            guard let attr = try? fm.attributesOfItem(atPath: path) else {
                return (0, 0, Date.distantPast, false)
            }
            let sz = Int64(attr[.size] as? UInt64 ?? 0)
            let mtime = attr[.modificationDate] as? Date ?? Date.distantPast
            return (sz, 1, mtime, true)
        }

        var totalSize: Int64 = 0
        var fileCount = 0
        var latestMTime = Date.distantPast
        var readable = true

        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, 0, latestMTime, false)
        }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else {
                readable = false
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

        return (totalSize, fileCount, latestMTime, readable)
    }
}
