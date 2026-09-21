import Foundation
import AppKit
import CoreAudio

// MARK: - 系统音频 HAL 插件与残存驱动排查治理引擎 (v1.70.0，v1.72.0 安全加固)
//
// 本轮改掉的四个真机缺陷：
//
// ① **在用判据方向错了**。旧判据是"插件 bundle id 是否等于某个已安装 .app 的 bundle id"。
//    真机 `/Library/Audio/Plug-Ins/HAL` 实测有 `BlackHole2ch.driver`、
//    `SteamStreamingMicrophone/Speakers.driver`、`ParrotAudioPlugin.driver`——
//    全部 pkg 安装、根本没有对应 `.app`，于是逐个被判成孤儿并默认全勾选。
//    现在改为**真实音频设备枚举**：CoreAudio `kAudioHardwarePropertyDevices`（设备名/UID/厂商）
//    + `kAudioHardwarePropertyPlugInList` + `kAudioPlugInPropertyBundleID`
//    （coreaudiod 实际加载的 HAL 插件 bundle id），并交叉核对默认输出设备。
//    本机实测：CoreAudio 路径可用（7 个设备、17 个已加载插件全部读到）。
// ② **两条路都不通时的降级**：`system_profiler SPAudioDataType -json` 只能证明"在用"
//    （它给不出插件 bundle id），插件清单读不到就**永不**得出"孤儿"结论；
//    两个证据源全挂 → 全部条目降级为"证据不足"，一个都不默认勾。
// ③ **Apple 官方保护只有 4 个硬编码名字**。现在扩到 bundle id `com.apple.` 前缀
//    + `/System/Library/Audio/Plug-Ins` 整片一律不碰。
// ④ **`killall -9 coreaudiod`**：先试提权失败再谎报成功，且 `-9` 会让正在播放的音频
//    硬中断。改为默认 TERM 并如实上报返回码。
//
// 删除本身全部交给 `ResidueDeletionGate`（治理域 + 软链防跳板 + G6/G8 + 白名单 +
// 真实权限校验 + 删除前实测体积 + 废纸篓可撤销）。

public final class AudioHALScanner {
    public static let shared = AudioHALScanner()

    private init() {}

    /// Apple 官方核心音频驱动白名单（历史上只有这 4 个名字，v1.72.0 起只是**额外**保险）
    public static let appleOfficialDrivers: Set<String> = [
        "AppleTimeSyncAudioClock.driver",
        "BluetoothAudioPlugIn.driver",
        "AirPodsAudioPlugIn.driver",
        "AppleAVBAudio.driver"
    ]

    /// Apple 官方 Bundle ID 前缀白名单
    public static let appleBundlePrefixes: Set<String> = [
        "com.apple.",
        "apple."
    ]

    /// 系统只读位置里的音频组件：整片不碰（SIP 保护，且本工具不可能有权限）
    public static let appleProtectedRoots: [String] = [
        "/System/Library/Audio/Plug-Ins",
        "/System/Library/Components",
        "/System/Library/Audio"
    ]

    /// 可覆盖的命令路径（自检注入 `SafeProcess.runner` 后只断言命令与参数）
    public static var killallPath = "/usr/bin/killall"
    public static var systemProfilerPath = "/usr/sbin/system_profiler"

    /// 自检注入点：非 nil 时完全不碰真实 CoreAudio
    public static var evidenceProvider: (() -> AudioDeviceEvidence)?

    // MARK: - 在用证据采集

    /// 取真实音频设备/驱动证据：CoreAudio 优先，失败退 `system_profiler`，再失败整体降级。
    public static func collectEvidence() -> AudioDeviceEvidence {
        if let injected = evidenceProvider { return injected() }
        let coreAudio = collectCoreAudioEvidence()
        if coreAudio.devicesReadable || coreAudio.pluginsReadable {
            // 设备读到了但插件清单没读到 → 补一次 system_profiler 只会更全，
            // 但它给不出 bundle id，所以不覆盖 CoreAudio 已拿到的部分。
            if coreAudio.isFullyReadable { return coreAudio }
            let profiler = collectSystemProfilerEvidence()
            if profiler.devicesReadable {
                return AudioDeviceEvidence(
                    loadedPluginKeys: coreAudio.loadedPluginKeys,
                    deviceTokens: coreAudio.deviceTokens.union(profiler.deviceTokens),
                    defaultOutputTokens: coreAudio.defaultOutputTokens.union(profiler.defaultOutputTokens),
                    pluginsReadable: coreAudio.pluginsReadable,
                    devicesReadable: true,
                    source: "coreaudio+system_profiler",
                    failureNote: coreAudio.failureNote ?? profiler.failureNote)
            }
            return coreAudio
        }
        let profiler = collectSystemProfilerEvidence()
        if profiler.devicesReadable { return profiler }
        return .unreadable
    }

    /// CoreAudio 采集（本机已实测编译与运行）
    public static func collectCoreAudioEvidence() -> AudioDeviceEvidence {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var pluginKeys = Set<String>()
        var tokens = Set<String>()
        var defaultTokens = Set<String>()
        var notes: [String] = []

        // 1) coreaudiod 实际加载的 HAL 插件 bundle id
        var pluginsReadable = true
        if let plugins = readAudioIDs(sys, kAudioHardwarePropertyPlugInList), !plugins.isEmpty {
            for p in plugins {
                if let bid = readAudioString(p, kAudioPlugInPropertyBundleID) {
                    pluginKeys.formUnion(normalizePluginKeys([bid]))
                } else {
                    notes.append("有一个已加载插件读不到 bundle id")
                }
            }
        } else {
            pluginsReadable = false
            notes.append("无法枚举已加载音频插件")
        }

        // 2) 设备清单：名称 / UID / 厂商 / 型号
        var devicesReadable = true
        if let devices = readAudioIDs(sys, kAudioHardwarePropertyDevices), !devices.isEmpty {
            for d in devices {
                for sel in [kAudioObjectPropertyName, kAudioDevicePropertyDeviceUID,
                            kAudioObjectPropertyManufacturer, kAudioObjectPropertyModelName] {
                    if let v = readAudioString(d, sel) {
                        tokens.formUnion(significantTokens(v))
                    }
                }
            }
        } else {
            devicesReadable = false
            notes.append("无法枚举音频设备")
        }

        // 3) 交叉核对默认输出设备（它是"绝对在用"的最强证据）
        if let defaultID = readAudioInt(sys, kAudioHardwarePropertyDefaultOutputDevice) {
            for sel in [kAudioObjectPropertyName, kAudioDevicePropertyDeviceUID] {
                if let v = readAudioString(defaultID, sel) {
                    defaultTokens.formUnion(significantTokens(v))
                }
            }
        } else {
            notes.append("无法读取默认输出设备")
        }

        return AudioDeviceEvidence(
            loadedPluginKeys: pluginKeys,
            deviceTokens: tokens.union(defaultTokens),
            defaultOutputTokens: defaultTokens,
            pluginsReadable: pluginsReadable,
            devicesReadable: devicesReadable,
            source: "coreaudio",
            failureNote: notes.isEmpty ? nil : notes.joined(separator: "；"))
    }

    /// 兜底：`system_profiler SPAudioDataType -json`。
    /// 只给得出设备名与厂商，**给不出插件 bundle id** → `pluginsReadable == false`，
    /// 因此这条路径只能证明"在用"，不足以证明"孤儿"。
    public static func collectSystemProfilerEvidence() -> AudioDeviceEvidence {
        guard SafeProcess.isAvailable(Self.systemProfilerPath) else {
            return .unreadable
        }
        guard let json = SafeProcess.output(Self.systemProfilerPath,
                                           ["SPAudioDataType", "-json"], timeout: 25) else {
            return AudioDeviceEvidence(loadedPluginKeys: [], deviceTokens: [],
                                        defaultOutputTokens: [], pluginsReadable: false,
                                        devicesReadable: false, source: "none",
                                        failureNote: "system_profiler 未能执行")
        }
        return parseSystemProfilerAudio(json)
    }

    /// 解析 `SPAudioDataType -json`（独立出来以便自检能直接喂 fixture 字符串）
    public static func parseSystemProfilerAudio(_ json: String) -> AudioDeviceEvidence {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPAudioDataType"] as? [[String: Any]] else {
            return AudioDeviceEvidence(loadedPluginKeys: [], deviceTokens: [],
                                        defaultOutputTokens: [], pluginsReadable: false,
                                        devicesReadable: false, source: "system_profiler",
                                        failureNote: "音频设备清单解析失败")
        }
        var tokens = Set<String>()
        var defaultTokens = Set<String>()
        var devicesReadable = false
        for section in sections {
            guard let items = section["_items"] as? [[String: Any]] else { continue }
            for entry in items {
                devicesReadable = true
                let name = entry["_name"] as? String ?? ""
                let maker = entry["coreaudio_device_manufacturer"] as? String ?? ""
                tokens.formUnion(significantTokens(name))
                tokens.formUnion(significantTokens(maker))
                let isDefault = (entry["coreaudio_default_audio_output_device"] as? String) == "spaudio_yes"
                    || (entry["coreaudio_default_audio_system_device"] as? String) == "spaudio_yes"
                if isDefault { defaultTokens.formUnion(significantTokens(name)) }
            }
        }
        guard devicesReadable else {
            return AudioDeviceEvidence(loadedPluginKeys: [], deviceTokens: [],
                                        defaultOutputTokens: [], pluginsReadable: false,
                                        devicesReadable: false, source: "system_profiler",
                                        failureNote: "音频设备清单为空")
        }
        return AudioDeviceEvidence(loadedPluginKeys: [], deviceTokens: tokens.union(defaultTokens),
                                    defaultOutputTokens: defaultTokens,
                                    pluginsReadable: false,   // 这条证据源给不出插件清单
                                    devicesReadable: true, source: "system_profiler",
                                    failureNote: "system_profiler 无法枚举已加载插件")
    }

    // MARK: CoreAudio 读取原语

    static func readAudioIDs(_ object: AudioObjectID,
                             _ selector: AudioObjectPropertySelector) -> [AudioObjectID]? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var out = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &out) == noErr else { return nil }
        return out
    }

    static func readAudioString(_ object: AudioObjectID,
                               _ selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else {
            return nil
        }
        var raw: UnsafeMutableRawPointer?
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &raw) == noErr,
              let raw else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeRetainedValue() as String
    }

    static func readAudioInt(_ object: AudioObjectID,
                             _ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(mSelector: selector,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        var value = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(object, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    // MARK: 名字归一化

    /// 停用词：这些词在设备名/厂商名里到处出现，拿它匹配会把所有驱动都误判成"在用"。
    public static let tokenStopWords: Set<String> = [
        "driver", "drivers", "plugin", "plugins", "plug", "component", "components",
        "audio", "audios", "audiod", "sound", "sounds", "device", "devices",
        "output", "inputs", "input", "system", "default", "core", "apple",
        "inc", "ltd", "corp", "company", "app", "apps", "bundle", "virtual",
        "stereo", "mono", "main", "name", "model", "type", "user", "data",
        "with", "for", "the", "and", "mic", "mics"
    ]

    /// 切成小写 token（非字母数字即分隔），过滤停用词与过短片段。
    public static func significantTokens(_ text: String, minLength: Int = 4) -> Set<String> {
        var current = ""
        var out = Set<String>()
        for ch in text.lowercased() {
            if ch.isLetter || ch.isNumber {
                current.append(ch)
            } else if !current.isEmpty {
                out.insert(current)
                current = ""
            }
        }
        if !current.isEmpty { out.insert(current) }
        return out.filter { $0.count >= minLength && !tokenStopWords.contains($0) }
    }

    /// 把 coreaudiod 报出的插件标识展开成多种可比对形态（小写、去扩展名、取末段）。
    public static func normalizePluginKeys(_ raw: [String]) -> Set<String> {
        var out = Set<String>()
        for item in raw {
            let lower = item.lowercased()
            out.insert(lower)
            out.insert((lower as NSString).deletingPathExtension)
            let last = (lower as NSString).lastPathComponent
            out.insert(last)
            out.insert((last as NSString).deletingPathExtension)
            let parts = lower.split(separator: ".")
            if parts.count >= 3 { out.insert(parts[parts.count - 1].lowercased()) }
        }
        return out
    }

    /// 该驱动是否被真实音频设备/coreaudiod 引用。命中即"在用"（保护方向）。
    public static func matchesLiveAudioDriver(
        name: String, bundleID: String?, evidence: AudioDeviceEvidence
    ) -> (matched: Bool, why: String?) {
        var keys: [String] = []
        keys.append(name)
        keys.append((name as NSString).deletingPathExtension)
        if let bid = bundleID {
            keys.append(bid)
            keys.append((bid as NSString).lastPathComponent)
            keys.append(((bid as NSString).lastPathComponent as NSString).deletingPathExtension)
        }
        let normalized = normalizePluginKeys(keys)
        if let hit = normalized.first(where: { evidence.loadedPluginKeys.contains($0) }), !hit.isEmpty {
            return (true, "coreaudiod 已加载该驱动（\(hit)）")
        }
        // 设备名/UID/厂商 token 反查驱动名（如 "BlackHole 2ch" ⊂ "BlackHole2ch.driver"）
        let haystack = "\(name) \(bundleID ?? "")".lowercased()
        if let token = evidence.deviceTokens.sorted().first(where: { $0.count >= 5 && haystack.contains($0) }) {
            return (true, "当前音频设备（\(token)）引用了该驱动")
        }
        return (false, nil)
    }

    // MARK: - 扫描

    /// 扫描指定目录或系统默认音频驱动目录。
    /// - Parameters:
    ///   - customHALDirs / customComponentDirs / customCacheDirs: 自检 fixture 覆盖
    ///   - evidence: 注入真实设备证据（nil = 走 CoreAudio）
    ///   - inventory: 注入已安装应用清单（nil = 走 `AppInventory`）
    /// （参数含模块内类型 `AppInventory.Snapshot`，故本方法为 internal；卡片同模块可直接调。）
    func scan(
        customHALDirs: [String]? = nil,
        customComponentDirs: [String]? = nil,
        customCacheDirs: [String]? = nil,
        evidence injected: AudioDeviceEvidence? = nil,
        inventory injectedInventory: AppInventory.Snapshot? = nil
    ) -> AudioPluginSummary {
        let fm = FileManager.default
        let evidence = injected ?? Self.collectEvidence()
        let snapshot = injectedInventory ?? AppInventory.current()

        var items: [AudioPluginItem] = []
        var totalSize: Int64 = 0
        var orphanCount = 0
        var orphanSize: Int64 = 0
        var activeCount = 0
        var confirmCount = 0

        func ingest(dirPath: String, defaultKind: AudioPluginKind) {
            // 系统只读位置：连扫都不扫（SIP + 无权限）
            if Self.isAppleProtected(dirPath) { return }
            guard fm.fileExists(atPath: dirPath),
                  let contents = try? fm.contentsOfDirectory(atPath: dirPath) else {
                return
            }
            for entry in contents.sorted() {
                guard !entry.hasPrefix(".") else { continue }
                let fullPath = (dirPath as NSString).appendingPathComponent(entry)
                if FileSystem.isSymlink(fullPath) {
                    // 软链本身不是驱动，且网关必然拒绝——登记为需确认，只帮用户定位
                    items.append(AudioPluginItem(
                        id: fullPath, name: entry, path: fullPath, kind: defaultKind,
                        status: .unknownNeedsConfirmation, size: 0,
                        modificationDate: Date.distantPast,
                        evidenceNote: "这是一个符号链接，指向授权位置之外，绝不跟随删除",
                        domainID: Self.domain(for: fullPath)?.id, isSelected: false))
                    confirmCount += 1
                    continue
                }
                let metrics = Self.calculateDirectoryMetrics(at: fullPath)
                let plist = Self.readInfoPlist(at: fullPath)
                let evaluated = Self.evaluateAudioPlugin(
                    name: entry, path: fullPath, defaultKind: defaultKind,
                    size: metrics.size, metricsReadable: metrics.readable,
                    infoPlistReadable: plist.readable, bundleID: plist.bundleID,
                    evidence: evidence,
                    installedBundleIDs: snapshot.bundleIDs,
                    inventoryComplete: snapshot.isComplete)

                let isOrphan = evaluated.status.isOrphanOrCorrupted
                if isOrphan {
                    orphanCount += 1
                    orphanSize += metrics.size
                } else if evaluated.status.isInUseOrProtected {
                    activeCount += 1
                } else {
                    confirmCount += 1
                }

                items.append(AudioPluginItem(
                    id: fullPath,
                    name: entry,
                    path: fullPath,
                    kind: evaluated.kind,
                    status: evaluated.status,
                    bundleID: evaluated.bundleID,
                    size: metrics.size,
                    fileCount: metrics.fileCount,
                    modificationDate: metrics.mtime,
                    evidenceNote: evaluated.note,
                    domainID: Self.domain(for: fullPath)?.id,
                    isSelected: isOrphan))
                totalSize += metrics.size
            }
        }

        // 1. HAL 驱动目录
        let halDirs: [String] = customHALDirs ?? [
            "/Library/Audio/Plug-Ins/HAL",
            NSString(string: "~/Library/Audio/Plug-Ins/HAL").expandingTildeInPath
        ]
        for dir in halDirs { ingest(dirPath: dir, defaultKind: .halDriver) }

        // 2. AudioUnit 组件目录
        let compDirs: [String] = customComponentDirs ?? [
            "/Library/Audio/Plug-Ins/Components",
            NSString(string: "~/Library/Audio/Plug-Ins/Components").expandingTildeInPath
        ]
        for dir in compDirs { ingest(dirPath: dir, defaultKind: .audioUnit) }

        // 3. coreaudiod 运行缓存（主目录内）
        //    这是**正在运行的守护进程**持有的目录，不再是"孤儿"：
        //    只有确认读不到设备清单（daemon 状态未知）时才降级为需确认；
        //    两种情况都**不默认勾选**，交给用户显式决定。
        let cacheDirs: [String] = customCacheDirs ?? [
            NSString(string: "~/Library/Caches/com.apple.audio.coreaudiod").expandingTildeInPath
        ]
        for cDir in cacheDirs {
            guard fm.fileExists(atPath: cDir) else { continue }
            let metrics = Self.calculateDirectoryMetrics(at: cDir)
            guard metrics.readable, metrics.size > 0 else { continue }
            let status: AudioPluginStatus = evidence.devicesReadable ? .activeInUse : .unknownNeedsConfirmation
            let note = evidence.devicesReadable
                ? "coreaudiod 正在运行，其缓存目录此刻被持有；建议先重启音频服务再清理"
                : "无法枚举音频设备，coreaudiod 状态未知，不默认勾选"
            if status == .activeInUse { activeCount += 1 } else { confirmCount += 1 }
            items.append(AudioPluginItem(
                id: cDir,
                name: "com.apple.audio.coreaudiod (音频服务缓存)",
                path: cDir,
                kind: .coreAudioCache,
                status: status,
                bundleID: "com.apple.audio.coreaudiod",
                size: metrics.size,
                fileCount: metrics.fileCount,
                modificationDate: metrics.mtime,
                evidenceNote: note,
                domainID: Self.domain(for: cDir)?.id,
                isSelected: false))
            totalSize += metrics.size
        }

        let sorted = items.sorted { a, b in
            if a.status.isOrphanOrCorrupted != b.status.isOrphanOrCorrupted {
                return a.status.isOrphanOrCorrupted
            }
            return a.size > b.size
        }

        return AudioPluginSummary(
            items: sorted,
            totalSize: totalSize,
            orphanCount: orphanCount,
            orphanSize: orphanSize,
            activeCount: activeCount,
            evidenceReadable: evidence.isFullyReadable,
            evidenceSource: evidence.source,
            needsConfirmationCount: confirmCount,
            evidenceFailure: evidence.failureNote)
    }

    /// 是否位于 Apple 只读保护位置（整片不碰）
    public static func isAppleProtected(_ path: String) -> Bool {
        guard !path.isEmpty else { return true }
        let real = FileSystem.normalizePath(FileSystem.realPath(path))
        if FileSystem.isSystemProtected(real) { return true }
        for root in appleProtectedRoots {
            let r = FileSystem.normalizePath(root)
            if real == r || real.hasPrefix(r + "/") { return true }
        }
        return false
    }

    /// Info.plist 读取结果（`readable == false` 时宿主归属未知，不得判孤儿）
    static func readInfoPlist(at path: String) -> (bundleID: String?, readable: Bool) {
        let exists = FileManager.default.fileExists(atPath: path)
        guard exists else { return (nil, false) }
        // .driver / .component 是 bundle：先看包内，再看裸目录
        let candidates = [
            (path as NSString).appendingPathComponent("Contents/Info.plist"),
            (path as NSString).appendingPathComponent("Info.plist")
        ]
        var sawPlist = false
        for c in candidates where FileManager.default.fileExists(atPath: c) {
            sawPlist = true
            if let dict = NSDictionary(contentsOfFile: c) {
                return (dict["CFBundleIdentifier"] as? String, true)
            }
        }
        if !sawPlist {
            // 退而用 Bundle API（可能仍读不到）
            if let bundle = Bundle(path: path), let bid = bundle.bundleIdentifier {
                return (bid, true)
            }
            return (nil, false)
        }
        return (nil, true)   // plist 在但无 CFBundleIdentifier：读到了，只是没有这个键
    }

    /// 评估音频插件与驱动的健康状态与宿主归属。
    ///
    /// 保护方向优先级：Apple 官方 > coreaudiod 已加载/设备引用 > 宿主 App 在完整清单中 >
    /// 确证孤儿；**任何一环读不到都落 `.unknownNeedsConfirmation`**。
    public static func evaluateAudioPlugin(
        name: String,
        path: String,
        defaultKind: AudioPluginKind,
        size: Int64,
        metricsReadable: Bool = true,
        infoPlistReadable: Bool = true,
        bundleID: String? = nil,
        evidence: AudioDeviceEvidence,
        installedBundleIDs: Set<String> = [],
        inventoryComplete: Bool = false
    ) -> (bundleID: String?, kind: AudioPluginKind, status: AudioPluginStatus, note: String?) {
        // 1. Apple 官方核心：系统位置 / bundle id 前缀 / 已知官方驱动名
        if isAppleProtected(path) {
            return (bundleID, defaultKind, .appleOfficial, "位于 /System 只读位置，永不触碰")
        }
        if appleOfficialDrivers.contains(name) {
            return (bundleID, defaultKind, .appleOfficial, "Apple 官方核心驱动")
        }
        if let bid = bundleID?.lowercased(),
           appleBundlePrefixes.contains(where: { bid.hasPrefix($0) }) {
            return (bundleID, defaultKind, .appleOfficial, "bundle id 属 com.apple 官方前缀")
        }

        // 2. 真实设备证据命中即"在用"（证据只读到一个来源也认，这是保护方向）
        let live = matchesLiveAudioDriver(name: name, bundleID: bundleID, evidence: evidence)
        if live.matched {
            return (bundleID, defaultKind, .activeInUse, live.why)
        }

        // 3. 量不出来 ≠ 损坏
        guard metricsReadable else {
            return (bundleID, defaultKind, .unknownNeedsConfirmation,
                    "无法读取该驱动目录内容，体积未知")
        }
        if size == 0 {
            return (bundleID, defaultKind, .corrupted, "目录为空（0 文件 0 字节），判定为损坏残留")
        }

        // 4. 宿主归属：读不到 Info.plist / 读不到 bundle id → 未知
        guard infoPlistReadable, let bid = bundleID?.lowercased(), !bid.isEmpty else {
            return (bundleID, defaultKind, .unknownNeedsConfirmation,
                    "读不到 Info.plist 的 CFBundleIdentifier，宿主归属未知")
        }

        // 5. 宿主 App 仍在（完整）已安装清单里 → 在用
        if inventoryComplete, installedBundleIDs.contains(bid) {
            return (bundleID, defaultKind, .activeInUse, "宿主 App 仍在已安装清单中")
        }
        let parts = bid.split(separator: ".")
        if inventoryComplete, parts.count >= 2 {
            let vendorPrefix = "\(parts[0]).\(parts[1])"
            if installedBundleIDs.contains(where: { $0.hasPrefix(vendorPrefix) }) {
                return (bundleID, defaultKind, .activeInUse, "同厂商前缀 \(vendorPrefix) 仍有已安装 App")
            }
        }

        // 6. 只有"插件清单 + 设备清单 + 安装清单"三者都可信，才允许得出孤儿结论
        guard evidence.isFullyReadable else {
            return (bundleID, defaultKind, .unknownNeedsConfirmation,
                    "未能读全 CoreAudio 已加载插件/设备清单\(inventoryComplete ? "" : "，且已安装应用清单不完整")，不判定为孤儿")
        }
        guard inventoryComplete else {
            return (bundleID, defaultKind, .unknownNeedsConfirmation,
                    "已安装应用清单不完整（有根目录读不到），不判定为孤儿")
        }
        return (bundleID, defaultKind, .orphanResidue,
                "coreaudiod 未加载该驱动、无设备引用，且宿主 App 不在完整安装清单中")
    }

    // MARK: - 删除（统一交给网关）

    /// 该路径归属的治理域（主目录内的用户插件与缓存返回 nil，走主目录护栏）
    static func domain(for path: String) -> GovernanceDomain? {
        GovernanceDomain.domain(forPath: path)
    }

    /// 清理选中的音频孤儿驱动与缓存。
    @discardableResult
    func clean(
        items: [AudioPluginItem],
        toTrash: Bool = true,
        journal: ResidueDeletionGate.Journal = .module(categoryName: "音频 HAL 驱动治理"),
        domainOverride: GovernanceDomain? = nil
    ) -> ResidueDeletionGate.Outcome {
        let candidates = items
            .filter { !$0.path.isEmpty }
            .map { ResidueDeletionGate.Candidate(
                $0.name, path: $0.path, domain: domainOverride ?? Self.domain(for: $0.path)) }
        let origin = Dictionary(items.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        return ResidueDeletionGate.execute(candidates, toTrash: toTrash, journal: journal) { cand in
            guard let item = origin[cand.path] else {
                return .make(cand, reason: .notDeletable, message: "该路径不在本轮选定清单里，未删除")
            }
            guard item.status.isOrphanOrCorrupted else {
                // 在用 / Apple 官方 / 需确认 → 一律拒删，并把模块自己的研判结论如实带出去
                return .make(cand, reason: .notDeletable,
                             message: "研判结论为「\(item.status.rawValue)」，不是确证的孤儿/损坏，未删除")
            }
            return nil
        }
    }

    /// 重载 coreaudiod。**默认 TERM（不再 -9）**，并把真实结果原样交给用户。
    public func restartCoreAudioService() -> (success: Bool, message: String) {
        guard SafeProcess.isAvailable(Self.killallPath) else {
            return (false, "未找到 \(Self.killallPath)，音频服务未重启。")
        }
        guard let result = SafeProcess.run(Self.killallPath, ["coreaudiod"], timeout: 10) else {
            return (false, "重启进程未能启动，coreaudiod 未确认重启。")
        }
        if result.succeeded {
            return (true, "已向 coreaudiod 发送 TERM，launchd 会自动重新拉起，音频堆栈将重载。")
        }
        if result.timedOut {
            return (false, "重启 coreaudiod 超时，未确认生效。")
        }
        let detail = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = detail.isEmpty ? "" : "：\(detail)"
        return (false, "coreaudiod 由 root 运行，MacClean 不提权，未能重启（返回码 \(result.exitCode)\(suffix)）。"
                + "需要立即生效请在终端执行 sudo \(Self.killallPath) coreaudiod。")
    }

    // MARK: - 辅助：递归统计目录指标

    struct Metrics {
        let size: Int64
        let fileCount: Int
        let mtime: Date
        /// false = 权限/解析失败，**不得**据此得出"损坏/空"的结论
        let readable: Bool
    }

    static func calculateDirectoryMetrics(at path: String) -> Metrics {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return Metrics(size: 0, fileCount: 0, mtime: Date.distantPast, readable: false)
        }
        if !isDir.boolValue {
            guard let attr = try? fm.attributesOfItem(atPath: path) else {
                return Metrics(size: 0, fileCount: 0, mtime: Date.distantPast, readable: false)
            }
            return Metrics(size: Int64(attr[.size] as? UInt64 ?? 0), fileCount: 1,
                           mtime: attr[.modificationDate] as? Date ?? Date.distantPast, readable: true)
        }
        var totalSize: Int64 = 0
        var fileCount = 0
        var latestMTime = Date.distantPast
        var readable = true
        guard let enumerator = fm.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return Metrics(size: 0, fileCount: 0, mtime: latestMTime, readable: false)
        }
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else {
                readable = false
                continue
            }
            if values.isDirectory == false {
                totalSize += Int64(values.fileSize ?? 0)
                fileCount += 1
            }
            if let mtime = values.contentModificationDate, mtime > latestMTime {
                latestMTime = mtime
            }
        }
        return Metrics(size: totalSize, fileCount: fileCount, mtime: latestMTime, readable: readable)
    }
}
