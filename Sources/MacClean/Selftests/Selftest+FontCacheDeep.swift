import Foundation
import CoreText

// MARK: - 字体缓存与孤儿系统字体残存治理深度自检 (v1.61.0 · v1.73.0 加固)

extension Selftest {
    static func suiteFontCacheDeep() {
        print("--- [Suite] 字体缓存与孤儿系统字体残存治理深度自检 (v1.61.0) ---")

        // 1. 字体格式与状态枚举判定
        check("FontCache: 字体格式解析与状态模型校验") {
            guard FontFormat.from(path: "/test/font.ttf") == .ttf else { return false }
            guard FontFormat.from(path: "/test/font.otf") == .otf else { return false }
            guard FontFormat.from(path: "/test/font.ttc") == .ttc else { return false }
            guard FontFormat.from(path: "/test/font.dfont") == .dfont else { return false }
            guard FontFormat.from(path: "/test/font.woff2") == .woff2 else { return false }
            guard FontFormat.from(path: "/test/unknown.xyz") == .other else { return false }

            let font = FontItem(
                id: "/font.ttf", fileName: "font.ttf", path: "/font.ttf", size: 2048,
                format: .ttf, familyName: "TestFont", postscriptName: "TestFont-Regular",
                status: .valid, isSystemProtected: false, isSelected: false
            )
            guard font.familyName == "TestFont" && font.status == .valid else { return false }
            // 解析正常、未在用都不构成删除依据
            guard !font.isDeletableVerdict else { return false }
            // 只有"损坏/重复"这两种带正向证据的状态才提供删除依据
            guard FontItemStatus.corrupted.providesDeletionEvidence
                    && FontItemStatus.duplicate.providesDeletionEvidence else { return false }
            guard !FontItemStatus.webFormat.providesDeletionEvidence
                    && !FontItemStatus.needsReview.providesDeletionEvidence
                    && !FontItemStatus.valid.providesDeletionEvidence else { return false }
            return true
        }

        // 2. 治理报告指标与释放潜能精算
        check("FontCache: 报告指标与释放潜力精算") {
            let f1 = FontItem(id: "1", fileName: "f1.ttf", path: "1", size: 1000, format: .ttf, familyName: "F1", postscriptName: "F1", status: .valid, isSystemProtected: false, isSelected: true)
            let f2 = FontItem(id: "2", fileName: "f2.ttf", path: "2", size: 2000, format: .ttf, familyName: "F2", postscriptName: "F2", status: .corrupted, isSystemProtected: false, isSelected: true)
            let f3 = FontItem(id: "3", fileName: "f3.ttf", path: "3", size: 3000, format: .ttf, familyName: "F3", postscriptName: "F3", status: .duplicate, isSystemProtected: false, isSelected: true)
            let f4 = FontItem(id: "4", fileName: "f4.ttf", path: "4", size: 4000, format: .ttf, familyName: "F4", postscriptName: "F4", status: .corrupted, isSystemProtected: true, isSelected: true)
            // f5 有损坏判据，但此刻在系统字体注册表里 → 坚决不计入释放潜力
            let f5 = FontItem(id: "5", fileName: "f5.ttf", path: "5", size: 9000, format: .ttf, familyName: "F5", postscriptName: "F5", status: .corrupted, isSystemProtected: false, isSelected: true, isRegisteredInUse: true)
            let c1 = FontCacheItem(id: "c1", name: "Cache 1", path: "c1", size: 5000, note: "note", isSelected: true)

            let report = FontInspectionReport(
                userFonts: [f1, f2, f3, f4, f5],
                cacheItems: [c1],
                totalFontSize: 19000,
                totalCacheSize: 5000
            )

            guard report.corruptedFonts.count == 3 else { return false }
            guard report.duplicateFonts.count == 1 else { return false }
            guard report.registeredInUseFonts.count == 1 else { return false }
            // f1 是 valid（不计入）、f4 受保护（不计入）、f5 在用（不计入）→ 只有 f2 + f3
            guard report.reclaimableFontSize == 5000 else {
                print("    ❌ reclaimableFontSize 不符: \(report.reclaimableFontSize)")
                return false
            }
            guard report.reclaimableCacheSize == 5000 else { return false }
            guard report.totalReclaimableSize == 10000 else { return false }
            return true
        }

        // 3. 系统字体保护与越界安全防护
        check("FontCache: 系统核心字体保护与越界防线校验") {
            let sysFonts = FontCacheInspector.shared.scanUserFonts(customDirectory: "/System/Library/Fonts")
            guard sysFonts.isEmpty else { return false }

            let globalFonts = FontCacheInspector.shared.scanUserFonts(customDirectory: "/Library/Fonts")
            guard globalFonts.isEmpty else { return false }

            // 尝试删除系统字体
            let fakeSysItem = FontItem(
                id: "/System/Library/Fonts/Helvetica.ttc", fileName: "Helvetica.ttc",
                path: "/System/Library/Fonts/Helvetica.ttc", size: 1000, format: .ttc,
                familyName: "Helvetica", postscriptName: "Helvetica", status: .corrupted,
                isSystemProtected: true, isSelected: true
            )
            let cleanRes = FontCacheInspector.shared.cleanFonts(
                items: [fakeSysItem], toTrash: true, journal: .none)
            guard cleanRes.cleanedCount == 0 && cleanRes.errorCount > 0 else { return false }
            // 全局字体位置的域声明：/Library/Fonts 必须落到 .fontsGlobal
            guard FontCacheInspector.governanceDomain(
                forPath: "/Library/Fonts/Some.ttf") == .fontsGlobal else { return false }
            let home = FileSystem.normalizePath(NSHomeDirectory())
            guard FontCacheInspector.governanceDomain(forPath: "\(home)/Library/Fonts/A.ttf") == nil else { return false }
            return true
        }

        // 4. 模拟字体目录扫描与损坏字体识别
        check("FontCache: 模拟目录扫描与损坏字体探测识别") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Fonts_Scan"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            let saved = FontCacheInspector.registeredFontURLsOverride
            FontCacheInspector.registeredFontURLsOverride = []
            defer { FontCacheInspector.registeredFontURLsOverride = saved }

            // 写入一个损坏的虚拟字体文件（非合法 TrueType 二进制）
            let corruptPath = (testDir as NSString).appendingPathComponent("corrupted_test.ttf")
            try? "Not A Real Font Binary Content".data(using: .utf8)?.write(to: URL(fileURLWithPath: corruptPath))
            // 空字体文件：连字节都读不出来 → 证据不足，只能"需确认"
            let emptyPath = (testDir as NSString).appendingPathComponent("empty_test.ttf")
            try? Data().write(to: URL(fileURLWithPath: emptyPath))

            let items = FontCacheInspector.shared.scanUserFonts(customDirectory: testDir)
            guard items.count == 2 else { return false }
            let corrupt = items.first { $0.fileName == "corrupted_test.ttf" }
            guard let corrupt, corrupt.status == .corrupted else {
                print("    ❌ 无容器特征的假字体未被识别为 .corrupted，实际为: \(corrupt?.status.rawValue ?? "nil")")
                return false
            }
            // 损坏判据成立（文件头无 sfnt 特征）时才会默选
            guard corrupt.isSelected else { return false }
            let empty = items.first { $0.fileName == "empty_test.ttf" }
            guard let empty, empty.status == .needsReview, !empty.isSelected else {
                print("    ❌ 读不出字节的字体应降级为需确认，实际为: \(empty?.status.rawValue ?? "nil")")
                return false
            }
            return true
        }

        // 5. 模拟字体安全清理与结果核验
        check("FontCache: 模拟字体安全清理与文件移除核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Fonts_Clean"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let fontFile = (testDir as NSString).appendingPathComponent("dummy.otf")
            let payload = "dummy font data".data(using: .utf8)!
            try? payload.write(to: URL(fileURLWithPath: fontFile))

            let item = FontItem(
                id: fontFile, fileName: "dummy.otf", path: fontFile, size: Int64(payload.count),
                format: .otf, familyName: nil, postscriptName: nil, status: .corrupted,
                isSystemProtected: false, isSelected: true
            )
            let saved = FontCacheInspector.registeredFontURLsOverride
            FontCacheInspector.registeredFontURLsOverride = []
            defer { FontCacheInspector.registeredFontURLsOverride = saved }

            let res = FontCacheInspector.shared.cleanFonts(items: [item], toTrash: false, journal: .none)
            // 释放量来自删除前实测，而不是扫描时自计的 item.size
            guard res.cleanedCount == 1 && res.freedBytes == Int64(payload.count) else {
                print("    ❌ 释放量未实测: cleaned=\(res.cleanedCount) freed=\(res.freedBytes)")
                return false
            }
            guard !fm.fileExists(atPath: fontFile) else { return false }
            guard res.cleanedPaths.count == 1 && res.trashedSnapshots.isEmpty else { return false }
            return true
        }

        // 6. 字体缓存目录扫描与安全清空核验
        check("FontCache: 字体缓存目录安全清空与防越界校验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Fonts_Caches"
            try? fm.removeItem(atPath: testDir)
            let cacheRoot = (testDir as NSString).appendingPathComponent("com.apple.FontRegistry")
            try? fm.createDirectory(atPath: cacheRoot, withIntermediateDirectories: true)
            let blob = (cacheRoot as NSString).appendingPathComponent("glyphs.bin")
            try? "glyphcache".data(using: .utf8)?.write(to: URL(fileURLWithPath: blob))
            defer { try? fm.removeItem(atPath: testDir) }

            let savedRoot = FontCacheInspector.userCachesRootOverride
            FontCacheInspector.userCachesRootOverride = testDir
            defer { FontCacheInspector.userCachesRootOverride = savedRoot }

            let fakeCache = FontCacheItem(
                id: "/System/Library/Caches/fake", name: "Fake",
                path: "/System/Library/Caches/fake", size: 100, note: "test", isSelected: true)
            let res = FontCacheInspector.shared.cleanCaches(items: [fakeCache], journal: .none)
            guard res.cleanedCount == 0 && res.errorCount > 0 else { return false }

            // 已登记缓存根：只清空内部子项，缓存根目录本身保留
            let okCache = FontCacheItem(id: cacheRoot, name: "FontRegistry", path: cacheRoot,
                                        size: 9, note: "test", isSelected: true)
            let okRes = FontCacheInspector.shared.cleanCaches(items: [okCache], toTrash: false, journal: .none)
            guard okRes.cleanedCount == 1, fm.fileExists(atPath: cacheRoot) else { return false }
            guard !fm.fileExists(atPath: blob) else { return false }
            return true
        }

        // 7. WOFF/WOFF2 解析失败绝不判损坏、绝不默选（P0 修复）
        check("FontCache: WOFF/WOFF2 在 CoreText 解析失败下仍不判损坏不默选") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Fonts_Web"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            let saved = FontCacheInspector.registeredFontURLsOverride
            FontCacheInspector.registeredFontURLsOverride = []
            defer { FontCacheInspector.registeredFontURLsOverride = saved }

            // 真实的 wOFF / wOF2 文件头：CoreText 一定解析不了
            try? Data([0x77, 0x4F, 0x46, 0x46, 0, 0, 1, 0]).write(to: URL(fileURLWithPath: testDir + "/web.woff"))
            try? Data([0x77, 0x4F, 0x46, 0x32, 0, 0, 1, 0]).write(to: URL(fileURLWithPath: testDir + "/web2.woff2"))
            // 确认本环境的 CoreText 确实解析不了它们（否则这条自检失去意义）
            guard CTFontManagerCreateFontDescriptorsFromURL(
                URL(fileURLWithPath: testDir + "/web.woff") as CFURL) == nil else {
                print("    ⚠️ 本机 CoreText 竟可解析 woff")
                return false
            }

            let items = FontCacheInspector.shared.scanUserFonts(customDirectory: testDir)
            guard items.count == 2 else { return false }
            for item in items {
                guard item.status == .webFormat else {
                    print("    ❌ \(item.fileName) 被判成 \(item.status.rawValue)")
                    return false
                }
                guard !item.isSelected, !item.isDeletableVerdict else { return false }
            }
            let report = FontInspectionReport(userFonts: items, totalFontSize: 16)
            guard report.webFonts.count == 2, report.corruptedFonts.isEmpty else { return false }
            guard report.reclaimableFontSize == 0 else { return false }

            // 即便用户手动勾选，删除也必须被模块判据拦下
            let forced = items.map { var c = $0; c.isSelected = true; return c }
            let res = FontCacheInspector.shared.cleanFonts(items: forced, toTrash: false, journal: .none)
            guard res.cleanedCount == 0 && res.errorCount == 2 else { return false }
            guard res.rejected.contains(where: { $0.message.contains("Web 字体") }) else { return false }
            guard fm.fileExists(atPath: testDir + "/web.woff") else { return false }
            return true
        }

        // 8. 在用字体坚决排除；注册表读不到时不产出任何可删结论（P0 修复）
        check("FontCache: 已注册在用字体坚决不删，注册表读不到时全量保留") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Fonts_InUse"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            let fontFile = testDir + "/used.ttf"
            try? "not a real font".data(using: .utf8)?.write(to: URL(fileURLWithPath: fontFile))

            let saved = FontCacheInspector.registeredFontURLsOverride
            let real = FileSystem.normalizePath(FileSystem.realPath(fontFile))

            // ① 注册表里能看到它 → 标"正在被系统使用"，扫描不默选、删除被拒
            FontCacheInspector.registeredFontURLsOverride = [real]
            defer { FontCacheInspector.registeredFontURLsOverride = saved }
            let scanned = FontCacheInspector.shared.scanUserFonts(customDirectory: testDir)
            guard let item = scanned.first, item.isRegisteredInUse else { return false }
            guard item.status == .corrupted, !item.isSelected else {
                print("    ❌ 在用字体被默选：status=\(item.status.rawValue) selected=\(item.isSelected)")
                return false
            }
            var forced = item
            forced.isSelected = true
            let resInUse = FontCacheInspector.shared.cleanFonts(items: [forced], toTrash: false, journal: .none)
            guard resInUse.cleanedCount == 0, resInUse.rejected.first?.message.contains("正在被系统使用") == true else { return false }
            guard fm.fileExists(atPath: fontFile) else { return false }

            // ② 注册表读不到（nil）→ 证据缺失，一律不得删
            FontCacheInspector.registeredFontURLsOverride = nil
            let savedFail = FontCacheInspector.registryReadFailure
            FontCacheInspector.registryReadFailure = true
            defer { FontCacheInspector.registryReadFailure = savedFail }
            let resBlind = FontCacheInspector.shared.cleanFonts(items: [forced], toTrash: false, journal: .none)
            guard resBlind.cleanedCount == 0 && resBlind.errorCount == 1 else { return false }
            guard resBlind.rejected.first?.message.contains("读不到") == true else { return false }
            guard fm.fileExists(atPath: fontFile) else { return false }
            return true
        }

        // 9. 白名单 / G6 硬排除 / G8 受保护路径在字体模块下必被拒
        check("FontCache: 白名单与硬排除路径经网关必被拦下且文件完好") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Fonts_Guard"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            let saved = FontCacheInspector.registeredFontURLsOverride
            FontCacheInspector.registeredFontURLsOverride = []
            defer { FontCacheInspector.registeredFontURLsOverride = saved }

            let wm = WhitelistManager.shared
            wm.removeAllRules()
            defer { wm.removeAllRules() }

            // 三种必拒目标：用户白名单目录内 / G6 硬排除 / G8 系统保护
            let whitelistedDir = testDir + "/protected"
            let whitelistedFile = whitelistedDir + "/a.ttf"
            try? fm.createDirectory(atPath: whitelistedDir, withIntermediateDirectories: true)
            let targets: [(String, String)] = [
                ("a.ttf", whitelistedFile),
                ("MailFont.ttf", FileSystem.normalizePath(NSHomeDirectory()) + "/Library/Mail/V9/Fonts/MailFont.ttf"),
                ("Helvetica.ttf", "/System/Library/Fonts/Helvetica.ttf"),
            ]
            // 只在临时 fixture 里造文件；后两条是**假想路径**，绝不在真实用户/系统位置写东西
            try? "font".data(using: .utf8)?.write(to: URL(fileURLWithPath: whitelistedFile))
            wm.addPathRule(whitelistedDir, comment: "字体网关自检")

            let items = targets.map { name, path in
                FontItem(id: path, fileName: name, path: path, size: 4, format: .ttf,
                         familyName: nil, postscriptName: nil, status: .corrupted,
                         isSystemProtected: false, isSelected: true)
            }
            let res = FontCacheInspector.shared.cleanFonts(items: items, toTrash: false, journal: .none)
            guard res.errorCount > 0 && res.cleanedCount == 0 && res.freedBytes == 0 else {
                print("    ❌ cleaned=\(res.cleanedCount) errors=\(res.errorCount)")
                return false
            }
            let reasons = Set(res.rejected.map { $0.reason })
            guard reasons.contains(.userWhitelisted) || reasons.contains(.hardExcluded) else {
                print("    ❌ 未见白名单/硬排除拒绝原因: \(res.rejected.map { $0.reason })")
                return false
            }
            guard reasons.contains(.systemProtected) else { return false }
            for (_, path) in targets where path.hasPrefix(testDir) {
                guard fm.fileExists(atPath: path) else { return false }
            }
            return true
        }

        // 10. 软链跳板：字体目录里指向系统位置的软链必被网关拒绝
        check("FontCache: 软链跳板目标被网关拒绝，指向的真身未被删除") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Fonts_Symlink"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir + "/fonts", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            let saved = FontCacheInspector.registeredFontURLsOverride
            FontCacheInspector.registeredFontURLsOverride = []
            defer { FontCacheInspector.registeredFontURLsOverride = saved }

            let outsideDir = testDir + "/outside"
            try? fm.createDirectory(atPath: outsideDir, withIntermediateDirectories: true)
            let victim = outsideDir + "/real.ttf"
            try? "real font bytes".data(using: .utf8)?.write(to: URL(fileURLWithPath: victim))
            let link = testDir + "/fonts/escape.ttf"
            try? fm.createSymbolicLink(atPath: link, withDestinationPath: victim)

            let item = FontItem(id: link, fileName: "escape.ttf", path: link, size: 0,
                                format: .ttf, familyName: nil, postscriptName: nil,
                                status: .corrupted, isSystemProtected: false, isSelected: true)
            let res = FontCacheInspector.shared.cleanFonts(items: [item], toTrash: false, journal: .none)
            guard res.cleanedCount == 0 && res.errorCount == 1 else { return false }
            guard res.rejected.first?.reason == .symlinkJump else {
                print("    ❌ 未按软链跳板拒绝: \(res.rejected.map { $0.reason })")
                return false
            }
            guard fm.fileExists(atPath: victim), fm.fileExists(atPath: link) else { return false }
            return true
        }

        // 11. atsutil 走 SafeProcess：命令与参数受控，失败绝不谎报成功
        check("FontCache: atsutil 经 SafeProcess 注入后命令参数正确且失败不谎报") {
            let savedRunner = SafeProcess.runner
            let savedPath = FontCacheInspector.atsutilPath
            defer {
                SafeProcess.runner = savedRunner
                FontCacheInspector.atsutilPath = savedPath
            }

            // 生产默认值必须是绝对路径的 atsutil（不允许用 PATH 查找）
            guard FontCacheInspector.atsutilPath == "/usr/bin/atsutil" else { return false }

            // 用一个 fixture 可执行文件满足"命令真实存在"的前置校验，
            // 这样断言落在**参数与结论**上，而自检不会真的改动系统字体数据库。
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Fonts_Atsutil"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            let fakeAtsutil = testDir + "/atsutil"
            try? Data("#!/bin/sh\nexit 0\n".utf8).write(to: URL(fileURLWithPath: fakeAtsutil))
            try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fakeAtsutil)
            guard SafeProcess.isAvailable(fakeAtsutil) else { return false }
            FontCacheInspector.atsutilPath = fakeAtsutil

            var seen: [(String, [String])] = []
            SafeProcess.runner = { path, args, _ in
                seen.append((path, args))
                return SafeProcess.Result(exitCode: 0, output: "")
            }
            let ok = FontCacheInspector.shared.resetUserAtsDatabases()
            guard ok.executed && ok.succeeded && ok.exitCode == 0 else { return false }
            guard seen.last?.0 == fakeAtsutil,
                  seen.last?.1 == ["databases", "-removeUser"] else {
                print("    ❌ 命令或参数不符: \(seen)")
                return false
            }
            guard ok.message.contains("退出码 0") else { return false }

            // 非 0 退出码：只能说"未重置"
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 1, output: "denied") }
            let fail = FontCacheInspector.shared.resetUserAtsDatabases()
            guard !fail.succeeded, fail.executed, fail.exitCode == 1 else { return false }
            guard fail.message.contains("未重置"), fail.message.contains("denied") else { return false }

            // 超时：不得声称已重置
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 0, output: "", timedOut: true) }
            let timeout = FontCacheInspector.shared.resetUserAtsDatabases()
            guard !timeout.succeeded, timeout.message.contains("未确认") else { return false }

            // 命令不存在：完全不执行，也不谎报
            SafeProcess.runner = { _, _, _ in SafeProcess.Result(exitCode: 0, output: "") }
            FontCacheInspector.atsutilPath = testDir + "/not-here"
            let missing = FontCacheInspector.shared.resetUserAtsDatabases()
            guard !missing.executed && !missing.succeeded && missing.exitCode == nil else { return false }
            guard seen.count == 1, missing.message.contains("未做任何改动") else { return false }
            return true
        }

        // 12. 删除失败不得计入 cleanedCount / freedBytes
        check("FontCache: 删除失败项不计入清理数与释放量") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Fonts_Partial"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }
            let saved = FontCacheInspector.registeredFontURLsOverride
            FontCacheInspector.registeredFontURLsOverride = []
            defer { FontCacheInspector.registeredFontURLsOverride = saved }

            let gonePath = testDir + "/vanished.ttf"
            try? "abc".data(using: .utf8)?.write(to: URL(fileURLWithPath: gonePath))
            let keepPath = testDir + "/kept.ttf"
            try? "abcdef".data(using: .utf8)?.write(to: URL(fileURLWithPath: keepPath))

            let gone = FontItem(id: gonePath, fileName: "vanished.ttf", path: gonePath, size: 999,
                                format: .ttf, familyName: nil, postscriptName: nil, status: .corrupted,
                                isSystemProtected: false, isSelected: true)
            let keep = FontItem(id: keepPath, fileName: "kept.ttf", path: keepPath, size: 999,
                                format: .ttf, familyName: nil, postscriptName: nil, status: .corrupted,
                                isSystemProtected: false, isSelected: true)
            // 扫完就消失的文件：网关判 missing，绝不记"已释放 999 字节"
            try? fm.removeItem(atPath: gonePath)
            let res = FontCacheInspector.shared.cleanFonts(items: [gone, keep], toTrash: false, journal: .none)
            guard res.cleanedCount == 1 else { return false }
            guard res.freedBytes == 6 else {
                print("    ❌ 释放量应为删除前实测的 6 字节，实际 \(res.freedBytes)")
                return false
            }
            guard res.errorCount == 1, res.rejected.first?.reason == .missing else { return false }
            guard !fm.fileExists(atPath: keepPath) else { return false }
            // summary 必须如实反映"1 项被拦"
            guard res.summary.contains("1 项被安全护栏拦下") else { return false }
            return true
        }
    }
}
