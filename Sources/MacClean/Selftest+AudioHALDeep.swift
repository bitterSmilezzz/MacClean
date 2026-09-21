import Foundation
import Darwin

// MARK: - 系统音频 HAL 插件与残存驱动排查治理深度自检 (v1.70.0，v1.72.0 加固)
//
// 本轮 P0：旧判据"bundle id 是否等于某个已安装 .app"在真机上必然误判——
// `/Library/Audio/Plug-Ins/HAL` 里的 BlackHole / SteamStreaming* / ParrotAudioPlugin
// 都是 pkg 安装、没有对应 `.app`。现在判据是真实音频设备枚举（CoreAudio），
// 并且**任何一环读不到都降级为"证据不足"**，一个都不默认勾。

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
            // 核心：证据不足既不是孤儿也不是损坏 → 永不进默认可删集合
            guard AudioPluginStatus.unknownNeedsConfirmation.isOrphanOrCorrupted == false else { return false }
            guard AudioPluginStatus.unknownNeedsConfirmation.isInUseOrProtected == false else { return false }
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
                kind: .halDriver, status: .appleOfficial,
                bundleID: "com.apple.audio.AppleTimeSyncAudioClock",
                size: 4096, fileCount: 8, modificationDate: date, isSelected: false
            )

            let summary = AudioPluginSummary(
                items: [item1, item2, item3],
                totalSize: 6144, orphanCount: 2, orphanSize: 2048, activeCount: 1,
                evidenceReadable: true, evidenceSource: "coreaudio",
                needsConfirmationCount: 0, evidenceFailure: nil)

            guard summary.totalSize == 6144 else { return false }
            guard summary.orphanCount == 2, summary.activeCount == 1 else { return false }
            guard summary.selectedSize == 2048, summary.selectedCount == 2 else { return false }
            guard summary.evidenceReadable, summary.evidenceSource == "coreaudio" else { return false }
            guard summary.needsConfirmationCount == 0 else { return false }
            return true
        }

        // 3. 真实设备标识归一化与匹配（CoreAudio 报的是目录名，Info.plist 报的是 bundle id）
        check("AudioHAL: 驱动标识归一化与设备 token 匹配") {
            let keys = AudioHALScanner.normalizePluginKeys([
                "SteamStreamingSpeakers.driver", "audio.existential.BlackHole2ch"
            ])
            guard keys.contains("steamstreamingspeakers.driver") else { return false }
            guard keys.contains("steamstreamingspeakers") else { return false }
            guard keys.contains("audio.existential.blackhole2ch") else { return false }
            guard keys.contains("blackhole2ch") else { return false }

            // 真机事实：pkg 安装的驱动没有 .app，只能靠 coreaudiod 已加载清单认领
            let evidence = AudioDeviceEvidence(
                loadedPluginKeys: keys,
                deviceTokens: AudioHALScanner.significantTokens("BlackHole 2ch"),
                defaultOutputTokens: [],
                pluginsReadable: true, devicesReadable: true, source: "coreaudio")
            let blackhole = AudioHALScanner.matchesLiveAudioDriver(
                name: "BlackHole2ch.driver", bundleID: "audio.existential.BlackHole2ch",
                evidence: evidence)
            guard blackhole.matched else { return false }
            let steam = AudioHALScanner.matchesLiveAudioDriver(
                name: "SteamStreamingSpeakers.driver",
                bundleID: "com.valvesoftware.SteamStreamingSpeakers", evidence: evidence)
            guard steam.matched else { return false }
            guard !AudioHALScanner.matchesLiveAudioDriver(
                name: "DefunctAudio.driver", bundleID: "com.oldcompany.defunctaudio",
                evidence: evidence).matched else { return false }

            // 停用词不参与匹配（否则 "audio"/"driver" 会把所有驱动判成在用）
            let tokens = AudioHALScanner.significantTokens("Apple Audio Driver Device")
            guard tokens.isEmpty else { return false }
            guard AudioHALScanner.significantTokens("BlackHole 2ch Speakers").contains("blackhole") else { return false }
            return true
        }

        // 4. Apple 官方保护面：com.apple 前缀 + /System 整片不碰
        check("AudioHAL: Apple 官方驱动保护面（前缀与系统位置）") {
            let evidence = AudioDeviceEvidence(loadedPluginKeys: [], deviceTokens: [],
                                               defaultOutputTokens: [], pluginsReadable: true,
                                               devicesReadable: true, source: "coreaudio")
            let parrot = AudioHALScanner.evaluateAudioPlugin(
                name: "ParrotAudioPlugin.driver",
                path: "/Library/Audio/Plug-Ins/HAL/ParrotAudioPlugin.driver",
                defaultKind: .halDriver, size: 400_000,
                infoPlistReadable: true, bundleID: "com.apple.audio.ParrotAudioPlugin",
                evidence: evidence, installedBundleIDs: [], inventoryComplete: true)
            guard parrot.status == .appleOfficial else { return false }

            let legacy = AudioHALScanner.evaluateAudioPlugin(
                name: "AppleTimeSyncAudioClock.driver",
                path: "/Library/Audio/Plug-Ins/HAL/AppleTimeSyncAudioClock.driver",
                defaultKind: .halDriver, size: 400_000,
                infoPlistReadable: true, bundleID: nil,
                evidence: evidence, installedBundleIDs: [], inventoryComplete: true)
            guard legacy.status == .appleOfficial else { return false }

            // /System 位置：即便 bundle id 读不到也永不触碰
            let sys = AudioHALScanner.evaluateAudioPlugin(
                name: "Mystery.driver", path: "/System/Library/Audio/Plug-Ins/HAL/Mystery.driver",
                defaultKind: .halDriver, size: 400_000, infoPlistReadable: false,
                evidence: .unreadable, installedBundleIDs: [], inventoryComplete: false)
            guard sys.status == .appleOfficial else { return false }
            guard AudioHALScanner.isAppleProtected("/System/Library/Audio/Plug-Ins/HAL/X.driver") else { return false }
            guard !AudioHALScanner.isAppleProtected("/Library/Audio/Plug-Ins/HAL/X.driver") else { return false }

            // 治理域归因（真实路径只做字符串归因，不碰盘）
            guard AudioHALScanner.domain(for: "/Library/Audio/Plug-Ins/HAL/X.driver") == GovernanceDomain.audioHAL
            else { return false }
            guard AudioHALScanner.domain(for: "/Library/Audio/Plug-Ins/Components/X.component")
                == GovernanceDomain.audioComponents else { return false }
            // 域根自身永不是删除目标（层级过浅）——真机只读判定
            let rootVerdict = FileSystem.governanceVerdict(
                "/Library/Audio/Plug-Ins/HAL", domain: GovernanceDomain.audioHAL)
            guard case .rejected(let reason) = rootVerdict, reason == .tooShallowForDomain else { return false }
            return true
        }

        // 5. 证据源读不到 → 全部需确认、零勾选
        check("AudioHAL: 设备枚举失败时不判孤儿且不默选") {
            let dir = audioFixtureDir("blind")
            let hal = (dir as NSString).appendingPathComponent("HAL")
            try? FileManager.default.createDirectory(
                atPath: (hal as NSString).appendingPathComponent("DefunctAudio.driver/Contents"),
                withIntermediateDirectories: true)
            writePlist(bundleID: "com.oldcompany.defunctaudio",
                       at: (hal as NSString)
                            .appendingPathComponent("DefunctAudio.driver/Contents/Info.plist"),
                       extra: "fake binary")
            try? FileManager.default.createDirectory(
                atPath: (hal as NSString).appendingPathComponent("BlackHole2ch.driver/Contents"),
                withIntermediateDirectories: true)
            writePlist(bundleID: "audio.existential.BlackHole2ch",
                       at: (hal as NSString)
                            .appendingPathComponent("BlackHole2ch.driver/Contents/Info.plist"),
                       extra: "fake binary")
            defer { try? FileManager.default.removeItem(atPath: dir) }

            // 插件清单读不到（system_profiler 那条路就是这个形状）→ 一律需确认
            let pluginsBlind = AudioDeviceEvidence(
                loadedPluginKeys: [], deviceTokens: ["macbook", "builtinspeakerdevice"],
                defaultOutputTokens: ["macbook"], pluginsReadable: false, devicesReadable: true,
                source: "system_profiler", failureNote: "system_profiler 无法枚举已加载插件")
            let blind = AudioHALScanner.shared.scan(
                customHALDirs: [hal], customComponentDirs: [], customCacheDirs: [],
                evidence: pluginsBlind,
                inventory: snapshot(bundleIDs: ["com.someone.else"]))
            guard blind.evidenceReadable == false else { return false }
            guard blind.orphanCount == 0, blind.orphanSize == 0 else { return false }
            guard blind.items.count == 2, blind.needsConfirmationCount == 2 else { return false }
            guard blind.items.allSatisfy({ $0.status == .unknownNeedsConfirmation && !$0.isSelected })
            else { return false }
            guard blind.selectedCount == 0 else { return false }

            // 连设备清单也读不到 → 同样是需确认（旧实现在这里会把一切判成孤儿）
            let stone = AudioHALScanner.shared.scan(
                customHALDirs: [hal], customComponentDirs: [], customCacheDirs: [],
                evidence: .unreadable, inventory: snapshot(bundleIDs: []))
            guard stone.items.count == 2, stone.orphanCount == 0 else { return false }
            guard stone.items.allSatisfy({ $0.status == .unknownNeedsConfirmation && !$0.isSelected })
            else { return false }

            // Info.plist 读不到 → 宿主归属未知，不得判孤儿
            let unknownHost = AudioHALScanner.evaluateAudioPlugin(
                name: "NoPlist.driver", path: "/Library/Audio/Plug-Ins/HAL/NoPlist.driver",
                defaultKind: .halDriver, size: 10_000,
                infoPlistReadable: false, bundleID: nil,
                evidence: AudioDeviceEvidence(loadedPluginKeys: [], deviceTokens: [],
                                              defaultOutputTokens: [], pluginsReadable: true,
                                              devicesReadable: true, source: "coreaudio"),
                installedBundleIDs: [], inventoryComplete: true)
            guard unknownHost.status == .unknownNeedsConfirmation else { return false }
            return true
        }

        // 6. 已安装清单命中 → 绝不为孤儿；清单不完整 → 同样不得判孤儿
        check("AudioHAL: 已安装应用清单命中者绝不为孤儿") {
            let dir = audioFixtureDir("inventory")
            let hal = (dir as NSString).appendingPathComponent("HAL")
            try? FileManager.default.createDirectory(
                atPath: (hal as NSString).appendingPathComponent("ZoomAudioDevice.driver/Contents"),
                withIntermediateDirectories: true)
            writePlist(bundleID: "us.zoom.zoomaudiodevice",
                       at: (hal as NSString)
                            .appendingPathComponent("ZoomAudioDevice.driver/Contents/Info.plist"),
                       extra: "fake binary")
            defer { try? FileManager.default.removeItem(atPath: dir) }

            // 证据可信但 coreaudiod 没加载它 —— 此时唯一能救它的是"宿主 App 还在装"
            let liveEvidence = AudioDeviceEvidence(
                loadedPluginKeys: AudioHALScanner.normalizePluginKeys(["com.apple.audio.MacAudio"]),
                deviceTokens: ["macbookair扬声器"], defaultOutputTokens: [],
                pluginsReadable: true, devicesReadable: true, source: "coreaudio")

            let savedSnapshot = AppInventory.snapshotOverride
            AppInventory.snapshotOverride = snapshot(bundleIDs: ["us.zoom.zoomaudiodevice"])
            defer { AppInventory.snapshotOverride = savedSnapshot }

            let installed = AudioHALScanner.shared.scan(
                customHALDirs: [hal], customComponentDirs: [], customCacheDirs: [],
                evidence: liveEvidence)     // 不传 inventory → 走 AppInventory.snapshotOverride
            guard let item = installed.items.first, item.name == "ZoomAudioDevice.driver" else { return false }
            guard item.status == .activeInUse, !item.isSelected else { return false }
            guard installed.orphanCount == 0 else { return false }

            // 清单不完整（有根目录读不到）→ 即便 coreaudiod 没加载也不许判孤儿
            AppInventory.snapshotOverride = snapshot(bundleIDs: ["us.zoom.zoomaudiodevice"],
                                                    incomplete: true)
            let distrust = AudioHALScanner.shared.scan(
                customHALDirs: [hal], customComponentDirs: [], customCacheDirs: [],
                evidence: liveEvidence)
            guard let distrustItem = distrust.items.first, distrustItem.status == .unknownNeedsConfirmation
            else { return false }
            guard distrustItem.isSelected == false, distrust.orphanCount == 0 else { return false }

            // 清单完整且宿主确实不在了 → 才允许给出孤儿结论（并默认可删）
            AppInventory.snapshotOverride = snapshot(bundleIDs: ["com.other.app"])
            let orphan = AudioHALScanner.shared.scan(
                customHALDirs: [hal], customComponentDirs: [], customCacheDirs: [],
                evidence: liveEvidence)
            guard let orphanItem = orphan.items.first, orphanItem.status == .orphanResidue else { return false }
            guard orphanItem.isSelected, orphan.orphanCount == 1 else { return false }
            guard let note = orphanItem.evidenceNote, note.contains("coreaudiod") else { return false }
            return true
        }

        // 7. 软链跳板与越界必被网关拦下，且目标文件仍在
        check("AudioHAL: 删除网关拒绝软链跳板与越出治理域") {
            let dir = audioFixtureDir("gate")
            let domain = makeFixtureDomain(id: "selftest.audio.hal", root: dir)
            let victim = (dir as NSString).appendingPathComponent("OldSound.driver")
            try? FileManager.default.createDirectory(atPath: victim, withIntermediateDirectories: true)
            try? "bytes".data(using: .utf8)?
                .write(to: URL(fileURLWithPath: (victim as NSString).appendingPathComponent("kext.bin")))
            let jump = (dir as NSString).appendingPathComponent("fonts-link")
            try? FileManager.default.createSymbolicLink(atPath: jump,
                                                        withDestinationPath: "/System/Library/Fonts")
            defer { try? FileManager.default.removeItem(atPath: dir) }

            let orphan = AudioPluginItem(
                id: victim, name: "OldSound.driver", path: victim, kind: .halDriver,
                status: .orphanResidue, size: 5, modificationDate: Date(), isSelected: true)
            let link = AudioPluginItem(
                id: jump, name: "fonts-link", path: jump, kind: .halDriver,
                status: .orphanResidue, size: 900_000_000, modificationDate: Date(), isSelected: true)

            let out = AudioHALScanner.shared.clean(items: [orphan, link], toTrash: false,
                                                   journal: .none, domainOverride: domain)
            guard out.cleanedCount == 1, out.freedBytes > 0 else { return false }
            guard out.rejected.contains(where: { $0.reason == .symlinkJump }) else { return false }
            guard FileManager.default.fileExists(atPath: "/System/Library/Fonts") else { return false }
            guard FileManager.default.fileExists(atPath: jump) else { return false }
            guard !FileManager.default.fileExists(atPath: victim) else { return false }

            // 越界 + 受保护状态都不得被删
            let outside = AudioPluginItem(
                id: "/Library/Audio/Plug-Ins/HAL", name: "HAL 根",
                path: "/Library/Audio/Plug-Ins/HAL", kind: .halDriver,
                status: .orphanResidue, size: 1, modificationDate: Date(), isSelected: true)
            let out2 = AudioHALScanner.shared.clean(items: [outside], toTrash: false,
                                                    journal: .none, domainOverride: domain)
            guard out2.cleanedCount == 0, out2.freedBytes == 0 else { return false }
            guard out2.rejected.first?.reason == .outsideDomain else { return false }
            guard FileManager.default.fileExists(atPath: "/Library/Audio/Plug-Ins/HAL") else { return false }

            // 域内、状态受保护：必须被 policy（而非层级/越界）拦下
            let shielded = (dir as NSString).appendingPathComponent("AppleTimeSyncAudioClock.driver")
            try? FileManager.default.createDirectory(atPath: shielded, withIntermediateDirectories: true)
            let inUse = AudioPluginItem(
                id: shielded, name: "AppleTimeSyncAudioClock.driver", path: shielded,
                kind: .halDriver, status: .appleOfficial, size: 1,
                modificationDate: Date(), isSelected: true)
            let out3 = AudioHALScanner.shared.clean(items: [inUse], toTrash: false,
                                                    journal: .none, domainOverride: domain)
            guard out3.cleanedCount == 0 else { return false }
            // 状态门槛是本模块的业务判据，不是安全护栏：reason 用 .notDeletable，
            // 且必须把"研判结论是什么"这句中文原因带出来（v1.73 起 policy 可携带消息）
            guard out3.rejected.first?.reason == .notDeletable,
                  out3.rejected.first?.message.contains("Apple 官方核心") == true else { return false }
            guard FileManager.default.fileExists(atPath: shielded) else { return false }
            return true
        }

        // 8. 删除失败不得计入 freedBytes / cleanedCount
        check("AudioHAL: 删除失败不计账，成功后按实测体积计账") {
            let dir = audioFixtureDir("failed")
            let domain = makeFixtureDomain(id: "selftest.audio.failed", root: dir)
            let stuck = (dir as NSString).appendingPathComponent("stuck.driver")
            try? FileManager.default.createDirectory(atPath: stuck, withIntermediateDirectories: true)
            let bin = (stuck as NSString).appendingPathComponent("driver.bin")
            try? String(repeating: "y", count: 2048).data(using: .utf8)?
                .write(to: URL(fileURLWithPath: bin))
            guard Darwin.chflags(stuck, UInt32(UF_IMMUTABLE)) == 0 else {
                try? FileManager.default.removeItem(atPath: dir)
                return false
            }
            defer {
                Darwin.chflags(stuck, 0)
                try? FileManager.default.removeItem(atPath: dir)
            }

            let item = AudioPluginItem(
                id: stuck, name: "stuck.driver", path: stuck, kind: .halDriver,
                status: .orphanResidue, size: 5_000_000_000,
                modificationDate: Date(), isSelected: true)
            let failed = AudioHALScanner.shared.clean(items: [item], toTrash: false,
                                                      journal: .none, domainOverride: domain)
            guard failed.cleanedCount == 0, failed.freedBytes == 0 else { return false }
            guard failed.failed.count == 1, failed.errorCount == 1 else { return false }
            guard FileManager.default.fileExists(atPath: stuck) else { return false }

            Darwin.chflags(stuck, 0)
            let ok = AudioHALScanner.shared.clean(items: [item], toTrash: false,
                                                  journal: .none, domainOverride: domain)
            guard ok.cleanedCount == 1, ok.freedBytes > 0, ok.freedBytes != item.size else { return false }
            guard !FileManager.default.fileExists(atPath: stuck) else { return false }
            guard ok.summary.contains("已清理 1 项") else { return false }
            return true
        }

        // 9. coreaudiod 重启：默认 TERM、参数与真实结果都要对上
        check("AudioHAL: coreaudiod 重启用 TERM 且如实上报结果") {
            let saved = SafeProcess.runner
            var seen: [(String, [String])] = []
            SafeProcess.runner = { path, args, _ in
                seen.append((path, args))
                return SafeProcess.Result(exitCode: 0, output: "")
            }
            defer { SafeProcess.runner = saved }

            let ok = AudioHALScanner.shared.restartCoreAudioService()
            guard ok.success else { return false }
            guard seen.last?.0 == AudioHALScanner.killallPath else { return false }
            // 关键：不能再带 -9（SIGKILL 会硬切正在播放的音频，且丢失退出码语义）
            guard seen.last?.1 == ["coreaudiod"] else { return false }
            guard AudioHALScanner.shared.restartCoreAudioService().message.contains("TERM") else { return false }

            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 1, output: "No matching processes belong to the user")
            }
            let denied = AudioHALScanner.shared.restartCoreAudioService()
            guard !denied.success else { return false }
            guard denied.message.contains("不提权"), denied.message.contains("sudo") else { return false }

            SafeProcess.runner = { _, _, _ in
                SafeProcess.Result(exitCode: 0, output: "", timedOut: true)
            }
            guard !AudioHALScanner.shared.restartCoreAudioService().success else { return false }
            return true
        }

        // 10. system_profiler 兜底解析：能证明在用，但不能证明孤儿
        check("AudioHAL: system_profiler 音频 JSON 解析与可信度标注") {
            let json = """
            {
              "SPAudioDataType" : [
                { "_items" : [
                  { "_name" : "BlackHole 2ch",
                    "coreaudio_device_manufacturer" : "Existential Audio Inc.",
                    "coreaudio_device_transport" : "coreaudio_device_type_virtual" },
                  { "_name" : "MacBook Air扬声器",
                    "coreaudio_default_audio_output_device" : "spaudio_yes",
                    "coreaudio_device_manufacturer" : "Apple Inc." }
                ] }
              ]
            }
            """
            let evidence = AudioHALScanner.parseSystemProfilerAudio(json)
            guard evidence.devicesReadable else { return false }
            // 这条证据源给不出插件 bundle id → 绝不能据它判孤儿
            guard evidence.pluginsReadable == false, evidence.isFullyReadable == false else { return false }
            guard evidence.deviceTokens.contains("blackhole") else { return false }
            guard evidence.defaultOutputTokens.contains("macbook") else { return false }
            guard evidence.source == "system_profiler" else { return false }

            // 解析失败必须显式降级，不能给出"可信的空清单"
            let broken = AudioHALScanner.parseSystemProfilerAudio("{ not json")
            guard !broken.devicesReadable, !broken.pluginsReadable else { return false }
            guard broken.failureNote != nil else { return false }
            let empty = AudioHALScanner.parseSystemProfilerAudio("{\"SPAudioDataType\":[]}")
            guard !empty.devicesReadable, empty.failureNote != nil else { return false }

            // 只有设备清单时：匹配到的算在用，匹配不到的一律需确认
            let evaluated = AudioHALScanner.evaluateAudioPlugin(
                name: "BlackHole2ch.driver", path: "/Library/Audio/Plug-Ins/HAL/BlackHole2ch.driver",
                defaultKind: .halDriver, size: 40_000, infoPlistReadable: true,
                bundleID: "audio.existential.BlackHole2ch",
                evidence: evidence, installedBundleIDs: [], inventoryComplete: true)
            guard evaluated.status == .activeInUse else { return false }
            guard let note = evaluated.note, note.contains("BlackHole".lowercased())
                || note.contains("设备") else { return false }
            return true
        }

        // 11. CoreAudio 采集通路（本机实测：设备与已加载插件都能读到）
        check("AudioHAL: CoreAudio 证据采集可用且失败时显式降级") {
            let e = AudioHALScanner.collectCoreAudioEvidence()
            guard e.source == "coreaudio" else { return false }
            if e.pluginsReadable {
                guard !e.loadedPluginKeys.isEmpty else { return false }
            }
            if e.devicesReadable {
                guard !e.deviceTokens.isEmpty else { return false }
            }
            if !e.pluginsReadable && !e.devicesReadable {
                // 读不到就必须留下原因，供卡片显示"仅提供定位与建议"
                guard e.failureNote != nil else { return false }
            }
            return true
        }

        // 12. 卡片如实呈现证据降级与 root 无权限原因
        check("AudioHAL: 卡片如实呈现证据降级与 root 无权限原因") {
            guard let src = SelftestSource.read("AudioHALOptimizerCard") else { return false }
            guard src.contains("无法读全系统音频设备与已加载驱动") else { return false }
            guard src.contains("outcome.needsPrivilege") else { return false }
            guard src.contains("evidenceNote") else { return false }
            guard !src.contains("hasPrefix(\"/System\")") else { return false }
            guard src.contains("AudioHALScanner.shared.clean(") else { return false }
            // 视图里不再有自建护栏与手写 clean 主体
            guard !src.contains("trashItem") else { return false }
            return true
        }

        // 13. 空目录与 0 字节驱动：损坏只在"确证为空"时给出
        check("AudioHAL: 空目录过滤与损坏判定") {
            let dir = audioFixtureDir("filter")
            let hal = (dir as NSString).appendingPathComponent("HAL")
            try? FileManager.default.createDirectory(atPath: hal, withIntermediateDirectories: true)
            try? "hidden".data(using: .utf8)?.write(to: URL(
                fileURLWithPath: (hal as NSString).appendingPathComponent(".DS_Store")))
            let emptyDriver = (hal as NSString).appendingPathComponent("Empty.driver")
            try? FileManager.default.createDirectory(atPath: emptyDriver,
                                                     withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: (dir as NSString)
                .appendingPathComponent("Components"), withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }

            let evidence = AudioDeviceEvidence(loadedPluginKeys: [], deviceTokens: [],
                                               defaultOutputTokens: [], pluginsReadable: true,
                                               devicesReadable: true, source: "coreaudio")
            let summary = AudioHALScanner.shared.scan(
                customHALDirs: [hal],
                customComponentDirs: [(dir as NSString).appendingPathComponent("Components")],
                customCacheDirs: [(dir as NSString).appendingPathComponent("NoCache")],
                evidence: evidence, inventory: snapshot(bundleIDs: []))
            guard summary.items.count == 1 else { return false }
            guard let item = summary.items.first, item.name == "Empty.driver" else { return false }
            guard item.status == .corrupted, item.isSelected else { return false }
            guard summary.totalSize == 0, summary.orphanCount == 1 else { return false }
            guard item.domainID == nil else { return false }   // fixture 路径不属于任何真实域
            return true
        }
    }
}

// MARK: - 音频套件自检辅助

/// 在 `NSTemporaryDirectory()` 下建干净的 fixture 目录（绝不碰真实 /Library）
func audioFixtureDir(_ name: String) -> String {
    let base = (NSTemporaryDirectory() as NSString)
        .appendingPathComponent("MacCleanSelftest/Audio/\(name)")
    try? FileManager.default.removeItem(atPath: base)
    try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
    return FileSystem.normalizePath(base)
}

/// 写一份最小可用的 bundle Info.plist
func writePlist(bundleID: String, at path: String, extra: String?) {
    let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
        <key>CFBundleIdentifier</key>
        <string>\(bundleID)</string>
    </dict>
    </plist>
    """
    try? xml.data(using: .utf8)?.write(to: URL(fileURLWithPath: path))
    if let extra {
        let sibling = (path as NSString).deletingLastPathComponent
            .appending("/SelftestPayload.bin")
        try? extra.data(using: .utf8)?.write(to: URL(fileURLWithPath: sibling))
    }
}

/// 造一份已安装应用清单 fixture
func snapshot(bundleIDs: Set<String>, incomplete: Bool = false) -> AppInventory.Snapshot {
    AppInventory.Snapshot(
        bundleIDs: bundleIDs,
        bundlePrefixes: Set(bundleIDs.map { $0.split(separator: ".").prefix(2).joined(separator: ".") }),
        normalizedNames: [],
        executableNames: [],
        runningBundleIDs: [],
        appPaths: [],
        unreadableRoots: incomplete ? ["/Applications"] : [])
}
