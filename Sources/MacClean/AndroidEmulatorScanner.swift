import Foundation

/// Android 模拟器 AVD 与 SDK 系统镜像孤儿的扫描 + 网关删除入口（v1.73.10）。
///
/// 判据见 `AndroidEmulatorModels.swift` 顶部。**安全侧与打印机/音频 HAL/ColorSync 三个模块逐字对齐**：
///  - 删除一律走 `ResidueDeletionGate`；默认根 `~/.android/avd` 在主目录内，`domain: nil` 即由主目录
///    护栏兜住，**本模块不登记任何 `GovernanceDomain`、不新增主目录外的可删根**（SDK 根只作为镜像
///    判据的证据，不作为删除目标）。`$ANDROID_AVD_HOME` 把根重定位到主目录外时，条目照列、
///    issue 先说明"只列示不删"，删除请求由主目录护栏拒绝并带回原因；
///  - 孤儿 = **没有任何 `.ini` 描述符的 `path=` 指向这棵 `.avd`**（不是"没有同名 .ini"，
///    见 `referencedAVDDirs`）；
///  - `status.isProvenOrphan == false`（`.needsConfirmation` / `.brokenImageNeedsConfirm` / `.liveHealthy`）
///    的条目不进删除管道，但**各自的拒绝原因都带进 `Outcome.rejected`**；
///  - 求体积走共享的 `FileSystem.directoryStats(at:)`（v1.73.10 复审 R2-P2-11 收编：本模块不再
///    自带递归 walker；口径已统一为 allocated 字节、软链不计、`WalkBlockFlag` 记 `readable`），
///    残缺时 `readable=false` → 卡片不得据此默认勾选，且必须补一条 issue 让 `isResultComplete` 翻假；
///  - 根读不到 / SDK 根读不到 / 有 `.avd` 是软链未判定时，不"静默返回空 summary"，而是往 `issues`
///    里记一笔（v1.73.4/v1.73.7 的 G9 契约）。
public final class AndroidEmulatorScanner {
    public static let shared = AndroidEmulatorScanner()
    private init() {}

    // MARK: - 常量（internal 是给自检留的注入缝，同 PrinterDriver/AudioHAL 的做法）

    static let historyCategory = "Android 模拟器与 SDK 镜像治理"

    /// AVD 数据目录根。默认 `~/.android/avd`；`$ANDROID_AVD_HOME` 是官方重定位开关
    /// （`avdmanager` 实测认它，见 `Selftest+AndroidEmulatorDeep` 的 4f 用例），
    /// 旧机器上还有 `$ANDROID_SDK_HOME/.android/avd` 这一层。
    /// **重定位到主目录外时本模块只列示、不删**——不新增主目录外的可删根，删除会被主目录护栏
    /// 拒掉并把原因带回结论里。
    /// 环境变量里的**相对值一律不收**：`CleanPaths.expand` 只展开 `~`，相对路径经 `normalizePath`
    /// 会变成 `/avd` 这种没人请求的绝对根（`defaultSDKRoots` 同一个理由）。
    static var defaultAVDRoot: String {
        let env = ProcessInfo.processInfo.environment
        if let v = env["ANDROID_AVD_HOME"], !v.isEmpty, v.hasPrefix("/") || v.hasPrefix("~") {
            return v
        }
        if let v = env["ANDROID_SDK_HOME"], !v.isEmpty, v.hasPrefix("/") || v.hasPrefix("~") {
            return (v as NSString).appendingPathComponent(".android/avd")
        }
        return "~/.android/avd"
    }

    /// SDK 根候选 —— 仅用于"image.sysdir.1 指向的镜像还在不在"这一**判据**，不作为删除根。
    /// 环境变量给的相对路径一律不收：拼出来的镜像路径会指向别处，把健康 AVD 误报成「镜像已删」。
    static var defaultSDKRoots: [String] {
        var roots = ["~/Library/Android/sdk"]
        for env in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            guard let v = ProcessInfo.processInfo.environment[env], !v.isEmpty else { continue }
            if v.hasPrefix("/") { roots.append(v) }
        }
        return roots
    }

    // MARK: - 扫描

    /// 扫描。
    /// - Parameters:
    ///   - customAVDRoot: 自检用注入点。传 nil 用默认。传了自定义路径 → 只在自检里出现，
    ///     **产品代码不会走到**（卡片只 `scan()` 无参）。
    ///   - customSDKRoots: 同上，喂给镜像判据。
    func scan(customAVDRoot: String? = nil,
              customSDKRoots: [String]? = nil) -> AndroidEmulatorSummary {
        let fm = FileManager.default
        let avdRoot = FileSystem.normalizePath(
            CleanPaths.expand(customAVDRoot ?? Self.defaultAVDRoot))
        var issues: [GovernanceEvidenceIssue] = []

        // SDK 根**必须既存在又可打开**才交给镜像判据：只判 `fileExists` 的话，一个存在但列不出
        // 来的 SDK 根会让每个 `image.sysdir.1` 都查不到，于是每台健康 AVD 都被写成
        // 「底层系统镜像已被删，AVD 起不来」——这是把"没看到"报成"没了"（G9 一路在消灭的形状），
        // 而且恰好落在最劝人删除的那一档上。
        // 用三态的 `probeDirectory` 而不是 `isPermissionDenied`：后者把 `.deferred`
        // （在途额度满 / 同路径正被别的线程读，**根本没去 open**）折成"不是权限问题"而放行，
        // 那条根随后照样让每个镜像都查不到，绕回同一个谎报。
        var sdkRoots: [String] = []
        for raw in (customSDKRoots ?? Self.defaultSDKRoots) {
            let root = FileSystem.normalizePath(CleanPaths.expand(raw))
            guard fm.fileExists(atPath: root) else { continue }
            switch FileSystem.probeDirectory(root) {
            case .readable:
                sdkRoots.append(root)
            case .unreadable:
                issues.append(GovernanceEvidenceIssue(kind: .permissionDenied, subject: root,
                    message: "SDK 根读不到，镜像存在性判据本轮未生效：\(root)"))
            case .deferred:
                issues.append(GovernanceEvidenceIssue(kind: .unreadable, subject: root,
                    message: "SDK 根本轮没有去打开（并发额度已满），镜像判据未生效：\(root)"))
            }
        }
        // 有候选根但一个都不可用 → `sdkRoots` 为空 → 镜像判据整体不生效，每条落「证据不足」；
        // 上面已逐条记 issue，`isResultComplete` 跟着翻假。

        // 根是否落在网关的常规放行面里（主目录 / `/tmp` / `/var/tmp`，判据与网关同表）。
        // 不在这里 → 本模块一条都不删，而且**界面不许把它默勾、卡片也不给勾选框**：
        // 「只列示、不删」必须是行为，不只是文案（v1.73.10 三次复审 P1-2：原来只有
        // `customAVDRoot == nil` 时才记 issue，而 `isSelected` 里根本没有这一项，
        // 于是 `/Volumes/...` 下的条目照样默认勾上、按钮照样可点）。
        let rootDeletable = FileSystem.isWithinGuardedRoot(FileSystem.normalizePath(avdRoot))
        if !rootDeletable {
            issues.append(GovernanceEvidenceIssue(kind: .unreadable, subject: avdRoot,
                message: "AVD 根不在网关的常规放行面内（主目录与两个临时目录之外，如 `$ANDROID_AVD_HOME` "
                    + "指向外接盘），本模块不新增可删根：以下条目只列示，一条都不勾、也不会删除"))
        }

        // 1) 先探 AVD 根：不存在 = 本机没装过 Android 模拟器（正常）；存在但读不到 = 盲区。
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: avdRoot, isDirectory: &isDir), isDir.boolValue else {
            // `issues` 必须原样带出去：上面可能已经记了"某个 SDK 根读不到""根在主目录外只列示"，
            // 这里回一个空 issues 就等于把那些证据丢掉、把面板渲染成"结果完整且这里没有孤儿"。
            return AndroidEmulatorSummary(items: [],
                                          orphanCount: 0, orphanSize: 0,
                                          brokenImageCount: 0, liveCount: 0, issues: issues,
                                          avdRoot: avdRoot, detectedSDKRoots: sdkRoots)
        }
        if FileSystem.isPermissionDenied(avdRoot) {
            // 读不到 ≠ 没有孤儿。记一笔进 issues，`isResultComplete` 会跟着翻假；卡片必须显示
            // "本轮没读到"，不是"这台机器没有可清理的 AVD"。
            issues.append(GovernanceEvidenceIssue(kind: .permissionDenied, subject: avdRoot,
                message: "AVD 根目录权限不足，当前用户读不到：\(avdRoot)"))
            return AndroidEmulatorSummary(items: [],
                                          orphanCount: 0, orphanSize: 0,
                                          brokenImageCount: 0, liveCount: 0, issues: issues,
                                          avdRoot: avdRoot, detectedSDKRoots: sdkRoots)
        }

        // 2) 顶层一次性列（`enumerator(at:)` + `errorHandler` + `recordDeniedAccess`；
        //    本文件已登记进 G18 lint 的 `mustBeThere`——被摘掉 errorHandler 就判红）。
        let avdURL = URL(fileURLWithPath: avdRoot, isDirectory: true)
        let blocked = FileSystem.WalkBlockFlag()
        guard let en = fm.enumerator(
            at: avdURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { url, error in
                FileSystem.recordDeniedAccess(url, error: error)
                blocked.set()
                return true
            }
        ) else {
            issues.append(GovernanceEvidenceIssue(kind: .unreadable, subject: avdRoot,
                message: "无法枚举 AVD 根目录：\(avdRoot)"))
            return AndroidEmulatorSummary(items: [],
                                          orphanCount: 0, orphanSize: 0,
                                          brokenImageCount: 0, liveCount: 0, issues: issues,
                                          avdRoot: avdRoot, detectedSDKRoots: sdkRoots)
        }

        var avdDirs: [String] = []
        var iniPaths: [String] = []
        var unjudgedEntries: [String] = []
        // 看得见 `.ini` 这个条目、却没能把它交给 `referencedAVDDirs` 的次数。
        // 每一份没被清算的描述符都必须否决"孤儿"确证：它可能正指向下面任意一棵目录。
        var unaccountedDescriptors = 0
        for case let url as URL in en {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            let name = url.lastPathComponent
            if name.hasSuffix(".ini") {
                // 只有"确认是个普通文件"才去解析内容；`values == nil`（列举与 stat 之间被删、
                // IO 错误）与"`.ini` 其实是指向目录的软链"都算**没清算**，不能静默当它不存在。
                if values?.isDirectory == false {
                    iniPaths.append(url.path)
                } else {
                    unaccountedDescriptors += 1
                    unjudgedEntries.append(name)
                }
            } else if name.hasSuffix(".avd") {
                if values?.isDirectory == true {
                    avdDirs.append(url.path)
                } else {
                    // `.avd` 但不是真目录：`isDirectory` 对**指向目录的软链**返回 false（实测），
                    // 而把 AVD 数据放到另一块盘正是 Google 文档里的常规做法。这一类既不判孤儿也不
                    // 判健康——静默跳过会让面板说"未发现孤儿 AVD"而它压根没看这一条。
                    unjudgedEntries.append(name)
                }
            }
        }

        // 3) 孤儿判据：**描述符的 `path=` 指向谁**，不是"有没有同名 .ini"。
        //    `avdmanager list avd` 实测按 ini 内容定位数据目录（描述符名与目录名可以不同），
        //    所以一个被别的名字的 ini 指向的 `.avd` 是**活的**，按文件名配对会把它误判孤儿。
        let pairing = Self.referencedAVDDirs(iniPaths: iniPaths)
        let unreadableDescriptorCount = pairing.unreadableInis.count + unaccountedDescriptors
        if unreadableDescriptorCount > 0 {
            // 有一份描述符没被清算（读不出来 / 没能判定它是文件），就没人能被**确证**为孤儿：
            // 它可能正指向下面任意一棵目录。
            issues.append(GovernanceEvidenceIssue(kind: .unreadable, subject: avdRoot,
                message: "有 \(unreadableDescriptorCount) 个 .ini 描述符本轮没能清算，"
                    + "无法确证任何一棵 AVD 是孤儿"))
        }

        // 4) 逐条判 AVD。SDK 根的镜像存在性用 `FileManager.fileExists`（跟随软链）——镜像目录
        //    在 SDK 内部，不是软链跳板；判据只需要"存在/不存在"，不需要枚举其内容。
        var items: [AndroidEmulatorItem] = []
        var orphanCount = 0, orphanSize: Int64 = 0
        var brokenImageCount = 0, liveCount = 0
        // 「描述符全清算了吗」必须同时看两件事：① 看得见却没读出来的 `.ini`；② **顶层枚举
        // 中途被拦**——被拦时那份 `.ini` 连"条目"都没交给我们，它指向哪棵目录完全未知，
        // 却不会出现在 ① 的计数里（三次复审 P1-1：原来只看 ①，于是活着的另一棵 AVD
        // 会被确证成孤儿并**默认勾选**，正好违反本文件自订的「每份未清算描述符都否决孤儿」）。
        let descriptorsCertain = Self.descriptorsCertain(
            unreadableDescriptors: pairing.unreadableInis.count + unaccountedDescriptors,
            topEnumerationBlocked: blocked.value)
        for avdPath in avdDirs.sorted() {
            let avdName = ((avdPath as NSString).lastPathComponent as NSString).deletingPathExtension
            let referenced = pairing.dirs.contains(FileSystem.normalizePath(avdPath))
            let configIni = Self.readConfigIni(avdPath: avdPath)
            var imagePresent: Bool? = nil
            if case .value(let rel) = configIni, !sdkRoots.isEmpty {
                // 相对路径拼到每一个候选 SDK 根下试；任一命中就算在。
                let relTrimmed = rel.hasSuffix("/") ? String(rel.dropLast()) : rel
                imagePresent = sdkRoots.contains { root in
                    fm.fileExists(atPath: (root as NSString).appendingPathComponent(relTrimmed))
                }
            }
            let verdict = Self.evaluateAVD(referencedByDescriptor: referenced,
                                           descriptorsCertain: descriptorsCertain,
                                           configIni: configIni,
                                           imagePresent: imagePresent,
                                           sdkRootsKnown: !sdkRoots.isEmpty)

            // 求体积走共享的 `FileSystem.directoryStats`（R2-P2-11 收编：allocated 口径、软链不计，
            // 与删除侧实测释放量同一个数）；walker 自带的 blocked 标记记 `readable`。根级 walker
            // 与顶层枚举是**两次独立遍历**，前者读子树、后者读顶层——两次都可能被权限拦，各自记账。
            let metrics = FileSystem.directoryStats(at: avdPath)
            if !metrics.readable {
                // 残缺项的 size 只是下限。这条 issue 必须在**任何 size 判断之外**：
                // 嵌进 `if size > 0` 里就退化成"一点都没读到 = 这里没东西"（v1.73.7 P1-2 同族）。
                issues.append(GovernanceEvidenceIssue(kind: .unreadable, subject: avdPath,
                    message: "该 AVD 目录本轮未读全，体积只是下限：\(avdPath)"))
            }
            let item = AndroidEmulatorItem(
                id: avdPath,
                name: avdName,
                path: avdPath,
                kind: verdict.kind,
                status: verdict.status,
                size: metrics.size,
                readable: metrics.readable,
                imageSysdir: configIni.value,
                note: verdict.note,
                isSelected: verdict.status.isProvenOrphan && metrics.readable && rootDeletable
            )
            items.append(item)
            switch verdict.status {
            case .orphanUnused:
                orphanCount += 1
                orphanSize += metrics.size
            case .brokenImageNeedsConfirm:
                brokenImageCount += 1
            case .needsConfirmation:
                break
            case .liveHealthy:
                liveCount += 1
            }
        }
        if !unjudgedEntries.isEmpty {
            issues.append(GovernanceEvidenceIssue(kind: .unreadable, subject: avdRoot,
                message: "AVD 根下有 \(unjudgedEntries.count) 个 `.avd` 条目不是真目录"
                    + "（多为指向别处的软链），本轮既不判孤儿也不判健康：\(unjudgedEntries.prefix(3).joined(separator: ", "))"))
        }
        if blocked.value {
            // 顶层枚举被拦但没走到 permissionDenied 早退（例：中途一个子项被拒），
            // 结果同样不完整——补一条 unreadable 让 isResultComplete 翻假。
            issues.append(GovernanceEvidenceIssue(kind: .unreadable, subject: avdRoot,
                message: "AVD 根下有一个或多个子项本轮读不到：\(avdRoot)"))
        }

        return AndroidEmulatorSummary(items: items,
                                      orphanCount: orphanCount,
                                      orphanSize: orphanSize,
                                      brokenImageCount: brokenImageCount,
                                      liveCount: liveCount,
                                      issues: issues,
                                      avdRoot: avdRoot,
                                      detectedSDKRoots: sdkRoots)
    }

    // MARK: - 描述符配对（孤儿判据的地基）

    /// 读 AVD 根下所有 `*.ini` 描述符，返回**被指向的数据目录集合**（已 normalize）。
    ///
    /// 为什么必须读内容：`avdmanager` 是按 ini 里的 `path=` 定位数据目录的，描述符的文件名与
    /// 目录名**可以完全不同**（本机实测：`zz-descriptor-name.ini` 指向 `probe.avd`，
    /// `avdmanager list avd` 照样把这台 AVD 列出来）。所以"没有同名 .ini"根本不是孤儿判据——
    /// 那样会把一台活的、能开机的 AVD 默认勾上删掉。
    /// - `path=`：绝对路径，首选。
    /// - `path.rel=`：相对 `~/.android` 的路径（`avd/xxx.avd`），只在 `path=` 缺失时兜底。
    /// 读不出来的 ini 单独返回：那意味着**任意一棵目录都可能被它指向**，孤儿判据整体失效。
    /// 分行必须用 `components(separatedBy: .newlines)`，**不能**用 `split(separator: "\n")`：
    /// 后者按字素簇比对，而 `\r\n` 在 Unicode 里是**一个**字素簇，实测 `"a\r\nb".split(separator: "\n")`
    /// 返回 1 个元素（`components` 返回 3）——CRLF 写法的描述符因此整份文件都不分行，
    /// `path=` 的值会吞掉后面所有行，配对永远对不上，一台活的 AVD 被判成孤儿并默认勾选。
    /// 值本身再按 `whitespacesAndNewlines` 清洗，防住残留的 `\r`。
    /// 解析所有描述符，返回「被指向的 AVD 目录集合」与「这份描述符没能清算」的清单。
    /// 后者的每一项都会否决孤儿确证（见 `descriptorsCertain`）——猜基准会把活盘送进可删集合。
    static func referencedAVDDirs(iniPaths: [String])
        -> (dirs: Set<String>, unreadableInis: [String]) {
        var dirs: Set<String> = []
        var unreadable: [String] = []
        let androidHome = FileSystem.normalizePath(CleanPaths.expand("~/.android"))
        for ini in iniPaths {
            guard let content = try? String(contentsOfFile: ini, encoding: .utf8) else {
                unreadable.append(ini)
                continue
            }
            var abs: String? = nil
            var rel: String? = nil
            for raw in content.components(separatedBy: .newlines) {
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if line.hasPrefix("#") { continue }
                guard let eq = line.firstIndex(of: "=") else { continue }
                let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
                if value.isEmpty { continue }
                if key == "path" { abs = value }
                if key == "path.rel" { rel = value }
            }
            // `path=` 只认**绝对路径**（`~`/`~/` 先展开）。其余形态一律算"这份描述符没清算"：
            // 猜一个基准去拼（旧写法拿 avdRoot 当基准）会拼出一个永不匹配的路径，于是那棵
            // 真正被指向的 AVD 看不见描述符 → 被判成孤儿 → **默认勾选**，正是最坏的走向
            // （三次复审前一轮 P1-1：`path=~/x` 或 `path=x.avd` 都能把活盘送进可删集合）。
            // 宁可让整轮"无人可确证孤儿"并如实记 issue，也不许在这里猜。
            if let a = abs {
                let expanded = CleanPaths.expand(a)
                if expanded.hasPrefix("/") {
                    dirs.insert(FileSystem.normalizePath(expanded))
                } else {
                    unreadable.append(ini)
                }
            } else if let r = rel {
                dirs.insert(FileSystem.normalizePath(
                    (androidHome as NSString).appendingPathComponent(r)))
            } else {
                // ini 读出来了但两个键都没有：它指向哪儿未知，等价于读不出来。
                unreadable.append(ini)
            }
        }
        return (dirs, unreadable)
    }

    // MARK: - 纯判据（自检可以直接喂参数）

    /// 「本轮有没有把描述符看全」= ① 每个 `.ini` 都清算了 **且** ② 顶层枚举没被中途拦。
    ///
    /// ② 必须参与：枚举被拦时那份 `.ini` 连条目都没交出来，不会进 ① 的计数，只看 ① 就会把
    /// 「没看见的描述符」当成「不存在」，进而把活着的 AVD 确证成孤儿并默认勾选（三次复审 P1-1）。
    /// 抽成纯函数是因为**本机造不出「顶层枚举中途被拒」的目录**（`skipsSubdirectoryDescendants`
    /// 下 chmod 某个子目录只会拦到那棵子树），行为侧无从复现——判据落地成函数才有执法点。
    static func descriptorsCertain(unreadableDescriptors: Int, topEnumerationBlocked: Bool) -> Bool {
        unreadableDescriptors == 0 && topEnumerationBlocked == false
    }

    /// 判据核心：有没有描述符**指向**这棵 `.avd` + `image.sysdir.1` 是否在 SDK 根下存在。
    /// 四条互斥状态：
    ///  - 没有任何描述符指向它（且所有描述符都读出来了）→ `.orphanUnused`，唯一默认可删档；
    ///  - 有描述符指向、SDK 根可读、镜像不在 → `.brokenImageNeedsConfirm`：**不默认勾选**，
    ///    镜像被 `sdkmanager` 删过不代表用户想丢数据盘；
    ///  - 有描述符指向、镜像在 → `.liveHealthy`；
    ///  - 其余（描述符读不出来 / SDK 根未知或读不到 / config.ini 读不出来或缺字段）→ `.needsConfirmation`。
    ///
    /// `configIni` 用三态的 `AndroidConfigIniReading`（v1.73.10 待议 #3）：config **读不出来**
    /// 与**未写明**是两种不同的"证据不足"，note 必须各说各的——但两者的处置完全一致：
    /// 都落 `.needsConfirmation`、都不可默勾。三态化只分化文案，不翻任何一档的状态。

    static func evaluateAVD(referencedByDescriptor: Bool,
                            descriptorsCertain: Bool,
                            configIni: AndroidConfigIniReading,
                            imagePresent: Bool?,
                            sdkRootsKnown: Bool)
        -> (kind: AndroidEmulatorKind, status: AndroidEmulatorStatus, note: String?) {
        if referencedByDescriptor {
            // 有描述符指向 = 这台 AVD 仍然被工具链认到，往下走镜像判据。
        } else if !descriptorsCertain {
            return (.liveAVD, .needsConfirmation,
                    "有 .ini 描述符本轮读不出来，无法确证该目录未被任何描述符指向")
        } else {
            return (.orphanAVD, .orphanUnused,
                    "没有任何 .ini 描述符的 path= 指向该目录，Android Studio/avdmanager 已认不到它")
        }
        if !sdkRootsKnown {
            // 本机没有可用（存在且可读）的 SDK 根——镜像存在性判据无法生效。这条不该被误报为
            // "健康"，更不该被报成"镜像已删"。
            return (.liveAVD, .needsConfirmation,
                    "未检测到可读的 Android SDK 根（`~/Library/Android/sdk` 或 $ANDROID_HOME），镜像判据未生效")
        }
        switch configIni {
        case .keyMissing:
            // `.avd/config.ini` 读出来了但没写 image.sysdir.1：可能是老式 AVD 或 config 残缺，
            // 不下"健康"结论——这是判据失效而不是数据健康。
            return (.liveAVD, .needsConfirmation,
                    "config.ini 未写明 image.sysdir.1，无法判定镜像存在性")
        case .unreadable:
            // config.ini 本身读不出来：镜像存在性这一眼根本没看成，与"看过了、没写"不是一回事，
            // 文案必须分开说。处置与 keyMissing 完全一致：证据不足、不默勾。
            return (.liveAVD, .needsConfirmation,
                    "config.ini 读不出来，无法判定镜像存在性")
        case .value(let sysdir):
            switch imagePresent {
            case .some(true):
                return (.liveAVD, .liveHealthy, nil)
            case .some(false):
                return (.brokenImageAVD, .brokenImageNeedsConfirm,
                        "image.sysdir.1 = \(sysdir) 在 SDK 根下不存在（底层系统镜像已被删，AVD 起不来）")
            case .none:
                return (.liveAVD, .needsConfirmation, "镜像存在性未判定")
            }
        }
    }

    // MARK: - config.ini 解析（只取 image.sysdir.1 一条键）

    /// 读 `.avd/config.ini` 的 `image.sysdir.1`，返回三态（见 `AndroidConfigIniReading`）。
    /// 分行必须用 `components(separatedBy: .newlines)`，**不能**用 `split(separator: "\n")`：
    /// 后者按字素簇比对，CRLF 文件整份不分行（同 `referencedAVDDirs` 的教训，见那边的注释）。
    /// 空值（`image.sysdir.1=` 后面什么都没有）按 `.keyMissing` 处理：看到的那一行里没有证据。
    static func readConfigIni(avdPath: String) -> AndroidConfigIniReading {
        let path = (avdPath as NSString).appendingPathComponent("config.ini")
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
            // 文件不存在 / 权限不足 / IO 错误：这一眼没看成，不是"没写"。
            return .unreadable
        }
        for raw in content.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[line.startIndex..<eq].trimmingCharacters(in: .whitespacesAndNewlines)
            if key == "image.sysdir.1" {
                let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespacesAndNewlines)
                return value.isEmpty ? .keyMissing : .value(value)
            }
        }
        return .keyMissing
    }

    // MARK: - 网关路由

    /// 本模块**恒不**给删除目标挂治理域：目标只该是主目录内的 `.avd`，走 `governanceVerdictWithinHome`。
    /// 这里刻意**不**转发 `GovernanceDomain.domain(forPath:)`——那个解析器会跟随软链并按最长根
    /// 匹配，于是 `$ANDROID_AVD_HOME` 指到 `/Library/Fonts/…` 下、或 `~/.android` 被软链到别的卷时，
    /// 本模块的删除请求会**借用别的模块登记的域**去裁决，绕开"本模块不新增主目录外可删根"这条声明。
    /// 返回 `nil` 对主目录内路径行为完全一致，对外部路径则是严格更安全的拒绝。
    static func domain(forPath path: String) -> GovernanceDomain? {
        nil
    }

    @discardableResult
    func clean(
        items: [AndroidEmulatorItem],
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: AndroidEmulatorScanner.historyCategory)
    ) -> ResidueDeletionGate.Outcome {
        var candidates: [ResidueDeletionGate.Candidate] = []
        var origin: [String: AndroidEmulatorItem] = [:]
        var blocked: [ResidueDeletionGate.Rejection] = []
        for item in items {
            let targets = item.deletionTargets.filter { !$0.isEmpty }
            // `deletionTargets` 已经把非孤儿挡在删除管道**之外**（安全侧优先：健康 AVD 的路径
            // 压根不进网关），但拒绝必须照样带进结论——否则调用方塞进健康项时表现为
            // 「什么都没发生」，把没去删和删失败折成同一个沉默。
            if targets.isEmpty {
                blocked.append(.make(name: item.name, path: item.path, reason: .notDeletable,
                                     message: "研判结论为「\(item.status.rawValue)」，不是确证的孤儿，未删除"))
                continue
            }
            // 根不在常规放行面（`scan()` 里同一条判据决定"只列示"）时，这里必须**当面拒绝**并说清
            // 原因，而不是把条目交给网关让它默默拒掉（三次复审 P1-2：界面承诺与行为要一致，
            // 而且 `/tmp` 其实是放行根，判据只能来自 `FileSystem.isWithinGuardedRoot`，不能手抄路径表）。
            if !FileSystem.isWithinGuardedRoot(FileSystem.normalizePath(item.path)) {
                blocked.append(.make(name: item.name, path: item.path, reason: .notDeletable,
                                     message: "该条目不在网关的常规放行面（主目录与两个临时目录）内，未删除"))
                continue
            }
            for target in targets {
                candidates.append(ResidueDeletionGate.Candidate(
                    item.name, path: target, domain: Self.domain(forPath: target)))
                origin[target] = item
            }
        }
        return ResidueDeletionGate.Outcome(rejected: blocked).merging(
            ResidueDeletionGate.execute(candidates, toTrash: toTrash, journal: journal) { cand in
                // 与上面 blocked 分支同判据，兜的是「调用方直接拿候选路径进来、绕过了 items」
                // 这类伪造：status 不是孤儿就不许删。
                guard let item = origin[cand.path] else {
                    return .make(cand, reason: .notDeletable, message: "该路径不在本轮选定清单里，未删除")
                }
                guard item.status.isProvenOrphan else {
                    return .make(cand, reason: .notDeletable,
                                 message: "研判结论为「\(item.status.rawValue)」，不是确证的孤儿，未删除")
                }
                guard FileSystem.isWithinGuardedRoot(FileSystem.normalizePath(cand.path)) else {
                    return .make(cand, reason: .notDeletable,
                                 message: "该路径不在常规放行面（主目录与两个临时目录）内，未删除")
                }
                return nil
            })
    }

    // MARK: - 目录指标 walker

    // （无本地实现）v1.73.10 复审 R2-P2-11：本模块此前自带的递归求体积 walker 是全仓第 5 份
    // 重复实现，且口径（`fileSize` 逻辑字节、不跳软链）与删除侧实测释放量不一致——已收编为
    // 对 `FileSystem.directoryStats(at:)` 的直接调用（见 `scan` 的逐条循环），本文件不再保留
    // 任何 enumerator 求体积代码。口径：allocated 字节、软链计 0、`WalkBlockFlag` 记 `readable`。
}
