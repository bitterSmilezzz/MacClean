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
        return MacCleanState.stateDirectory.appendingPathComponent("undo_sessions.json")
    }

    private static let lock = NSLock()

    /// 包住 `load → insert → save` 整段。与上面那把 `lock` **必须是两把不同的锁**：
    /// `NSLock` 不可重入，同一把锁在 `load()` 里再 lock 一次就是自死锁且零输出。
    private static let transactionLock = NSLock()

    static func load() -> [CleanUndoSession] {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([CleanUndoSession].self, from: data)) ?? []
    }

    private static func save(_ sessions: [CleanUndoSession]) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(sessions) else { return false }
        do {
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// **变更撤销快照的唯一入口**：原子的"读—改—写"，返回是否真的落盘。
    /// 除本文件内部与自检的状态还原外，任何地方都不许直接 `save(...)`。
    /// 容量策略不在这里做——`restore` 只是回写自己那一行，不该顺手获得
    /// "淘汰最老快照"的权力。
    @discardableResult
    private static func mutate(_ body: (inout [CleanUndoSession]) -> Void) -> Bool {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        var sessions = load()
        body(&sessions)
        return save(sessions)
    }

    /// 记录新撤销会话
    static func record(session: CleanUndoSession) {
        mutate { sessions in
            sessions.insert(session, at: 0)
            // 仅保留最近 100 次清理会话，防无限制增长
            if sessions.count > 100 { sessions = Array(sessions.prefix(100)) }
        }
    }

    /// 自检专用：整体替换（走同一把事务锁）。生产代码不许调用。
    static func replaceAllForSelftest(_ sessions: [CleanUndoSession]) {
        _ = mutate { $0 = sessions }
    }

    /// 根据历史记录 ID 查询关联的撤销会话
    static func session(for recordID: UUID) -> CleanUndoSession? {
        load().first { $0.recordID == recordID }
    }

    /// 根据会话 ID 查询
    static func session(by sessionID: UUID) -> CleanUndoSession? {
        load().first { $0.id == sessionID }
    }

    /// 执行一键放回原位。
    ///
    /// 搬文件这段**不能**关在临界区里（一次放回可能要移动上百个文件、耗时秒级，
    /// 那会把所有后台清理的记账一起阻塞住）；但也不能像旧写法那样"开头 `load()` 一份数组、
    /// 结尾整片 `save()`"——那中间的秒级窗口里任何一次 `record` 都会被这份陈旧数组覆盖掉，
    /// 于是**历史记录还在、撤销快照没了**，用户点那一行只会得到"未找到对应的清理撤销快照"。
    /// 现在改成：先在只读快照上做实际搬运，攒下结果，最后用一次原子的读改写落账。
    static func restore(sessionID: UUID) -> RestoreResult {
        guard var session = session(by: sessionID) else {
            return RestoreResult(errors: ["未找到对应的清理撤销快照"])
        }
        var result = RestoreResult()
        var restored: [(index: Int, path: String)] = []
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
                restored.append((i, destPath))
                // 联动使测量与增量缓存失效
                FileSystem.invalidateMeasurements(for: [destPath])
            } catch {
                result.failed += 1
                result.errors.append("\(entry.itemName)：移动失败 - \(error.localizedDescription)")
            }
        }

        guard !restored.isEmpty else { return result }
        var accounted = false
        let wrote = mutate { sessions in
            guard let idx = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
            for r in restored {
                guard r.index < sessions[idx].entries.count else { continue }
                sessions[idx].entries[r.index].isRestored = true
                sessions[idx].entries[r.index].restoredPath = r.path
            }
            accounted = true
        }
        // 文件已经真的搬回原位了，账却没落成——必须说出来。
        // 否则这一行既不显示"放回"（废纸篓里已没有文件）也不显示"已放回"（isRestored 仍为假），
        // 用户再点一次只会得到"废纸篓中文件已被清空或移除"，把已经做成的事报成失败且永不收敛。
        if !accounted || !wrote {
            result.errors.append("文件已放回原位，但撤销快照未能记账（状态文件写入失败或该会话已被淘汰）")
        }
        return result
    }
}
