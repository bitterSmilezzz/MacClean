import Foundation

// 自检套件：清理撤销与回滚机制（v1.35.0）
extension Selftest {
    static func suiteUndo() {
        // MARK: - 清理撤销与回滚机制

        check("清理回滚快照：移入废纸篓生成快照与路径记录完整") {
            let tmpDir = "/private/tmp/macclean_undo_test1_\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let testFile = tmpDir + "/test_trash.txt"
            let content = "MacClean Undo Test Content"
            try? content.write(toFile: testFile, atomically: true, encoding: .utf8)

            let item = CleanItem(
                name: "测试清理项",
                path: testFile,
                size: Int64(content.utf8.count),
                nature: .losslessCache,
                consequence: "测试文件",
                category: .logsAndTemp,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: nil, level: .dormant)
            )

            let originalRealPath = FileSystem.realPath(testFile)

            let result = Cleaner.clean([item], permanently: false) { _ in }
            guard result.succeeded == 1 else { return false }
            guard let snapshot = result.trashedSnapshots.first else { return false }

            // 原文件已被移入废纸篓
            let originalExists = FileManager.default.fileExists(atPath: testFile)
            let trashExists = FileManager.default.fileExists(atPath: snapshot.trashPath)
            defer { try? FileManager.default.removeItem(atPath: snapshot.trashPath) }

            let pathMatches = FileSystem.normalizePath(snapshot.originalPath) == FileSystem.normalizePath(testFile)
                || snapshot.originalPath == originalRealPath
            return !originalExists && trashExists && pathMatches
        }

        check("清理回滚执行：从废纸篓放回原位并联动缓存更新") {
            let tmpDir = "/private/tmp/macclean_undo_test2_\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let testFile = tmpDir + "/restore_me.txt"
            let content = "Data to restore"
            try? content.write(toFile: testFile, atomically: true, encoding: .utf8)

            let item = CleanItem(
                name: "还原测试项",
                path: testFile,
                size: Int64(content.utf8.count),
                nature: .losslessCache,
                consequence: "测试",
                category: .logsAndTemp,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: nil, level: .dormant)
            )

            // 1. 清理并记录撤销会话
            let cleanRes = Cleaner.clean([item], permanently: false) { _ in }
            guard let entry = cleanRes.trashedSnapshots.first else { return false }

            // 隔离测试存储
            let testStoreURL = URL(fileURLWithPath: tmpDir).appendingPathComponent("test_undo.json")
            UndoManagerStore.fileURLOverride = testStoreURL
            defer {
                UndoManagerStore.fileURLOverride = nil
                try? FileManager.default.removeItem(atPath: entry.trashPath)
            }

            let session = CleanUndoSession(recordID: UUID(), entries: cleanRes.trashedSnapshots)
            UndoManagerStore.record(session: session)

            // 2. 执行放回原位
            let restoreRes = UndoManagerStore.restore(sessionID: session.id)

            let fileRestored = FileManager.default.fileExists(atPath: testFile)
            let trashEmpty = !FileManager.default.fileExists(atPath: entry.trashPath)
            let updatedSession = UndoManagerStore.session(by: session.id)

            return restoreRes.succeeded == 1 && fileRestored && trashEmpty && (updatedSession?.isFullyRestored == true)
        }

        check("清理回滚安全：目标路径冲突时自动防覆盖重命名放回") {
            let tmpDir = "/private/tmp/macclean_undo_test3_\(UUID().uuidString)"
            try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(atPath: tmpDir) }

            let testFile = tmpDir + "/conflict.txt"
            try? "Old File in Trash".write(toFile: testFile, atomically: true, encoding: .utf8)

            let item = CleanItem(
                name: "冲突测试项",
                path: testFile,
                size: 20,
                nature: .losslessCache,
                consequence: "测试",
                category: .logsAndTemp,
                use: UseState(ownerIsRunning: false, ownerName: nil, lastUsed: nil, level: .dormant)
            )

            let cleanRes = Cleaner.clean([item], permanently: false) { _ in }
            guard let entry = cleanRes.trashedSnapshots.first else { return false }

            let testStoreURL = URL(fileURLWithPath: tmpDir).appendingPathComponent("test_undo.json")
            UndoManagerStore.fileURLOverride = testStoreURL
            defer {
                UndoManagerStore.fileURLOverride = nil
                try? FileManager.default.removeItem(atPath: entry.trashPath)
            }

            // 在原位置故意创建新文件（模拟同名冲突）
            let newContent = "New Existing File"
            try? newContent.write(toFile: testFile, atomically: true, encoding: .utf8)

            let session = CleanUndoSession(recordID: UUID(), entries: cleanRes.trashedSnapshots)
            UndoManagerStore.record(session: session)

            // 执行恢复
            let restoreRes = UndoManagerStore.restore(sessionID: session.id)

            // 校验：现有新文件未被覆盖
            let currentContent = (try? String(contentsOfFile: testFile, encoding: .utf8)) ?? ""
            let originalFileIntact = (currentContent == newContent)

            // 校验：恢复的文件存在且重命名
            let hasRestoredFile = restoreRes.restoredPaths.first != nil
                && FileManager.default.fileExists(atPath: restoreRes.restoredPaths.first!)
                && restoreRes.restoredPaths.first != testFile

            return restoreRes.succeeded == 1 && originalFileIntact && hasRestoredFile
        }
    }
}
