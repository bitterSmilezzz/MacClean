import Foundation

/// 跨会话增量扫描缓存（v1.34.0）
///
/// 核心思想：记录目录或文件的指纹（mtime + inode + 子项数量及第一层子项修改时间总和）。
/// 在下一次全量扫描时，若指纹完全匹配，直接复用上一次深度测量的 `Measurement`，
/// 避免枚举遍历数十万个小文件所带来的重复磁盘 I/O。
///
/// 线程安全：内部所有读写操作均由 `NSLock` 保护。
enum IncrementalCache {

    /// 目录/文件轻量指纹
    struct Fingerprint: Codable, Equatable {
        let mtime: TimeInterval
        let inode: UInt64
        let isDirectory: Bool
        let childCount: Int
        let directChildrenMTimeSum: TimeInterval
    }

    /// 缓存条目
    struct Entry: Codable {
        let fingerprint: Fingerprint
        let measurement: FileSystem.Measurement
        let timestamp: Date
    }

    private static var cache: [String: Entry] = [:]
    private static let lock = NSLock()

    // 统计指标
    private(set) static var hitCount: Int = 0
    private(set) static var missCount: Int = 0

    /// 计算指定路径的轻量指纹（耗时通常为微秒级，最多只读一层直接子项）
    static func fingerprint(for path: String) -> Fingerprint? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        let isDir = (st.st_mode & S_IFMT) == S_IFDIR
        let mtime = TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        let inode = UInt64(st.st_ino)

        if !isDir {
            return Fingerprint(
                mtime: mtime,
                inode: inode,
                isDirectory: false,
                childCount: 0,
                directChildrenMTimeSum: 0
            )
        }

        // 对于目录：只读取一层直接子项的计数与前 50 项的 mtime 总和（极速微秒级）
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: path) else {
            return Fingerprint(
                mtime: mtime,
                inode: inode,
                isDirectory: true,
                childCount: 0,
                directChildrenMTimeSum: 0
            )
        }

        var sumMTime: TimeInterval = 0
        let sampleLimit = min(items.count, 50)
        for i in 0..<sampleLimit {
            let childPath = (path as NSString).appendingPathComponent(items[i])
            var cst = stat()
            if lstat(childPath, &cst) == 0 {
                sumMTime += TimeInterval(cst.st_mtimespec.tv_sec)
            }
        }

        return Fingerprint(
            mtime: mtime,
            inode: inode,
            isDirectory: true,
            childCount: items.count,
            directChildrenMTimeSum: sumMTime
        )
    }

    /// 获取缓存的测量结果（若存在且指纹一致）
    static func lookup(at path: String) -> FileSystem.Measurement? {
        let key = FileSystem.normalizePath(path)
        lock.lock()
        guard let entry = cache[key] else {
            missCount += 1
            lock.unlock()
            return nil
        }
        lock.unlock()

        // 外部校验当前真实指纹是否匹配
        guard let currentFp = fingerprint(for: path) else {
            // 目标已不存在
            invalidate([path])
            lock.lock()
            missCount += 1
            lock.unlock()
            return nil
        }

        if currentFp == entry.fingerprint {
            lock.lock()
            hitCount += 1
            lock.unlock()
            return entry.measurement
        } else {
            lock.lock()
            missCount += 1
            lock.unlock()
            return nil
        }
    }

    /// 记录/更新测量结果与指纹
    static func update(at path: String, measurement: FileSystem.Measurement) {
        let key = FileSystem.normalizePath(path)
        guard let fp = fingerprint(for: path) else { return }
        lock.lock()
        cache[key] = Entry(fingerprint: fp, measurement: measurement, timestamp: Date())
        lock.unlock()
    }

    /// 让指定路径及其所有祖先目录从增量缓存中失效
    static func invalidate(_ paths: [String]) {
        lock.lock()
        defer { lock.unlock() }
        for p in paths {
            for candidate in [p, FileSystem.realPath(p)] {
                var current = FileSystem.normalizePath(candidate)
                while current.count > 1 {
                    cache.removeValue(forKey: current)
                    let parent = FileSystem.normalizePath((current as NSString).deletingLastPathComponent)
                    if parent == current { break }
                    current = parent
                }
            }
        }
    }

    /// 当前缓存条目数
    static var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.count
    }

    /// 重置统计指标
    static func resetStats() {
        lock.lock()
        hitCount = 0
        missCount = 0
        lock.unlock()
    }

    /// 清空所有缓存（如手动强制完全重新扫描时）
    static func clear() {
        lock.lock()
        cache.removeAll(keepingCapacity: true)
        hitCount = 0
        missCount = 0
        lock.unlock()
    }

    // MARK: - 磁盘持久化
    private static var cacheFileURL: URL {
        // 走 MacCleanState：自检设了 MACCLEAN_STATE_DIR 时不会与真实机器的
        // 跨会话指纹缓存互相覆盖（并发跑自检时尤其需要）
        let dir = MacCleanState.stateDirectory
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir.appendingPathComponent("scan_incremental_cache.json")
    }

    static func saveToDisk() {
        lock.lock()
        let snapshot = cache
        lock.unlock()

        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: cacheFileURL, options: .atomic)
            } catch {
                // 保存失败不中断主流程
            }
        }
    }

    static func loadFromDisk() {
        let url = cacheFileURL
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let loaded = try? JSONDecoder().decode([String: Entry].self, from: data) else {
            return
        }

        lock.lock()
        // 仅保留未超期条目（例如 7 天内的缓存）
        let cutoff = Date().addingTimeInterval(-7 * 86400)
        cache = loaded.filter { $0.value.timestamp > cutoff }
        lock.unlock()
    }
}
