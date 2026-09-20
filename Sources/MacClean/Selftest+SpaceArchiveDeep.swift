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
