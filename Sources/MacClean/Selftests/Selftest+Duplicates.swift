import SwiftUI
import ViewInspector
import Darwin
import Combine
import CoreGraphics
import ImageIO
import CryptoKit

// 自检套件：重复文件
//
// 从原本 2712 行的单个 `Selftest.run()` 中按领域切出（行 1056–1276）。
// 切分点取在 `check(...)` 语句边界，**执行顺序与拆分前完全一致** ——
// `run()` 按原顺序依次调用各套件，Swift 自上而下执行，语义不变。
extension Selftest {
    static func suiteDuplicates() {
        // MARK: - 重复文件查找与去重

        check("重复文件：Partial Hash 与 SHA256 哈希计算正确") {
            let tmpDir = "/private/tmp/macclean-dup-hash-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let fileA = tmpDir + "/fileA.bin"
            let fileB = tmpDir + "/fileB.bin"
            let contentA = Data(repeating: 0x41, count: 16384) // 16KB 'A'
            let contentB = Data(repeating: 0x41, count: 16384) // identical 16KB 'A'

            FileManager.default.createFile(atPath: fileA, contents: contentA)
            FileManager.default.createFile(atPath: fileB, contents: contentB)

            guard let partialA = DuplicateScanner.calculatePartialHash(at: fileA, length: 8192),
                  let partialB = DuplicateScanner.calculatePartialHash(at: fileB, length: 8192),
                  partialA == partialB else { return false }

            guard let fullA = DuplicateScanner.calculateFullSHA256(at: fileA),
                  let fullB = DuplicateScanner.calculateFullSHA256(at: fileB),
                  fullA == fullB && !fullA.isEmpty else { return false }

            return true
        }

        check("重复文件：文件扫描分组与 isOriginal 标记") {
            let tmpDir = "/private/tmp/macclean-dup-group-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            // 构造两组文件：第一组 3 个相同内容 (10KB)，第二组 1 个独有内容
            let data1 = "MacCleanDuplicateGroupTest1234567890".data(using: .utf8)!
            let data2 = "DifferentContentForSingleFileTest".data(using: .utf8)!

            let f1 = tmpDir + "/original.txt"
            let f2 = tmpDir + "/copy1.txt"
            let f3 = tmpDir + "/copy2.txt"
            let f4 = tmpDir + "/unique.txt"

            FileManager.default.createFile(atPath: f1, contents: data1)
            FileManager.default.createFile(atPath: f2, contents: data1)
            FileManager.default.createFile(atPath: f3, contents: data1)
            FileManager.default.createFile(atPath: f4, contents: data2)

            let groups = DuplicateScanner.scanDuplicates(in: [tmpDir], minSize: 10) { _, _ in }
            guard groups.count == 1 else { return false }
            let group = groups[0]
            guard group.items.count == 3 else { return false }
            // 必须有且仅有 1 个 isOriginal == true
            let originals = group.items.filter { $0.isOriginal }
            guard originals.count == 1 else { return false }
            // 浪费空间应为 2 个副本的大小
            guard group.wastedBytes == Int64(data1.count * 2) else { return false }
            return true
        }

        check("重复文件：硬链接不计入「可节省空间」（删了不释放字节）") {
            // 两条硬链接指向同一 inode：大小相同、SHA-256 相同，必然被分进同一组。
            // 但删掉其中一条**释放 0 字节**——数据仍由另一条链接持有。
            // 不做 inode 区分就会把同一份数据反复计入"可节省"，报出一个删了也拿不到的数字。
            let base = "/private/tmp/macclean-hardlink-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: base) }
            let a = base + "/a.bin"
            let b = base + "/b.bin"   // 硬链接到 a
            let c = base + "/c.bin"   // 真副本
            FileManager.default.createFile(atPath: a, contents: Data(repeating: 7, count: 100_000))
            guard (try? FileManager.default.linkItem(atPath: a, toPath: b)) != nil,
                  (try? FileManager.default.copyItem(atPath: a, toPath: c)) != nil else {
                return true   // 文件系统不支持则跳过
            }
            guard let ka = DuplicateScanner.inodeKey(forPath: a),
                  let kb = DuplicateScanner.inodeKey(forPath: b),
                  let kc = DuplicateScanner.inodeKey(forPath: c) else { return false }
            // 前提：硬链接共享 inode，真副本不共享
            guard ka == kb, ka != kc else { return false }

            let items = [
                DuplicateFileItem(path: a, name: "a.bin", size: 100_000, modificationDate: nil, inodeKey: ka),
                DuplicateFileItem(path: b, name: "b.bin", size: 100_000, modificationDate: nil, inodeKey: kb),
                DuplicateFileItem(path: c, name: "c.bin", size: 100_000, modificationDate: nil, inodeKey: kc),
            ]
            let group = DuplicateGroup(hash: "test", fileSize: 100_000, items: items)
            // 三条路径、两个互异 inode → 只能省一份；硬链接那条要如实标注
            return group.wastedBytes == 100_000 && group.hardLinkCount == 1
        }

        check("重复文件：全是硬链接时「可节省空间」为 0") {
            let base = "/private/tmp/macclean-hardlink2-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: base) }
            let a = base + "/x.bin"
            FileManager.default.createFile(atPath: a, contents: Data(repeating: 3, count: 50_000))
            var paths = [a]
            for i in 1...2 {
                let link = base + "/x-\(i).bin"
                if (try? FileManager.default.linkItem(atPath: a, toPath: link)) != nil { paths.append(link) }
            }
            guard paths.count == 3 else { return true }
            let items = paths.compactMap { p -> DuplicateFileItem? in
                guard let k = DuplicateScanner.inodeKey(forPath: p) else { return nil }
                return DuplicateFileItem(path: p, name: (p as NSString).lastPathComponent,
                                         size: 50_000, modificationDate: nil, inodeKey: k)
            }
            guard items.count == 3 else { return false }
            let group = DuplicateGroup(hash: "test", fileSize: 50_000, items: items)
            return group.wastedBytes == 0 && group.hardLinkCount == 2
        }

        check("重复文件：扫描可被取消，且取消不清空已有结果") {
            // 原实现没有取消途径：全量 SHA-256 一旦开跑就只能等完，
            // 且再次点扫描会被 `guard !isScanning` 静默丢弃（用户看不到任何反馈）。
            let dup = DuplicateState()
            // 取消标志的读写：请求取消后，扫描侧的判据必须立刻为真
            dup.cancelScan()   // 未在扫描时应当是 no-op
            guard !dup.isScanning else { return false }

            // 扫描函数本身支持取消：一开始就取消 → 立刻返回空表且不抛错
            let started = Date()
            let groups = DuplicateScanner.scanDuplicates(
                in: ["/private/tmp"],
                minSize: 1_048_576,
                isCancelled: { true },
                progress: { _, _ in }
            )
            // 已经取消 → 不应返回任何结果，且要很快返回（不是跑完再丢）
            return groups.isEmpty && Date().timeIntervalSince(started) < 5
        }

        check("重复文件：智能勾选与清理逻辑") {
            let tmpDir = "/private/tmp/macclean-dup-clean-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let data = "CleanableContentTest".data(using: .utf8)!
            let f1 = tmpDir + "/original.txt"
            let f2 = tmpDir + "/dupe.txt"
            FileManager.default.createFile(atPath: f1, contents: data)
            FileManager.default.createFile(atPath: f2, contents: data)

            let state = DuplicateState()
            state.searchPaths = [tmpDir]
            state.minSizeBytes = 5
            state.startScan()

            // 等待后台扫描完成（最多 2 秒）
            let deadline = Date().addingTimeInterval(2.0)
            while state.isScanning && Date() < deadline {
                RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
            }

            guard state.groups.count == 1 else { return false }
            // 智能勾选测试
            state.autoSelectDuplicates()
            let group = state.groups[0]
            let selected = group.items.filter { $0.isSelected }
            let unselected = group.items.filter { !$0.isSelected }
            guard selected.count == 1 && unselected.count == 1 else { return false }
            guard unselected.first?.isOriginal == true else { return false }

            // 清理勾选项（permanently: true 在 tmp 目录快速删除）
            _ = state.cleanSelected(permanently: true)

            // 清理后原文件应依然存在，副本已被删除，且分组被清空
            let originalExists = FileManager.default.fileExists(atPath: f1)
            let dupeExists = FileManager.default.fileExists(atPath: f2)
            guard originalExists && !dupeExists else { return false }
            guard state.groups.isEmpty else { return false }

            return true
        }

        check("相似文件：词干提取与衍生归一化") {
            let s1 = DuplicateScanner.normalizedStem(for: "Video_Presentation (1).mp4")
            let s2 = DuplicateScanner.normalizedStem(for: "Video_Presentation copy.mov")
            let s3 = DuplicateScanner.normalizedStem(for: "Video_Presentation_副本.mkv")
            let s4 = DuplicateScanner.normalizedStem(for: "Video_Presentation-backup.mp4")
            let s5 = DuplicateScanner.normalizedStem(for: "Video_Presentation.mp4")

            guard s1 == "video_presentation" else { return false }
            guard s2 == "video_presentation" else { return false }
            guard s3 == "video_presentation" else { return false }
            guard s4 == "video_presentation" else { return false }
            guard s5 == "video_presentation" else { return false }

            guard DuplicateScanner.isDerivedCopyName("MyDoc copy.pdf") else { return false }
            guard DuplicateScanner.isDerivedCopyName("Photo (2).png") else { return false }
            guard DuplicateScanner.isDerivedCopyName("Project_副本.zip") else { return false }
            guard !DuplicateScanner.isDerivedCopyName("MyOriginalDocument.pdf") else { return false }
            return true
        }

        check("相似文件：聚类与推荐保留规则") {
            let tmpDir = "/private/tmp/macclean-sim-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            // 创建同词干、不同大小的衍生文件（如高清源视频与衍生副本/转码）
            let dataLarge = Data(repeating: 0x41, count: 2000)
            let dataSmall = Data(repeating: 0x42, count: 1200)

            let f1 = tmpDir + "/MovieTeaser.mov"
            let f2 = tmpDir + "/MovieTeaser (1).mp4"
            FileManager.default.createFile(atPath: f1, contents: dataLarge)
            FileManager.default.createFile(atPath: f2, contents: dataSmall)

            let groups = DuplicateScanner.scanDuplicates(in: [tmpDir], minSize: 100) { _, _ in }
            guard groups.count == 1 else { return false }
            let group = groups[0]
            guard group.matchKind == .similar else { return false }
            guard group.items.count == 2 else { return false }

            // 推荐保留应该偏向体积更大/命名纯净的 MovieTeaser.mov
            guard let original = group.items.first(where: \.isOriginal) else { return false }
            guard original.path == f1 else { return false }
            guard group.wastedBytes == Int64(dataSmall.count) else { return false }

            return true
        }

        check("重复文件：多级稀疏采样秒级过滤头同尾异假阳性大文件") {
            let tmpDir = "/private/tmp/macclean-sample-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            // 构造 4 个 1.2MB 大小完全相同的文件：
            // 文件 A: 头 H, 中 M1, 尾 T1
            // 文件 B: 头 H, 中 M1, 尾 T2 (头同尾异，模拟格式相同的不同视频/压缩包)
            // 文件 C: 头 H, 中 M2, 尾 T1 (头尾同中异)
            // 文件 D: 文件 A 的完全拷贝
            let totalBytes = 1_200_000
            let headSize = 16384
            let tailSize = 16384
            let midSize = 16384
            let midOffset = (totalBytes / 2) - (midSize / 2)

            func makeData(midByte: UInt8, tailByte: UInt8) -> Data {
                var d = Data(repeating: 0x48, count: headSize) // Head 'H'
                d.append(Data(repeating: 0x00, count: midOffset - headSize))
                d.append(Data(repeating: midByte, count: midSize))
                let remaining = totalBytes - d.count - tailSize
                d.append(Data(repeating: 0x00, count: remaining))
                d.append(Data(repeating: tailByte, count: tailSize))
                return d
            }

            let dataA = makeData(midByte: 0x31, tailByte: 0x54) // M1, T1
            let dataB = makeData(midByte: 0x31, tailByte: 0x58) // M1, T2 (尾部不同)
            let dataC = makeData(midByte: 0x32, tailByte: 0x54) // M2, T1 (中部不同)
            let dataD = dataA

            let pathA = "\(tmpDir)/videoA.mp4"
            let pathB = "\(tmpDir)/videoB.mp4"
            let pathC = "\(tmpDir)/videoC.mp4"
            let pathD = "\(tmpDir)/videoD_copy.mp4"

            FileManager.default.createFile(atPath: pathA, contents: dataA)
            FileManager.default.createFile(atPath: pathB, contents: dataB)
            FileManager.default.createFile(atPath: pathC, contents: dataC)
            FileManager.default.createFile(atPath: pathD, contents: dataD)

            // 1. 传统头 8KB 哈希：4 个文件完全相同（假阳性）
            let headA = DuplicateScanner.calculatePartialHash(at: pathA, length: 8192)
            let headB = DuplicateScanner.calculatePartialHash(at: pathB, length: 8192)
            let headC = DuplicateScanner.calculatePartialHash(at: pathC, length: 8192)
            let headD = DuplicateScanner.calculatePartialHash(at: pathD, length: 8192)
            guard headA != nil, headA == headB, headB == headC, headC == headD else { return false }

            // 2. 多级自适应采样哈希：能精准区分尾部或中部不同的文件
            let sampleA = DuplicateScanner.calculateSampledHash(at: pathA, fileSize: Int64(totalBytes))
            let sampleB = DuplicateScanner.calculateSampledHash(at: pathB, fileSize: Int64(totalBytes))
            let sampleC = DuplicateScanner.calculateSampledHash(at: pathC, fileSize: Int64(totalBytes))
            let sampleD = DuplicateScanner.calculateSampledHash(at: pathD, fileSize: Int64(totalBytes))

            guard let sA = sampleA, let sB = sampleB, let sC = sampleC, let sD = sampleD else { return false }
            // A 与 D 相同
            guard sA == sD else { return false }
            // 尾部不同则采样哈希不同
            guard sA != sB else { return false }
            // 中部不同则采样哈希不同
            guard sA != sC else { return false }

            // 3. 端到端扫描：仅 A 与 D 归为一组，B 与 C 被前置淘汰，不产生假阳性
            let groups = DuplicateScanner.scanDuplicates(in: [tmpDir], minSize: 100_000) { _, _ in }
            guard groups.count == 1 else { return false }
            let group = groups[0]
            guard group.matchKind == .exact, group.items.count == 2 else { return false }
            let groupedPaths = Set(group.items.map(\.path))
            guard groupedPaths.contains(pathA) && groupedPaths.contains(pathD) else { return false }
            guard !groupedPaths.contains(pathB) && !groupedPaths.contains(pathC) else { return false }

            return true
        }

        check("重复文件：自适应大缓冲 SHA256 与标准哈希一致性") {
            let tmpDir = "/private/tmp/macclean-sha-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            // 构造 1.5MB 测试文件跨越 1MB 自适应缓冲边界
            var testData = Data(capacity: 1_500_000)
            for i in 0..<150 {
                testData.append(Data(repeating: UInt8(i % 255), count: 10_000))
            }
            let testFile = "\(tmpDir)/test_adaptive.dat"
            FileManager.default.createFile(atPath: testFile, contents: testData)

            // 标准 CryptoKit 哈希作为黄金标准
            let expectedDigest = CryptoKit.SHA256.hash(data: testData)
            let expectedHex = expectedDigest.map { String(format: "%02hhx", $0) }.joined()

            // 引擎自适应分块哈希
            guard let engineHex = DuplicateScanner.calculateFullSHA256(at: testFile) else { return false }
            guard engineHex == expectedHex else { return false }

            return true
        }

        check("重复文件：并发特征提取与即时取消响应") {
            let tmpDir = "/private/tmp/macclean-concurrent-\(UUID().uuidString)"
            try FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            // 创建 6 个重复对
            for i in 1...6 {
                let data = "MacCleanConcurrencyTestFilePayload-\(i)".data(using: .utf8)!
                FileManager.default.createFile(atPath: "\(tmpDir)/file_\(i)_1.bin", contents: data)
                FileManager.default.createFile(atPath: "\(tmpDir)/file_\(i)_2.bin", contents: data)
            }

            // 1. 正常并发比对应准确找到 6 组
            let groups = DuplicateScanner.scanDuplicates(in: [tmpDir], minSize: 10) { _, _ in }
            guard groups.count == 6 else { return false }
            for g in groups {
                guard g.items.count == 2 else { return false }
            }

            // 2. 模拟取消信号应即时安全退出，返回空列表
            let cancelledGroups = DuplicateScanner.scanDuplicates(
                in: [tmpDir],
                minSize: 10,
                isCancelled: { true }
            ) { _, _ in }
            guard cancelledGroups.isEmpty else { return false }

            return true
        }

    }
}
