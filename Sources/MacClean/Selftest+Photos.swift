import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO

// 自检套件：照片元数据与对比
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 1652–1849）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suitePhotos() {
        check("照片元数据：EXIF 参数深度提取与格式化") {
            let tmp = "/private/tmp/macclean-exif-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            let path = "\(tmp)/photo_with_exif.jpg"
            let cs = CGColorSpaceCreateDeviceGray()
            guard let ctx = CGContext(
                data: nil,
                width: 64,
                height: 64,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }

            let bpr = ctx.bytesPerRow
            if let ptr = ctx.data?.bindMemory(to: UInt8.self, capacity: bpr * 64) {
                for y in 0..<64 {
                    for x in 0..<64 {
                        ptr[y * bpr + x] = UInt8(x ^ y)
                    }
                }
            }
            guard let img = ctx.makeImage() else { return false }
            let url = URL(fileURLWithPath: path) as CFURL
            guard let dest = CGImageDestinationCreateWithURL(url, "public.jpeg" as CFString, 1, nil) else { return false }

            let exif: [CFString: Any] = [
                kCGImagePropertyExifExposureTime: 0.004,
                kCGImagePropertyExifFNumber: 1.8,
                kCGImagePropertyExifISOSpeedRatings: [100],
                kCGImagePropertyExifFocalLength: 24.0,
                kCGImagePropertyExifLensModel: "iPhone 15 Pro lens 24mm"
            ]
            let tiff: [CFString: Any] = [
                kCGImagePropertyTIFFMake: "Apple",
                kCGImagePropertyTIFFModel: "iPhone 15 Pro",
                kCGImagePropertyTIFFDateTime: "2024:06:01 10:30:00"
            ]
            let props: [CFString: Any] = [
                kCGImagePropertyExifDictionary: exif,
                kCGImagePropertyTIFFDictionary: tiff
            ]
            CGImageDestinationAddImage(dest, img, props as CFDictionary)
            guard CGImageDestinationFinalize(dest) else { return false }

            let meta = PhotoMetadata.extract(from: URL(fileURLWithPath: path))
            guard meta.pixelWidth == 64 && meta.pixelHeight == 64 else { return false }
            guard meta.hasExif else { return false }
            guard meta.shutterString == "1/250s" else { return false }
            guard meta.apertureString == "f/1.8" else { return false }
            guard meta.isoString == "ISO 100" else { return false }
            guard meta.cameraSummary.contains("iPhone 15 Pro") else { return false }
            guard meta.format == "JPG" else { return false }
            return true
        }

        check("照片元数据：非 EXIF 普通图片回退解析与哈希") {
            let tmp = "/private/tmp/macclean-plainimg-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            let path = "\(tmp)/screenshot.png"
            let cs = CGColorSpaceCreateDeviceGray()
            guard let ctx = CGContext(
                data: nil,
                width: 48,
                height: 48,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }

            guard let img = ctx.makeImage() else { return false }
            let url = URL(fileURLWithPath: path) as CFURL
            guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return false }
            CGImageDestinationAddImage(dest, img, nil)
            guard CGImageDestinationFinalize(dest) else { return false }

            let meta = PhotoMetadata.extract(from: URL(fileURLWithPath: path))
            guard meta.pixelWidth == 48 && meta.pixelHeight == 48 else { return false }
            guard !meta.hasExif else { return false }
            guard meta.shutterString == "未知快门" else { return false }
            guard meta.format == "PNG" else { return false }
            guard meta.dHash != nil else { return false }
            return true
        }

        check("照片对比：智能画质评分与推荐保留引擎") {
            let metaA = PhotoMetadata(
                fileURL: URL(fileURLWithPath: "/tmp/a.jpg"),
                filePath: "/tmp/a.jpg",
                fileName: "a.jpg",
                fileSize: 4_000_000,
                format: "JPG",
                pixelWidth: 4032,
                pixelHeight: 3024,
                colorSpace: "Display P3",
                make: "Apple",
                model: "iPhone 15 Pro",
                lensModel: nil,
                focalLength: 24.0,
                focalLengthIn35mm: 24.0,
                apertureFNumber: 1.78,
                exposureTimeSeconds: 0.002, // 1/500s 高速快门
                isoSpeed: 64, // 低感纯净
                captureDate: Date(),
                captureDateString: "2024:06:01 10:30:00",
                dHash: 0x1234567890ABCDEF
            )

            let metaB = PhotoMetadata(
                fileURL: URL(fileURLWithPath: "/tmp/b.jpg"),
                filePath: "/tmp/b.jpg",
                fileName: "b.jpg",
                fileSize: 1_000_000,
                format: "JPG",
                pixelWidth: 2016,
                pixelHeight: 1512, // 较低分辨率
                colorSpace: "sRGB",
                make: "Apple",
                model: "iPhone 15 Pro",
                lensModel: nil,
                focalLength: 24.0,
                focalLengthIn35mm: 24.0,
                apertureFNumber: 1.78,
                exposureTimeSeconds: 0.033, // 1/30s 较慢快门
                isoSpeed: 800, // 高感噪点多
                captureDate: Date().addingTimeInterval(-2),
                captureDateString: "2024:06:01 10:29:58",
                dHash: 0x1234567890ABCDE0
            )

            let comparison = PhotoComparisonResult.compare(photoA: metaA, photoB: metaB)
            guard comparison.recommendedChoice == .left else { return false }
            guard comparison.scoreA > comparison.scoreB else { return false }
            guard comparison.recommendationReason.contains("左图") else { return false }
            guard comparison.diffRows.count >= 6 else { return false }
            guard comparison.similarity > 0.9 else { return false }
            return true
        }

        check("照片对比组件：PhotoCompareSheet 渲染与快速决策") {
            let tmp = "/private/tmp/macclean-sheet-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmp) }

            let p1 = "\(tmp)/shot1.jpg"
            let p2 = "\(tmp)/shot2.jpg"
            let cs = CGColorSpaceCreateDeviceGray()
            if let ctx = CGContext(data: nil, width: 32, height: 32, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.none.rawValue),
               let img = ctx.makeImage() {
                for p in [p1, p2] {
                    if let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: p) as CFURL, "public.jpeg" as CFString, 1, nil) {
                        CGImageDestinationAddImage(dest, img, nil)
                        CGImageDestinationFinalize(dest)
                    }
                }
            }

            let item1 = DuplicateFileItem(path: p1, name: "shot1.jpg", size: 5000, modificationDate: Date(), isSelected: false, isOriginal: true)
            let item2 = DuplicateFileItem(path: p2, name: "shot2.jpg", size: 5000, modificationDate: Date(), isSelected: true, isOriginal: false)
            let group = DuplicateGroup(hash: "photo-group-hash", fileSize: 5000, items: [item1, item2], matchKind: .similarImage)

            let state = DuplicateState()
            state.groups = [group]

            var dismissed = false
            let sheet = PhotoCompareSheet(group: group, dupState: state) {
                dismissed = true
            }

            // 测试快速决策：保留左图（取消 item1 勾选，选中 item2 待清理）
            sheet.keepOnlyA()
            guard state.groups[0].items[0].isSelected == false else { return false }
            guard state.groups[0].items[1].isSelected == true else { return false }

            // 测试快速决策：保留右图（选中 item1 待清理，取消 item2 勾选）
            sheet.keepOnlyB()
            guard state.groups[0].items[0].isSelected == true else { return false }
            guard state.groups[0].items[1].isSelected == false else { return false }

            // 测试两张均保留
            sheet.keepBoth()
            guard state.groups[0].items[0].isSelected == false else { return false }
            guard state.groups[0].items[1].isSelected == false else { return false }

            // 测试完成按钮交互
            let doneBtn = try button("photoCompareDoneButton", in: sheet)
            try doneBtn.tap()
            guard dismissed else { return false }

            return true
        }

    }
}
