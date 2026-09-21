import Foundation
import AppKit
import ColorSync

// MARK: - 系统多显示器色彩描述与 ICC Profile 残存治理引擎 (v1.68.0，v1.72.0 判据修复)
//
// 本轮改掉的三个判据缺陷：
//
// ① **两字子串当厂商/品类判据**。旧代码写着 `lowerName.contains("lg")`、`contains("hp")`，
//    于是 `Flagship-Pro.icc`、`MyHpNotes.icc`、任何含 "lg"/"hp" 字母对的文件名都会被判成
//    "显示器/打印机配置"，进而直接进"建议清理 + 默认勾选"。
//    现在：显式厂商词表 + 短词只允许**整词（词边界）**命中 + 长词才允许子串，且子串两侧
//    都要求 ≥4 字符。
//
// ② **在用判据方向反了**。旧代码只看"文件名里有没有当前屏幕名的片段"，
//    既不看 macOS 真正的引用记录，也不看最近是否写过。
//    现在按硬证据链判：接驳显示器的 **UUID**（profile 文件名就是 `<显示名>-<UUID>.icc`）
//    → ColorSync 偏好里指向该 profile 的记录 → 屏幕名整词匹配 → 30 天内写过即视为在用；
//    以上全部落空**且**证据可信，才判"已断开残留"。
//
// ③ **「读不到」被读成「没在用」**。屏幕列表为空（无头/权限）或偏好文件解析失败时，
//    旧实现照判孤儿并默认勾选。现在一律 `.needsConfirmation`，一个都不默认勾。
//
// 真机实测：`/Library/ColorSync/Profiles` 是 `drwxr-xr-x root:wheel` —— 本工具没有删除权限，
// 所以网关必然回 `.needsPrivilege`；卡片据此明确告诉用户"只帮你定位"，而不是"清理失败"。
//
// 对 `NSScreen` 等真实机器状态的依赖全部收在 `collectEvidence(now:)` 里，
// 并提供 `evidenceProvider` / `scan(evidence:)` 两个注入口，自检可构造 fixture 覆盖分支。

public final class ColorSyncScanner {
    public static let shared = ColorSyncScanner()

    private init() {}

    /// Apple 官方核心色彩描述文件白名单（严禁清理）
    public static let systemProtectedProfiles: Set<String> = [
        "sRGB Profile.icc",
        "Display P3.icc",
        "Generic RGB Profile.icc",
        "Generic Gray Profile.icc",
        "Generic CMYK Profile.icc",
        "AdobeRGB1998.icc",
        "Apple RGB.icc",
        "Color LCD.icc"
    ]

    /// 显式厂商/品类词表（小写整词）。短于 4 字符的词**只允许整词命中**。
    public static let displayVendorVocabulary: Set<String> = [
        "hp", "lg", "aoc", "msi", "tcl",
        "dell", "asus", "acer", "benq", "eizo", "lenovo",
        "samsung", "philips", "hisense", "xiaomi", "innocn", "nanotech",
        "viewsonic", "ultrafine", "prodisplay", "cintiq", "wacom", "thunderbolt", "displaylink",
        "retina", "colorlcd"
    ]

    /// 显示器品类词（≥4 字符，允许子串命中）
    public static let displayKindVocabulary: Set<String> = [
        "display", "monitor", "screen", "panel", "lcd", "oled", "mini",
        "cinema", "imac", "prodisplay", "ultrasharp", "visionpad"
    ]

    /// 打印机相关词表（同样只允许整词或 ≥4 字符子串）
    public static let printerVocabulary: Set<String> = [
        "hp", "epson", "canon", "brother", "xerox", "ricoh", "lexmark",
        "samsung", "kyocera", "konica", "fuji", "printer", "printers", "mfp"
    ]

    /// 「多快算在用」：30 天内写过一律视为在用
    public static let activeWindow: TimeInterval = 30 * 86400

    /// ColorSync 偏好源（用户 + 系统）。可覆盖：自检据此喂 fixture。
    public static var preferencePaths: [String] = [
        NSString(string: "~/Library/Preferences/ColorSync Preferences.plist").expandingTildeInPath,
        "/Library/Preferences/ColorSync Preferences.plist"
    ]
    /// 自检注入点：非 nil 时完全不碰真实 NSScreen / 偏好文件
    public static var evidenceProvider: (() -> ColorSyncEvidence)?
    /// 打印机色彩配置的在用证据源（默认复用打印机模块的 CUPS 证据）。
    /// 单独留注入点：自检不能为了判一个 .icc 去猜真实 `/etc/cups` 的可读性。
    public static var printerEvidenceProvider: () -> PrinterEvidence = {
        PrinterDriverScanner.collectActivePrinterEvidence()
    }

    // MARK: - 词法工具

    /// 切成小写 token：非字母数字即边界（这就是"词边界匹配"的实现）。
    public static func tokens(of text: String) -> [String] {
        var current = ""
        var out: [String] = []
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out
    }

    /// 词表命中判定：整词命中即可（短词如 "hp"/"lg" 只有这一条路）；
    /// 子串命中要求**词表词 ≥4 字符且落在词边界上**（左侧是行首或非字母），
    /// 既杜绝 `contains("hp")` 式误命中，又保住 `DellUltraSharp…` 这类连写名。
    public static func matchesVocabulary(_ text: String, _ vocabulary: Set<String>) -> Bool {
        let lowered = text.lowercased()
        for token in tokens(of: text) {
            if vocabulary.contains(token) { return true }
            guard token.count >= 4 else { continue }
            for word in vocabulary where word.count >= 4
                && containsAtWordBoundary(lowered, word) {
                return true
            }
        }
        return false
    }

    /// `needle` 是否以**词边界**出现在 `haystack` 里（左侧为行首或非字母）。
    public static func containsAtWordBoundary(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty, !haystack.isEmpty else { return false }
        for range in haystack.ranges(of: needle) {
            if range.lowerBound == haystack.startIndex { return true }
            if !haystack[haystack.index(before: range.lowerBound)].isLetter { return true }
        }
        return false
    }

    /// ≥4 字符的有效 token 集合（用于跨名匹配，短词一律不参与）
    public static func significantTokens(_ text: String) -> Set<String> {
        Set(tokens(of: text).filter { $0.count >= 4 })
    }

    /// 屏幕名与 profile 名里到处都有的通用词，不参与"这块屏在用哪个配置"的匹配。
    public static let nameStopWords: Set<String> = [
        "display", "displays", "monitor", "monitors", "screen", "screens",
        "built", "builtin", "retina", "color", "colors", "colour",
        "profile", "profiles", "icc", "icm", "the", "and", "series", "model",
        "type", "user", "named", "sync", "agent"
    ]

    /// 用于「profile 名 ↔ 接驳显示器名」比对的 token 集合
    public static func nameTokens(of text: String) -> Set<String> {
        Set(significantTokens(text).filter { !nameStopWords.contains($0) })
    }

    /// 从 `<显示名>-<UUID>.icc` 形态的文件名里取 UUID（大小写不敏感）。
    /// macOS 为每台接驳显示器生成的 profile 就是这个形态，所以这是最硬的在用证据。
    public static func displayUUID(in fileName: String) -> String? {
        let base = (fileName as NSString).deletingPathExtension
        guard base.count > 37 else { return nil }
        let tail = String(base.suffix(36))
        guard tail.allSatisfy({ $0.isHexDigit || $0 == "-" }) else { return nil }
        let groups = tail.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let expected = [8, 4, 4, 4, 12]
        guard groups.count == expected.count,
              zip(groups, expected).allSatisfy({ $0.count == $1 }) else { return nil }
        // UUID 前必须是「显示名-」的分隔符，避免把普通带横杠的名字当成 UUID
        guard base.dropLast(36).last == "-" else { return nil }
        return tail.uppercased()
    }

    // MARK: - 证据采集（真实机器状态只允许出现在这里）

    /// 采集在用证据：接驳显示器 + ColorSync 偏好引用。
    public static func collectEvidence(now: Date = Date()) -> ColorSyncEvidence {
        if let injected = evidenceProvider { return injected() }
        let (displays, displaysReadable) = currentDisplays()
        var referenced = Set<String>()
        var readable = true
        var sources: [String] = []
        var unreadable: [String] = []
        for path in preferencePaths {
            switch collectReferencedProfiles(at: path) {
            case .ok(let paths, let existed):
                referenced.formUnion(paths)
                sources.append(path)
                if !existed { sources.append("\(path)（不存在，视为无引用）") }
            case .failed(let why):
                readable = false
                unreadable.append("\(path)（\(why)）")
            }
        }
        return ColorSyncEvidence(displays: displays, displaysReadable: displaysReadable,
                                 referencedProfilePaths: referenced, preferenceReadable: readable,
                                 preferenceSources: sources, unreadableSources: unreadable, now: now)
    }

    /// 当前接驳显示器列表。空列表（无头、窗口服务不可用）→ `readable == false`。
    public static func currentDisplays() -> (displays: [ConnectedDisplay], readable: Bool) {
        var out: [ConnectedDisplay] = []
        for screen in NSScreen.screens {
            let name = screen.localizedName
            var uuid = ""
            if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32,
               let ref = CGDisplayCreateUUIDFromDisplayID(number) {
                uuid = uuidString(ref.takeUnretainedValue()) ?? ""
            }
            out.append(ConnectedDisplay(name: name, uuid: uuid))
        }
        return (out, !out.isEmpty)
    }

    enum PreferenceOutcome {
        case ok(Set<String>, Bool)     // 引用路径集合 + 文件是否真的存在
        case failed(String)
    }

    /// 读一份 ColorSync 偏好 plist，递归收集其中指向 profile 的记录。
    static func collectReferencedProfiles(at path: String) -> PreferenceOutcome {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return .ok([], false)          // 不存在 = 真的没有引用记录，不是读不到
        }
        guard !isDir.boolValue, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return .failed("无读取权限或内容损坏")
        }
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) else {
            return .failed("无法解析为 plist")
        }
        var out = Set<String>()
        collectProfileStrings(in: root, into: &out, depth: 0)
        return .ok(out, true)
    }

    private static func collectProfileStrings(in value: Any, into out: inout Set<String>, depth: Int) {
        guard depth < 6 else { return }
        if let s = value as? String {
            let lower = s.lowercased()
            if lower.hasSuffix(".icc") || lower.hasSuffix(".icm") || lower.hasSuffix(".icc/") {
                let trimmed = (lower.hasSuffix("/") ? String(s.dropLast()) : s)
                out.insert(FileSystem.normalizePath(trimmed))
                out.insert((trimmed as NSString).lastPathComponent.lowercased())
            }
            return
        }
        if let arr = value as? [Any] {
            for v in arr { collectProfileStrings(in: v, into: &out, depth: depth + 1) }
            return
        }
        if let dict = value as? [String: Any] {
            for (_, v) in dict { collectProfileStrings(in: v, into: &out, depth: depth + 1) }
        }
    }

    /// CFUUID → 标准 8-4-4-4-12 大写十六进制串
    static func uuidString(_ uuid: CFUUID) -> String? {
        let bytes = CFUUIDGetUUIDBytes(uuid)
        return withUnsafeBytes(of: bytes) { raw -> String in
            let p = raw.bindMemory(to: UInt8.self)
            func hex(_ from: Int, _ to: Int) -> String {
                (from...to).map { String(format: "%02X", p[$0]) }.joined()
            }
            return "\(hex(0, 3))-\(hex(4, 5))-\(hex(6, 7))-\(hex(8, 9))-\(hex(10, 15))"
        }
    }

    // MARK: - 扫描

    /// 扫描指定的或系统的 ColorSync 配置文件目录。
    /// - Parameters:
    ///   - customDirectories: 自检 fixture 覆盖
    ///   - evidence: 注入在用证据（含 `displays`/`now`），nil 时走真实机器状态
    public func scan(customDirectories: [String]? = nil,
                     evidence injected: ColorSyncEvidence? = nil) -> ColorSyncSummary {
        let fm = FileManager.default
        let evidence = injected ?? Self.collectEvidence()

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
        var confirmCount = 0

        for dirPath in searchDirs {
            // 系统只读位置：连扫都不扫
            if Self.isAppleProtected(dirPath) { continue }
            guard fm.fileExists(atPath: dirPath) else { continue }
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: dirPath),
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
                options: [.skipsHiddenFiles],
                errorHandler: { _, _ in true }
            ) else { continue }

            for case let fileURL as URL in enumerator {
                let path = fileURL.path
                let fileName = fileURL.lastPathComponent
                let ext = fileURL.pathExtension.lowercased()

                // 缓存识别沿用 v1.68.0 语义：路径含 com.apple.ColorSync
                let isCache = path.lowercased().contains("com.apple.colorsync")
                let isProfile = ext == "icc" || ext == "icm"
                guard isProfile || isCache else { continue }

                // 目录本身不是删除对象（枚举器会继续走进去）
                var dirFlag: ObjCBool = false
                fm.fileExists(atPath: path, isDirectory: &dirFlag)
                if dirFlag.boolValue { continue }
                if FileSystem.isSymlink(path) {
                    items.append(ICCProfileItem(
                        id: path, name: fileName, path: path, kind: .customProfile,
                        status: .needsConfirmation, size: 0,
                        modificationDate: Date.distantPast,
                        evidenceNote: "符号链接，可能指向授权位置之外，绝不跟随删除",
                        domainID: Self.domain(for: path)?.id, isSelected: false))
                    confirmCount += 1
                    continue
                }

                let values = try? fileURL.resourceValues(
                    forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey])
                guard let values else {
                    // 读不到元数据 ≠ 0 字节损坏
                    items.append(ICCProfileItem(
                        id: path, name: fileName, path: path, kind: .customProfile,
                        status: .needsConfirmation, size: 0,
                        modificationDate: Date.distantPast,
                        evidenceNote: "无法读取文件大小与修改时间，未判定为可清理",
                        domainID: Self.domain(for: path)?.id, isSelected: false))
                    confirmCount += 1
                    continue
                }
                let size = Int64(values.fileSize ?? 0)
                let mtime = values.contentModificationDate ?? Date.distantPast

                let evaluated = Self.evaluateProfile(
                    fileName: fileName, path: path, size: size, modificationDate: mtime,
                    evidence: evidence)

                let isOrphan = evaluated.status.isOrphanOrCorrupted
                if isOrphan {
                    orphanCount += 1
                    orphanSize += size
                } else if evaluated.status.isInUseOrProtected {
                    activeCount += 1
                } else {
                    confirmCount += 1
                }

                items.append(ICCProfileItem(
                    id: path,
                    name: fileName,
                    path: path,
                    kind: evaluated.kind,
                    status: evaluated.status,
                    size: size,
                    modificationDate: mtime,
                    evidenceNote: evaluated.note,
                    domainID: Self.domain(for: path)?.id,
                    isSelected: isOrphan))
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
            activeCount: activeCount,
            evidenceTrustworthy: evidence.isInUseEvidenceTrustworthy,
            needsConfirmationCount: confirmCount,
            unreadableSources: evidence.unreadableSources)
    }

    /// 是否位于 Apple 只读位置
    public static func isAppleProtected(_ path: String) -> Bool {
        guard !path.isEmpty else { return true }
        let real = FileSystem.normalizePath(FileSystem.realPath(path))
        if FileSystem.isSystemProtected(real) { return true }
        for root in ["/System/Library/ColorSync", "/System/Library/Displays"] {
            let r = FileSystem.normalizePath(root)
            if real == r || real.hasPrefix(r + "/") { return true }
        }
        return false
    }

    /// 研判单个配置文件的类型与状态。
    ///
    /// `evidence` 携带 `displays`（接驳显示器）与 `now`（30 天窗口基准），
    /// 两者都可注入，因此这条判定链在自检里是被真实执行到的。
    public static func evaluateProfile(
        fileName: String,
        path: String,
        size: Int64,
        modificationDate: Date,
        evidence: ColorSyncEvidence
    ) -> (kind: ICCProfileKind, status: ICCProfileStatus, note: String?) {
        // 1. Apple 官方核心 / 系统只读位置
        if isAppleProtected(path) {
            return (.displayProfile, .systemProtected, "位于系统硬保护位置，永不触碰")
        }
        if systemProtectedProfiles.contains(fileName) {
            return (.displayProfile, .systemProtected, "Apple 内置核心色彩配置，系统与各 App 直接按名引用")
        }

        let isCache = path.lowercased().contains("com.apple.colorsync")

        // 2. 确证 0 字节的 profile 是损坏（"读不到体积"由调用方单独降级，不走这条）
        if size == 0 && !isCache {
            return (kindOf(fileName: fileName, path: path, isCache: false),
                    .corrupted, "文件为 0 字节，确证损坏")
        }

        // 3. 在用证据链（方向：先证明"在用"，剩下才谈"残留"）
        let referenced = isReferenced(fileName: fileName, path: path, evidence: evidence)
        if referenced != nil {
            return (kindOf(fileName: fileName, path: path, isCache: isCache),
                    .activeConnected, referenced)
        }
        if evidence.now.timeIntervalSince(modificationDate) < activeWindow {
            return (kindOf(fileName: fileName, path: path, isCache: isCache),
                    .recentlyActive,
                    "近 30 天内写过（视为在用），不默认勾选")
        }

        // 缓存：可再生，但必须等过 30 天窗口才谈清理
        if isCache {
            return (.colorSyncCache, .disconnectedOrphan,
                    "ColorSync 缓存超过 30 天未写，系统需要时会自动重建")
        }

        // 4. 证据不足 → 需确认
        guard evidence.isInUseEvidenceTrustworthy else {
            let why = evidence.unreadableSources.isEmpty
                ? "未能读全接驳显示器/ColorSync 偏好引用"
                : "证据源读不到：\(evidence.unreadableSources.joined(separator: "、"))"
            return (kindOf(fileName: fileName, path: path, isCache: false),
                    .needsConfirmation, why + "，不判定为残留")
        }

        // 5. 打印机色彩配置：归打印机模块的证据说话，读不到 CUPS 就不判残留
        let kind = kindOf(fileName: fileName, path: path, isCache: false)
        if kind == .printerProfile {
            let cups = Self.printerEvidenceProvider()
            guard cups.sourcesReadable else {
                return (.printerProfile, .needsConfirmation,
                        "读不到 CUPS 已配置打印机，无法判断该打印机色彩配置是否在用")
            }
            let hit = PrinterDriverScanner.matchesConfigured(keywords: cups.keywords, text: fileName)
            return (.printerProfile,
                    hit ? .activeConnected : .disconnectedOrphan,
                    hit ? "命中 CUPS 已配置打印机" : "CUPS 配置中无对应打印机队列")
        }

        // 6. 显示器 profile：命中接驳显示器的 UUID / 名字整词已在第 3 步排除，
        //    此处只剩"确实是显示器 profile 且当前没有那台屏"
        if kind == .displayProfile {
            return (.displayProfile, .disconnectedOrphan,
                    "属于显示器 profile，但当前无接驳显示器 UUID/名称匹配、无偏好引用且超 30 天未写")
        }

        // 7. 用户自校准/未知用途：没有证据能说它没在用
        return (.customProfile, .needsConfirmation,
                "无引用记录但也无断开证据：自定义校准配置可能仍被某个 App 使用，请人工确认")
    }

    /// 该 profile 是否被"当前接驳显示器 / 偏好记录"引用；返回命中原因，nil 表示未命中。
    static func isReferenced(fileName: String, path: String,
                             evidence: ColorSyncEvidence) -> String? {
        let normalized = FileSystem.normalizePath(path)
        if evidence.referencedProfilePaths.contains(normalized)
            || evidence.referencedProfilePaths.contains(fileName.lowercased()) {
            return "ColorSync 偏好里有指向该配置的记录"
        }
        let uuid = displayUUID(in: fileName)
        for display in evidence.displays where !display.uuid.isEmpty {
            if let uuid, display.uuid.uppercased() == uuid {
                return "当前接驳显示器「\(display.name)」正使用该配置"
            }
        }
        // 名字整词命中（≥4 字符、滤掉通用词）——覆盖"用户自己命名的显示器配置"
        let profileTokens = nameTokens(of: fileName)
        if !profileTokens.isEmpty {
            for display in evidence.displays
            where !profileTokens.isDisjoint(with: nameTokens(of: display.name)) {
                return "名称命中当前接驳显示器「\(display.name)」"
            }
        }
        return nil
    }

    /// 分类：显式词表 + 结构性路径信号（不再有任意两字子串）。
    /// 显示器信号优先于打印机信号——`HP_27inch.icc` 是显示器配置，不是打印机配置。
    static func kindOf(fileName: String, path: String, isCache: Bool) -> ICCProfileKind {
        if isCache { return .colorSyncCache }
        if path.contains("/ColorSync/Profiles/Displays/") { return .displayProfile }
        if matchesVocabulary(fileName, displayVendorVocabulary)
            || matchesVocabulary(fileName, displayKindVocabulary) { return .displayProfile }
        if displayUUID(in: fileName) != nil { return .displayProfile }
        if matchesVocabulary(fileName, printerVocabulary) { return .printerProfile }
        return .customProfile
    }

    // MARK: - 删除（统一交给网关）

    /// 该路径归属的治理域（主目录内的用户配置与缓存返回 nil，走主目录护栏）
    static func domain(for path: String) -> GovernanceDomain? {
        guard !path.isEmpty else { return nil }
        let real = FileSystem.normalizePath(FileSystem.realPath(path))
        let root = GovernanceDomain.colorSyncProfiles.normalizedRoot
        if real.hasPrefix(root + "/") { return .colorSyncProfiles }
        return nil
    }

    /// 清理选中的 ICC 配置文件与缓存。
    @discardableResult
    func clean(
        items: [ICCProfileItem],
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: "ColorSync 色彩配置治理"),
        domainOverride: GovernanceDomain? = nil
    ) -> ResidueDeletionGate.Outcome {
        let candidates = items
            .filter { !$0.path.isEmpty }
            .map { ResidueDeletionGate.Candidate(
                $0.name, path: $0.path, domain: domainOverride ?? Self.domain(for: $0.path)) }
        let origin = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return ResidueDeletionGate.execute(candidates, toTrash: toTrash, journal: journal) { cand in
            guard let item = origin[cand.path], item.status.isOrphanOrCorrupted else {
                return .blockedByBaseGate      // 在用 / 系统核心 / 需确认 → 一律拒删
            }
            return nil
        }
    }
}
