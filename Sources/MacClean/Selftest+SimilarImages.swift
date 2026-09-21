import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：相似图片与感知哈希
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 1407–1546）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteSimilarImages() {
        check("感知哈希：dHash 计算与汉明距离") {
            guard ImageHash.isImageFile(path: "photo.JPG") else { return false }
            guard ImageHash.isImageFile(path: "image.png") else { return false }
            guard ImageHash.isImageFile(path: "snapshot.heic") else { return false }
            guard !ImageHash.isImageFile(path: "document.pdf") else { return false }
            guard !ImageHash.isImageFile(path: "video.mp4") else { return false }

            let tmp = "/private/tmp/macclean-dhash-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            func writeTestPattern(width: Int, height: Int, path: String, pattern: (Int, Int) -> UInt8) -> Bool {
                let cs = CGColorSpaceCreateDeviceGray()
                guard let ctx = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }

                let bpr = ctx.bytesPerRow
                guard let ptr = ctx.data?.bindMemory(to: UInt8.self, capacity: bpr * height) else { return false }
                for y in 0..<height {
                    for x in 0..<width {
                        ptr[y * bpr + x] = pattern(x, y)
                    }
                }
                guard let img = ctx.makeImage() else { return false }
                let url = URL(fileURLWithPath: path) as CFURL
                guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return false }
                CGImageDestinationAddImage(dest, img, nil)
                return CGImageDestinationFinalize(dest)
            }

            let p1 = "\(tmp)/img_64.png"
            let p2 = "\(tmp)/img_48.png"
            let p3 = "\(tmp)/other.png"

            // 图像 1 与图像 2 具有相同的棋盘/对角渐变视觉特征（仅尺寸不同：64x64 vs 48x48）
            guard writeTestPattern(width: 64, height: 64, path: p1, pattern: { x, y in UInt8((x * 255 / 64) ^ (y * 255 / 64)) }) else { return false }
            guard writeTestPattern(width: 48, height: 48, path: p2, pattern: { x, y in UInt8((x * 255 / 48) ^ (y * 255 / 48)) }) else { return false }
            // 图像 3 具有同心圆正弦特征，视觉差异极大
            guard writeTestPattern(width: 64, height: 64, path: p3, pattern: { x, y in
                let dx = Double(x - 32), dy = Double(y - 32)
                return UInt8(clamping: Int(sin(sqrt(dx*dx + dy*dy) / 4.0) * 127.0 + 128.0))
            }) else { return false }

            guard let h1 = ImageHash.computeDHash(path: p1),
                  let h2 = ImageHash.computeDHash(path: p2),
                  let h3 = ImageHash.computeDHash(path: p3) else { return false }

            let distSimilar = ImageHash.hammingDistance(h1, h2)
            let distDifferent = ImageHash.hammingDistance(h1, h3)

            guard distSimilar <= 8 else { return false }
            guard ImageHash.isSimilar(h1, h2, maxDistance: 8) else { return false }
            guard ImageHash.similarity(h1, h2) >= 0.875 else { return false }

            guard distDifferent > 8 else { return false }
            guard !ImageHash.isSimilar(h1, h3, maxDistance: 8) else { return false }

            return true
        }

        check("相似图片：视觉聚类与推荐保留规则") {
            let tmp = "/private/tmp/macclean-imgcluster-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            func writeTestPattern(width: Int, height: Int, path: String, pattern: (Int, Int) -> UInt8) -> Bool {
                let cs = CGColorSpaceCreateDeviceGray()
                guard let ctx = CGContext(
                    data: nil,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: 0,
                    space: cs,
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                ) else { return false }

                let bpr = ctx.bytesPerRow
                guard let ptr = ctx.data?.bindMemory(to: UInt8.self, capacity: bpr * height) else { return false }
                for y in 0..<height {
                    for x in 0..<width {
                        ptr[y * bpr + x] = pattern(x, y)
                    }
                }
                guard let img = ctx.makeImage() else { return false }
                let url = URL(fileURLWithPath: path) as CFURL
                guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return false }
                CGImageDestinationAddImage(dest, img, nil)
                return CGImageDestinationFinalize(dest)
            }

            // 创建两张同图不同分辨率的图片（模拟相机原图与缩略图/连拍）
            let fHigh = "\(tmp)/DSC_1001.png"
            let fLow = "\(tmp)/DSC_1002.png"
            let fUnrelated = "\(tmp)/Unrelated_Artwork.png"

            guard writeTestPattern(width: 80, height: 80, path: fHigh, pattern: { x, y in UInt8((x * 255 / 80) ^ (y * 255 / 80)) }) else { return false }
            guard writeTestPattern(width: 40, height: 40, path: fLow, pattern: { x, y in UInt8((x * 255 / 40) ^ (y * 255 / 40)) }) else { return false }
            guard writeTestPattern(width: 80, height: 80, path: fUnrelated, pattern: { x, y in
                let dx = Double(x - 40), dy = Double(y - 40)
                return UInt8(clamping: Int(sin(sqrt(dx*dx + dy*dy) / 4.0) * 127.0 + 128.0))
            }) else { return false }

            // 扫描该目录（minSize 设为 1，确保测试小文件参与扫描）
            let groups = DuplicateScanner.scanDuplicates(in: [tmp], minSize: 1) { _, _ in }
            let simGroups = groups.filter { $0.matchKind == .similarImage }
            guard simGroups.count == 1 else { return false }

            let group = simGroups[0]
            guard group.items.count == 2 else { return false }
            // 推荐保留应该偏向体积大/高清的 fHigh (80x80)
            guard let original = group.items.first(where: \.isOriginal) else { return false }
            guard original.path == fHigh else { return false }
            guard original.recommendationReason?.contains("推荐保留") == true else { return false }

            // 次要副本应带相似度标签
            guard let secondary = group.items.first(where: { !$0.isOriginal }) else { return false }
            guard secondary.path == fLow else { return false }
            guard secondary.recommendationReason?.contains("相似度") == true else { return false }

            // 独立无相似的图片不应成组
            let allGroupedPaths = Set(group.items.map(\.path))
            guard !allGroupedPaths.contains(fUnrelated) else { return false }

            return true
        }

        check("相似图片组件：DuplicateThumbnailView 渲染与空态回退") {
            let thumb = DuplicateThumbnailView(path: "/nonexistent/test.png", isImage: true)
            _ = try thumb.inspect()
            return true
        }

        check("相似图片分桶：候选对与两两全比对完全等价（O(n²) 优化不漏判）") {
            // 这条守住的是优化本身：分桶换掉全比对之后，**任何一对距离 ≤ 8 的哈希
            // 仍必须被找到**。漏一对就是真实的相似图片没被归组，属于静默正确性回归。
            let maxDistance = 8
            var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
            func next() -> UInt64 {
                seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
                return seed
            }
            var hashes: [UInt64] = []
            let base = next()
            for bit in 0..<64 { hashes.append(base ^ (UInt64(1) << UInt64(bit))) }
            // 扰动 8 位的成对样本：正好压在阈值边界上，最容易漏
            for bit in 0..<64 { hashes.append((base ^ (UInt64(1) << UInt64(bit))) ^ (base >> 32)) }
            for _ in 0..<200 { hashes.append(next()) }

            func pairKey(_ i: Int, _ j: Int) -> String { "\(min(i, j))-\(max(i, j))" }
            var brute = Set<String>()
            for i in 0..<(hashes.count - 1) {
                for j in (i + 1)..<hashes.count where ImageHash.isSimilar(hashes[i], hashes[j], maxDistance: maxDistance) {
                    brute.insert(pairKey(i, j))
                }
            }
            guard !brute.isEmpty else { return false }

            var buckets: [UInt64: [Int]] = [:]
            for (idx, hash) in hashes.enumerated() {
                let keys = ImageHash.bandKeys(of: hash, bands: maxDistance + 1)
                guard keys.count == maxDistance + 1, Set(keys).count == keys.count else { return false }
                for key in keys { buckets[key, default: []].append(idx) }
            }
            var bucketed = Set<String>()
            for indices in buckets.values where indices.count > 1 {
                for a in 0..<(indices.count - 1) {
                    for b in (a + 1)..<indices.count
                    where ImageHash.isSimilar(hashes[indices[a]], hashes[indices[b]], maxDistance: maxDistance) {
                        bucketed.insert(pairKey(indices[a], indices[b]))
                    }
                }
            }
            return bucketed == brute
        }

    }
}
