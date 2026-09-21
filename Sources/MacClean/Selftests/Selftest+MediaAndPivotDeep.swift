import Foundation
import SwiftUI
import AVFoundation
import CoreVideo
import CoreMedia

// 自检套件：重复文件与大文件智能分析进阶 (v1.46.0)
extension Selftest {
    /// 生成一个真实可读的 H.264 mp4，用来验证元数据解析链路。
    ///
    /// 为什么非得造真的：AVFoundation 迁移到 `load(...)` 之后，每个字段都被
    /// `try? … ?? 0/[]` 兜住了——真要是全部解析失败，代码照样编译、
    /// 现有断言照样全绿，界面上却再也显示不出时长/分辨率/码率。
    /// 只查"不崩溃、nil 不崩"是守不住这种坏法的，必须有一个**真的有值**的样本。
    /// 像素内容全不填（未初始化的 BGRA 也是一帧合法画面），自检只关心容器与轨道元数据。
    static func makeVideoFixture(at path: String, frames: Int = 6, timescale: Int32 = 10) -> Bool {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(atPath: path)
        let (w, h) = (320, 240)
        guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mp4) else { return false }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: w,
            AVVideoHeightKey: h,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: w,
                kCVPixelBufferHeightKey as String: h,
            ])
        guard writer.canAdd(input) else { return false }
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var appended = 0
        var lastT = CMTime.zero
        for i in 0..<frames {
            var buffer: CVPixelBuffer?
            guard CVPixelBufferCreate(kCFAllocatorDefault, w, h,
                                      kCVPixelFormatType_32BGRA, nil, &buffer) == kCVReturnSuccess,
                  let buffer else { break }
            // 编码器没 ready 就 append 会**直接抛 ObjC 异常**（不是返回 false），
            // 进程当场终止——实测就是这样把整个自检跑断的，必须先等。
            var waits = 0
            while !input.isReadyForMoreMediaData && waits < 300 {
                Thread.sleep(forTimeInterval: 0.01)
                waits += 1
            }
            guard input.isReadyForMoreMediaData else { break }
            let t = CMTime(value: CMTimeValue(i), timescale: timescale)
            if adaptor.append(buffer, withPresentationTime: t) {
                appended += 1
                lastT = t
            }
        }
        guard appended >= 2 else { return false }
        input.markAsFinished()
        // 收尾时间取**实际写进去的最后一帧**：用循环上界的话，中途 ready 超时
        // 提前 break 会让 endSession 落在没写过的时间戳上。
        writer.endSession(atSourceTime: lastT)

        // 完成回调在 AVFoundation 自己的队列上跑，等它期间不能占着协作线程池
        let done = DispatchGroup()
        done.enter()
        writer.finishWriting { done.leave() }
        guard done.wait(timeout: .now() + .seconds(15)) == .success else { return false }
        return writer.status == .completed && FileManager.default.fileExists(atPath: path)
    }

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
            // （AVFoundation 只剩异步 `load`，这里必须等解析真的跑完再断言：
            //   只查缓存会把"根本没去解析"也判成通过。用 `DispatchGroup` 而不是
            //   裸标志位——后者主线程和 Task 各写各的，Thread Sanitizer 会报竞争。）
            let missing = "/non/existent/path/media.mp4"
            var parsed: MediaMetadata?
            let parsedDone = DispatchGroup()
            parsedDone.enter()
            Task {
                parsed = await MediaMetadataParser.parse(path: missing, fileSize: 1024)
                parsedDone.leave()
            }
            // 超时不算通过，但窗口要给足：这是"解析有没有卡住"的判据，
            // 不是性能基准，机器被并行构建压满时不该假红（真卡住 10 秒同样是失败）。
            guard parsedDone.wait(timeout: .now() + .seconds(10)) == .success else { return false }
            guard parsed == nil else { return false }
            // 同步侧只读缓存：没预热过的路径必须是 nil，body 里不再隐式发起解析
            guard MediaMetadataParser.cached(path: missing) == nil else { return false }

            return true
        }

        // 真造一个能读的 mp4 走完整解析链路：守住"字段全被 try? 兜成 0/nil
        // 但看起来一切正常"这一类失败——那只有拿真的有值的样本才测得出来。
        check("媒体元数据端到端：真实 mp4 样本解析出时长/分辨率/码率，并回填缓存") {
            let dir = NSTemporaryDirectory() + "macclean-media-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: dir) }
            let file = dir + "/selftest.mp4"
            guard makeVideoFixture(at: file) else {
                print("      跳过：本机无法生成 H.264 样例（AVAssetWriter 不可用）")
                return true
            }
            let size = FileSystem.size(at: file)
            var meta: MediaMetadata?
            let done = DispatchGroup()
            done.enter()
            Task {
                meta = await MediaMetadataParser.load(path: file, fileSize: size)
                done.leave()
            }
            guard done.wait(timeout: .now() + .seconds(20)) == .success else { return false }
            guard let meta else {
                print("      真实 mp4 解析返回 nil —— 字段被 try? 静默吞掉了")
                return false
            }
            var bad: [String] = []
            if meta.durationSeconds <= 0 { bad.append("durationSeconds=\(meta.durationSeconds)") }
            if meta.pixelWidth != 320 || meta.pixelHeight != 240 {
                bad.append("分辨率 \(meta.pixelWidth)x\(meta.pixelHeight)，期望 320x240")
            }
            if !meta.hasVideo { bad.append("hasVideo=false") }
            if meta.bitrateKbps <= 0 { bad.append("bitrateKbps=\(meta.bitrateKbps)") }
            if meta.videoCodec?.isEmpty != false { bad.append("videoCodec 为空") }
            if !bad.isEmpty { print("      " + bad.joined(separator: "、")); return false }
            // `load` 必须回填缓存，否则同步侧（body / sort 比较器）永远读不到
            return MediaMetadataParser.cached(path: file)?.durationSeconds == meta.durationSeconds
        }

        // 解析从"用到才同步解析"改成"后台按批预热"之后，必须有一条上限锁死：
        // 缓存超过 500 条是整体丢弃的，不限流的话一个几千项的媒体分类会把缓存反复清空，
        // 每次重绘重解析几千个文件——比改造前更贵。而且 `.task(id:)` 的键与预热对象
        // 必须同源，否则会静默出现"键没变、这一项却没被预热"。
        check("媒体预热：按上限截断、只挑媒体文件，且键与实际预热对象同源") {
            let items: [CleanItem] = (0..<1000).map { i in
                CleanItem(name: "m\(i)", path: "/tmp/media-selftest/m\(i).\(i.isMultiple(of: 2) ? "mp4" : "txt")",
                          size: 1024, nature: .losslessCache, category: .largeFiles)
            }
            let targets = MediaMetadataParser.warmTargets(from: items)
            guard targets.count == MediaMetadataParser.warmLimit else {
                print("      预热条数 \(targets.count)，上限 \(MediaMetadataParser.warmLimit)")
                return false
            }
            // 只挑媒体文件，且保持列表原有顺序（排在前面的先被预热）
            guard targets.allSatisfy({ MediaMetadataParser.isMediaFile(path: $0.path) }) else { return false }
            guard targets.first?.path == "/tmp/media-selftest/m0.mp4" else { return false }
            // 上限之后的媒体项不得进入预热集：m998 是 mp4，排在第 499 位之后
            guard !targets.contains(where: { $0.path.contains("/m998.") }) else {
                print("      上限之后的项被拉进了预热集")
                return false
            }
            let paths = MediaMetadataParser.warmPaths(from: items)
            guard paths == targets.map(\.path) else {
                print("      键与实际预热对象不同源")
                return false
            }
            // 空列表与非媒体列表都必须什么都不做
            guard MediaMetadataParser.warmTargets(from: []).isEmpty,
                  MediaMetadataParser.warmTargets(from: Array(items.filter { !$0.path.hasSuffix(".mp4") })).isEmpty
            else { return false }
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
