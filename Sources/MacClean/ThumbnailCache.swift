import AppKit

// MARK: - 视图缩略图缓存（v1.72.0 性能与主线程治理）
//
// 原先缩略图是在 SwiftUI `body` 里**同步**解码的（`DuplicateThumbnailView`、
// `PhotoCompareView`、`UninstallerView` 三处各写一份）。后果不是"慢一点"而是
// **每次重渲染都重新打盘**：勾选任一文件、悬停、切换分组，都会让所有可见行
// 重新读文件 + 解码 + 走一次 iconservices IPC。300 张图的重复文件列表里，
// 一次勾选就是几百次磁盘访问发生在主线程上。
//
// 现在：解码移到后台队列，结果按路径缓存，主线程只做赋值。

final class ThumbnailCache {
    static let shared = ThumbnailCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: Set<String> = []
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "com.macclean.thumbnail",
                                      qos: .userInitiated, attributes: .concurrent)

    private init() { cache.countLimit = 500 }   // 按个数限制，够一屏 + 滚动余量

    /// 缓存键：同一文件可能被不同尺寸请求（列表 26pt 用 64px、对比视图用 1024px），
    /// 不区分尺寸就会让大图挤掉小图或反过来显示错尺寸。
    private func key(_ path: String, asIcon: Bool, maxPixelSize: Int) -> String {
        "\(path)|\(asIcon ? "icon" : "\(maxPixelSize)")"
    }

    /// 已有结果时同步取回，避免为命中缓存也走一次异步回调
    func cached(_ path: String, asIcon: Bool = false, maxPixelSize: Int = 64) -> NSImage? {
        cache.object(forKey: key(path, asIcon: asIcon, maxPixelSize: maxPixelSize) as NSString)
    }

    /// 取缩略图。命中缓存时**同步**回调（仍在主线程），否则后台解码后回主线程。
    /// 同一路径的并发请求只会真正解码一次。
    func image(for path: String, asIcon: Bool = false, maxPixelSize: Int = 64,
               completion: @escaping (NSImage) -> Void) {
        let cacheKey = key(path, asIcon: asIcon, maxPixelSize: maxPixelSize)
        if let hit = cache.object(forKey: cacheKey as NSString) {
            completion(hit)
            return
        }
        lock.lock()
        let duplicate = inFlight.contains(cacheKey)
        if !duplicate { inFlight.insert(cacheKey) }
        lock.unlock()
        guard !duplicate else { return }

        queue.async { [weak self] in
            let decoded = Self.decode(path: path, asIcon: asIcon, maxPixelSize: maxPixelSize)
            self?.lock.lock()
            self?.inFlight.remove(cacheKey)
            self?.lock.unlock()
            guard let decoded else { return }
            self?.cache.setObject(decoded, forKey: cacheKey as NSString)
            DispatchQueue.main.async { completion(decoded) }
        }
    }

    /// 实际解码。只允许在后台队列调用。
    static func decode(path: String, asIcon: Bool, maxPixelSize: Int = 64) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        if asIcon {
            return NSWorkspace.shared.icon(forFile: path)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return NSWorkspace.shared.icon(forFile: path)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return NSWorkspace.shared.icon(forFile: path)
        }
        return NSImage(cgImage: cg, size: NSSize(width: maxPixelSize, height: maxPixelSize))
    }
}
