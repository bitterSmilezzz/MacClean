import Foundation
import SwiftUI

// 自检套件：重复文件与大文件智能分析进阶 (v1.46.0)
extension Selftest {
    static func suiteMediaAndPivotDeep() {
        check("媒体元数据模型：时长、分辨率与码率格式化验证") {
            let meta4K = MediaMetadata(
                filePath: "/fake/video_4k.mp4",
                fileSize: 1024 * 1024 * 1500, // 1.5 GB
                durationSeconds: 5072, // 1小时24分32秒
                pixelWidth: 3840,
                pixelHeight: 2160,
                bitrateKbps: 24500, // 24.5 Mbps
                videoCodec: "H.264",
                audioSampleRate: 48000,
                hasVideo: true,
                hasAudio: true
            )

            guard meta4K.durationString == "01:24:32" else { return false }
            guard meta4K.resolutionString == "4K" else { return false }
            guard meta4K.bitrateString == "24.5 Mbps" else { return false }
            guard meta4K.summaryBadge == "4K · 24.5 Mbps · 01:24:32" else { return false }
            guard meta4K.badgeText == meta4K.summaryBadge else { return false }
            guard meta4K.detailedSummary.contains("编码: H.264") else { return false }
            guard meta4K.detailedSummary.contains("48 kHz") else { return false }

            let metaAudio = MediaMetadata(
                filePath: "/fake/music.flac",
                fileSize: 1024 * 1024 * 35,
                durationSeconds: 225, // 3分45秒
                pixelWidth: 0,
                pixelHeight: 0,
                bitrateKbps: 320,
                videoCodec: nil,
                audioSampleRate: 44100,
                hasVideo: false,
                hasAudio: true
            )

            guard metaAudio.durationString == "03:45" else { return false }
            guard metaAudio.resolutionString == "纯音频" else { return false }
            guard metaAudio.bitrateString == "320 kbps" else { return false }
            guard metaAudio.summaryBadge == "320 kbps · 03:45" else { return false }

            return true
        }

        check("媒体元数据解析器：后缀安全判定与缓存一致性") {
            // 常见媒体后缀识别
            guard MediaMetadataParser.isMediaFile(path: "/Users/test/movie.mkv") else { return false }
            guard MediaMetadataParser.isMediaFile(path: "/Users/test/audio.flac") else { return false }
            guard MediaMetadataParser.isMediaFile(path: "/Users/test/video.MP4") else { return false }

            // 非媒体文件安全过滤
            guard !MediaMetadataParser.isMediaFile(path: "/Users/test/document.pdf") else { return false }
            guard !MediaMetadataParser.isMediaFile(path: "/Users/test/archive.zip") else { return false }
            guard !MediaMetadataParser.isMediaFile(path: "/Users/test/code.swift") else { return false }

            // 解析不存在或非法路径时不崩溃且返回 nil
            let nonExistent = MediaMetadataParser.cachedOrParse(path: "/non/existent/path/media.mp4", fileSize: 1024)
            guard nonExistent == nil else { return false }

            return true
        }

        check("多维交叉透视矩阵：年份与类型多维聚合及热点排查") {
            let cal = Calendar.current
            let now = Date()
            let year2025 = cal.date(byAdding: .year, value: -1, to: now) ?? now
            let year2024 = cal.date(byAdding: .year, value: -2, to: now) ?? now
            let yearOld = cal.date(byAdding: .year, value: -4, to: now) ?? now

            let item1 = CleanItem(
                name: "ubuntu-22.04.iso",
                path: "/Users/demo/ubuntu-22.04.iso",
                size: 1024 * 1024 * 1024 * 4, // 4GB 虚拟机与镜像
                nature: .userData,
                category: .largeFiles,
                use: UseState(lastUsed: year2025),
                rule: "L0"
            )

            let item2 = CleanItem(
                name: "backup-xcode.xcarchive",
                path: "/Users/demo/backup-xcode.xcarchive",
                size: 1024 * 1024 * 1024 * 8, // 8GB 项目归档与开发包
                nature: .userData,
                category: .largeFiles,
                use: UseState(lastUsed: year2024),
                rule: "L0"
            )

            let item3 = CleanItem(
                name: "feature_film.mov",
                path: "/Users/demo/feature_film.mov",
                size: 1024 * 1024 * 1024 * 15, // 15GB 音视频
                nature: .userData,
                category: .largeFiles,
                use: UseState(lastUsed: year2024),
                rule: "L0"
            )

            let item4 = CleanItem(
                name: "old_logs.tar.gz",
                path: "/Users/demo/old_logs.tar.gz",
                size: 1024 * 1024 * 500, // 500MB 压缩包
                nature: .userData,
                category: .largeFiles,
                use: UseState(lastUsed: yearOld),
                rule: "L0"
            )

            let matrix = PivotAnalyzer.analyze(items: [item1, item2, item3, item4])

            // 矩阵基础总数校验
            guard matrix.totalCount == 4 else { return false }
            let expectedTotal = item1.size + item2.size + item3.size + item4.size
            guard matrix.totalBytes == expectedTotal else { return false }

            // 热点排查：Top 1 必须是 15GB 的 2024 年音视频
            guard let top1 = matrix.topHotspots.first else { return false }
            guard top1.type == .media && top1.totalBytes == item3.size else { return false }

            // 年份合计与类型合计计算准确性
            let mediaTypeTotal = matrix.totalBytes(forType: .media)
            guard mediaTypeTotal == item3.size else { return false }

            let year2024Label = PivotAnalyzer.yearLabel(for: year2024)
            let year2024Total = matrix.totalBytes(forYear: year2024Label)
            guard year2024Total == item2.size + item3.size else { return false }

            // 针对空列表的健壮性保护
            let emptyMatrix = PivotAnalyzer.analyze(items: [])
            guard emptyMatrix.totalCount == 0, emptyMatrix.totalBytes == 0, emptyMatrix.topHotspots.isEmpty else { return false }

            return true
        }

        check("大文件排序机制：码率与时长多维排序扩展") {
            let sortOrders = LargeFileSortOrder.allCases
            guard sortOrders.contains(.bitrateDescending) else { return false }
            guard sortOrders.contains(.durationDescending) else { return false }
            guard LargeFileSortOrder.bitrateDescending.rawValue == "媒体码率最高优先" else { return false }
            guard LargeFileSortOrder.durationDescending.rawValue == "媒体时长最长优先" else { return false }
            return true
        }
    }
}
