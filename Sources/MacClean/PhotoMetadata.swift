import Foundation
import CoreGraphics
import ImageIO

/// 照片 EXIF 与画质元数据模型
struct PhotoMetadata: Equatable {
    let fileURL: URL
    let filePath: String
    let fileName: String
    let fileSize: Int64
    let format: String

    // 图像尺寸与色彩
    let pixelWidth: Int
    let pixelHeight: Int
    let colorSpace: String?

    // 相机与镜头硬件
    let make: String?              // 相机品牌 (如 Apple, SONY, Canon)
    let model: String?             // 相机型号 (如 iPhone 15 Pro, ILCE-7RM5)
    let lensModel: String?         // 镜头型号 (如 iPhone 15 Pro back triple camera 24mm f/1.78)

    // 曝光与快门参数
    let focalLength: Double?       // 物理焦距 (mm)
    let focalLengthIn35mm: Double? // 等效 35mm 焦距 (mm)
    let apertureFNumber: Double?   // 光圈值 (如 1.78)
    let exposureTimeSeconds: Double? // 快门秒数 (如 0.005)
    let isoSpeed: Int?             // 感光度 (如 64)

    // 拍摄时间
    let captureDate: Date?
    let captureDateString: String?

    // 感知哈希
    var dHash: UInt64?

    // MARK: - 衍生与格式化展示属性

    /// 是否包含有效的相机 EXIF 元数据
    var hasExif: Bool {
        apertureFNumber != nil || exposureTimeSeconds != nil || isoSpeed != nil || make != nil || model != nil
    }

    /// 分辨率字符串，例如 "4032 × 3024 (12.2 MP)"
    var resolutionString: String {
        guard pixelWidth > 0 && pixelHeight > 0 else { return "未知尺寸" }
        let megapixels = Double(pixelWidth * pixelHeight) / 1_000_000.0
        if megapixels >= 0.1 {
            return "\(pixelWidth) × \(pixelHeight) (\(String(format: "%.1f", megapixels)) MP)"
        } else {
            return "\(pixelWidth) × \(pixelHeight)"
        }
    }

    /// 格式化快门速度，例如 "1/250s", "1/4s", "2.5s"
    var shutterString: String {
        guard let sec = exposureTimeSeconds, sec > 0 else { return "未知快门" }
        if sec >= 1.0 {
            if sec == floor(sec) {
                return "\(Int(sec))s"
            } else {
                return String(format: "%.1fs", sec)
            }
        } else {
            let denominator = Int(round(1.0 / sec))
            return "1/\(denominator)s"
        }
    }

    /// 格式化光圈，例如 "f/1.8"
    var apertureString: String {
        guard let f = apertureFNumber, f > 0 else { return "未知光圈" }
        if f == floor(f) {
            return "f/\(Int(f))"
        } else {
            return String(format: "f/%.1f", f)
        }
    }

    /// 格式化 ISO 感光度，例如 "ISO 64"
    var isoString: String {
        guard let iso = isoSpeed, iso > 0 else { return "未知 ISO" }
        return "ISO \(iso)"
    }

    /// 格式化焦距，例如 "24 mm" 或 "24 mm (等效 35mm)"
    var focalLengthString: String {
        if let eq = focalLengthIn35mm, eq > 0 {
            return "\(Int(round(eq))) mm (等效)"
        } else if let f = focalLength, f > 0 {
            return "\(String(format: "%.1f", f)) mm"
        } else {
            return "未知焦距"
        }
    }

    /// 格式化相机与镜头，例如 "iPhone 15 Pro"
    var cameraSummary: String {
        if let m = model, !m.isEmpty {
            if let mk = make, !mk.isEmpty, !m.lowercased().contains(mk.lowercased()) {
                return "\(mk) \(m)"
            }
            return m
        } else if let mk = make, !mk.isEmpty {
            return mk
        } else {
            return "未知设备"
        }
    }

    /// 格式化拍摄时间
    var captureTimeString: String {
        if let date = captureDate {
            return Date.usageFormatter.string(from: date)
        } else if let raw = captureDateString, !raw.isEmpty {
            return raw
        } else {
            return "未知拍摄时间"
        }
    }

    // MARK: - 从文件提取 EXIF 与元数据

    /// 原生轻量级提取照片的所有参数与元信息
    static func extract(from url: URL) -> PhotoMetadata {
        let path = url.path
        let filename = url.lastPathComponent
        let ext = url.pathExtension.uppercased()

        var fileSize: Int64 = 0
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64 {
            fileSize = size
        }

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return PhotoMetadata(
                fileURL: url,
                filePath: path,
                fileName: filename,
                fileSize: fileSize,
                format: ext.isEmpty ? "IMAGE" : ext,
                pixelWidth: 0,
                pixelHeight: 0,
                colorSpace: nil,
                make: nil,
                model: nil,
                lensModel: nil,
                focalLength: nil,
                focalLengthIn35mm: nil,
                apertureFNumber: nil,
                exposureTimeSeconds: nil,
                isoSpeed: nil,
                captureDate: nil,
                captureDateString: nil,
                dHash: nil
            )
        }

        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]

        // 基础尺寸
        let pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
        let pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
        let colorSpace = properties[kCGImagePropertyProfileName] as? String
            ?? properties[kCGImagePropertyColorModel] as? String

        // TIFF 字典 (相机品牌、型号、时间)
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let tiffDateTime = tiff?[kCGImagePropertyTIFFDateTime] as? String

        // Exif 字典 (光圈、快门、ISO、焦距、镜头)
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]

        let apertureFNumber = exif?[kCGImagePropertyExifFNumber] as? Double
        let exposureTime = exif?[kCGImagePropertyExifExposureTime] as? Double
        let focalLength = exif?[kCGImagePropertyExifFocalLength] as? Double
        let focalLength35mm = exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double
        let lensModel = (exif?[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

        var isoSpeed: Int? = nil
        if let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isoArray.first {
            isoSpeed = first
        } else if let isoVal = exif?[kCGImagePropertyExifISOSpeedRatings] as? Int {
            isoSpeed = isoVal
        }

        // 解析拍摄日期
        let exifDateTime = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
            ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String
            ?? tiffDateTime

        var parsedDate: Date? = nil
        if let dateStr = exifDateTime {
            parsedDate = parseExifDate(dateStr)
        }

        // 异步或按需计算 dHash
        let dHash = ImageHash.computeDHash(url: url)

        return PhotoMetadata(
            fileURL: url,
            filePath: path,
            fileName: filename,
            fileSize: fileSize,
            format: ext.isEmpty ? "IMAGE" : ext,
            pixelWidth: pixelWidth,
            pixelHeight: pixelHeight,
            colorSpace: colorSpace,
            make: make,
            model: model,
            lensModel: lensModel,
            focalLength: focalLength,
            focalLengthIn35mm: focalLength35mm,
            apertureFNumber: apertureFNumber,
            exposureTimeSeconds: exposureTime,
            isoSpeed: isoSpeed,
            captureDate: parsedDate,
            captureDateString: exifDateTime,
            dHash: dHash
        )
    }

    private static func parseExifDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // 标准 EXIF 时间格式为 "yyyy:MM:dd HH:mm:ss"
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        if let date = formatter.date(from: string) {
            return date
        }
        // 兼容带横线或斜线格式
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.date(from: string)
    }
}

// MARK: - 照片差异比对与智能画质评分引擎

/// 比对优势方
enum PhotoWinnerChoice: String, Equatable {
    case left = "左侧更佳"
    case right = "右侧更佳"
    case tie = "相当"
    case none = "无明显优势"
}

/// 单个参数差异行
struct PhotoDiffRow: Identifiable, Equatable {
    let id: UUID = UUID()
    let icon: String
    let label: String
    let valA: String
    let valB: String
    let winner: PhotoWinnerChoice
    let hint: String?
}

/// 综合对比与建议报告
struct PhotoComparisonResult: Equatable {
    let metaA: PhotoMetadata
    let metaB: PhotoMetadata

    /// 感知哈希相似度 (0.0 ~ 1.0)
    let similarity: Double
    /// 汉明距离 (0 ~ 64)
    let hammingDistance: Int

    /// 差异行列表
    let diffRows: [PhotoDiffRow]

    /// 综合推荐选择
    let recommendedChoice: PhotoWinnerChoice
    /// 综合推荐理由阐述
    let recommendationReason: String

    /// 左侧得分
    let scoreA: Double
    /// 右侧得分
    let scoreB: Double

    /// 计算两张照片的差异与智能分析
    static func compare(photoA: PhotoMetadata, photoB: PhotoMetadata) -> PhotoComparisonResult {
        var rows: [PhotoDiffRow] = []

        var scoreA: Double = 50.0
        var scoreB: Double = 50.0
        var reasons: [String] = []

        // 1. 分辨率对比
        let pixelsA = photoA.pixelWidth * photoA.pixelHeight
        let pixelsB = photoB.pixelWidth * photoB.pixelHeight
        let resWinner: PhotoWinnerChoice
        if pixelsA > 0 && pixelsB > 0 {
            let ratio = Double(pixelsA) / Double(pixelsB)
            if ratio >= 1.25 {
                resWinner = .left
                scoreA += 25.0
                reasons.append("左图分辨率更高 (\(photoA.pixelWidth)×\(photoA.pixelHeight))，细节更丰富")
            } else if ratio <= 0.8 {
                resWinner = .right
                scoreB += 25.0
                reasons.append("右图分辨率更高 (\(photoB.pixelWidth)×\(photoB.pixelHeight))，细节更丰富")
            } else {
                resWinner = .tie
            }
        } else {
            resWinner = .none
        }
        rows.append(PhotoDiffRow(
            icon: "aspectratio",
            label: "图像分辨率",
            valA: photoA.resolutionString,
            valB: photoB.resolutionString,
            winner: resWinner,
            hint: resWinner == .left ? "更高分辨率" : (resWinner == .right ? "更高分辨率" : nil)
        ))

        // 2. 快门速度对比 (越快越不容易手抖模糊，运动抓拍更清晰)
        let shutterWinner: PhotoWinnerChoice
        if let secA = photoA.exposureTimeSeconds, let secB = photoB.exposureTimeSeconds, secA > 0, secB > 0 {
            if secA < secB * 0.75 && secB >= 0.02 { // 比如 1/250s (0.004) vs 1/30s (0.033)
                shutterWinner = .left
                scoreA += 15.0
                reasons.append("左图快门更快 (\(photoA.shutterString))，防抖抓拍更清晰")
            } else if secB < secA * 0.75 && secA >= 0.02 {
                shutterWinner = .right
                scoreB += 15.0
                reasons.append("右图快门更快 (\(photoB.shutterString))，防抖抓拍更清晰")
            } else {
                shutterWinner = .tie
            }
        } else {
            shutterWinner = .none
        }
        rows.append(PhotoDiffRow(
            icon: "timer",
            label: "快门速度",
            valA: photoA.shutterString,
            valB: photoB.shutterString,
            winner: shutterWinner,
            hint: shutterWinner == .left ? "更高速防抖" : (shutterWinner == .right ? "更高速防抖" : nil)
        ))

        // 3. 感光度 ISO 对比 (同等场景下 ISO 越低噪点越少画面越纯净)
        let isoWinner: PhotoWinnerChoice
        if let isoA = photoA.isoSpeed, let isoB = photoB.isoSpeed, isoA > 0, isoB > 0 {
            if Double(isoA) <= Double(isoB) * 0.6 {
                isoWinner = .left
                scoreA += 15.0
                reasons.append("左图 ISO 更低 (\(photoA.isoString))，暗部噪点更少更纯净")
            } else if Double(isoB) <= Double(isoA) * 0.6 {
                isoWinner = .right
                scoreB += 15.0
                reasons.append("右图 ISO 更低 (\(photoB.isoString))，暗部噪点更少更纯净")
            } else {
                isoWinner = .tie
            }
        } else {
            isoWinner = .none
        }
        rows.append(PhotoDiffRow(
            icon: "rays",
            label: "感光度 ISO",
            valA: photoA.isoString,
            valB: photoB.isoString,
            winner: isoWinner,
            hint: isoWinner == .left ? "低噪点纯净" : (isoWinner == .right ? "低噪点纯净" : nil)
        ))

        // 4. 光圈值对比
        let apertureWinner: PhotoWinnerChoice = .none
        rows.append(PhotoDiffRow(
            icon: "camera.aperture",
            label: "光圈大小",
            valA: photoA.apertureString,
            valB: photoB.apertureString,
            winner: apertureWinner,
            hint: nil
        ))

        // 5. 文件体积与格式
        let sizeWinner: PhotoWinnerChoice
        if photoA.fileSize > 0 && photoB.fileSize > 0 {
            if pixelsA == pixelsB {
                let ratio = Double(photoA.fileSize) / Double(photoB.fileSize)
                if ratio >= 1.5 {
                    sizeWinner = .left
                    scoreA += 5.0
                } else if ratio <= 0.67 {
                    sizeWinner = .right
                    scoreB += 5.0
                } else {
                    sizeWinner = .tie
                }
            } else {
                sizeWinner = (pixelsA > pixelsB) ? .left : .right
            }
        } else {
            sizeWinner = .none
        }
        rows.append(PhotoDiffRow(
            icon: "internaldrive",
            label: "文件体积与格式",
            valA: "\(photoA.fileSize.byteStringCN) (\(photoA.format))",
            valB: "\(photoB.fileSize.byteStringCN) (\(photoB.format))",
            winner: sizeWinner,
            hint: nil
        ))

        // 6. 拍摄时间对比
        let timeWinner: PhotoWinnerChoice
        var timeHint: String? = nil
        if let tA = photoA.captureDate, let tB = photoB.captureDate {
            let diffSec = abs(tA.timeIntervalSince(tB))
            if diffSec < 5.0 {
                timeHint = String(format: "高速连拍 (相隔 %.1f 秒)", diffSec)
            }
            timeWinner = (tA >= tB) ? .left : .right
        } else {
            timeWinner = .none
        }
        rows.append(PhotoDiffRow(
            icon: "calendar.badge.clock",
            label: "拍摄时间",
            valA: photoA.captureTimeString,
            valB: photoB.captureTimeString,
            winner: timeWinner,
            hint: timeHint
        ))

        // 7. 相机设备
        rows.append(PhotoDiffRow(
            icon: "camera",
            label: "相机设备",
            valA: photoA.cameraSummary,
            valB: photoB.cameraSummary,
            winner: .none,
            hint: nil
        ))

        // 8. 视觉相似度
        let dHashA = photoA.dHash ?? ImageHash.computeDHash(url: photoA.fileURL)
        let dHashB = photoB.dHash ?? ImageHash.computeDHash(url: photoB.fileURL)
        let similarity: Double
        let hammingDist: Int
        if let hA = dHashA, let hB = dHashB {
            similarity = ImageHash.similarity(hA, hB)
            hammingDist = ImageHash.hammingDistance(hA, hB)
        } else {
            similarity = 1.0
            hammingDist = 0
        }

        let simText = "\(String(format: "%.1f", similarity * 100))% (汉明距离: \(hammingDist))"
        rows.append(PhotoDiffRow(
            icon: "waveform.path.ecg",
            label: "感知视觉相似度",
            valA: simText,
            valB: simText,
            winner: .tie,
            hint: similarity >= 0.95 ? "构图高度一致" : "存在构图或光线微变"
        ))

        // 综合裁定
        let recommendedChoice: PhotoWinnerChoice
        let reasonStr: String
        if scoreA > scoreB + 5.0 {
            recommendedChoice = .left
            if reasons.isEmpty {
                reasonStr = "综合画质评估推荐保留左侧照片，文件质量更佳。"
            } else {
                reasonStr = "推荐保留左侧：\(reasons.joined(separator: "；"))。"
            }
        } else if scoreB > scoreA + 5.0 {
            recommendedChoice = .right
            if reasons.isEmpty {
                reasonStr = "综合画质评估推荐保留右侧照片，文件质量更佳。"
            } else {
                reasonStr = "推荐保留右侧：\(reasons.joined(separator: "；"))。"
            }
        } else {
            recommendedChoice = .tie
            reasonStr = "两张照片的曝光参数、分辨率与画质高度接近，建议按构图偏好选择保留。"
        }

        return PhotoComparisonResult(
            metaA: photoA,
            metaB: photoB,
            similarity: similarity,
            hammingDistance: hammingDist,
            diffRows: rows,
            recommendedChoice: recommendedChoice,
            recommendationReason: reasonStr,
            scoreA: scoreA,
            scoreB: scoreB
        )
    }
}
