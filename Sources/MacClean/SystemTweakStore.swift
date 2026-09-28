import Foundation

/// 系统偏好的**读 / 写 / 还原**。
///
/// ## 这里没有任何删除路径
///
/// 它不删文件、不碰磁盘内容，所以**不走**统一删除网关、也不注册治理域——
/// 那是给"不可逆的文件删除"用的。这里换的是另一种副作用：改设置。
///
/// 但"不许猜"这条底线一样：**每一次写入都必须先读到旧值、并落下一条撤销记录之后**
/// 才允许发出写命令。读失败就拒绝写——否则撤销记录里会存一个错的"旧值"，
/// 将来还原时会把一个本来有值的键删掉或改成错的数，那比不改更糟。
enum SystemTweakStore {

    static let defaultsPath = "/usr/bin/defaults"
    static let killallPath = "/usr/bin/killall"

    // MARK: - 读（只读，永不写）

    /// 读任意 domain/key 的现状。
    ///
    /// 返回 `.unset` = 这个键确实不存在（一个**真实的、可以还原到的状态**）；
    /// 返回 `nil` = **读失败**（命令起不来、输出解析不了）。
    /// 这两者绝对不能混：前者可以安全地写进撤销记录，后者写进去就是伪造。
    /// `defaults` 报"这个东西不存在"时的文案。**跨系统版本、跨查询粒度都会变**，所以是一张表：
    ///
    /// | 场景 | 实际输出 |
    /// |---|---|
    /// | 旧版 macOS，键不存在 | `The domain/default pair of (com.apple.dock, show-recents) does not exist` |
    /// | macOS 27，键不存在 | `Error: Could not find key 'show-recents' in domain 'com.apple.dock'.` |
    /// | macOS 27，**域**不存在 | `Error: Domain 'com.example.nope' not found.` |
    ///
    /// 这张表是**被真机一条条逼出来的**：起初只认第一句，于是 macOS 27 上所有"未设置"的键
    /// 都被显示成「读不到」；补了第二句之后，`--prefs-roundtrip` 又在"域根本不存在"这一步
    /// 红了——因为第三句的 `not found` 不在表里。
    ///
    /// 为什么值得这么啰嗦：**"读不到"与"未设置"在"能不能写"这件事上结论相反**。
    /// 前者必须拒绝写（没有旧值就没有真撤销），后者是可以安全记进撤销记录的真实状态。
    /// 认错方向的后果是功能静默不可用，或者写出一条假的撤销记录。
    ///
    /// 反向也要小心：只按"非 0 退出"就判未设置，会把权限错误之类的真失败误当成"不存在"。
    /// 所以这里匹配的是**查找失败**的措辞，认不出来的仍然返回读失败。
    private static let keyMissingMarkers = [
        "does not exist",
        "could not find",
        "not find key",
        "domain/default pair",
        "not found",
    ]

    static func readRaw(domain: String, key: String, kind: TweakKind) -> TweakValue? {
        guard let result = SafeProcess.run(defaultsPath, ["read", domain, key], timeout: 8) else {
            return nil
        }
        if result.exitCode != 0 {
            // `SafeProcess` 把 stdout/stderr 合到同一个管道，所以这里能看到 `defaults` 的报错。
            let text = result.output.lowercased()
            if keyMissingMarkers.contains(where: { text.contains($0) }) {
                return .unset
            }
            return nil
        }
        return TweakValue.parse(raw: result.output, kind: kind)
    }

    static func read(_ tweak: SystemTweak) -> TweakValue? {
        readRaw(domain: tweak.domain, key: tweak.key, kind: tweak.kind)
    }

    /// 体检：逐条读现状给结论。**只读，绝不写任何偏好。**
    static func inspect(_ tweaks: [SystemTweak] = SystemTweak.catalog) -> [TweakFinding] {
        tweaks.map { tweak in
            let current = read(tweak)
            return TweakFinding(tweak: tweak,
                                current: current,
                                status: TweakFinding.status(current: current,
                                                            recommended: tweak.recommended))
        }
    }

    // MARK: - 写（必须能还原）

    /// 一条撤销记录。
    ///
    /// `previous == .unset` 是关键：它表示"改之前这个键根本不存在"，
    /// 还原时**必须删除该键**，而不是写一个像默认值的数。
    struct ChangeRecord: Codable, Identifiable, Equatable {
        var id: UUID = UUID()
        var tweakID: String
        var domain: String
        var key: String
        var kind: TweakKind
        var previous: TweakValue
        var appliedAt: Date = Date()
    }

    enum ApplyOutcome: Equatable {
        case applied(ChangeRecord)
        /// 读不到旧值 → 拒绝写（没有旧值就没有真的撤销）
        case refusedReadingFailed
        /// 撤销记录落盘失败 → 拒绝写（宁可什么都没发生）
        case refusedUndoNotPersisted
        case writeFailed
    }

    /// 应用一条优化项。
    ///
    /// 顺序不能改：**先读 → 再落撤销记录 → 最后才写**。
    /// 任何一步失败都停下，且不留半成品（写失败会把刚落的记录撤掉）。
    static func apply(_ tweak: SystemTweak) -> ApplyOutcome {
        guard let previous = read(tweak) else {
            return .refusedReadingFailed
        }
        let record = ChangeRecord(tweakID: tweak.id, domain: tweak.domain,
                                  key: tweak.key, kind: tweak.kind, previous: previous)
        guard appendRecord(record) else { return .refusedUndoNotPersisted }
        guard writeRaw(domain: tweak.domain, key: tweak.key, value: tweak.recommended) else {
            removeRecord(record.id)
            return .writeFailed
        }
        return .applied(record)
    }

    /// 写一个值。`.unset` = **删除该键**（这才是"还原到没设过"）。
    @discardableResult
    static func writeRaw(domain: String, key: String, value: TweakValue) -> Bool {
        if value == .unset {
            return SafeProcess.run(defaultsPath, ["delete", domain, key], timeout: 8)?.succeeded ?? false
        }
        let args = ["write", domain, key] + value.writeArguments
        return SafeProcess.run(defaultsPath, args, timeout: 8)?.succeeded ?? false
    }

    /// 撤销一次改动：把记录里的旧值写回去，成功后删掉这条记录。
    @discardableResult
    static func revert(_ record: ChangeRecord) -> Bool {
        if record.previous == .unset {
            // 目标状态是"这个键不存在"。它可能**已经**不存在了（比如用户自己删了），
            // 此时 `defaults delete` 会以非 0 退出——那不是失败，是目标已达成。
            if readRaw(domain: record.domain, key: record.key, kind: record.kind) == .unset {
                removeRecord(record.id)
                return true
            }
        }
        guard writeRaw(domain: record.domain, key: record.key, value: record.previous) else {
            return false
        }
        removeRecord(record.id)
        return true
    }

    /// 重启进程让偏好生效。
    ///
    /// **必须由用户显式触发**：重启 Dock 会让整条程序坞闪一下，
    /// 重启 Finder 会关掉所有访达窗口。工具不替用户决定这件事。
    @discardableResult
    static func restart(process: String) -> Bool {
        SafeProcess.run(killallPath, [process], timeout: 8)?.succeeded ?? false
    }

    // MARK: - 撤销记录的落盘

    /// 记录条数上限：只留最近的一批。撤销是"刚改错了能退回来"，
    /// 不是"永久审计账本"，没必要无限增长。
    static let recordLimit = 100

    private static let lock = NSLock()

    static var storeURL: URL {
        MacCleanState.stateDirectory.appendingPathComponent("tweak_changes.json")
    }

    /// 读全部撤销记录。读不出来就当空——**但不能因此放行写入**：
    /// `appendRecord` 会在读失败时返回 false，从而拒绝写入。
    static func loadRecords() -> [ChangeRecord]? {
        lock.lock()
        defer { lock.unlock() }
        return loadRecordsUnlocked()
    }

    private static func loadRecordsUnlocked() -> [ChangeRecord]? {
        let url = storeURL
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        guard let data = try? Data(contentsOf: url) else { return nil }
        if data.isEmpty { return [] }
        do {
            return try makeDecoder().decode([ChangeRecord].self, from: data)
        } catch {
            // 解不开 = 文件坏了，或**编码/解码策略不一致**。
            // **返回 nil 而不是 []**：返回 [] 会让调用方以为"没有记录"，
            // 随后 append 时把坏文件整片覆盖掉。
            return nil
        }
    }

    /// 追加一条记录，成功返回 true。
    /// 只有在**确实落盘成功**之后才返回 true——调用方据此决定要不要动系统。
    @discardableResult
    private static func appendRecord(_ record: ChangeRecord) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard var records = loadRecordsUnlocked() else { return false }
        records.append(record)
        if records.count > recordLimit {
            records = Array(records.suffix(recordLimit))
        }
        return writeRecordsUnlocked(records)
    }

    private static func removeRecord(_ id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var records = loadRecordsUnlocked() else { return }
        records.removeAll { $0.id == id }
        _ = writeRecordsUnlocked(records)
    }

    private static func writeRecordsUnlocked(_ records: [ChangeRecord]) -> Bool {
        guard let data = try? makeEncoder().encode(records) else { return false }
        do {
            try data.write(to: storeURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// 编解码策略必须**成对出现**，不能一边一套。
    ///
    /// 这里踩过的坑：写的时候用了 `.iso8601`（人类可读），读的时候图省事用了
    /// `JSONDecoder()` 的默认策略（`.deferredToDate`，把 Date 当 double）——
    /// 于是 `.iso8601` 的字符串解不成 Date，**整份撤销记录永远读不回来**，
    /// 撤销功能等于失效，而且失败得很安静（`loadRecordsUnlocked` 返回 nil，
    /// 调用方只看到"没有记录"）。
    /// 抓出它的是自检里那条"写入顺序"用例；所以这两个构造函数故意放在一起。
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// 自检用：整体替换（只在隔离状态目录下用）。
    static func replaceRecordsForSelftest(_ records: [ChangeRecord]) {
        lock.lock()
        defer { lock.unlock() }
        _ = writeRecordsUnlocked(records)
    }

    /// 自检用。
    static func resetRecordsForSelftest() {
        replaceRecordsForSelftest([])
    }
}
