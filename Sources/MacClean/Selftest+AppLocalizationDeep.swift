import Foundation

// MARK: - 应用程序多语言本地化资源包瘦身深度自检 (v1.60.0)

extension Selftest {
    static func suiteAppLocalizationDeep() {
        print("--- [Suite] 应用程序多语言本地化资源包瘦身深度治理 (v1.60.0) ---")

        // 1. 语言代码保护判定不变量
        check("AppLocalization: 核心母语与基础资源受保护判定") {
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

            guard let inspected = AppLocalizationScanner.inspectAppBundle(at: testAppPath) else {
                print("    ❌ 未能扫描到模拟应用")
                return false
            }

            guard inspected.appName == "LocalizationTestApp" else { return false }
            guard inspected.bundleID == "com.macclean.test.localization" else { return false }
            guard inspected.totalPackCount == 6 else { return false }
            guard inspected.protectedPackCount == 3 else { return false } // Base, zh-Hans, en
            guard inspected.removablePackCount == 3 else { return false } // fr, de, ja

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

            guard let inspected = AppLocalizationScanner.inspectAppBundle(at: testAppPath) else {
                return false
            }

            // 尝试同时传入保护语言（zh-Hans）和非保护语言（fr, ru）进行清理
            let zhPath = (resPath as NSString).appendingPathComponent("zh-Hans.lproj")
            let frPath = (resPath as NSString).appendingPathComponent("fr.lproj")
            let ruPath = (resPath as NSString).appendingPathComponent("ru.lproj")
            let targetIDs: Set<String> = [zhPath, frPath, ruPath]

            // 执行彻底删除测试
            let result = AppLocalizationScanner.clean(bundle: inspected, selectedItemIDs: targetIDs, permanently: true)

            // zh-Hans 必须被保护防线直接跳过，只有 fr 和 ru 被清理
            guard result.cleanedCount == 2 else {
                print("    ❌ 清理数量不符，期望 2，实际 \(result.cleanedCount)")
                return false
            }
            guard result.errorCount == 0 else { return false }

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
    }
}
