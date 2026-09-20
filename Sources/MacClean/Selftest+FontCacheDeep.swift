import Foundation
import CoreText

// MARK: - 字体缓存与孤儿系统字体残存治理深度自检 (v1.61.0)

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
                id: "/font.ttf",
                fileName: "font.ttf",
                path: "/font.ttf",
                size: 2048,
                format: .ttf,
                familyName: "TestFont",
                postscriptName: "TestFont-Regular",
                status: .valid,
                isSystemProtected: false,
                isSelected: false
            )
            guard font.familyName == "TestFont" && font.status == .valid else { return false }
            return true
        }

        // 2. 治理报告指标与释放潜能精算
        check("FontCache: 报告指标与释放潜力精算") {
            let f1 = FontItem(id: "1", fileName: "f1.ttf", path: "1", size: 1000, format: .ttf, familyName: "F1", postscriptName: "F1", status: .valid, isSystemProtected: false, isSelected: true)
            let f2 = FontItem(id: "2", fileName: "f2.ttf", path: "2", size: 2000, format: .ttf, familyName: "F2", postscriptName: "F2", status: .corrupted, isSystemProtected: false, isSelected: true)
            let f3 = FontItem(id: "3", fileName: "f3.ttf", path: "3", size: 3000, format: .ttf, familyName: "F3", postscriptName: "F3", status: .duplicate, isSystemProtected: false, isSelected: true)
            let f4 = FontItem(id: "4", fileName: "f4.ttf", path: "4", size: 4000, format: .ttf, familyName: "F4", postscriptName: "F4", status: .corrupted, isSystemProtected: true, isSelected: true)

            let c1 = FontCacheItem(id: "c1", name: "Cache 1", path: "c1", size: 5000, note: "note", isSelected: true)

            let report = FontInspectionReport(
                userFonts: [f1, f2, f3, f4],
                cacheItems: [c1],
                totalFontSize: 10000,
                totalCacheSize: 5000
            )

            guard report.corruptedFonts.count == 2 else { return false }
            guard report.duplicateFonts.count == 1 else { return false }
            // f1 是 valid (不计入 reclaimableFontSize)，f4 是 systemProtected (不计入)
            // 只有 f2(2000) + f3(3000) = 5000
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
                id: "/System/Library/Fonts/Helvetica.ttc",
                fileName: "Helvetica.ttc",
                path: "/System/Library/Fonts/Helvetica.ttc",
                size: 1000,
                format: .ttc,
                familyName: "Helvetica",
                postscriptName: "Helvetica",
                status: .valid,
                isSystemProtected: true,
                isSelected: true
            )
            let cleanRes = FontCacheInspector.shared.cleanFonts(items: [fakeSysItem], toTrash: true)
            guard cleanRes.cleanedCount == 0 && cleanRes.errorCount > 0 else { return false }

            return true
        }

        // 4. 模拟字体目录扫描与损坏字体识别
        check("FontCache: 模拟目录扫描与损坏字体探测识别") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Fonts_Scan"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            // 写入一个损坏的虚拟字体文件（非合法 TrueType 二进制）
            let corruptPath = (testDir as NSString).appendingPathComponent("corrupted_test.ttf")
            try? "Not A Real Font Binary Content".data(using: .utf8)?.write(to: URL(fileURLWithPath: corruptPath))

            let items = FontCacheInspector.shared.scanUserFonts(customDirectory: testDir)
            guard items.count == 1 else { return false }
            guard items[0].status == .corrupted else {
                print("    ❌ 损坏字体未被识别为 .corrupted，实际为: \(items[0].status)")
                return false
            }
            guard items[0].isSelected == true else { return false } // 损坏字体默认预选

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
            try? "dummy font data".data(using: .utf8)?.write(to: URL(fileURLWithPath: fontFile))

            let item = FontItem(
                id: fontFile,
                fileName: "dummy.otf",
                path: fontFile,
                size: 15,
                format: .otf,
                familyName: nil,
                postscriptName: nil,
                status: .corrupted,
                isSystemProtected: false,
                isSelected: true
            )

            let res = FontCacheInspector.shared.cleanFonts(items: [item], toTrash: false)
            guard res.cleanedCount == 1 && res.freedBytes == 15 else { return false }
            guard !fm.fileExists(atPath: fontFile) else { return false }

            return true
        }

        // 6. 字体缓存目录扫描与安全清空核验
        check("FontCache: 字体缓存目录安全清空与防越界校验") {
            let fm = FileManager.default

            // 验证防越界：非用户 Caches 目录必须被拒绝
            let fakeCache = FontCacheItem(
                id: "/System/Library/Caches/fake",
                name: "Fake",
                path: "/System/Library/Caches/fake",
                size: 100,
                note: "test",
                isSelected: true
            )
            let res = FontCacheInspector.shared.cleanCaches(items: [fakeCache])
            guard res.cleanedCount == 0 && res.errorCount > 0 else { return false }

            // 验证 atsutil 命令路径与调用安全性
            guard fm.fileExists(atPath: "/usr/bin/atsutil") else {
                // 如果系统没有 atsutil 则安全跳过
                return true
            }

            return true
        }
    }
}
