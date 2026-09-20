import Foundation

// MARK: - 系统多显示器色彩描述与 ICC Profile 残存治理深度自检 (v1.68.0)

extension Selftest {
    static func suiteColorSyncDeep() {
        print("--- [Suite] 系统多显示器色彩描述与 ICC Profile 残存治理深度自检 (v1.68.0) ---")

        // 1. 配置分类、图标与健康状态研判
        check("ColorSync: 配置分类、图标与健康状态研判") {
            guard ICCProfileKind.displayProfile.icon == "display.2" else { return false }
            guard ICCProfileKind.printerProfile.icon == "printer.fill" else { return false }
            guard ICCProfileKind.customProfile.icon == "slider.horizontal.3" else { return false }
            guard ICCProfileKind.colorSyncCache.icon == "archivebox.fill" else { return false }

            guard ICCProfileStatus.disconnectedOrphan.isOrphanOrCorrupted == true else { return false }
            guard ICCProfileStatus.corrupted.isOrphanOrCorrupted == true else { return false }
            guard ICCProfileStatus.activeConnected.isOrphanOrCorrupted == false else { return false }
            guard ICCProfileStatus.systemProtected.isOrphanOrCorrupted == false else { return false }

            return true
        }

        // 2. 概览指标统计与已选释放容量精算
        check("ColorSync: 概览指标统计与已选释放容量精算") {
            let date = Date()
            let item1 = ICCProfileItem(
                id: "/p1", name: "Dell_U2720Q.icc", path: "/p1",
                kind: .displayProfile, status: .disconnectedOrphan,
                size: 2048, modificationDate: date, isSelected: true
            )
            let item2 = ICCProfileItem(
                id: "/p2", name: "Corrupted.icc", path: "/p2",
                kind: .displayProfile, status: .corrupted,
                size: 0, modificationDate: date, isSelected: true
            )
            let item3 = ICCProfileItem(
                id: "/p3", name: "Built-in Retina.icc", path: "/p3",
                kind: .displayProfile, status: .activeConnected,
                size: 4096, modificationDate: date, isSelected: false
            )

            let summary = ColorSyncSummary(
                items: [item1, item2, item3],
                totalSize: 6144,
                orphanCount: 2,
                orphanSize: 2048,
                activeCount: 1
            )

            guard summary.totalSize == 6144 else { return false }
            guard summary.orphanCount == 2 else { return false }
            guard summary.orphanSize == 2048 else { return false }
            guard summary.activeCount == 1 else { return false }
            guard summary.selectedSize == 2048 else { return false }
            guard summary.selectedCount == 2 else { return false }

            return true
        }

        // 3. 系统核心白名单与活动显示器安全防线
        check("ColorSync: 系统核心白名单与活动显示器安全防线") {
            let sRGB = ColorSyncScanner.evaluateProfile(
                fileName: "sRGB Profile.icc",
                path: "/Library/ColorSync/Profiles/sRGB Profile.icc",
                size: 3000,
                activeKeywords: ["built-in"]
            )
            guard sRGB.status == .systemProtected else { return false }

            let displayP3 = ColorSyncScanner.evaluateProfile(
                fileName: "Display P3.icc",
                path: "/Library/ColorSync/Profiles/Display P3.icc",
                size: 3000,
                activeKeywords: ["built-in"]
            )
            guard displayP3.status == .systemProtected else { return false }

            // 拦截清理
            let protectedItem = ICCProfileItem(
                id: "/Library/ColorSync/Profiles/sRGB Profile.icc",
                name: "sRGB Profile.icc",
                path: "/Library/ColorSync/Profiles/sRGB Profile.icc",
                kind: .displayProfile,
                status: .systemProtected,
                size: 3000,
                modificationDate: Date(),
                isSelected: true
            )
            let activeItem = ICCProfileItem(
                id: "/Library/ColorSync/Profiles/Active.icc",
                name: "Active.icc",
                path: "/Library/ColorSync/Profiles/Active.icc",
                kind: .displayProfile,
                status: .activeConnected,
                size: 3000,
                modificationDate: Date(),
                isSelected: true
            )
            let sysPathItem = ICCProfileItem(
                id: "/System/Library/ColorSync/Profiles/Test.icc",
                name: "Test.icc",
                path: "/System/Library/ColorSync/Profiles/Test.icc",
                kind: .displayProfile,
                status: .disconnectedOrphan,
                size: 3000,
                modificationDate: Date(),
                isSelected: true
            )

            let res = ColorSyncScanner.shared.clean(items: [protectedItem, activeItem, sysPathItem], toTrash: false)
            guard res.cleanedCount == 0 && res.errorCount == 3 else { return false }

            return true
        }

        // 4. 模拟多显示器环境与配置文件扫描提取
        check("ColorSync: 模拟多显示器环境与配置文件扫描提取") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_ColorSync_Scan"
            let userProfiles = (testDir as NSString).appendingPathComponent("Profiles")
            let cacheDir = (testDir as NSString).appendingPathComponent("com.apple.ColorSync")

            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: userProfiles, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            // 写入断开的 LG 屏配置
            let lgIcc = (userProfiles as NSString).appendingPathComponent("LG UltraFine 4K.icc")
            try? "mock_lg_profile_data".data(using: .utf8)?.write(to: URL(fileURLWithPath: lgIcc))

            // 写入损坏的 0 字节配置
            let brokenIcc = (userProfiles as NSString).appendingPathComponent("Broken.icc")
            fm.createFile(atPath: brokenIcc, contents: Data())

            // 写入 ColorSync 缓存文件
            let cacheFile = (cacheDir as NSString).appendingPathComponent("cache.data")
            try? "mock_colorsync_cache".data(using: .utf8)?.write(to: URL(fileURLWithPath: cacheFile))

            let summary = ColorSyncScanner.shared.scan(customDirectories: [userProfiles, cacheDir])
            guard summary.items.count == 3 else { return false }
            guard summary.orphanCount == 3 else { return false }
            guard summary.totalSize > 0 else { return false }

            // 验证损坏配置检测
            let corruptedItem = summary.items.first(where: { $0.name == "Broken.icc" })
            guard let corruptedItem, corruptedItem.status == .corrupted else { return false }

            // 验证缓存识别
            let cacheItem = summary.items.first(where: { $0.path.contains("com.apple.ColorSync") })
            guard let cacheItem, cacheItem.kind == .colorSyncCache else { return false }

            return true
        }

        // 5. 模拟孤儿配置安全清理与核验
        check("ColorSync: 模拟孤儿配置安全清理与核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_ColorSync_Clean"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let orphanIcc = (testDir as NSString).appendingPathComponent("Old_Samsung_Monitor.icc")
            try? "mock_samsung_profile_bytes".data(using: .utf8)?.write(to: URL(fileURLWithPath: orphanIcc))
            let fileSize = Int64((try? fm.attributesOfItem(atPath: orphanIcc)[.size] as? UInt64) ?? 0)

            let orphanItem = ICCProfileItem(
                id: orphanIcc,
                name: "Old_Samsung_Monitor.icc",
                path: orphanIcc,
                kind: .displayProfile,
                status: .disconnectedOrphan,
                size: fileSize,
                modificationDate: Date(),
                isSelected: true
            )

            guard fm.fileExists(atPath: orphanIcc) else { return false }

            let res = ColorSyncScanner.shared.clean(items: [orphanItem], toTrash: false)
            guard res.cleanedCount == 1 else { return false }
            guard res.freedBytes == fileSize else { return false }
            guard res.errorCount == 0 else { return false }
            guard !fm.fileExists(atPath: orphanIcc) else { return false }

            return true
        }

        // 6. 空目录与非 profile 杂项文件过滤排查
        check("ColorSync: 空目录与非 profile 杂项文件过滤排查") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_ColorSync_Filter"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            // 写入非 icc 文件（如 txt, plist, log）
            let txtFile = (testDir as NSString).appendingPathComponent("readme.txt")
            let plistFile = (testDir as NSString).appendingPathComponent("config.plist")
            try? "readme".data(using: .utf8)?.write(to: URL(fileURLWithPath: txtFile))
            try? "plist".data(using: .utf8)?.write(to: URL(fileURLWithPath: plistFile))

            let summary = ColorSyncScanner.shared.scan(customDirectories: [testDir])
            guard summary.items.isEmpty else { return false }
            guard summary.totalSize == 0 else { return false }

            return true
        }
    }
}
