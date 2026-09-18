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
        let format = ext.isEmpty ? "IMAGE" : ext
        let fileSize = readFileSize(atPath: path)

        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return undecodableMetadata(url: url, path: path, fileName: filename,
                                       format: format, fileSize: fileSize)
        }

        let properties = (CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]) ?? [:]
        let fields = ExifFields(properties: properties)

        return PhotoMetadata(
            fileURL: url,
            filePath: path,
            fileName: filename,
            fileSize: fileSize,
            format: format,
            pixelWidth: fields.pixelWidth,
            pixelHeight: fields.pixelHeight,
            colorSpace: fields.colorSpace,
            make: fields.make,
            model: fields.model,
            lensModel: fields.lensModel,
            focalLength: fields.focalLength,
            focalLengthIn35mm: fields.focalLengthIn35mm,
            apertureFNumber: fields.apertureFNumber,
            exposureTimeSeconds: fields.exposureTimeSeconds,
            isoSpeed: fields.isoSpeed,
            captureDate: fields.captureDate,
            captureDateString: fields.captureDateString,
            // 异步或按需计算 dHash
            dHash: ImageHash.computeDHash(url: url)
        )
    }

    /// 读取文件字节数，读不到属性时按 0 处理
    private static func readFileSize(atPath path: String) -> Int64 {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int64 {
            return size
        }
        return 0
    }

    /// 图像无法解码时的占位元数据：保留文件自身信息，EXIF 字段全空
    private static func undecodableMetadata(url: URL, path: String, fileName: String,
                                            format: String, fileSize: Int64) -> PhotoMetadata {
        PhotoMetadata(
            fileURL: url,
            filePath: path,
            fileName: fileName,
            fileSize: fileSize,
            format: format,
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

    /// ImageIO 属性字典中解析出的相机 / 曝光 / 时间字段
    private struct ExifFields {
        var pixelWidth = 0
        var pixelHeight = 0
        var colorSpace: String?
        var make: String?
        var model: String?
        var lensModel: String?
        var focalLength: Double?
        var focalLengthIn35mm: Double?
        var apertureFNumber: Double?
        var exposureTimeSeconds: Double?
        var isoSpeed: Int?
        var captureDate: Date?
        var captureDateString: String?

        init(properties: [CFString: Any]) {
            // 基础尺寸
            pixelWidth = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            pixelHeight = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            colorSpace = properties[kCGImagePropertyProfileName] as? String
                ?? properties[kCGImagePropertyColorModel] as? String

            // TIFF 字典 (相机品牌、型号、时间)
            let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
            make = (tiff?[kCGImagePropertyTIFFMake] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            model = (tiff?[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let tiffDateTime = tiff?[kCGImagePropertyTIFFDateTime] as? String

            // Exif 字典 (光圈、快门、ISO、焦距、镜头)
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            apertureFNumber = exif?[kCGImagePropertyExifFNumber] as? Double
            exposureTimeSeconds = exif?[kCGImagePropertyExifExposureTime] as? Double
            focalLength = exif?[kCGImagePropertyExifFocalLength] as? Double
            focalLengthIn35mm = exif?[kCGImagePropertyExifFocalLenIn35mmFilm] as? Double
            lensModel = (exif?[kCGImagePropertyExifLensModel] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)

            if let isoArray = exif?[kCGImagePropertyExifISOSpeedRatings] as? [Int], let first = isoArray.first {
                isoSpeed = first
            } else if let isoVal = exif?[kCGImagePropertyExifISOSpeedRatings] as? Int {
                isoSpeed = isoVal
            }

            // 解析拍摄日期：Exif 原始时间优先，退回数字化时间，再退回 TIFF 时间
            captureDateString = exif?[kCGImagePropertyExifDateTimeOriginal] as? String
                ?? exif?[kCGImagePropertyExifDateTimeDigitized] as? String
                ?? tiffDateTime
            if let dateStr = captureDateString {
                captureDate = parseExifDate(dateStr)
            }
        }
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
        let pair = PhotoPair(a: photoA, b: photoB)

        // 逐项判定：顺序即差异表行序，也是推荐理由的拼接顺序
        let criteria: [CriterionVerdict] = [
            resolutionVerdict(pair),
            shutterVerdict(pair),
            isoVerdict(pair),
            apertureVerdict(pair),
            fileSizeVerdict(pair),
            captureTimeVerdict(pair),
            cameraVerdict(pair)
        ]
        var scoreA: Double = 50.0
        var scoreB: Double = 50.0
        var reasons: [String] = []
        for criterion in criteria {
            scoreA += criterion.scoreA
            scoreB += criterion.scoreB
            if let reason = criterion.reason { reasons.append(reason) }
        }
        var rows: [PhotoDiffRow] = criteria.map(\.row)

        // 8. 视觉相似度
        let hash = perceptualSimilarity(pair)
        rows.append(similarityRow(similarity: hash.similarity, hammingDistance: hash.hammingDistance))

        // 综合裁定
        let verdict = recommendation(scoreA: scoreA, scoreB: scoreB, reasons: reasons)

        return PhotoComparisonResult(
            metaA: photoA,
            metaB: photoB,
            similarity: hash.similarity,
            hammingDistance: hash.hammingDistance,
            diffRows: rows,
            recommendedChoice: verdict.choice,
            recommendationReason: verdict.reason,
            scoreA: scoreA,
            scoreB: scoreB
        )
    }

    // MARK: - 单项画质判定

    /// 待比对的一对照片，附派生像素总量
    private struct PhotoPair {
        let a: PhotoMetadata
        let b: PhotoMetadata

        var pixelsA: Int { a.pixelWidth * a.pixelHeight }
        var pixelsB: Int { b.pixelWidth * b.pixelHeight }
    }

    /// 单项判定结果：差异行 + 双方得分增量 + 可选推荐理由
    private struct CriterionVerdict {
        let row: PhotoDiffRow
        var scoreA: Double = 0
        var scoreB: Double = 0
        var reason: String? = nil
    }

    /// 1. 分辨率对比：像素总量领先 25% 以上才算优势，得 25 分
    private static func resolutionVerdict(_ pair: PhotoPair) -> CriterionVerdict {
        func verdict(_ winner: PhotoWinnerChoice, scoreA: Double = 0, scoreB: Double = 0,
                     reason: String? = nil) -> CriterionVerdict {
            CriterionVerdict(
                row: PhotoDiffRow(
                    icon: "aspectratio",
                    label: "图像分辨率",
                    valA: pair.a.resolutionString,
                    valB: pair.b.resolutionString,
                    winner: winner,
                    hint: winner == .left ? "更高分辨率" : (winner == .right ? "更高分辨率" : nil)
                ),
                scoreA: scoreA,
                scoreB: scoreB,
                reason: reason
            )
        }

        guard pair.pixelsA > 0, pair.pixelsB > 0 else { return verdict(.none) }
        let ratio = Double(pair.pixelsA) / Double(pair.pixelsB)
        if ratio >= 1.25 {
            return verdict(.left, scoreA: 25.0,
                           reason: "左图分辨率更高 (\(pair.a.pixelWidth)×\(pair.a.pixelHeight))，细节更丰富")
        }
        if ratio <= 0.8 {
            return verdict(.right, scoreB: 25.0,
                           reason: "右图分辨率更高 (\(pair.b.pixelWidth)×\(pair.b.pixelHeight))，细节更丰富")
        }
        return verdict(.tie)
    }

    /// 2. 快门速度对比：越快越不容易手抖模糊，需快 25% 且较慢一方不慢于 1/50s，得 15 分
    private static func shutterVerdict(_ pair: PhotoPair) -> CriterionVerdict {
        func verdict(_ winner: PhotoWinnerChoice, scoreA: Double = 0, scoreB: Double = 0,
                     reason: String? = nil) -> CriterionVerdict {
            CriterionVerdict(
                row: PhotoDiffRow(
                    icon: "timer",
                    label: "快门速度",
                    valA: pair.a.shutterString,
                    valB: pair.b.shutterString,
                    winner: winner,
                    hint: winner == .left ? "更高速防抖" : (winner == .right ? "更高速防抖" : nil)
                ),
                scoreA: scoreA,
                scoreB: scoreB,
                reason: reason
            )
        }

        guard let secA = pair.a.exposureTimeSeconds, let secB = pair.b.exposureTimeSeconds,
              secA > 0, secB > 0 else { return verdict(.none) }
        if secA < secB * 0.75 && secB >= 0.02 { // 比如 1/250s (0.004) vs 1/30s (0.033)
            return verdict(.left, scoreA: 15.0,
                           reason: "左图快门更快 (\(pair.a.shutterString))，防抖抓拍更清晰")
        }
        if secB < secA * 0.75 && secA >= 0.02 {
            return verdict(.right, scoreB: 15.0,
                           reason: "右图快门更快 (\(pair.b.shutterString))，防抖抓拍更清晰")
        }
        return verdict(.tie)
    }

    /// 3. 感光度 ISO 对比：同等场景下 ISO 越低噪点越少，低至对方 60% 以下得 15 分
    private static func isoVerdict(_ pair: PhotoPair) -> CriterionVerdict {
        func verdict(_ winner: PhotoWinnerChoice, scoreA: Double = 0, scoreB: Double = 0,
                     reason: String? = nil) -> CriterionVerdict {
            CriterionVerdict(
                row: PhotoDiffRow(
                    icon: "rays",
                    label: "感光度 ISO",
                    valA: pair.a.isoString,
                    valB: pair.b.isoString,
                    winner: winner,
                    hint: winner == .left ? "低噪点纯净" : (winner == .right ? "低噪点纯净" : nil)
                ),
                scoreA: scoreA,
                scoreB: scoreB,
                reason: reason
            )
        }

        guard let isoA = pair.a.isoSpeed, let isoB = pair.b.isoSpeed, isoA > 0, isoB > 0 else {
            return verdict(.none)
        }
        if Double(isoA) <= Double(isoB) * 0.6 {
            return verdict(.left, scoreA: 15.0,
                           reason: "左图 ISO 更低 (\(pair.a.isoString))，暗部噪点更少更纯净")
        }
        if Double(isoB) <= Double(isoA) * 0.6 {
            return verdict(.right, scoreB: 15.0,
                           reason: "右图 ISO 更低 (\(pair.b.isoString))，暗部噪点更少更纯净")
        }
        return verdict(.tie)
    }

    /// 4. 光圈大小：只展示双方取值，不参与评分
    private static func apertureVerdict(_ pair: PhotoPair) -> CriterionVerdict {
        CriterionVerdict(
            row: PhotoDiffRow(
                icon: "camera.aperture",
                label: "光圈大小",
                valA: pair.a.apertureString,
                valB: pair.b.apertureString,
                winner: .none,
                hint: nil
            )
        )
    }

    /// 5. 文件体积与格式：同分辨率下体积大 50% 以上得 5 分；分辨率不同则直接按像素总量定优劣
    private static func fileSizeVerdict(_ pair: PhotoPair) -> CriterionVerdict {
        func verdict(_ winner: PhotoWinnerChoice, scoreA: Double = 0, scoreB: Double = 0) -> CriterionVerdict {
            CriterionVerdict(
                row: PhotoDiffRow(
                    icon: "internaldrive",
                    label: "文件体积与格式",
                    valA: "\(pair.a.fileSize.byteStringCN) (\(pair.a.format))",
                    valB: "\(pair.b.fileSize.byteStringCN) (\(pair.b.format))",
                    winner: winner,
                    hint: nil
                ),
                scoreA: scoreA,
                scoreB: scoreB
            )
        }

        guard pair.a.fileSize > 0, pair.b.fileSize > 0 else { return verdict(.none) }
        guard pair.pixelsA == pair.pixelsB else {
            return verdict(pair.pixelsA > pair.pixelsB ? .left : .right)
        }
        let ratio = Double(pair.a.fileSize) / Double(pair.b.fileSize)
        if ratio >= 1.5 { return verdict(.left, scoreA: 5.0) }
        if ratio <= 0.67 { return verdict(.right, scoreB: 5.0) }
        return verdict(.tie)
    }

    /// 6. 拍摄时间：只展示先后顺序与高速连拍提示，不参与评分
    private static func captureTimeVerdict(_ pair: PhotoPair) -> CriterionVerdict {
        var hint: String? = nil
        let winner: PhotoWinnerChoice
        if let tA = pair.a.captureDate, let tB = pair.b.captureDate {
            let diffSec = abs(tA.timeIntervalSince(tB))
            if diffSec < 5.0 {
                hint = String(format: "高速连拍 (相隔 %.1f 秒)", diffSec)
            }
            winner = (tA >= tB) ? .left : .right
        } else {
            winner = .none
        }
        return CriterionVerdict(
            row: PhotoDiffRow(
                icon: "calendar.badge.clock",
                label: "拍摄时间",
                valA: pair.a.captureTimeString,
                valB: pair.b.captureTimeString,
                winner: winner,
                hint: hint
            )
        )
    }

    /// 7. 相机设备：只展示双方机型，不参与评分
    private static func cameraVerdict(_ pair: PhotoPair) -> CriterionVerdict {
        CriterionVerdict(
            row: PhotoDiffRow(
                icon: "camera",
                label: "相机设备",
                valA: pair.a.cameraSummary,
                valB: pair.b.cameraSummary,
                winner: .none,
                hint: nil
            )
        )
    }

    /// 8. 视觉相似度：dHash 缺失时按完全一致处理（沿用历史口径）
    private static func perceptualSimilarity(_ pair: PhotoPair) -> (similarity: Double, hammingDistance: Int) {
        let dHashA = pair.a.dHash ?? ImageHash.computeDHash(url: pair.a.fileURL)
        let dHashB = pair.b.dHash ?? ImageHash.computeDHash(url: pair.b.fileURL)
        guard let hA = dHashA, let hB = dHashB else { return (1.0, 0) }
        return (ImageHash.similarity(hA, hB), ImageHash.hammingDistance(hA, hB))
    }

    /// 相似度差异行：左右同值，仅用提示语区分「构图高度一致」与「存在微变」
    private static func similarityRow(similarity: Double, hammingDistance: Int) -> PhotoDiffRow {
        let simText = "\(String(format: "%.1f", similarity * 100))% (汉明距离: \(hammingDistance))"
        return PhotoDiffRow(
            icon: "waveform.path.ecg",
            label: "感知视觉相似度",
            valA: simText,
            valB: simText,
            winner: .tie,
            hint: similarity >= 0.95 ? "构图高度一致" : "存在构图或光线微变"
        )
    }

    /// 综合裁定：总分领先超过 5 分才算胜出，否则视为相当
    private static func recommendation(scoreA: Double, scoreB: Double,
                                       reasons: [String]) -> (choice: PhotoWinnerChoice, reason: String) {
        if scoreA > scoreB + 5.0 {
            return (.left, reasons.isEmpty
                    ? "综合画质评估推荐保留左侧照片，文件质量更佳。"
                    : "推荐保留左侧：\(reasons.joined(separator: "；"))。")
        }
        if scoreB > scoreA + 5.0 {
            return (.right, reasons.isEmpty
                    ? "综合画质评估推荐保留右侧照片，文件质量更佳。"
                    : "推荐保留右侧：\(reasons.joined(separator: "；"))。")
        }
        return (.tie, "两张照片的曝光参数、分辨率与画质高度接近，建议按构图偏好选择保留。")
    }
}
