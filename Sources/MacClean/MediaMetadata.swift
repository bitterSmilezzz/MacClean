import Foundation
import AVFoundation
import CoreMedia

/// 大型音视频文件元数据模型
struct MediaMetadata: Equatable {
    let filePath: String
    let fileSize: Int64
    let durationSeconds: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let bitrateKbps: Int
    let videoCodec: String?
    let audioSampleRate: Int?
    let hasVideo: Bool
    let hasAudio: Bool

    // MARK: - 格式化展示属性

    /// 格式化时长（例如 "01:24:32" 或 "03:45"）
    var durationString: String {
        guard durationSeconds > 0 else { return "00:00" }
        let totalSec = Int(round(durationSeconds))
        let hours = totalSec / 3600
        let minutes = (totalSec % 3600) / 60
        let seconds = totalSec % 60

        if hours > 0 {
            return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
        } else {
            return String(format: "%02d:%02d", minutes, seconds)
        }
    }

    /// 分辨率描述（例如 "4K", "1080p", "720p" 或 "1920×1080"）
    var resolutionString: String {
        guard hasVideo, pixelWidth > 0, pixelHeight > 0 else {
            return hasAudio ? "纯音频" : "未知尺寸"
        }
        let maxSide = max(pixelWidth, pixelHeight)
        let minSide = min(pixelWidth, pixelHeight)

        if maxSide >= 3840 || minSide >= 2160 {
            return "4K"
        } else if maxSide >= 2560 || minSide >= 1440 {
            return "2K"
        } else if maxSide >= 1920 || minSide >= 1080 {
            return "1080p"
        } else if maxSide >= 1280 || minSide >= 720 {
            return "720p"
        } else {
            return "\(pixelWidth)×\(pixelHeight)"
        }
    }

    /// 格式化比特率/码率（例如 "24.5 Mbps" 或 "320 kbps"）
    var bitrateString: String {
        guard bitrateKbps > 0 else { return "未知码率" }
        if bitrateKbps >= 1000 {
            let mbps = Double(bitrateKbps) / 1000.0
            return String(format: "%.1f Mbps", mbps)
        } else {
            return "\(bitrateKbps) kbps"
        }
    }

    /// 综合摘要胶囊文案（例如 "4K · 24.5 Mbps · 01:24:32" 或 "320 kbps · 03:45"）
    var summaryBadge: String {
        var parts: [String] = []
        if hasVideo {
            parts.append(resolutionString)
        }
        if bitrateKbps > 0 {
            parts.append(bitrateString)
        }
        if durationSeconds > 0 {
            parts.append(durationString)
        }
        return parts.joined(separator: " · ")
    }

    /// 便捷徽标文案
    var badgeText: String { summaryBadge }

    /// 详细规格描述（供展开行显示）
    var detailedSummary: String {
        var parts: [String] = []
        if hasVideo {
            if let codec = videoCodec {
                parts.append("编码: \(codec)")
            }
            if pixelWidth > 0 && pixelHeight > 0 {
                parts.append("尺寸: \(pixelWidth)×\(pixelHeight)")
            }
        }
        if durationSeconds > 0 {
            parts.append("时长: \(durationString)")
        }
        if bitrateKbps > 0 {
            parts.append("码率: \(bitrateString)")
        }
        if let sr = audioSampleRate, sr > 0 {
            parts.append("采样率: \(sr / 1000) kHz")
        }
        return parts.joined(separator: " · ")
    }
}

/// 音视频元数据轻量解析器
final class MediaMetadataParser {
    static let mediaExtensions: Set<String> = [
        "mp4", "mov", "mkv", "m4v", "avi", "wmv", "mp3", "flac", "wav", "aac", "m4a", "webm", "ogg"
    ]

    private static let cacheLock = NSLock()
    private static var cache: [String: MediaMetadata] = [:]

    /// 判断指定路径是否为受支持的音视频媒体文件
    static func isMediaFile(path: String) -> Bool {
        let ext = (path as NSString).pathExtension.lowercased()
        return mediaExtensions.contains(ext)
    }

    /// 从缓存获取或同步解析音视频元数据
    static func cachedOrParse(path: String, fileSize: Int64) -> MediaMetadata? {
        cacheLock.lock()
        if let hit = cache[path] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        guard let meta = parse(path: path, fileSize: fileSize) else {
            return nil
        }

        cacheLock.lock()
        if cache.count > 500 {
            cache.removeAll(keepingCapacity: true)
        }
        cache[path] = meta
        cacheLock.unlock()
        return meta
    }

    /// 解析指定本地音视频文件
    static func parse(path: String, fileSize: Int64) -> MediaMetadata? {
        guard isMediaFile(path: path) else { return nil }
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: false])

        let durationSec = CMTimeGetSeconds(asset.duration)
        let validDuration = durationSec.isFinite && durationSec > 0 ? durationSec : 0

        var width = 0
        var height = 0
        var hasVideo = false
        var hasAudio = false
        var videoCodec: String? = nil
        var audioSampleRate: Int? = nil
        var totalEstimatedRate: Float = 0

        let videoTracks = asset.tracks(withMediaType: .video)
        if let videoTrack = videoTracks.first {
            hasVideo = true
            let size = videoTrack.naturalSize.applying(videoTrack.preferredTransform)
            width = Int(abs(size.width))
            height = Int(abs(size.height))
            totalEstimatedRate += videoTrack.estimatedDataRate

            // 提取视频编码格式描述
            let descriptions = videoTrack.formatDescriptions as? [CMFormatDescription] ?? []
            if let desc = descriptions.first {
                let subtype = CMFormatDescriptionGetMediaSubType(desc)
                videoCodec = fourCCToString(subtype)
            }
        }

        let audioTracks = asset.tracks(withMediaType: .audio)
        if let audioTrack = audioTracks.first {
            hasAudio = true
            totalEstimatedRate += audioTrack.estimatedDataRate

            let descriptions = audioTrack.formatDescriptions as? [CMFormatDescription] ?? []
            if let desc = descriptions.first {
                if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(desc)?.pointee {
                    audioSampleRate = Int(asbd.mSampleRate)
                }
            }
        }

        guard hasVideo || hasAudio else { return nil }

        // 计算码率 (kbps)
        var bitrateKbps = 0
        if totalEstimatedRate > 0 {
            bitrateKbps = Int(totalEstimatedRate / 1000.0)
        } else if validDuration > 0 && fileSize > 0 {
            // 通过文件大小与时长推导平均码率
            bitrateKbps = Int((Double(fileSize * 8) / validDuration) / 1000.0)
        }

        return MediaMetadata(
            filePath: path,
            fileSize: fileSize,
            durationSeconds: validDuration,
            pixelWidth: width,
            pixelHeight: height,
            bitrateKbps: bitrateKbps,
            videoCodec: videoCodec,
            audioSampleRate: audioSampleRate,
            hasVideo: hasVideo,
            hasAudio: hasAudio
        )
    }

    /// FourCC 整数转可读编码字符串
    private static func fourCCToString(_ code: FourCharCode) -> String {
        let n = Int(code)
        var s = ""
        let b0 = Character(UnicodeScalar((n >> 24) & 255) ?? " ")
        let b1 = Character(UnicodeScalar((n >> 16) & 255) ?? " ")
        let b2 = Character(UnicodeScalar((n >> 8) & 255) ?? " ")
        let b3 = Character(UnicodeScalar(n & 255) ?? " ")
        s.append(b0); s.append(b1); s.append(b2); s.append(b3)
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)

        switch trimmed.lowercased() {
        case "avc1": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "apcn", "apch", "ap4h", "ap4x": return "ProRes"
        case "mp4a": return "AAC"
        case "alac": return "ALAC"
        default: return trimmed.isEmpty ? "RAW" : trimmed.uppercased()
        }
    }
}
