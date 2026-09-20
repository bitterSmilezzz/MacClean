import Foundation

// MARK: - APFS 本地时间机器快照数据模型

public struct APFSSnapshot: Identifiable, Equatable, Hashable {
    public let id: String
    public let name: String
    public let dateString: String
    public let date: Date?
    public let volume: String

    public init(name: String, dateString: String, date: Date? = nil, volume: String = "/") {
        self.id = name
        self.name = name
        self.dateString = dateString
        self.date = date
        self.volume = volume
    }
}

// MARK: - 休眠映像与虚拟内存 Swap 数据模型

public struct VMMemoryInfo: Equatable {
    public var sleepimageExists: Bool = false
    public var sleepimageSize: Int64 = 0
    public var swapFilesCount: Int = 0
    public var totalSwapSize: Int64 = 0
    public var hibernateMode: Int? = nil
    public var isDesktopMac: Bool = false
    public var recommendedHibernateMode: Int = 0

    public init(
        sleepimageExists: Bool = false,
        sleepimageSize: Int64 = 0,
        swapFilesCount: Int = 0,
        totalSwapSize: Int64 = 0,
        hibernateMode: Int? = nil,
        isDesktopMac: Bool = false,
        recommendedHibernateMode: Int = 0
    ) {
        self.sleepimageExists = sleepimageExists
        self.sleepimageSize = sleepimageSize
        self.swapFilesCount = swapFilesCount
        self.totalSwapSize = totalSwapSize
        self.hibernateMode = hibernateMode
        self.isDesktopMac = isDesktopMac
        self.recommendedHibernateMode = recommendedHibernateMode
    }

    /// 智能分析建议说明
    public var suggestionText: String {
        guard let mode = hibernateMode else {
            return "未能获取当前休眠模式"
        }
        if mode == 0 {
            return "当前已是 Mode 0 (RAM 休眠，不占用 SSD 磁盘空间)，处于最省存储模式。"
        }
        if isDesktopMac {
            return "当前检测为台式 Mac (无需防电池耗尽断电)，建议切换为 Mode 0 释放 \(sleepimageSize.byteStringCN) 的 SSD 物理占用。"
        }
        if mode == 3 {
            return "当前为 SafeSleep (Mode 3: RAM + 磁盘双重备份)。若为常插电办公，可切换为 Mode 0 释放 \(sleepimageSize.byteStringCN) 存储空间。"
        }
        return "当前模式为 Mode \(mode)。"
    }
}

// MARK: - 系统底层存储深度治理引擎

public enum SystemDeepStorageInspector {

    // MARK: - APFS 本地快照检测与清理

    /// 解析 `tmutil listlocalsnapshots /` 的标准输出
    public static func parseSnapshots(from output: String, volume: String = "/") -> [APFSSnapshot] {
        var snapshots: [APFSSnapshot] = []
        let lines = output.components(separatedBy: .newlines)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            // 示例格式: com.apple.TimeMachine.2026-09-19-140000.local
            if trimmed.contains("com.apple.TimeMachine.") {
                let name = trimmed
                // 提取时间戳字符串
                let parts = trimmed.components(separatedBy: "com.apple.TimeMachine.")
                if let suffix = parts.last {
                    let datePart = suffix.replacingOccurrences(of: ".local", with: "")
                    let parsedDate = formatter.date(from: datePart)
                    snapshots.append(
                        APFSSnapshot(
                            name: name,
                            dateString: datePart,
                            date: parsedDate,
                            volume: volume
                        )
                    )
                }
            }
        }
        return snapshots.sorted { ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
    }

    /// 列出指定宗卷上的所有 APFS 本地快照
    public static func listLocalSnapshots(volume: String = "/") -> [APFSSnapshot] {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots", volume]
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            return parseSnapshots(from: output, volume: volume)
        } catch {
            return []
        }
    }

    /// 安全删除指定名称的本地快照
    public static func deleteLocalSnapshot(snapshotName: String) -> (success: Bool, message: String) {
        // tmutil deletelocalsnapshots 需要传入日期后缀或完整格式
        // 格式通常为: tmutil deletelocalsnapshots 2026-09-19-140000
        var targetDate = snapshotName
        if targetDate.contains("com.apple.TimeMachine.") {
            targetDate = targetDate.replacingOccurrences(of: "com.apple.TimeMachine.", with: "")
            targetDate = targetDate.replacingOccurrences(of: ".local", with: "")
        }

        let pipe = Pipe()
        let errPipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["deletelocalsnapshots", targetDate]
        process.standardOutput = pipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            let outData = pipe.fileHandleForReading.readDataToEndOfFile()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let outMsg = String(data: outData, encoding: .utf8) ?? ""
            let errMsg = String(data: errData, encoding: .utf8) ?? ""

            if process.terminationStatus == 0 {
                return (true, "已成功删除快照: \(snapshotName)")
            } else {
                return (false, "删除快照失败 (code \(process.terminationStatus)): \(errMsg.isEmpty ? outMsg : errMsg)")
            }
        } catch {
            return (false, "执行快照删除异常: \(error.localizedDescription)")
        }
    }

    /// 一键删除所有给定的本地快照
    public static func deleteAllLocalSnapshots(snapshots: [APFSSnapshot]) -> (succeededCount: Int, failedCount: Int) {
        var succeeded = 0
        var failed = 0
        for s in snapshots {
            let res = deleteLocalSnapshot(snapshotName: s.name)
            if res.success {
                succeeded += 1
            } else {
                failed += 1
            }
        }
        return (succeeded, failed)
    }

    // MARK: - 休眠映像与虚拟内存 Swap 检测

    /// 解析 `pmset -g` 输出中的 `hibernatemode`
    public static func parseHibernateMode(from output: String) -> Int? {
        let lines = output.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("hibernatemode") {
                let parts = trimmed.split(whereSeparator: { $0.isWhitespace })
                if parts.count >= 2, let mode = Int(parts[1]) {
                    return mode
                }
            }
        }
        return nil
    }

    /// 深度检测 `/var/vm` 中的休眠映像与 Swap 交换文件
    public static func inspectVMMemory() -> VMMemoryInfo {
        var info = VMMemoryInfo()
        let fm = FileManager.default

        // 1. 检查 sleepimage
        let sleepimagePath = "/var/vm/sleepimage"
        if fm.fileExists(atPath: sleepimagePath) {
            info.sleepimageExists = true
            if let attrs = try? fm.attributesOfItem(atPath: sleepimagePath),
               let size = attrs[.size] as? NSNumber {
                info.sleepimageSize = size.int64Value
            }
        }

        // 2. 检查 swapfile
        let vmDir = "/var/vm"
        if let contents = try? fm.contentsOfDirectory(atPath: vmDir) {
            for file in contents where file.hasPrefix("swapfile") {
                info.swapFilesCount += 1
                let filePath = (vmDir as NSString).appendingPathComponent(file)
                if let attrs = try? fm.attributesOfItem(atPath: filePath),
                   let size = attrs[.size] as? NSNumber {
                    info.totalSwapSize += size.int64Value
                }
            }
        }

        // 3. 读取当前休眠模式
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g"]
        process.standardOutput = pipe
        process.standardError = Pipe()

        if let _ = try? process.run() {
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            info.hibernateMode = parseHibernateMode(from: output)
        }

        // 4. 判断是否为台式 Mac (Mac mini, Mac Studio, Mac Pro, iMac)
        info.isDesktopMac = isCurrentMachineDesktop()
        info.recommendedHibernateMode = info.isDesktopMac ? 0 : 3

        return info
    }

    private static func isCurrentMachineDesktop() -> Bool {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let modelString = String(cString: model).lowercased()

        return modelString.contains("mini") ||
            modelString.contains("studio") ||
            modelString.contains("pro") && !modelString.contains("book") ||
            modelString.contains("imac")
    }

    /// 生成安全的休眠模式优化与 sleepimage 释放 Shell 脚本命令
    public static func generateHibernateOptimizationScript(targetMode: Int = 0) -> String {
        return """
        # --- MacClean 休眠镜像与物理存储释放命令 ---
        # 1. 设置休眠模式为 \(targetMode) (0: 纯内存休眠不写磁盘, 释放数十 GB 空间)
        sudo pmset -a hibernatemode \(targetMode)

        # 2. 安全删除当前的 sleepimage 物理镜像文件
        sudo rm -f /var/vm/sleepimage

        # 3. 创建空的 0 字节只读占位文件，防止 macOS 再次自动生成
        sudo touch /var/vm/sleepimage
        sudo chflags uchg /var/vm/sleepimage
        echo "✅ 休眠镜像已成功瘦身并锁定！"
        """
    }
}
