import Foundation
import AppKit

// MARK: - 应用程序多语言本地化资源扫描与瘦身引擎 (v1.60.0 / v1.74.0 安全加固)
//
// `.lproj` 住在 App 包**内部**，删它不是"删缓存"，而是**改动了 Apple 签名过的东西**：
// `Contents/_CodeSignature/CodeResources` 以资源规则密封了包内每个文件，
// 少一个目录就等于签名被破坏 —— 之后开启 Hardened Runtime 的 App、Gatekeeper 复核、
// 以及 App 自己的自动更新都可能报"应用已损坏，无法打开"，用户只能重装或重新签名才恢复。
// 也就是说：**这个模块误删的代价是"整 App 不可用"，而不是"少点空间"**。
//
// 原实现有四处直接踩在这条代价上：
// ① `isSelected: !isProtected` —— 扫出来就默认全勾，等于把"是否愿意用签名换空间"
//    这个决定替用户做了；
// ② `clean` 自带一份 `hasPrefix("/System")` 字符串护栏，**不走网关**：
//    用户白名单、G6 硬排除、软链跳板、真实 unlink 权限全部失效，也不写历史与撤销快照；
// ③ 完全不看 App 是否在跑，也不区分 `com.apple.*` 系统组件；
// ④ `contentsOfDirectory` 用 `try?`，读不到就当"没有语言包"，语言列表也硬编码 zh/en。
//
// 现在：判定证据不足即整株阻断、绝不默选、删除一律过 `ResidueDeletionGate`，
// 并把"会破坏签名"这句话作为模型字段交给卡片逐项展示。

public enum AppLocalizationScanner {

    /// 默认扫描根（`/Applications` 与用户自己的 Applications）
    public static let defaultDirectories: [String] = [
        "/Applications",
        NSString(string: "~/Applications").expandingTildeInPath,
    ]

    /// 一轮扫描的全景结论： bundles + **读不到的证据源**。
    /// `issues` 非空即结论不完整，卡片不得渲染成"没有可清理项 / 系统很干净"。
    public struct Report: Equatable {
        public var bundles: [AppLocalizationBundle]
        public var issues: [GovernanceEvidenceIssue]

        public init(bundles: [AppLocalizationBundle] = [], issues: [GovernanceEvidenceIssue] = []) {
            self.bundles = bundles
            self.issues = issues
        }

        public var isResultComplete: Bool { issues.isEmpty }
        public var incompletenessBanner: String? {
            issues.isEmpty ? nil : GovernanceEvidenceIssue.incompleteBanner(issues)
        }
    }

    /// 扫描指定目录下的应用多语言包（兼容旧调用方：只要 bundles 列表）。
    static func scan(
        directories: [String] = defaultDirectories,
        languages: [String]? = nil,
        inventory: AppInventory.Snapshot? = nil
    ) -> [AppLocalizationBundle] {
        scanReport(directories: directories, languages: languages, inventory: inventory).bundles
    }

    /// 同上，但把"哪里没读到"一并交出来。
    static func scanReport(
        directories: [String] = defaultDirectories,
        languages: [String]? = nil,
        inventory: AppInventory.Snapshot? = nil
    ) -> Report {
        let fm = FileManager.default
        let langs = languages ?? LocalizationHelper.preferredLanguageCodes()
        let snapshot = inventory ?? AppInventory.current()
        var issues: [GovernanceEvidenceIssue] = []

        // 母语/系统语言读不到 → 无法知道哪份资源是用户看得懂的，整轮只给定位不给删除
        let languageIssue: GovernanceEvidenceIssue? = langs.isEmpty
            ? GovernanceEvidenceIssue(kind: .unreadable, subject: "AppleLanguages / 系统语言",
                                      message: "读不到本机语言与母语列表，无法判定哪份 .lproj 是你在用的语言。"
                                             + "本轮不提供任何删除建议。")
            : nil
        if let languageIssue { issues.append(languageIssue) }

        var bundles: [AppLocalizationBundle] = []

        for baseDir in directories {
            // 安全防线：绝不扫描系统目录
            if baseDir.hasPrefix("/System") { continue }

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: baseDir, isDirectory: &isDir), isDir.boolValue else {
                continue   // 根不存在（如没建过 ~/Applications）不算读失败
            }
            // 根存在但读不到：这是"结果不完整"，不是"这台机器没装 App"
            if FileSystem.isPermissionDenied(baseDir) {
                issues.append(GovernanceEvidenceIssue(
                    kind: .permissionDenied, subject: baseDir,
                    message: "应用目录权限不足，当前用户读不到：\(baseDir)"))
                continue
            }
            guard let enumerator = fm.enumerator(
                at: URL(fileURLWithPath: baseDir),
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsPackageDescendants, .skipsHiddenFiles]
            ) else {
                issues.append(GovernanceEvidenceIssue(
                    kind: .unreadable, subject: baseDir,
                    message: "无法枚举应用目录：\(baseDir)"))
                continue
            }

            while let fileURL = enumerator.nextObject() as? URL {
                guard fileURL.pathExtension == "app" else { continue }

                // 排除当前运行的 MacClean 自身
                let appName = fileURL.deletingPathExtension().lastPathComponent
                if appName == "MacClean" { continue }

                guard let inspected = inspectAppBundle(
                    at: fileURL.path, languages: langs, evidence: languageIssue, inventory: snapshot)
                else { continue }

                // 仅收录至少 1 个可清理、且总语言包数 >= 2 的应用
                if inspected.removablePackCount > 0 && inspected.totalPackCount >= 2 {
                    bundles.append(inspected)
                }
            }
        }

        return Report(
            bundles: bundles.sorted { $0.totalReclaimablePotential > $1.totalReclaimablePotential },
            issues: issues)
    }

    /// 检查指定 App 包内部的语言资源。
    ///
    /// 返回的每个 `LanguagePackItem.isProtected` 就是"本工具不许删"的结论，
    /// 阻断原因写在 `protectionReason` 里供卡片直说。
    static func inspectAppBundle(
        at appPath: String,
        languages: [String]? = nil,
        evidence: GovernanceEvidenceIssue? = nil,
        inventory: AppInventory.Snapshot? = nil
    ) -> AppLocalizationBundle? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: appPath) else { return nil }

        // 安全检查：严禁触碰 /System
        if appPath.hasPrefix("/System") { return nil }
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

        let langs = languages ?? LocalizationHelper.preferredLanguageCodes()
        let snapshot = inventory ?? AppInventory.current()
        let running = isAppRunning(appPath: appPath, bundleID: bundleID, snapshot: snapshot)
        let isAppleApp = LocalizationHelper.isAppleSystemBundleID(bundleID)

        // 整株阻断的原因（优先级：证据不足 > 运行中 > Apple 组件）
        var blockReason: String?
        var blockIsRunning = false
        var blockIsApple = false
        if let evidence {
            blockReason = evidence.message
        } else if running {
            blockReason = "应用正在运行：删除包内资源会让其立即异常"
            blockIsRunning = true
        } else if isAppleApp {
            blockReason = "Apple 官方组件（bundle id 以 com.apple. 开头），不提供包内资源清理"
            blockIsApple = true
        }
        let blocked = blockReason != nil

        // 寻找 Resources 目录下的所有 *.lproj 目录
        let items: [String]
        do {
            items = try fm.contentsOfDirectory(atPath: resourcesPath)
        } catch {
            // 读不到语言包清单 = 无法给出任何结论，不是"这个 App 没有外语包"
            return AppLocalizationBundle(
                id: appPath, appName: appName, bundleID: bundleID, appPath: appPath,
                appTotalSize: directorySize(at: appPath), languagePacks: [],
                isRunningApp: blockIsRunning, isAppleSystemApp: blockIsApple,
                evidenceNote: "语言资源目录读不到（\(resourcesPath)）：无法判断可清理项。")
        }

        var packs: [LanguagePackItem] = []
        for item in items where item.hasSuffix(".lproj") {
            let lprojPath = (resourcesPath as NSString).appendingPathComponent(item)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: lprojPath, isDirectory: &isDir), isDir.boolValue else { continue }
            // 软链指向包外即跳出授权位置：扫描阶段就不计入潜能（网关也会拒）
            if FileSystem.isSymlink(lprojPath) { continue }
            let code = LocalizationHelper.extractLanguageCode(from: item)

            let reason: String?
            if blocked {
                reason = blockReason
            } else if LocalizationHelper.isProtected(code: code, userLanguages: langs) {
                reason = LocalizationHelper.normalizeLanguage(code) == "base"
                    ? "基础界面资源（Base.lproj）：App 的默认文案，删了就没有任何界面文字"
                    : "母语 / 系统语言对应的语言资源，坚决保留"
            } else {
                reason = nil
            }

            let pack = LanguagePackItem(
                id: lprojPath,
                code: code,
                displayName: LocalizationHelper.displayName(for: code),
                path: lprojPath,
                size: directorySize(at: lprojPath),
                // 阻断时全部保护：既有 UI 只允许勾选 `!isProtected`，这样默选也进不来
                isProtected: reason != nil,
                // **绝不默认勾选**：删包内资源要用签名完整性换空间，决定权只能在用户
                isSelected: false,
                protectionReason: reason
            )
            packs.append(pack)
        }

        return AppLocalizationBundle(
            id: appPath,
            appName: appName,
            bundleID: bundleID,
            appPath: appPath,
            appTotalSize: directorySize(at: appPath),
            languagePacks: packs.sorted {
                // 排序：保护语言排前面，其余按占用大小降序
                if $0.isProtected != $1.isProtected {
                    return $0.isProtected && !$1.isProtected
                }
                return $0.size > $1.size
            },
            isRunningApp: blockIsRunning,
            isAppleSystemApp: blockIsApple,
            evidenceNote: blocked ? blockReason : nil
        )
    }

    /// App 此刻是否在运行：优先用注入过的清单（自检可造），再实测 NSWorkspace。
    static func isAppRunning(appPath: String, bundleID: String?,
                             snapshot: AppInventory.Snapshot) -> Bool {
        if let bid = bundleID?.lowercased(), !bid.isEmpty, snapshot.runningBundleIDs.contains(bid) {
            return true
        }
        let real = FileSystem.normalizePath(FileSystem.realPath(appPath))
        for app in NSWorkspace.shared.runningApplications {
            guard let url = app.bundleURL else { continue }
            if FileSystem.normalizePath(FileSystem.realPath(url.path)) == real { return true }
            if let bid = bundleID?.lowercased(), app.bundleIdentifier?.lowercased() == bid { return true }
        }
        return false
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

    // MARK: - 清理

    /// 待删候选（域名按路径归属决定：`/Applications` 下走包内资源域，其余走主目录护栏）
    static func candidates(bundle: AppLocalizationBundle, selectedItemIDs: Set<String>)
        -> [ResidueDeletionGate.Candidate] {
        bundle.languagePacks
            .filter { selectedItemIDs.contains($0.id) }
            .map { ResidueDeletionGate.Candidate($0.displayName, path: $0.path, domain: $0.governanceDomain) }
    }

    /// 执行选定语言包的清理：一律交给 `ResidueDeletionGate`。
    ///
    /// 返回逐项拒绝原因，卡片要如实展示而不是笼统一句"清理失败"。
    /// （v1.72 那批并行改动里的 `(cleanedCount, cleanedBytes, errorCount)` 元组兼容壳
    ///   已删除：生产侧只有 `Uninstaller` 在用，且它调的就是本方法。）
    @discardableResult
    static func cleanOutcome(
        bundle: AppLocalizationBundle,
        selectedItemIDs: Set<String>,
        permanently: Bool = false,
        journal: ResidueDeletionGate.Journal = .module(categoryName: "多语言资源瘦身"),
        languages: [String]? = nil,
        inventory: AppInventory.Snapshot? = nil
    ) -> ResidueDeletionGate.Outcome {
        var byPath: [String: LanguagePackItem] = [:]
        for item in bundle.languagePacks where selectedItemIDs.contains(item.id) {
            byPath[item.path] = item
        }

        let langs = languages ?? LocalizationHelper.preferredLanguageCodes()
        let snapshot = inventory ?? AppInventory.current()
        // 删除时刻重新核实在否运行 / 是否 Apple 组件：扫描缓存可能是几分钟前的状态
        let runningNow = isAppRunning(appPath: bundle.appPath, bundleID: bundle.bundleID, snapshot: snapshot)
        let appleNow = LocalizationHelper.isAppleSystemBundleID(bundle.bundleID)
        let expectedPrefix = (bundle.appPath as NSString).appendingPathComponent("Contents/Resources")

        return ResidueDeletionGate.execute(
            candidates(bundle: bundle, selectedItemIDs: selectedItemIDs),
            toTrash: !permanently,
            journal: journal,
            policy: { candidate in
                guard let item = byPath[candidate.path] else {
                    return .make(candidate, reason: .notDeletable,
                                 message: "该路径不在本轮选定的语言包清单里，未删除")
                }
                // ① 母语/系统语言/Base：坚决保护（用**实时**语言列表重算，不只看扫描缓存）
                if item.isProtected || LocalizationHelper.isProtected(code: item.code, userLanguages: langs) {
                    return .make(candidate, reason: .notDeletable,
                                 message: "「\(item.code)」是你的母语/系统语言或 Base 资源，坚决保留")
                }
                // ② 运行中的 App / Apple 官方组件
                if runningNow {
                    return .make(candidate, reason: .inUse,
                                 message: "\(bundle.appName) 正在运行：删除包内资源会让它立即异常")
                }
                if appleNow { return .make(candidate, reason: .systemProtected,
                                           message: "Apple 官方组件（com.apple.*），不提供包内资源清理") }
                // ③ 形状校验：必须是这个 App 自己 Contents/Resources 下的 .lproj 本体
                let real = FileSystem.normalizePath(FileSystem.realPath(candidate.path))
                let realPrefix = FileSystem.normalizePath(FileSystem.realPath(expectedPrefix))
                guard real.hasPrefix(realPrefix + "/"), real.hasSuffix(".lproj") else {
                    return .make(candidate, reason: .notDeletable,
                                 message: "不是该 App 自己 Contents/Resources 下的 .lproj 本体，未删除")
                }
                // ④ 只删 App 本体之下第 3 层（Contents/Resources/<x>.lproj）：
                //    层级更浅的目标可能是 App 本体或 Resources 目录自身，一律拒。
                let appReal = FileSystem.normalizePath(FileSystem.realPath(bundle.appPath))
                let depthBelowApp = real.dropFirst(appReal.count)
                    .split(separator: "/").count
                guard real.hasPrefix(appReal), depthBelowApp >= 3 else {
                    return .make(candidate, reason: .tooShallowForDomain,
                                 message: "层级过浅（可能是 App 本体或 Resources 目录自身），未删除")
                }
                return nil
            })
    }
}
