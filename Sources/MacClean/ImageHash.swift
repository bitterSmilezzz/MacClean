import Foundation
import CoreGraphics
import ImageIO

/// 原生高性能感知哈希（Perceptual Hash / dHash 差异哈希）工具
enum ImageHash {
    /// 支持的图片扩展名集合
    static let supportedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "webp", "tiff", "tif", "bmp"
    ]

    /// 判断指定路径是否属于支持比对的图片文件
    static func isImageFile(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return supportedExtensions.contains(ext)
    }

    /// 基于 CoreGraphics 与 ImageIO 原生底层计算 64 位差异感知哈希 (dHash)
    ///
    /// 核心步骤：
    /// 1. 直接在 ImageIO 解码阶段下采样为 16px 极微缩略图，避免载入高清大图造成内存占用；
    /// 2. 绘制到 9x8 灰度位图上下文；
    /// 3. 逐行对比相邻列像素亮度：左边 > 右边 则该 bit 置 1，否则置 0；
    /// 4. 8 行 x 8 次对比 = 64 位整型 (UInt64)。
    static func computeDHash(url: URL) -> UInt64? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 16,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }

        let width = 9
        let height = 8
        let colorSpace = CGColorSpaceCreateDeviceGray()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        context.interpolationQuality = .medium
        context.draw(thumbnail, in: CGRect(x: 0, y: 0, width: width, height: height))

        guard let pixelData = context.data else { return nil }
        let bpr = context.bytesPerRow
        let buffer = pixelData.bindMemory(to: UInt8.self, capacity: bpr * height)

        var hash: UInt64 = 0
        for row in 0..<8 {
            for col in 0..<8 {
                let left = buffer[row * bpr + col]
                let right = buffer[row * bpr + col + 1]
                if left > right {
                    hash |= (UInt64(1) << (row * 8 + col))
                }
            }
        }
        return hash
    }

    /// 根据文件路径便捷计算 dHash
    static func computeDHash(path: String) -> UInt64? {
        computeDHash(url: URL(fileURLWithPath: path))
    }

    /// 计算两个 64 位感知哈希之间的汉明距离（不同 bit 位数）
    @inline(__always)
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }

    /// 评估两张图片的感知相似度 (0.0 ~ 1.0)
    static func similarity(_ a: UInt64, _ b: UInt64) -> Double {
        let dist = hammingDistance(a, b)
        return max(0.0, 1.0 - (Double(dist) / 64.0))
    }

    /// 判断两张图片是否在设定的汉明距离阈值内视作视觉相似（默认最大距离 <= 8，即相似度 >= 87.5%）
    static func isSimilar(_ a: UInt64, _ b: UInt64, maxDistance: Int = 8) -> Bool {
        hammingDistance(a, b) <= maxDistance
    }
}
