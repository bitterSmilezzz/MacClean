import Foundation
import Darwin

// MARK: - 应用程序多语言本地化资源包瘦身深度自检 (v1.60.0 / v1.74.0 加固)

extension Selftest {
    static func suiteAppLocalizationDeep() {
        print("--- [Suite] 应用程序多语言本地化资源包瘦身深度治理 (v1.60.0) ---")

        // 1. 语言代码保护判定不变量
        check("AppLocalization: 核心母语与基础资源受保护判定") {
            // 语言列表显式注入：这条断言不能随真机语言设置翻转
            let saved = LocalizationHelper.preferredLanguagesOverride
            defer { LocalizationHelper.preferredLanguagesOverride = saved }
            LocalizationHelper.preferredLanguagesOverride = ["zh-Hans-CN", "en"]

            let protectedCases = [
                "base", "Base", "Base.lproj",
                "zh", "zh-Hans", "zh-Hant", "zh_CN", "zh_TW", "zh_HK", "zh-CN.lproj",
                "en", "en-US", "en-GB", "en_US", "en.lproj"
            ]
            for code in protectedCases {
                guard LocalizationHelper.isProtected(code: code) else {
                    print("    ❌ 未能正确保护语言代码: \(code)")
                    return false
                }
            }

            let nonProtectedCases = [
                "fr", "de", "ja", "ko", "es", "ru", "ar", "it", "pt", "nl", "fr.lproj"
            ]
            for code in nonProtectedCases {
                guard !LocalizationHelper.isProtected(code: code) else {
                    print("    ❌ 误保护了外语代码: \(code)")
                    return false
                }
            }

            // v1.74.0：母语 / AppleLanguages 首项及其地区变体一律坚决保护
            LocalizationHelper.preferredLanguagesOverride = ["ja-JP", "fr-CA"]
            for code in ["ja", "ja.lproj", "ja-JP", "fr", "fr-FR"] {
                guard LocalizationHelper.isProtected(code: code) else {
                    print("    ❌ 用户母语 \(code) 未受保护")
                    return false
                }
            }
            guard !LocalizationHelper.isProtected(code: "de") else { return false }

            // 语言列表读不到 → 归一化后为空，扫描阶段据此降级为"证据不足"
            LocalizationHelper.preferredLanguagesOverride = []
            guard LocalizationHelper.preferredLanguageCodes().isEmpty else { return false }
            return true
        }

        // 2. 语言代码名称映射与国际化显示
        check("AppLocalization: 常用语言代码友好名称映射解析") {
            let frName = LocalizationHelper.displayName(for: "fr")
            guard frName.contains("法语") || frName.contains("French") else { return false }

            let deName = LocalizationHelper.displayName(for: "de")
            guard deName.contains("德语") || deName.contains("German") else { return false }

            let zhHansName = LocalizationHelper.displayName(for: "zh-Hans.lproj")
            guard zhHansName.contains("简体中文") else { return false }

            let baseName = LocalizationHelper.displayName(for: "Base.lproj")
            guard baseName.contains("基础界面") || baseName.contains("Base") else { return false }

            return true
        }

        // 3. 模型可瘦身空间与数量精算
        check("AppLocalization: 模型统计与释放潜力精算") {
            let p1 = LanguagePackItem(id: "/app/zh.lproj", code: "zh", displayName: "中文", path: "/app/zh.lproj", size: 1000, isProtected: true, isSelected: false)
            let p2 = LanguagePackItem(id: "/app/en.lproj", code: "en", displayName: "英文", path: "/app/en.lproj", size: 2000, isProtected: true, isSelected: false)
            let p3 = LanguagePackItem(id: "/app/fr.lproj", code: "fr", displayName: "法文", path: "/app/fr.lproj", size: 3000, isProtected: false, isSelected: true)
            let p4 = LanguagePackItem(id: "/app/de.lproj", code: "de", displayName: "德文", path: "/app/de.lproj", size: 4000, isProtected: false, isSelected: false)

            let bundle = AppLocalizationBundle(
                id: "/app",
                appName: "TestApp",
                bundleID: "com.test.app",
                appPath: "/Applications/TestApp.app",
                appTotalSize: 50000,
                languagePacks: [p1, p2, p3, p4]
            )

            guard bundle.totalPackCount == 4 else { return false }
            guard bundle.protectedPackCount == 2 else { return false }
            guard bundle.removablePackCount == 2 else { return false }
            guard bundle.selectedPackCount == 1 else { return false }
            guard bundle.reclaimableSize == 3000 else { return false }
            guard bundle.totalReclaimablePotential == 7000 else { return false }

            return true
        }

        // 4. 系统应用与越界安全防护
        check("AppLocalization: 系统目录与受保护语言防线校验") {
            // 系统应用绝对不扫描
            let sysBundle = AppLocalizationScanner.inspectAppBundle(at: "/System/Applications/Calculator.app")
            guard sysBundle == nil else { return false }

            // 越界清理拦截
            let fakeBundle = AppLocalizationBundle(
                id: "/System/Applications/Test.app",
                appName: "SysTest",
                bundleID: "com.apple.test",
                appPath: "/System/Applications/Test.app",
                appTotalSize: 1000,
                languagePacks: [
                    LanguagePackItem(id: "/System/Applications/Test.app/Contents/Resources/fr.lproj", code: "fr", displayName: "法语", path: "/System/Applications/Test.app/Contents/Resources/fr.lproj", size: 100, isProtected: false, isSelected: true)
                ]
            )
            let cleanRes = AppLocalizationScanner.clean(bundle: fakeBundle, selectedItemIDs: ["/System/Applications/Test.app/Contents/Resources/fr.lproj"], permanently: false)
            guard cleanRes.cleanedCount == 0 && cleanRes.errorCount > 0 else { return false }

            return true
        }

        // 5. 模拟应用 Bundle 资源目录扫描
        check("AppLocalization: 模拟应用 Bundle 语言包扫描与识别") {
            let fm = FileManager.default
            let testAppPath = "/tmp/MacCleanTest_Localization_App.app"
            let resPath = (testAppPath as NSString).appendingPathComponent("Contents/Resources")
            let infoPlistPath = (testAppPath as NSString).appendingPathComponent("Contents/Info.plist")

            // 清理旧目录并创建
            try? fm.removeItem(atPath: testAppPath)
            try? fm.createDirectory(atPath: resPath, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testAppPath) }

            // 写入 Info.plist
            let infoDict: [String: Any] = [
                "CFBundleDisplayName": "LocalizationTestApp",
                "CFBundleIdentifier": "com.macclean.test.localization"
            ]
            (infoDict as NSDictionary).write(toFile: infoPlistPath, atomically: true)

            // 创建若干 .lproj 目录与假文件
            let lprojs = ["Base.lproj", "zh-Hans.lproj", "en.lproj", "fr.lproj", "de.lproj", "ja.lproj"]
            for lproj in lprojs {
                let dir = (resPath as NSString).appendingPathComponent(lproj)
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let dummyFile = (dir as NSString).appendingPathComponent("Localizable.strings")
                try? "key = value;".data(using: .utf8)?.write(to: URL(fileURLWithPath: dummyFile))
            }

            guard let inspected = AppLocalizationScanner.inspectAppBundle(
                at: testAppPath, languages: ["zh-Hans", "en"]) else {
                print("    ❌ 未能扫描到模拟应用")
                return false
            }

            guard inspected.appName == "LocalizationTestApp" else { return false }
            guard inspected.bundleID == "com.macclean.test.localization" else { return false }
            guard inspected.totalPackCount == 6 else { return false }
            guard inspected.protectedPackCount == 3 else { return false } // Base, zh-Hans, en
            guard inspected.removablePackCount == 3 else { return false } // fr, de, ja
            // v1.74.0：扫出来一个都不许勾（删包内资源=破坏签名密封，决定权只能在用户）
            guard inspected.selectedPackCount == 0 else {
                print("    ❌ 语言包被默认勾选")
                return false
            }
            for pack in inspected.languagePacks {
                guard pack.isSelected == false else { return false }
                if pack.isProtected {
                    guard pack.protectionReason?.isEmpty == false else {
                        print("    ❌ 受保护语言包没有给出原因")
                        return false
                    }
                } else {
                    // 可删项也必须把代价说清楚
                    guard pack.deletionRisk.contains("签名") else { return false }
                }
            }
            return true
        }

        // 6. 模拟瘦身清理执行与保护不变量
        check("AppLocalization: 模拟瘦身执行与保护语言防误删验证") {
            let fm = FileManager.default
            let testAppPath = "/tmp/MacCleanTest_Localization_Clean.app"
            let resPath = (testAppPath as NSString).appendingPathComponent("Contents/Resources")
            let infoPlistPath = (testAppPath as NSString).appendingPathComponent("Contents/Info.plist")

            try? fm.removeItem(atPath: testAppPath)
            try? fm.createDirectory(atPath: resPath, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testAppPath) }

            let infoDict: [String: Any] = [
                "CFBundleDisplayName": "CleanTestApp",
                "CFBundleIdentifier": "com.macclean.test.clean"
            ]
            (infoDict as NSDictionary).write(toFile: infoPlistPath, atomically: true)

            let lprojs = ["zh-Hans.lproj", "en.lproj", "fr.lproj", "ru.lproj"]
            for lproj in lprojs {
                let dir = (resPath as NSString).appendingPathComponent(lproj)
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let dummyFile = (dir as NSString).appendingPathComponent("Strings.strings")
                try? "content".data(using: .utf8)?.write(to: URL(fileURLWithPath: dummyFile))
            }

            guard let inspected = AppLocalizationScanner.inspectAppBundle(
                at: testAppPath, languages: ["zh-Hans", "en"]) else {
                return false
            }

            // 尝试同时传入保护语言（zh-Hans）和非保护语言（fr, ru）进行清理
            let zhPath = (resPath as NSString).appendingPathComponent("zh-Hans.lproj")
            let frPath = (resPath as NSString).appendingPathComponent("fr.lproj")
            let ruPath = (resPath as NSString).appendingPathComponent("ru.lproj")
            let targetIDs: Set<String> = [zhPath, frPath, ruPath]

            // 执行彻底删除测试
            let result = AppLocalizationScanner.clean(bundle: inspected, selectedItemIDs: targetIDs,
                                                      permanently: true, journal: .none)

            // zh-Hans 必须被保护防线挡下：不计入清理，且**如实报为被拒**（旧实现是静默跳过）
            guard result.cleanedCount == 2 else {
                print("    ❌ 清理数量不符，期望 2，实际 \(result.cleanedCount)")
                return false
            }
            guard result.errorCount == 1 else {
                print("    ❌ 受保护语言包未被显式拒绝，而是静默跳过：\(result.errorCount)")
                return false
            }

            // 物理磁盘检验：zh-Hans 依然存在，fr 与 ru 已被删除
            guard fm.fileExists(atPath: zhPath) else {
                print("    ❌ 严重错误：受保护语言 zh-Hans 被误删！")
                return false
            }
            guard !fm.fileExists(atPath: frPath) && !fm.fileExists(atPath: ruPath) else {
                print("    ❌ 外语包未被彻底删除")
                return false
            }

            return true
        }

        // 7. 治理域接线：授权只覆盖包内资源，永远删不到 .app 本体
        check("AppLocalization: 治理域深度判定永删不到 App 本体") {
            // 域根与其下 1~3 层（App 本体、Contents、Resources）都必须被域拒绝
            for shallow in [
                "/Applications",
                "/Applications/SelftestFake.app",
                "/Applications/SelftestFake.app/Contents",
                "/Applications/SelftestFake.app/Contents/Resources",
            ] {
                let verdict = FileSystem.governanceVerdict(shallow, domain: .appLocalizedResources)
                guard case .rejected(let reason) = verdict, reason == .tooShallowForDomain else {
                    print("    ❌ 层级过浅的路径未被域拒绝：\(shallow) → \(verdict)")
                    return false
                }
            }
            // 别人家 App 的资源不在本模块授权范围内时也不能被"顺路"放行
            guard FileSystem.governanceVerdict("/Library/Fonts/x.lproj",
                                               domain: .appLocalizedResources).message
                .contains("不在任何已登记的治理域") else { return false }

            // 条目的域归属：/Applications 下走包内资源域，自检 fixture 走主目录护栏
            let inApplications = LanguagePackItem(
                id: "/Applications/Foo.app/Contents/Resources/fr.lproj", code: "fr",
                displayName: "法语", path: "/Applications/Foo.app/Contents/Resources/fr.lproj",
                size: 1, isProtected: false)
            guard inApplications.governanceDomain == .appLocalizedResources else { return false }
            let inTemp = LanguagePackItem(
                id: "/tmp/Foo.app/Contents/Resources/fr.lproj", code: "fr",
                displayName: "法语", path: "/tmp/Foo.app/Contents/Resources/fr.lproj",
                size: 1, isProtected: false)
            guard inTemp.governanceDomain == nil else { return false }

            // 把"语言包"伪造成 App 本体：模块自己的清理入口也必须拒掉，且不许碰文件
            let bodyBundle = AppLocalizationBundle(
                id: "/Applications/SelftestFake.app", appName: "SelftestFake",
                bundleID: "com.macclean.selftest.fake",
                appPath: "/Applications/SelftestFake.app", appTotalSize: 1,
                languagePacks: [LanguagePackItem(
                    id: "/Applications/SelftestFake.app", code: "fr", displayName: "法语",
                    path: "/Applications/SelftestFake.app", size: 1, isProtected: false)])
            let res = AppLocalizationScanner.cleanOutcome(
                bundle: bodyBundle, selectedItemIDs: ["/Applications/SelftestFake.app"],
                permanently: true, journal: .none, languages: ["zh-Hans", "en"],
                inventory: localizationSelftestInventory())
            guard res.cleanedCount == 0 && res.errorCount > 0 else {
                print("    ❌ App 本体被当成可删语言包")
                return false
            }
            guard res.rejected.first?.reason == .tooShallowForDomain else {
                print("    ❌ 拒绝原因不是「层级过浅」：\(String(describing: res.rejected.first?.reason))")
                return false
            }
            return true
        }

        // 8. 运行中的 App / Apple 官方组件绝不进入可删集合，强删也删不动
        check("AppLocalization: 运行中 App 与 com.apple 系统应用不进可删集合") {
            let fm = FileManager.default
            let base = "/tmp/MacCleanTest_Localization_Running_\(UUID().uuidString)"
            let appPath = base + "/RunningDemo.app"
            let resPath = appPath + "/Contents/Resources"
            try? fm.createDirectory(atPath: resPath, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: base) }
            let info: [String: Any] = ["CFBundleIdentifier": "com.demo.running"]
            (info as NSDictionary).write(toFile: appPath + "/Contents/Info.plist", atomically: true)
            var packPaths: [String] = []
            for lproj in ["Base.lproj", "fr.lproj", "de.lproj", "ja.lproj"] {
                try? fm.createDirectory(atPath: resPath + "/" + lproj, withIntermediateDirectories: true)
                let f = resPath + "/" + lproj + "/Localizable.strings"
                try? "x".data(using: .utf8)?.write(to: URL(fileURLWithPath: f))
                packPaths.append(resPath + "/" + lproj)
            }

            // 把该 App 的 bundle id 声明成"正在运行"（清单注入，不依赖真机在跑什么）
            let running = AppInventory.Snapshot(
                bundleIDs: ["com.demo.running"], bundlePrefixes: ["com.demo"],
                normalizedNames: [], executableNames: [],
                runningBundleIDs: ["com.demo.running"], appPaths: [appPath], unreadableRoots: [])

            guard let bundle = AppLocalizationScanner.inspectAppBundle(
                at: appPath, languages: ["zh-Hans", "en"], evidence: nil, inventory: running)
            else { return false }
            guard bundle.isRunningApp, bundle.removablePackCount == 0,
                  bundle.totalReclaimablePotential == 0 else {
                print("    ❌ 运行中的 App 仍列出了可清理语言包")
                return false
            }
            guard bundle.blockReason?.contains("正在运行") == true else { return false }
            guard bundle.isDeletionBlocked else { return false }

            // 即使调用方硬把每一项都勾上（旧版默选的行为），一个也删不掉
            let all = Set(bundle.languagePacks.map(\.id))
            let forced = AppLocalizationScanner.clean(
                bundle: bundle, selectedItemIDs: all, permanently: true, journal: .none,
                languages: ["zh-Hans", "en"], inventory: running)
            guard forced.cleanedCount == 0 else {
                print("    ❌ 运行中 App 的语言包被删除了")
                return false
            }
            guard packPaths.allSatisfy({ fm.fileExists(atPath: $0) }) else { return false }
            // 母语/Base 也在可删集合之外，且带原因
            guard bundle.languagePacks.first(where: { $0.code == "Base" })?.isProtected == true else { return false }

            // 用户母语那份资源同样进不了可删集合（这里把 ja 当母语，App 未在运行）
            let idle = localizationSelftestInventory()
            guard let native = AppLocalizationScanner.inspectAppBundle(
                at: appPath, languages: ["ja-JP"], evidence: nil, inventory: idle) else { return false }
            let jaPack = native.languagePacks.first(where: { $0.code == "ja" })
            guard native.removablePackCount == 2, jaPack?.isProtected == true else {
                print("    ❌ 母语 ja 未被坚决保留：removable=\(native.removablePackCount)")
                return false
            }
            guard jaPack?.protectionReason?.contains("母语") == true else { return false }
            guard native.languagePacks.first(where: { $0.code == "fr" })?.isProtected == false else { return false }
            // 母语那份即使被硬勾上，policy 也拦住（不依赖扫描时的 isProtected）
            let jaPath = native.languagePacks.first(where: { $0.code == "ja" })?.path
            let forcedNative = AppLocalizationScanner.clean(
                bundle: native, selectedItemIDs: [jaPath ?? ""], permanently: true, journal: .none,
                languages: ["ja-JP"], inventory: idle)
            guard forcedNative.cleanedCount == 0, fm.fileExists(atPath: resPath + "/ja.lproj") else {
                print("    ❌ 母语语言包被删除")
                return false
            }

            // Apple 官方组件：com.apple.* 一律整株阻断
            let appleInfo: [String: Any] = ["CFBundleIdentifier": "com.apple.SelftestDemo"]
            (appleInfo as NSDictionary).write(toFile: appPath + "/Contents/Info.plist", atomically: true)
            guard let appleBundle = AppLocalizationScanner.inspectAppBundle(
                at: appPath, languages: ["zh-Hans", "en"], evidence: nil, inventory: idle)
            else { return false }
            guard appleBundle.isAppleSystemApp, appleBundle.removablePackCount == 0 else {
                print("    ❌ com.apple.* 系统应用出现了可清理项")
                return false
            }
            let appleForced = AppLocalizationScanner.clean(
                bundle: appleBundle, selectedItemIDs: Set(appleBundle.languagePacks.map(\.id)),
                permanently: true, journal: .none, languages: ["zh-Hans", "en"],
                inventory: idle)
            guard appleForced.cleanedCount == 0 else { return false }

            // 读不到 bundle id 时按系统组件处理（"读不到"≠"可以删"）
            guard LocalizationHelper.isAppleSystemBundleID(nil) else { return false }
            guard LocalizationHelper.isAppleSystemBundleID("") else { return false }
            guard LocalizationHelper.isAppleSystemBundleID("com.demo.running") == false else { return false }
            return true
        }

        // 9. 证据源读不到 → 报"结果不完整"，而不是"没有外语包可清理"
        check("AppLocalization: 应用目录与语言列表读不到时报结果不完整") {
            let fm = FileManager.default
            let base = "/tmp/MacCleanTest_Localization_Denied_\(UUID().uuidString)"
            let appsRoot = base + "/Applications"
            let lockedRoot = base + "/LockedApps"
            let appPath = lockedRoot + "/SealedDemo.app"
            let resPath = appPath + "/Contents/Resources"
            let readableApp = appsRoot + "/ReadableDemo.app"
            let readableRes = readableApp + "/Contents/Resources"
            try? fm.createDirectory(atPath: resPath, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: readableRes, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: lockedRoot, withIntermediateDirectories: true)
            defer {
                chmod(lockedRoot, 0o755)
                try? fm.removeItem(atPath: base)
            }
            for app in [appPath, readableApp] {
                let info: [String: Any] = ["CFBundleDisplayName": (app as NSString).lastPathComponent
                    .replacingOccurrences(of: ".app", with: ""),
                    "CFBundleIdentifier": "com.demo.\((app as NSString).lastPathComponent)"]
                (info as NSDictionary).write(toFile: app + "/Contents/Info.plist", atomically: true)
            }
            for dir in [resPath, readableRes] {
                for lproj in ["Base.lproj", "fr.lproj", "ja.lproj"] {
                    try? fm.createDirectory(atPath: dir + "/" + lproj, withIntermediateDirectories: true)
                }
            }
            guard chmod(lockedRoot, 0o000) == 0 else {
                return true   // root 跑自检时造不出"读不到"，跳过而非误报
            }
            guard FileSystem.isPermissionDenied(lockedRoot) else { return false }

            // ① 扫描根读不到：0 项 + 一条权限问题，结论不完整
            let denied = AppLocalizationScanner.scanReport(
                directories: [lockedRoot], languages: ["zh-Hans", "en"],
                inventory: localizationSelftestInventory())
            guard denied.bundles.isEmpty else { return false }
            guard !denied.isResultComplete else {
                print("    ❌ 读不到的应用目录被当成「完整结果」")
                return false
            }
            guard denied.issues.first?.kind == .permissionDenied else { return false }
            guard denied.incompletenessBanner?.contains("不完整") == true else { return false }

            // ② 正常可读的根：结果完整、真的识别出可瘦身 App（证明 ① 不是"永远不完整"）
            let ok = AppLocalizationScanner.scanReport(
                directories: [appsRoot], languages: ["zh-Hans", "en"],
                inventory: localizationSelftestInventory())
            guard ok.isResultComplete, ok.incompletenessBanner == nil else {
                print("    ❌ 读得到的目录被报成不完整")
                return false
            }
            guard ok.bundles.count == 1, let scanned = ok.bundles.first else { return false }
            guard scanned.appName == "ReadableDemo", scanned.removablePackCount == 2 else { return false }
            guard scanned.selectedPackCount == 0 else {
                print("    ❌ 扫描结果里出现了默认勾选")
                return false
            }

            // ③ 语言列表读不到：整轮降级为"仅定位与建议"，一个可删名额都不给
            let noLang = AppLocalizationScanner.scanReport(
                directories: [appsRoot], languages: [], inventory: localizationSelftestInventory())
            guard !noLang.isResultComplete else { return false }
            guard noLang.issues.contains(where: { $0.kind == .unreadable && $0.subject.contains("语言") })
            else {
                print("    ❌ 语言列表读不到时没有留下证据源问题记录")
                return false
            }
            guard noLang.bundles.allSatisfy({ $0.removablePackCount == 0 && $0.selectedPackCount == 0 })
            else { return false }
            // 直接检查被降级的那个 App：全部语言包都是受保护态，且写着证据不足
            guard let blocked = AppLocalizationScanner.inspectAppBundle(
                at: readableApp, languages: [],
                evidence: GovernanceEvidenceIssue(kind: .unreadable, subject: "AppleLanguages",
                                                  message: "读不到本机语言列表"),
                inventory: localizationSelftestInventory()) else { return false }
            guard blocked.isDeletionBlocked, blocked.removablePackCount == 0 else { return false }
            guard blocked.languagePacks.allSatisfy({ $0.isProtected }) else { return false }
            guard blocked.evidenceNote?.contains("语言") == true else { return false }
            return true
        }

        // 10. 用户白名单与 G6 硬排除（照片图库）在本模块 policy 下必被拒
        check("AppLocalization: 白名单与照片图库路径必被清理网关拒绝") {
            let fm = FileManager.default
            let base = "/tmp/MacCleanTest_Localization_WL_\(UUID().uuidString)"
            let appPath = base + "/WLDemo.app"
            let resPath = appPath + "/Contents/Resources"
            try? fm.createDirectory(atPath: resPath, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: base) }
            let wlInfo: [String: Any] = ["CFBundleIdentifier": "com.demo.wl"]
            (wlInfo as NSDictionary).write(toFile: appPath + "/Contents/Info.plist", atomically: true)
            let wlPack = resPath + "/fr.lproj"
            let otherPack = resPath + "/de.lproj"
            for dir in [wlPack, otherPack] {
                try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
                try? "x".data(using: .utf8)?.write(to: URL(fileURLWithPath: dir + "/Localizable.strings"))
            }

            let wm = WhitelistManager.shared
            let savedRules = wm.rules
            defer { wm.rules = savedRules }
            wm.removeAllRules()
            wm.addPathRule(wlPack, comment: "自检保护")

            guard let bundle = AppLocalizationScanner.inspectAppBundle(
                at: appPath, languages: ["zh-Hans", "en"],
                inventory: localizationSelftestInventory()) else { return false }
            let res = AppLocalizationScanner.cleanOutcome(
                bundle: bundle, selectedItemIDs: [wlPack], permanently: true, journal: .none,
                languages: ["zh-Hans", "en"], inventory: localizationSelftestInventory())
            guard res.cleanedCount == 0 && res.errorCount > 0 else {
                print("    ❌ 白名单语言包被删除")
                return false
            }
            guard fm.fileExists(atPath: wlPack) else {
                print("    ❌ 白名单语言包被删除（物理）")
                return false
            }
            guard res.rejected.first?.reason == .userWhitelisted else { return false }

            // G6：照片图库是自管理容器，"藏在图库里的 .app" 也一个字节都不许碰
            let libraryApp = CleanPaths.expand("~/Pictures/Photos Library.photoslibrary")
                + "/SelftestInside.app"
            let inside = AppLocalizationBundle(
                id: libraryApp, appName: "SelftestInside", bundleID: "com.demo.inside",
                appPath: libraryApp, appTotalSize: 1,
                languagePacks: [LanguagePackItem(
                    id: libraryApp + "/Contents/Resources/fr.lproj", code: "fr",
                    displayName: "法语", path: libraryApp + "/Contents/Resources/fr.lproj",
                    size: 1, isProtected: false)])
            let g6 = AppLocalizationScanner.cleanOutcome(
                bundle: inside, selectedItemIDs: [libraryApp + "/Contents/Resources/fr.lproj"],
                permanently: true, journal: .none, languages: ["zh-Hans", "en"],
                inventory: localizationSelftestInventory())
            guard g6.cleanedCount == 0 && g6.errorCount > 0 else { return false }
            guard g6.rejected.first?.reason == .hardExcluded else {
                print("    ❌ 照片图库内的路径未被判为硬排除：\(String(describing: g6.rejected.first?.reason))")
                return false
            }
            // 上面那条清理没有"顺手"波及同 App 的其它语言包
            guard fm.fileExists(atPath: otherPack) else { return false }
            return true
        }

        // 11. 删除失败一个字节都不许记（旧实现按扫描缓存的 item.size 凭空记账）
        check("AppLocalization: 删除失败不计入 cleanedCount 与 freedBytes") {
            let fm = FileManager.default
            let base = "/tmp/MacCleanTest_Localization_Fail_\(UUID().uuidString)"
            let appPath = base + "/FailDemo.app"
            let resPath = appPath + "/Contents/Resources"
            let pack = resPath + "/fr.lproj"
            let inner = pack + "/Localizable.strings"
            try? fm.createDirectory(atPath: pack, withIntermediateDirectories: true)
            defer {
                lchflags(inner, 0)
                try? fm.removeItem(atPath: base)
            }
            let failInfo: [String: Any] = ["CFBundleIdentifier": "com.demo.fail"]
            (failInfo as NSDictionary).write(toFile: appPath + "/Contents/Info.plist", atomically: true)
            try? "payload".data(using: .utf8)?.write(to: URL(fileURLWithPath: inner))
            guard lchflags(inner, UInt32(UF_IMMUTABLE)) == 0 else { return true }

            var bundle = AppLocalizationBundle(
                id: appPath, appName: "FailDemo", bundleID: "com.demo.fail",
                appPath: appPath, appTotalSize: 1,
                languagePacks: [LanguagePackItem(
                    id: pack, code: "fr", displayName: "法语", path: pack,
                    size: 888_888, isProtected: false)])
            bundle.languagePacks[0].isSelected = true   // 用户手动勾选后的状态
            let res = AppLocalizationScanner.cleanOutcome(
                bundle: bundle, selectedItemIDs: [pack], permanently: true, journal: .none,
                languages: ["zh-Hans", "en"], inventory: localizationSelftestInventory())
            guard res.cleanedCount == 0 else {
                print("    ❌ 删除失败却计了 cleanedCount")
                return false
            }
            guard res.freedBytes == 0 else {
                print("    ❌ 删除失败却计了 freedBytes：\(res.freedBytes)")
                return false
            }
            guard res.errorCount > 0, res.failed.count == 1 else { return false }
            guard fm.fileExists(atPath: pack) else { return false }
            return true
        }
    }
}

/// 自检用的"完整可信"已安装清单：不注入的话，结论会随本机装了哪些 App 翻转。
private func localizationSelftestInventory() -> AppInventory.Snapshot {
    AppInventory.Snapshot(
        bundleIDs: ["com.apple.Safari"], bundlePrefixes: ["com.apple"],
        normalizedNames: [], executableNames: [], runningBundleIDs: [],
        appPaths: [], unreadableRoots: [])
}
