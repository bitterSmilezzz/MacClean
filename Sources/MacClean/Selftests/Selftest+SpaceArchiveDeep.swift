import Foundation
import SwiftUI
import ViewInspector

// 自检套件：空间透视超大陈旧冷文件原位归档压缩与外接盘迁移 (v1.54.0)
extension Selftest {
    static func suiteSpaceArchiveDeep() {
        check("空间归档模型：SpaceNode canArchiveOrMigrate 与 isColdOrFrozen 资格判定") {
            // 1. 系统核心与空路径绝对不可归档
            let sysNode = SpaceNode(name: "System", path: "/System", size: 50 * 1024 * 1024 * 1024, color: .purple)
            guard sysNode.canArchiveOrMigrate == false else { return false }

            let rootNode = SpaceNode(name: "Root", path: "/", size: 100 * 1024 * 1024 * 1024, color: .blue)
            guard rootNode.canArchiveOrMigrate == false else { return false }

            let emptyNode = SpaceNode(name: "Virtual", path: nil, size: 50 * 1024 * 1024, color: .gray)
            guard emptyNode.canArchiveOrMigrate == false else { return false }

            // 2. 小于 10 MB 的项不建议归档
            let smallNode = SpaceNode(name: "Small", path: "/tmp", size: 1024 * 1024, color: .green)
            guard smallNode.canArchiveOrMigrate == false else { return false }

            // 3. 闲置沉睡度判定
            let activeNode = SpaceNode(
                name: "Active",
                size: 100,
                color: .green,
                modificationDate: Date().addingTimeInterval(-10 * 86400) // 10天前
            )
            guard activeNode.isColdOrFrozen == false else { return false }

            let coldNode = SpaceNode(
                name: "Cold",
                size: 100,
                color: .orange,
                modificationDate: Date().addingTimeInterval(-200 * 86400) // 200天前
            )
            guard coldNode.isColdOrFrozen == true else { return false }

            let frozenNode = SpaceNode(
                name: "Frozen",
                size: 100,
                color: .purple,
                modificationDate: Date().addingTimeInterval(-400 * 86400) // 400天前
            )
            guard frozenNode.isColdOrFrozen == true else { return false }

            return true
        }

        check("外接驱动器探测：ExternalVolumeInfo 数据模型与系统卷排除逻辑") {
            let service = SpaceArchiveService.shared
            let detected = service.detectExternalVolumes()

            // 验证：绝不包含系统根卷、系统分区与内部保护挂载点
            for vol in detected {
                guard vol.path != "/" && vol.path != "/System" else { return false }
                guard !vol.name.lowercased().contains("macintosh hd") else { return false }
                guard vol.availableBytes >= 0 else { return false }
                guard !vol.formattedAvailable.isEmpty else { return false }
            }

            // 模型属性完整性
            let dummy = ExternalVolumeInfo(
                id: "/Volumes/TestDrive",
                name: "TestDrive",
                path: "/Volumes/TestDrive",
                availableBytes: 50 * 1024 * 1024 * 1024,
                totalBytes: 128 * 1024 * 1024 * 1024,
                isRemovable: true
            )
            guard dummy.formattedAvailable.contains("GB") || dummy.formattedAvailable.contains("GiB") else { return false }
            guard dummy.isRemovable == true else { return false }

            return true
        }

        check("原位归档压缩引擎：合成目录 ditto 压缩与 .zip 完整性验证") {
            let fm = FileManager.default
            let tmpDir = "/tmp/MacClean_ArchiveTest_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

            // 创建子文件
            let fileA = "\(tmpDir)/dataA.txt"
            let fileB = "\(tmpDir)/dataB.bin"
            try? "Hello MacClean Archive A\n".write(toFile: fileA, atomically: true, encoding: .utf8)
            let binaryData = Data(repeating: 0x42, count: 64 * 1024) // 64 KB
            try? binaryData.write(to: URL(fileURLWithPath: fileB))

            let service = SpaceArchiveService.shared
            let res = service.archiveInPlace(sourcePath: tmpDir, deleteOriginal: false)

            defer {
                try? fm.removeItem(atPath: tmpDir)
                if !res.archivePath.isEmpty {
                    try? fm.removeItem(atPath: res.archivePath)
                }
            }

            guard res.success == true else { return false }
            guard res.archivePath.hasSuffix(".zip") else { return false }
            guard fm.fileExists(atPath: res.archivePath) else { return false }
            guard res.archiveSize > 0 else { return false }
            guard res.originalSize >= 64 * 1024 else { return false }
            guard res.deletedOriginal == false else { return false }

            return true
        }

        check("ditto 经 SafeProcess 执行：超时/失败都不碰原件，且绝不退化成 10 秒默认值") {
            let fm = FileManager.default
            // 超时值本身就是判据的一部分：默认 10 秒会把大目录判成超时（"永远失败"换"永远卡住"），
            // 缩到十几分钟又会砍掉本来跑得完的任务。所以既断"显式传了这个常量"，也断"常量本身没缩水"。
            guard SpaceArchiveService.dittoTimeout >= 30 * 60 else { return false }
            let root = "/private/tmp/macclean_ditto_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: root + "/victim", withIntermediateDirectories: true)
            try? Data(repeating: 0x41, count: 4096).write(to: URL(fileURLWithPath: root + "/victim/a.bin"))
            try? fm.createDirectory(atPath: root + "/vol", withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: root) }

            let savedRunner = SafeProcess.runner
            defer { SafeProcess.runner = savedRunner }
            var seen: [(String, [String], TimeInterval)] = []

            // ① 超时：半截压缩包要删掉，原件一步都不许动。
            //    这里**故意给 exitCode 0**——被 SIGTERM 后自己收尾、干净退出是真实存在的形状，
            //    只有 `!timedOut` 那一半拦得住；给 -1 的话这条 guard 里超时判据永远不可证伪。
            SafeProcess.runner = { path, args, timeout in
                seen.append((path, args, timeout))
                try? Data(repeating: 0x5A, count: 512).write(to: URL(fileURLWithPath: args.last ?? "/dev/null"))
                return SafeProcess.Result(exitCode: 0, output: "", timedOut: true)
            }
            let timedOut = SpaceArchiveService.shared.archiveInPlace(sourcePath: root + "/victim",
                                                                     deleteOriginal: true)
            guard timedOut.success == false, timedOut.deletedOriginal == false else { return false }
            guard fm.fileExists(atPath: root + "/victim"),
                  !fm.fileExists(atPath: root + "/victim.zip") else { return false }
            guard timedOut.errorMessage?.contains("分钟") == true else { return false }
            guard let first = seen.first, first.0 == "/usr/bin/ditto",
                  first.1.first == "-c", first.1.contains(root + "/victim"),
                  first.2 == SpaceArchiveService.dittoTimeout else { return false }

            // ② 失败：ditto 的 stderr 必须原样播报，不许吞成一句"执行异常"
            try? fm.createDirectory(atPath: root + "/victim2", withIntermediateDirectories: true)
            try? Data(repeating: 0x42, count: 2048).write(to: URL(fileURLWithPath: root + "/victim2/b.bin"))
            SafeProcess.runner = { path, args, timeout in
                seen.append((path, args, timeout))
                return SafeProcess.Result(exitCode: 1, output: "No space left on device")
            }
            let failed = SpaceArchiveService.shared.archiveInPlace(sourcePath: root + "/victim2",
                                                                   deleteOriginal: true)
            guard failed.success == false, failed.deletedOriginal == false,
                  failed.errorMessage?.contains("No space left on device") == true,
                  fm.fileExists(atPath: root + "/victim2") else { return false }

            // ③ 迁移是**复制形态**：`--sequesterRsrc` 只在 PKZip（-c -k）下合法，
            //    带上它 ditto 在解析参数阶段就退出，迁移一个字节都不会复制。
            seen.removeAll()
            SafeProcess.runner = { path, args, timeout in
                seen.append((path, args, timeout))
                return SafeProcess.Result(exitCode: 0, output: "")
            }
            _ = SpaceArchiveService.shared.migrateToVolume(sourcePath: root + "/victim2",
                                                           targetVolumePath: root + "/vol",
                                                           deleteOriginal: false)
            guard let m = seen.first, m.0 == "/usr/bin/ditto",
                  !m.1.contains("-c"), !m.1.contains("-k"),
                  !m.1.contains("--sequesterRsrc"), !m.1.contains("--keepParent"),
                  m.1 == [root + "/victim2", root + "/vol/victim2"],
                  m.2 == SpaceArchiveService.dittoTimeout else { return false }
            return true
        }

        check("外接盘迁移真的把文件复制过去，且绝不碰目标卷上已有的同名目录") {
            let fm = FileManager.default
            let root = "/private/tmp/macclean_migrate_\(UUID().uuidString)"
            defer { try? fm.removeItem(atPath: root) }
            try? fm.createDirectory(atPath: root + "/src", withIntermediateDirectories: true)
            try? Data(repeating: 0x43, count: 8192).write(to: URL(fileURLWithPath: root + "/src/payload.bin"))
            try? fm.createDirectory(atPath: root + "/vol", withIntermediateDirectories: true)
            // 用户外接盘上已经有一个同名目录，里面是他自己的东西
            try? fm.createDirectory(atPath: root + "/vol/src", withIntermediateDirectories: true)
            try? "mine".write(toFile: root + "/vol/src/PREEXISTING.txt", atomically: true, encoding: .utf8)

            // 真跑 ditto（不注入），验证复制形态确实可用
            let res = SpaceArchiveService.shared.migrateToVolume(sourcePath: root + "/src",
                                                                 targetVolumePath: root + "/vol",
                                                                 deleteOriginal: false)
            guard res.success else {
                print("      迁移未成功: \(res.errorMessage ?? "无原因")")
                return false
            }
            guard res.destinationPath != root + "/vol/src",
                  fm.fileExists(atPath: res.destinationPath + "/payload.bin") else { return false }
            // 既有同名目录必须原样还在，且没被混进本次复制的内容
            guard fm.fileExists(atPath: root + "/vol/src/PREEXISTING.txt"),
                  !fm.fileExists(atPath: root + "/vol/src/payload.bin") else { return false }
            return true
        }

        check("空间归档：源码接线——无裸 Process，两处 ditto 都显式带超时") {
            let path = (Selftest.sourceDirectoryPath as NSString).appendingPathComponent("SpaceArchiveService.swift")
            guard let src = try? String(contentsOfFile: path, encoding: .utf8) else {
                print("      读不到 \(path)")
                return false
            }
            // 逐行扫并跳过注释：本仓库喜欢在注释里写"此前是裸 Process()"，整文件子串匹配会被自己撞红
            for (idx, line) in src.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("//") || t.hasPrefix("///") { continue }
                if t.contains("Process()") || t.contains("waitUntilExit") {
                    print("      SpaceArchiveService.swift:\(idx + 1) 又出现裸子进程调用")
                    return false
                }
            }
            // 两处调用（归档 + 迁移）都必须挂同一个有界超时
            let runs = src.components(separatedBy: "SafeProcess.run(").count - 1
            let timed = src.components(separatedBy: "timeout: Self.dittoTimeout").count - 1
            guard runs == 2, timed == 2 else { return false }
            return true
        }

        check("原位归档安全删除：deleteOriginal 移入废纸篓行为核验") {
            let fm = FileManager.default
            let tmpDir = "/tmp/MacClean_ArchiveTrashTest_\(UUID().uuidString)"
            try? fm.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)

            let sample = "\(tmpDir)/sample.txt"
            try? "Some sample content for trash testing".write(toFile: sample, atomically: true, encoding: .utf8)

            let service = SpaceArchiveService.shared
            let res = service.archiveInPlace(sourcePath: tmpDir, deleteOriginal: true)

            defer {
                if !res.archivePath.isEmpty {
                    try? fm.removeItem(atPath: res.archivePath)
                }
            }

            guard res.success == true else { return false }
            guard res.deletedOriginal == true else { return false }
            guard fm.fileExists(atPath: res.archivePath) else { return false }
            guard !fm.fileExists(atPath: tmpDir) else { return false }

            return true
        }

        check("外接盘迁移脚本生成：generateMigrationScript 断言与容错逻辑") {
            let service = SpaceArchiveService.shared
            let sampleSrc = "/Users/developer/Projects/HugeOldArchive"
            let script = service.generateMigrationScript(for: sampleSrc, targetVolumePath: "/Volumes/BackupDisk")

            guard script.hasPrefix("#!/bin/bash") else { return false }
            guard script.contains("set -euo pipefail") else { return false }
            guard script.contains("rsync -avP --remove-source-files") else { return false }
            guard script.contains("[ ! -e \"$SRC\" ]") else { return false }
            guard script.contains("[ ! -d \"$DEST_VOL\" ]") else { return false }
            guard script.contains("/Volumes/BackupDisk") else { return false }

            return true
        }

        check("空间透视交互：SpaceVisualizerView 顶栏控件与色彩模式选择器 ViewInspector 检验") {
            let app = AppState()
            let visualizer = SpaceVisualizerView()
            let view = visualizer.environmentObject(app)
            guard let inspected = try? view.inspect() else { return false }

            // 检验色彩模式选择器
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "visualizerColorModePicker")) != nil else {
                return false
            }

            // 检验动作方法可调用性
            let node = SpaceNode(name: "TestNode", size: 100, color: .blue)
            visualizer.performArchive(node: node, deleteOriginal: false)
            visualizer.performMigration(node: node, targetVolume: "/tmp", deleteOriginal: false)

            return true
        }
    }
}
