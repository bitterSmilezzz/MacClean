import Foundation

// MARK: - 清理撤销与回滚数据模型（v1.35.0）

/// 单个移入废纸篓文件的快照条目
struct TrashedItemEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var originalPath: String
    var trashPath: String
    var size: Int64
    var itemName: String
    var isRestored: Bool = false
    var restoredPath: String? = nil
}

/// 单次清理会话的撤销快照
struct CleanUndoSession: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var recordID: UUID
    var createdAt: Date = Date()
    var entries: [TrashedItemEntry]

    /// 当前是否还有可还原的项目（未还原且废纸篓文件仍存在）
    var canRestore: Bool {
        entries.contains { entry in
            !entry.isRestored && FileManager.default.fileExists(atPath: entry.trashPath)
        }
    }

    /// 废纸篓中尚存的可还原文件数
    var availableCount: Int {
        entries.filter { entry in
            !entry.isRestored && FileManager.default.fileExists(atPath: entry.trashPath)
        }.count
    }

    /// 全部项目是否均已还原
    var isFullyRestored: Bool {
        !entries.isEmpty && entries.allSatisfy(\.isRestored)
    }
}

/// 放回原位还原结果
struct RestoreResult: Equatable {
    var succeeded: Int = 0
    var failed: Int = 0
    var restoredBytes: Int64 = 0
    var restoredPaths: [String] = []
    var errors: [String] = []

    var summary: String {
        if failed == 0 {
            return "已成功放回 \(succeeded) 项"
        } else if succeeded == 0 {
            return "放回失败：\(errors.first ?? "文件已从废纸篓清除")"
        } else {
            return "已放回 \(succeeded) 项，\(failed) 项失败"
        }
    }
}

// MARK: - 撤销会话持久化与还原执行器

enum UndoManagerStore {
    /// 单元测试注入用路径
    static var fileURLOverride: URL?

    private static var fileURL: URL {
        if let override = fileURLOverride { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        let dir = base.appendingPathComponent("MacClean", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("undo_sessions.json")
    }

    private static let lock = NSLock()

    static func load() -> [CleanUndoSession] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([CleanUndoSession].self, from: data)) ?? []
    }

    static func save(_ sessions: [CleanUndoSession]) {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(sessions) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// 记录新撤销会话
    static func record(session: CleanUndoSession) {
        var sessions = load()
        sessions.insert(session, at: 0)
        // 仅保留最近 100 次清理会话，防无限制增长
        if sessions.count > 100 {
            sessions = Array(sessions.prefix(100))
        }
        save(sessions)
    }

    /// 根据历史记录 ID 查询关联的撤销会话
    static func session(for recordID: UUID) -> CleanUndoSession? {
        load().first { $0.recordID == recordID }
    }

    /// 根据会话 ID 查询
    static func session(by sessionID: UUID) -> CleanUndoSession? {
        load().first { $0.id == sessionID }
    }

    /// 执行一键放回原位
    static func restore(sessionID: UUID) -> RestoreResult {
        var sessions = load()
        guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else {
            return RestoreResult(errors: ["未找到对应的清理撤销快照"])
        }

        var session = sessions[idx]
        var result = RestoreResult()
        let fm = FileManager.default

        for i in 0..<session.entries.count {
            guard !session.entries[i].isRestored else { continue }
            let entry = session.entries[i]

            // 1. 检查废纸篓中的文件是否存在
            guard fm.fileExists(atPath: entry.trashPath) else {
                result.failed += 1
                result.errors.append("\(entry.itemName)：废纸篓中文件已被清空或移除")
                continue
            }

            // 2. 目标父目录检查与自动重建
            let targetDir = (entry.originalPath as NSString).deletingLastPathComponent
            if !fm.fileExists(atPath: targetDir) {
                try? fm.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
            }

            // 3. 目标路径防覆盖重命名
            var destPath = entry.originalPath
            if fm.fileExists(atPath: destPath) {
                let ext = (entry.originalPath as NSString).pathExtension
                let base = ((entry.originalPath as NSString).lastPathComponent as NSString).deletingPathExtension
                let dir = (entry.originalPath as NSString).deletingLastPathComponent
                let suffix = ext.isEmpty ? "" : ".\(ext)"
                var counter = 1
                while fm.fileExists(atPath: destPath) {
                    let newName = "\(base) (恢复 \(counter))\(suffix)"
                    destPath = (dir as NSString).appendingPathComponent(newName)
                    counter += 1
                }
            }

            // 4. 执行移动放回
            do {
                try fm.moveItem(atPath: entry.trashPath, toPath: destPath)
                session.entries[i].isRestored = true
                session.entries[i].restoredPath = destPath
                result.succeeded += 1
                result.restoredBytes += entry.size
                result.restoredPaths.append(destPath)
                // 联动使测量与增量缓存失效
                FileSystem.invalidateMeasurements(for: [destPath])
            } catch {
                result.failed += 1
                result.errors.append("\(entry.itemName)：移动失败 - \(error.localizedDescription)")
            }
        }

        sessions[idx] = session
        save(sessions)
        return result
    }
}
