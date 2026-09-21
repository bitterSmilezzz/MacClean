import SwiftUI
import ViewInspector
import Darwin

// 自检套件：重复文件与相似图片清理体验升级 (v1.41.0)
extension Selftest {
    static func suiteDuplicateDeep() {
        check("重复对比增强：通用文件属性比对与评分引擎") {
            let tmpDir = "/private/tmp/macclean-dup-deep-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let origPath = tmpDir + "/Document.txt"
            let copyPath = tmpDir + "/Document (1).txt"

            let content1 = "Hello World\nLine 2\nLine 3\n"
            let content2 = "Hello World\nLine 2\nLine 3\nLine 4\n"

            FileManager.default.createFile(atPath: origPath, contents: content1.data(using: .utf8))
            FileManager.default.createFile(atPath: copyPath, contents: content2.data(using: .utf8))

            let itemA = DuplicateFileItem(path: origPath, name: "Document.txt", size: Int64(content1.count), modificationDate: Date())
            let itemB = DuplicateFileItem(path: copyPath, name: "Document (1).txt", size: Int64(content2.count), modificationDate: Date())

            let comp = FileComparisonResult.compare(itemA: itemA, itemB: itemB)

            // 验证差异属性提取
            guard !comp.diffRows.isEmpty else { return false }
            guard comp.diffRows.contains(where: { $0.label == "文件大小" }) else { return false }
            guard comp.diffRows.contains(where: { $0.label == "存储目录" }) else { return false }

            // 验证推荐倾向：itemB 是 " (1)" 副本后缀，itemA 应该胜出
            guard comp.recommendedChoice == .left else { return false }
            guard comp.recommendationReason.contains("副本") || comp.recommendationReason.contains("A") else { return false }

            return true
        }

        check("重复对比增强：文本文件前部对齐提取与安全截断") {
            let tmpDir = "/private/tmp/macclean-txt-deep-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let txtFile = tmpDir + "/source.swift"
            let lines = (1...30).map { "print(\($0))" }.joined(separator: "\n")
            FileManager.default.createFile(atPath: txtFile, contents: lines.data(using: .utf8))

            let previewLines = FileComparisonResult.extractTextPreview(path: txtFile, maxLines: 16)
            guard let previewLines = previewLines, !previewLines.isEmpty else { return false }

            // 必须按行返回且最多截取 16 行
            guard previewLines.count == 16 else { return false }
            guard previewLines.first == "print(1)" else { return false }
            guard previewLines.last == "print(16)" else { return false }
            guard !previewLines.contains("print(17)") else { return false }

            // 二进制文件安全过滤：不存在或非文本文件
            let binFile = tmpDir + "/app.bin"
            FileManager.default.createFile(atPath: binFile, contents: Data([0x00, 0xFF, 0xFE, 0x12]))
            let binPreview = FileComparisonResult.extractTextPreview(path: binFile)
            guard binPreview == nil else { return false }

            return true
        }

        check("重复多维批量勾选：保留最新 / 保留最早 / 保留文稿工作区") {
            let tmpDir = "/private/tmp/macclean-batch-dup-\(UUID().uuidString)"
            let dlDir = CleanPaths.expand("~/Downloads/macclean-test-dl-\(UUID().uuidString)")
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(atPath: dlDir, withIntermediateDirectories: true)
            defer {
                try? FileManager.default.removeItem(atPath: tmpDir)
                try? FileManager.default.removeItem(atPath: dlDir)
            }

            let pathWork = tmpDir + "/ProjectReport.pdf"
            let pathDl = dlDir + "/ProjectReport.pdf"

            FileManager.default.createFile(atPath: pathWork, contents: Data(repeating: 1, count: 1000))
            FileManager.default.createFile(atPath: pathDl, contents: Data(repeating: 1, count: 1000))

            // 设置不同修改时间
            let now = Date()
            let olderDate = now.addingTimeInterval(-3600)
            let newerDate = now

            let itemWork = DuplicateFileItem(path: pathWork, name: "ProjectReport.pdf", size: 1000, modificationDate: olderDate)
            let itemDl = DuplicateFileItem(path: pathDl, name: "ProjectReport.pdf", size: 1000, modificationDate: newerDate)

            let group = DuplicateGroup(
                hash: "test_batch_hash",
                fileSize: 1000,
                items: [itemWork, itemDl],
                matchKind: .exact,
                suggestionNote: ""
            )

            let state = DuplicateState()
            state.groups = [group]

            // 1. 验证 selectOlderDuplicates: 保留最新（itemDl），勾选较旧（itemWork）
            state.selectOlderDuplicates()
            guard state.groups[0].items[0].isSelected == true else { return false } // itemWork is older -> selected
            guard state.groups[0].items[1].isSelected == false else { return false } // itemDl is newer -> kept

            // 2. 验证 selectNewerDuplicates: 保留最早（itemWork），勾选较新（itemDl）
            state.selectNewerDuplicates()
            guard state.groups[0].items[0].isSelected == false else { return false } // itemWork is older -> kept
            guard state.groups[0].items[1].isSelected == true else { return false } // itemDl is newer -> selected

            // 3. 验证 selectDownloadsDuplicates: 优先保留工作目录，勾选下载目录副本
            state.selectDownloadsDuplicates()
            guard state.groups[0].items[0].isSelected == false else { return false } // work -> kept
            guard state.groups[0].items[1].isSelected == true else { return false } // dl -> selected

            // 4. 验证零误伤原则：组内绝不会全部被勾选
            guard state.groups[0].items.filter({ !$0.isSelected }).count >= 1 else { return false }

            return true
        }

        check("双栏比对界面与交互快捷决策渲染") {
            let item1 = DuplicateFileItem(path: "/tmp/doc_a.txt", name: "doc_a.txt", size: 2048, modificationDate: Date())
            let item2 = DuplicateFileItem(path: "/tmp/doc_b.txt", name: "doc_b.txt", size: 2048, modificationDate: Date())
            let group = DuplicateGroup(hash: "test_doc_hash", fileSize: 2048, items: [item1, item2], matchKind: .exact, suggestionNote: "")
            let dupState = DuplicateState()
            dupState.groups = [group]

            let sheet = FileCompareSheet(group: group, dupState: dupState, onDismiss: {})
            guard let inspected = try? sheet.inspect() else { return false }

            // 验证完成按钮与无障碍标识
            let doneBtn = try? inspected.find(viewWithAccessibilityIdentifier: "fileCompareDoneButton")
            guard doneBtn != nil else { return false }

            return true
        }
    }
}
