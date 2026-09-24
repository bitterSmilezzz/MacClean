import Foundation
import CoreText

// MARK: - 字体缓存与孤儿系统字体残存治理引擎 (v1.61.0 · v1.73.0 安全加固)
//
// 本轮修掉三个真机可复现的误删：
//
// ① **WOFF / WOFF2 被判损坏并默认勾选删除**。CoreText 从来就不解析 Web 字体格式，
//    `CTFontManagerCreateFontDescriptorsFromURL` 对它们返回 nil 是**格式属性**、
//    不是文件缺陷。旧代码把"解析失败"直接写成 `.corrupted` + `isSelected: true`，
//    于是用户放进字体目录的 web 字体包会被静默删掉。
//
// ② **"解析失败即可删"**。一个字体能不能删，唯一的硬证据是它此刻在不在系统字体注册表里：
//    在用者删掉即坏排版。现在删除前用 `CTFontManagerCopyAvailableFontURLs()`
//    枚举已注册字体（实测本环境可编译可链接，返回 655 条），命中者坚决排除并标注
//    "正在被系统使用"；注册表读不到时**不产出任何可删结论**（读不到 ≠ 可以删）。
//    `.corrupted` 也升级为需要正向证据：解析失败 **且** 文件头不具备 sfnt 容器特征。
//
// ③ **删除绕开一切护栏**。旧 `cleanFonts` 只有 `path.hasPrefix("/System")` 一条字符串
//    护栏，`cleanCaches` 自己 `removeItem` 子项，记账用扫描时缓存的 `item.size`。
//    现在两条路径全部走 `ResidueDeletionGate`：全局字体位置声明 `.fontsGlobal` 治理域，
//    体积在删除前实测，`atsutil` 走 `SafeProcess` 且只有退出码 0 才说"已重置"。

public final class FontCacheInspector {
    public static let shared = FontCacheInspector()

    // MARK: 注入点（自检用，生产路径恒为默认值）

    /// 覆盖系统字体注册表枚举结果（nil = 真的问 CoreText）。
    static var registeredFontURLsOverride: Set<String>?
    /// true 时视为"注册表读不到"，用于验证证据缺失下的降级行为。
    static var registryReadFailure: Bool = false
    /// 调用的命令路径可覆盖：自检据此断言"到底调了哪个命令、带了哪些参数"。
    static var atsutilPath = "/usr/bin/atsutil"
    /// 用户缓存根可覆盖（自检用 fixture 目录，避免在真实 `~/Library/Caches` 里造文件）。
    static var userCachesRootOverride: String?

    private init() {}

    // MARK: - 扫描

    /// 执行全景扫描：用户字体排查 + 字体缓存审计
    public func scan() -> FontInspectionReport {
        let registry = registeredFontPaths()
        let fonts = scanUserFonts(registry: registry)
        let caches = scanFontCaches()

        return FontInspectionReport(
            userFonts: fonts,
            cacheItems: caches,
            totalFontSize: fonts.reduce(0) { $0 + $1.size },
            totalCacheSize: caches.reduce(0) { $0 + $1.size },
            registryUnavailable: registry == nil
        )
    }

    /// 扫描用户字体目录 ~/Library/Fonts
    public func scanUserFonts(customDirectory: String? = nil) -> [FontItem] {
        scanUserFonts(customDirectory: customDirectory, registry: registeredFontPaths())
    }

    /// 扫描用户字体目录。`registry == nil` 表示注册表读不到：
    /// 此时不产出"在用"标记，也**绝不**把任何项升级成可删结论。
    func scanUserFonts(customDirectory: String? = nil, registry: Set<String>?) -> [FontItem] {
        let userFontsDir = customDirectory ?? NSString(string: "~/Library/Fonts").expandingTildeInPath
        let fm = FileManager.default

        // 扫描范围防线：本模块只治理用户字体目录。
        // `/Library/Fonts` 归 `.fontsGlobal` 治理域、由网关裁决；`/System/**` 受 G8 硬保护。
        if Self.isOutsideUserFontScope(userFontsDir) { return [] }

        guard fm.fileExists(atPath: userFontsDir) else { return [] }
        // 读不到目录内容 → 空列表（而不是"这里的东西都能删"）
        guard let files = try? fm.contentsOfDirectory(atPath: userFontsDir) else { return [] }

        var items: [FontItem] = []
        var seenPostscriptNames: Set<String> = []
        let supportedExts: Set<String> = ["ttf", "otf", "ttc", "dfont", "woff", "woff2"]

        for file in files.sorted() {
            if file.hasPrefix(".") { continue }
            let ext = (file as NSString).pathExtension.lowercased()
            guard supportedExts.contains(ext) else { continue }

            let filePath = (userFontsDir as NSString).appendingPathComponent(file)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: filePath, isDirectory: &isDir), !isDir.boolValue else { continue }
            // 软链本身不列：删它不释放空间，而且它是软链跳板的经典入口
            if FileSystem.isSymlink(filePath) { continue }

            let size = FileSystem.size(at: filePath)
            let format = FontFormat.from(path: filePath)
            let inUse = Self.isRegistered(filePath, in: registry)

            // CoreText 解析：只用于取元数据与识别重复副本，**不单独构成可删依据**
            let descriptors = CTFontManagerCreateFontDescriptorsFromURL(
                URL(fileURLWithPath: filePath) as CFURL) as? [CTFontDescriptor]

            if let firstDesc = descriptors?.first {
                let family = CTFontDescriptorCopyAttribute(firstDesc, kCTFontFamilyNameAttribute) as? String
                let psName = CTFontDescriptorCopyAttribute(firstDesc, kCTFontNameAttribute) as? String

                var status: FontItemStatus = .valid
                var note: String?
                if let ps = psName, !ps.isEmpty {
                    if seenPostscriptNames.contains(ps) {
                        status = .duplicate
                        note = "与同目录另一份字体的 PostScript 名相同"
                    } else {
                        seenPostscriptNames.insert(ps)
                    }
                }
                if inUse { note = Self.appendNote(note, "正在被系统使用（已注册）") }

                items.append(FontItem(
                    id: filePath, fileName: file, path: filePath, size: size, format: format,
                    familyName: family, postscriptName: psName, status: status,
                    isSystemProtected: false,
                    isSelected: status.providesDeletionEvidence && !inUse,
                    isRegisteredInUse: inUse, note: note))
                continue
            }

            // ── CoreText 解析失败：三种情形，只有第二种才是"损坏" ──
            if format == .woff || format == .woff2 {
                // ① Web 字体：解析不了是 CoreText 的能力边界，与文件好坏无关
                items.append(FontItem(
                    id: filePath, fileName: file, path: filePath, size: size, format: format,
                    familyName: nil, postscriptName: nil, status: .webFormat,
                    isSystemProtected: false, isSelected: false, isRegisteredInUse: inUse,
                    note: "WOFF/WOFF2 属 Web 字体格式，CoreText 不解析属正常现象，不按损坏处理"))
                continue
            }

            let signature = Self.fontContainerSignature(of: filePath)
            switch signature {
            case .some(false):
                // ② 文件头连 sfnt 字体容器特征都没有 → 确有损坏证据
                items.append(FontItem(
                    id: filePath, fileName: file, path: filePath, size: size, format: format,
                    familyName: nil, postscriptName: nil, status: .corrupted,
                    isSystemProtected: false, isSelected: !inUse, isRegisteredInUse: inUse,
                    note: inUse ? "正在被系统使用，已坚决保留" : "文件头无 TrueType/OpenType 容器特征"))
            case .some(true), .none:
                // ③ 容器特征在但读不出字形（加密、新表版本、dfont 资源叉），
                //    或**文件根本读不到**：证据不足 → 需确认，绝不默认勾选
                items.append(FontItem(
                    id: filePath, fileName: file, path: filePath, size: size, format: format,
                    familyName: nil, postscriptName: nil, status: .needsReview,
                    isSystemProtected: false, isSelected: false, isRegisteredInUse: inUse,
                    note: signature == nil
                        ? "文件无法读取，证据不足"
                        : "CoreText 解析失败但容器特征存在，可能是加密或新版本字形表"))
            }
        }

        // 排序：有删除证据的在前，需确认的其次，其余按体积降序
        return items.sorted { a, b in
            if a.status.providesDeletionEvidence != b.status.providesDeletionEvidence {
                return a.status.providesDeletionEvidence
            }
            if (a.status == .needsReview) != (b.status == .needsReview) {
                return a.status == .needsReview
            }
            return a.size > b.size
        }
    }

    /// 扫描字体缓存目录（只认登记过的精确路径，绝不退化成删父目录）
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
            guard Self.isUserCachePath(candidate.path) else { continue }
            guard fm.fileExists(atPath: candidate.path) else { continue }
            let size = FileSystem.size(at: candidate.path)
            if size > 0 {
                results.append(FontCacheItem(
                    id: candidate.path, name: candidate.name, path: candidate.path,
                    size: size, note: candidate.note, isSelected: true))
            }
        }
        return results
    }

    // MARK: - 系统字体注册表（唯一能证明"这个字体在用"的证据源）

    /// 当前系统已注册字体的**真实路径**集合。
    ///
    /// 返回 nil 表示读不到注册表。调用方**必须**把 nil 当成证据缺失：
    /// 不得据此认为"这个字体没在被使用"。
    public func registeredFontPaths() -> Set<String>? {
        if let override = Self.registeredFontURLsOverride { return override }
        if Self.registryReadFailure { return nil }
        guard let urls = CTFontManagerCopyAvailableFontURLs() as? [URL], !urls.isEmpty else {
            return nil
        }
        return Set(urls.map { FileSystem.normalizePath(FileSystem.realPath($0.path)) })
    }

    // MARK: - 判定辅助

    /// 用户字体目录之外的扫描范围（SIP 保护位置与 `/Library/Fonts` 全局字体目录）。
    /// `/System` 一族走 `FileSystem.isSystemProtected` 的统一判据，不再手写
    /// `hasPrefix("/System/")` 字符串护栏——项目早就给 ColorSync/PrinterDriver
    /// 各立了 lint 禁这条形态，本轮把 Screenshots/Downloads/QuickLook/AppLocalization
    /// 与这一处（FontCache 的归一化 sibling）一起收进同一条 G18 全仓 lint。
    static func isOutsideUserFontScope(_ dir: String) -> Bool {
        let normalized = FileSystem.normalizePath(dir)
        if FileSystem.isSystemProtected(normalized) { return true }
        return normalized == GovernanceDomain.fontsGlobal.normalizedRoot
            || normalized.hasPrefix(GovernanceDomain.fontsGlobal.normalizedRoot + "/")
    }

    static func isRegistered(_ path: String, in registry: Set<String>?) -> Bool {
        guard let registry else { return false }
        return registry.contains(FileSystem.normalizePath(FileSystem.realPath(path)))
    }

    /// 是否位于用户缓存根之下（缓存治理唯一被授权的范围）
    static func isUserCachePath(_ path: String) -> Bool {
        let root = userCachesRootOverride ?? NSString(string: "~/Library/Caches").expandingTildeInPath
        let prefix = FileSystem.normalizePath(root)
        let normalized = FileSystem.normalizePath(path)
        return normalized.hasPrefix(prefix + "/")
    }

    /// 字体容器特征：前 4 字节是否命中 sfnt/TrueType/OpenType/集合魔数。
    ///
    /// - `nil`：**读不到文件**（权限、空文件、竞态删除）→ 证据不足
    /// - `true`：容器特征在，但 CoreText 读不出字形 → 同样不能断定损坏
    /// - `false`：连容器特征都没有 → 这才是"损坏"的正向证据
    static func fontContainerSignature(of path: String) -> Bool? {
        let magic: [[UInt8]] = [
            [0x00, 0x01, 0x00, 0x00],   // TrueType
            [0x4F, 0x54, 0x54, 0x4F],   // 'OTTO' OpenType/CFF
            [0x74, 0x72, 0x75, 0x65],   // 'true'
            [0x74, 0x74, 0x63, 0x66],   // 'ttcf' 字体集合
            [0x74, 0x79, 0x70, 0x31],   // 'typ1'
        ]
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return nil }
        let head = [UInt8](data)
        return magic.contains { head == $0 }
    }

    static func appendNote(_ existing: String?, _ add: String) -> String {
        guard let existing, !existing.isEmpty else { return add }
        return existing + "；" + add
    }

    // MARK: - 治理域声明

    /// 全局字体位置声明 `.fontsGlobal`；主目录内的传 nil 走主目录护栏。
    static func governanceDomain(forPath path: String) -> GovernanceDomain? {
        GovernanceDomain.domain(forPath: path)
    }

    // MARK: - 删除（全部走统一网关）

    /// 安全清理字体文件。
    ///
    /// 三层拦截，任何一层不过都会出现在 `outcome.rejected` 里并带真实中文原因：
    /// ① 在用 / 系统受保护 / 无正向证据的项**在进网关之前**就被剔除（附模块自己的原因）；
    /// ② 网关护栏（软链跳板 + G8 + G6 + 用户白名单 + 治理域 + 真实 unlink 权限）；
    /// ③ 删除前实测体积，失败项计入 `failed` 而**不**计入 `cleanedCount`/`freedBytes`。
    @discardableResult
    func cleanFonts(
        items: [FontItem],
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: "字体残留治理")
    ) -> ResidueDeletionGate.Outcome {
        guard !items.isEmpty else { return ResidueDeletionGate.Outcome() }
        let registry = registeredFontPaths()

        var outcome = ResidueDeletionGate.Outcome()
        var candidates: [ResidueDeletionGate.Candidate] = []

        for item in items {
            if let blocked = blockVerdict(for: item, registry: registry) {
                outcome.rejected.append(.make(name: item.fileName, path: item.path,
                                              reason: blocked.reason, message: blocked.message))
                continue
            }
            candidates.append(.init(item.fileName, path: item.path,
                                    domain: Self.governanceDomain(forPath: item.path)))
        }

        outcome.merge(ResidueDeletionGate.execute(candidates, toTrash: toTrash, journal: journal))
        return outcome
    }

    /// 单个字体条目的模块级判据：返回「拒绝原因 + 中文说明」，nil 表示可以进网关。
    ///
    /// reason 用各自的语义位（在用 → `.inUse`，证据不足/非清理对象 → `.notDeletable`，
    /// 系统受保护 → `.systemProtected`），不再一律借 `.systemProtected` 冒充业务结论。
    func blockVerdict(for item: FontItem, registry: Set<String>?)
        -> (reason: GovernanceVerdict.Reason, message: String)? {
        if item.isSystemProtected {
            return (.systemProtected, "系统受保护字体，绝不可删")
        }
        if registry == nil {
            return (.notDeletable, "系统字体注册表读取失败，无法确认是否在用——按「读不到 ≠ 可以删」保留")
        }
        if Self.isRegistered(item.path, in: registry) || item.isRegisteredInUse {
            return (.inUse, "正在被系统使用（已注册进 CoreText 字体注册表），坚决保留")
        }
        if !item.status.providesDeletionEvidence {
            switch item.status {
            case .webFormat:
                return (.notDeletable, "WOFF/WOFF2 属 Web 字体格式，CoreText 解析不了属正常现象，不按损坏处理")
            case .needsReview:
                return (.notDeletable, "证据不足（无法确认文件已损坏），需你手动确认后再处理")
            case .valid:
                return (.notDeletable, "字体解析正常，不是残留")
            case .orphan:
                return (.notDeletable, "本模块不产出孤儿结论，需确认")
            case .corrupted, .duplicate:
                break
            }
        }
        return nil
    }

    /// 安全清理字体缓存：只清空已登记的**精确**缓存目录内部子项，缓存根永不删除。
    @discardableResult
    func cleanCaches(
        items: [FontCacheItem],
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: "字体渲染缓存治理")
    ) -> ResidueDeletionGate.Outcome {
        guard !items.isEmpty else { return ResidueDeletionGate.Outcome() }
        let fm = FileManager.default
        var outcome = ResidueDeletionGate.Outcome()
        var candidates: [ResidueDeletionGate.Candidate] = []

        for item in items {
            guard Self.isUserCachePath(item.path) else {
                outcome.rejected.append(.make(name: item.name, path: item.path, reason: .outsideDomain,
                                              message: "不在用户 ~/Library/Caches 下的已登记缓存路径，拒绝"))
                continue
            }
            guard let contents = try? fm.contentsOfDirectory(atPath: item.path) else {
                // 读不到子项 = 失败，绝不能当成"已清空"
                outcome.failed.append((item.name, item.path, "缓存目录无法枚举，按失败处理（不计入已清理）"))
                continue
            }
            for child in contents.sorted() {
                let childPath = (item.path as NSString).appendingPathComponent(child)
                candidates.append(.init(child, path: childPath,
                                        domain: Self.governanceDomain(forPath: childPath)))
            }
        }

        outcome.merge(ResidueDeletionGate.execute(
            candidates, toTrash: toTrash, journal: journal) { candidate in
            // 只允许删已登记缓存目录的**直接子项**，且不得是整个缓存根自己
            guard Self.isUserCachePath(candidate.path) else {
                return .make(candidate, reason: .outsideDomain,
                             message: "子项不在本模块登记的缓存目录内，拒绝删除")
            }
            return nil
        })
        return outcome
    }

    // MARK: - ATS 字体数据库重置

    /// 重置用户 ATS 字体数据库。
    ///
    /// **只有拿到退出码 0 这个证据，才允许对用户说"已重置"**；
    /// 命令不存在、启动失败、超时、非 0 退出码分别给出不同结论，一律不谎报。
    @discardableResult
    public func resetUserAtsDatabases() -> AtsResetResult {
        let path = Self.atsutilPath
        guard SafeProcess.isAvailable(path) else { return .notExecuted }
        guard let result = SafeProcess.run(path, ["databases", "-removeUser"], timeout: 15) else {
            return AtsResetResult(executed: false, succeeded: false,
                                  message: "字体数据库重置命令未能启动，未做任何改动", exitCode: nil)
        }
        if result.timedOut {
            return AtsResetResult(executed: true, succeeded: false,
                                  message: "atsutil 执行超时，字体缓存**未确认**已重置",
                                  exitCode: result.exitCode)
        }
        let output = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.succeeded else {
            return AtsResetResult(
                executed: true, succeeded: false,
                message: "atsutil 返回退出码 \(result.exitCode)，字体缓存未重置"
                    + (output.isEmpty ? "" : "：\(output)"),
                exitCode: result.exitCode)
        }
        return AtsResetResult(executed: true, succeeded: true,
                              message: "用户字体注册表数据库已重置（atsutil databases -removeUser 退出码 0）",
                              exitCode: 0)
    }
}
