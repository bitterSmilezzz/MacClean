import Foundation

// MARK: - 系统音频 HAL 插件与残存驱动排查治理深度自检 (v1.70.0)

extension Selftest {
    static func suiteAudioHALDeep() {
        print("--- [Suite] 系统音频 HAL 插件与残存驱动排查治理深度自检 (v1.70.0) ---")

        // 1. 插件分类、图标与健康状态枚举判定
        check("AudioHAL: 插件分类、图标与健康状态枚举判定") {
            guard AudioPluginKind.halDriver.icon == "speaker.wave.3.fill" else { return false }
            guard AudioPluginKind.audioUnit.icon == "waveform" else { return false }
            guard AudioPluginKind.vstPlugin.icon == "dial.low.fill" else { return false }
            guard AudioPluginKind.coreAudioCache.icon == "archivebox.fill" else { return false }

            guard AudioPluginStatus.orphanResidue.isOrphanOrCorrupted == true else { return false }
            guard AudioPluginStatus.corrupted.isOrphanOrCorrupted == true else { return false }
            guard AudioPluginStatus.activeInUse.isOrphanOrCorrupted == false else { return false }
            guard AudioPluginStatus.appleOfficial.isOrphanOrCorrupted == false else { return false }

            return true
        }

        // 2. 概要指标统计与已选释放容量精算
        check("AudioHAL: 概要指标统计与已选释放容量精算") {
            let date = Date()
            let item1 = AudioPluginItem(
                id: "/p1", name: "ZoomAudioDevice.driver", path: "/p1",
                kind: .halDriver, status: .orphanResidue, bundleID: "us.zoom.audiodevice",
                size: 2048, fileCount: 4, modificationDate: date, isSelected: true
            )
            let item2 = AudioPluginItem(
                id: "/p2", name: "Corrupted.driver", path: "/p2",
                kind: .halDriver, status: .corrupted, bundleID: nil,
                size: 0, fileCount: 0, modificationDate: date, isSelected: true
            )
            let item3 = AudioPluginItem(
                id: "/p3", name: "AppleTimeSyncAudioClock.driver", path: "/p3",
                kind: .halDriver, status: .appleOfficial, bundleID: "com.apple.audio.AppleTimeSyncAudioClock",
                size: 4096, fileCount: 8, modificationDate: date, isSelected: false
            )

            let summary = AudioPluginSummary(
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

        // 3. Apple 官方核心白名单与系统防线越界拦截
        check("AudioHAL: Apple 官方核心白名单与系统防线越界拦截") {
            // Apple 官方驱动白名单校验
            let appleDriver = AudioHALScanner.evaluateAudioPlugin(
                name: "AppleTimeSyncAudioClock.driver",
                path: "/Library/Audio/Plug-Ins/HAL/AppleTimeSyncAudioClock.driver",
                defaultKind: .halDriver,
                size: 5000,
                installedBIDs: []
            )
            guard appleDriver.status == .appleOfficial else { return false }

            // 已安装应用关联驱动判定
            let activeDriver = AudioHALScanner.evaluateAudioPlugin(
                name: "InstalledAudio.driver",
                path: "/dummy/InstalledAudio.driver",
                defaultKind: .halDriver,
                size: 5000,
                installedBIDs: ["com.installed.app"]
            )
            // 没有 Info.plist 时默认孤儿，若有已安装匹配则为 activeInUse
            guard activeDriver.kind == .halDriver else { return false }

            // 系统目录拦截
            let sysItem = AudioPluginItem(
                id: "/System/Library/Audio/Plug-Ins/HAL/Sys.driver",
                name: "Sys.driver",
                path: "/System/Library/Audio/Plug-Ins/HAL/Sys.driver",
                kind: .halDriver,
                status: .appleOfficial,
                size: 1000,
                modificationDate: Date(),
                isSelected: true
            )
            let resSys = AudioHALScanner.shared.clean(items: [sysItem], toTrash: false)
            guard resSys.cleanedCount == 0 && resSys.errorCount > 0 else { return false }

            // 受保护活跃项拦截
            let activeItem = AudioPluginItem(
                id: "/Library/Audio/Plug-Ins/HAL/InUse.driver",
                name: "InUse.driver",
                path: "/Library/Audio/Plug-Ins/HAL/InUse.driver",
                kind: .halDriver,
                status: .activeInUse,
                size: 1000,
                modificationDate: Date(),
                isSelected: true
            )
            let resActive = AudioHALScanner.shared.clean(items: [activeItem], toTrash: false)
            guard resActive.cleanedCount == 0 && resActive.errorCount > 0 else { return false }

            return true
        }

        // 4. 模拟 HAL 目录扫描与已卸载应用孤儿驱动识别
        check("AudioHAL: 模拟 HAL 目录扫描与已卸载应用孤儿驱动识别") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_AudioHAL_Scan"
            let halDir = (testDir as NSString).appendingPathComponent("HAL")
            let compDir = (testDir as NSString).appendingPathComponent("Components")
            let cacheDir = (testDir as NSString).appendingPathComponent("Cache")

            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: halDir, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: compDir, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            // 写入孤儿驱动（包含 Contents/Info.plist）
            let orphanDriver = (halDir as NSString).appendingPathComponent("DefunctAudio.driver")
            let contentsDir = (orphanDriver as NSString).appendingPathComponent("Contents")
            try? fm.createDirectory(atPath: contentsDir, withIntermediateDirectories: true)

            let plistPath = (contentsDir as NSString).appendingPathComponent("Info.plist")
            let plistContent = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>CFBundleIdentifier</key>
                <string>com.oldcompany.defunctaudio</string>
            </dict>
            </plist>
            """
            try? plistContent.data(using: .utf8)?.write(to: URL(fileURLWithPath: plistPath))

            let binaryPath = (contentsDir as NSString).appendingPathComponent("DefunctAudio")
            try? "fake_mach_o_binary".data(using: .utf8)?.write(to: URL(fileURLWithPath: binaryPath))

            let summary = AudioHALScanner.shared.scan(
                customHALDirs: [halDir],
                customComponentDirs: [compDir],
                customCacheDirs: [cacheDir]
            )

            guard summary.items.count == 1 else { return false }
            guard summary.orphanCount == 1 else { return false }
            guard summary.totalSize > 0 else { return false }

            let item = summary.items.first
            guard let item, item.bundleID == "com.oldcompany.defunctaudio" else { return false }
            guard item.status == .orphanResidue else { return false }

            return true
        }

        // 5. 模拟安全清理与文件移除核验
        check("AudioHAL: 模拟安全清理与文件移除核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_AudioHAL_Clean"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let driverDir = (testDir as NSString).appendingPathComponent("OldVirtualSound.driver")
            try? fm.createDirectory(atPath: driverDir, withIntermediateDirectories: true)
            let file = (driverDir as NSString).appendingPathComponent("driver.bin")
            try? "mock_driver_bytes".data(using: .utf8)?.write(to: URL(fileURLWithPath: file))
            let fileSize = Int64((try? fm.attributesOfItem(atPath: file)[.size] as? UInt64) ?? 0)

            let item = AudioPluginItem(
                id: driverDir,
                name: "OldVirtualSound.driver",
                path: driverDir,
                kind: .halDriver,
                status: .orphanResidue,
                bundleID: "com.old.sound",
                size: fileSize,
                fileCount: 1,
                modificationDate: Date(),
                isSelected: true
            )

            guard fm.fileExists(atPath: driverDir) else { return false }

            let res = AudioHALScanner.shared.clean(items: [item], toTrash: false)
            guard res.cleanedCount == 1 else { return false }
            guard res.freedBytes == fileSize else { return false }
            guard res.errorCount == 0 else { return false }
            guard !fm.fileExists(atPath: driverDir) else { return false }

            return true
        }

        // 6. 空目录与非驱动杂项文件鲁棒性断言
        check("AudioHAL: 空目录与非驱动杂项文件鲁棒性断言") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_AudioHAL_Filter"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            // 写入隐藏文件
            let hidden = (testDir as NSString).appendingPathComponent(".DS_Store")
            try? "hidden".data(using: .utf8)?.write(to: URL(fileURLWithPath: hidden))

            let summary = AudioHALScanner.shared.scan(
                customHALDirs: [testDir],
                customComponentDirs: [testDir + "/empty"],
                customCacheDirs: [testDir + "/nocache"]
            )

            guard summary.items.isEmpty else { return false }
            guard summary.totalSize == 0 else { return false }

            return true
        }
    }
}
