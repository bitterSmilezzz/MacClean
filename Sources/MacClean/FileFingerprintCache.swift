import Foundation

// MARK: - 文件指纹数据实体

public struct CachedFingerprint: Codable, Equatable {
    public let path: String
    public let fileSize: Int64
    public let mtime: Double
    public var headerHash: String?
    public var sampledHash: String?
    public var fullSHA256: String?
    public var cachedAt: Date

    public init(
        path: String,
        fileSize: Int64,
        mtime: Double,
        headerHash: String? = nil,
        sampledHash: String? = nil,
        fullSHA256: String? = nil,
        cachedAt: Date = Date()
    ) {
        self.path = path
        self.fileSize = fileSize
        self.mtime = mtime
        self.headerHash = headerHash
        self.sampledHash = sampledHash
        self.fullSHA256 = fullSHA256
        self.cachedAt = cachedAt
    }
}

// MARK: - 重复大文件轻量指纹持久化缓存引擎

public final class FileFingerprintCache {
    public static let shared = FileFingerprintCache()

    // 内存指纹映射表 (Key: 路径)
    private var memoryCache: [String: CachedFingerprint] = [:]
    private let lock = NSLock()

    // 性能指标统计
    public private(set) var hitsCount: Int = 0
    public private(set) var missesCount: Int = 0
    public private(set) var savedBytes: Int64 = 0

    // 测试隔离支持
    public var overrideCacheDirectory: URL? {
        didSet {
            loadFromDisk()
        }
    }

    public init(cacheDirectory: URL? = nil) {
        self.overrideCacheDirectory = cacheDirectory
        loadFromDisk()
    }

    private var cacheFileURL: URL {
        if let custom = overrideCacheDirectory {
            return custom.appendingPathComponent("fingerprints.json")
        }
        let cacheDir = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Caches/com.macclean.app", isDirectory: true)
        return cacheDir.appendingPathComponent("fingerprints.json")
    }

    /// 仅清空内存中的缓存条目与统计（不删除磁盘文件）
    public func clearMemory() {
        lock.lock()
        defer { lock.unlock() }
        memoryCache.removeAll()
        hitsCount = 0
        missesCount = 0
        savedBytes = 0
    }

    /// 重置统计指标
    public func resetStats() {
        lock.lock()
        defer { lock.unlock() }
        hitsCount = 0
        missesCount = 0
        savedBytes = 0
    }

    /// 查询缓存的指纹（需校验文件大小与修改时间一致性）
    public func get(path: String, size: Int64, mtime: Date?) -> CachedFingerprint? {
        lock.lock()
        defer { lock.unlock() }

        guard let entry = memoryCache[path] else {
            missesCount += 1
            return nil
        }

        // 大小是否一致
        guard entry.fileSize == size else {
            memoryCache.removeValue(forKey: path)
            missesCount += 1
            return nil
        }

        // 修改时间是否一致（容忍 1 毫秒浮点误差）
        if let currentMtime = mtime {
            let diff = abs(entry.mtime - currentMtime.timeIntervalSince1970)
            guard diff < 0.001 else {
                memoryCache.removeValue(forKey: path)
                missesCount += 1
                return nil
            }
        }

        hitsCount += 1
        if entry.fullSHA256 != nil {
            savedBytes += size
        }
        return entry
    }

    /// 存入或更新指纹
    public func put(
        path: String,
        size: Int64,
        mtime: Date?,
        headerHash: String? = nil,
        sampledHash: String? = nil,
        fullSHA256: String? = nil
    ) {
        lock.lock()
        defer { lock.unlock() }

        let mtimeVal = mtime?.timeIntervalSince1970 ?? 0

        var entry = memoryCache[path] ?? CachedFingerprint(
            path: path,
            fileSize: size,
            mtime: mtimeVal
        )

        // 若 mtime 或 size 发生变化，重置旧哈希
        if entry.fileSize != size || abs(entry.mtime - mtimeVal) >= 0.001 {
            entry = CachedFingerprint(path: path, fileSize: size, mtime: mtimeVal)
        }

        if let h = headerHash { entry.headerHash = h }
        if let s = sampledHash { entry.sampledHash = s }
        if let f = fullSHA256 { entry.fullSHA256 = f }
        entry.cachedAt = Date()

        memoryCache[path] = entry
    }

    /// 使指定路径缓存失效
    public func invalidate(path: String) {
        lock.lock()
        defer { lock.unlock() }
        memoryCache.removeValue(forKey: path)
    }

    /// 清空所有缓存
    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        memoryCache.removeAll()
        hitsCount = 0
        missesCount = 0
        savedBytes = 0
        try? FileManager.default.removeItem(at: cacheFileURL)
    }

    /// 缓存项总数
    public var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return memoryCache.count
    }

    // MARK: - 持久化序列化

    /// 持久化存盘（原子化写入，防止断电或意外退出损坏缓存文件）
    public func saveToDisk() {
        lock.lock()
        let snapshot = memoryCache
        let fileURL = cacheFileURL
        lock.unlock()

        // 仅在有缓存项时写入
        guard !snapshot.isEmpty else { return }

        let dir = fileURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    /// 从磁盘加载缓存
    public func loadFromDisk() {
        lock.lock()
        defer { lock.unlock() }

        let fileURL = cacheFileURL
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        if let loaded = try? decoder.decode([String: CachedFingerprint].self, from: data) {
            self.memoryCache = loaded
        }
    }
}
