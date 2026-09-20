import Foundation

// MARK: - 系统底层存储深度治理自检套件 (v1.48.0)

extension Selftest {
    static func suiteSystemDeepStorage() {
        print("==> 运行系统底层存储深度治理自检 (v1.48.0)...")

        // 1. APFS 本地快照输出解析
        check("底层存储深度：tmutil 本地快照输出文本解析与时间戳排序") {
            let mockOutput = """
            Snapshots for volume group /:
            com.apple.TimeMachine.2026-09-18-100000.local
            com.apple.TimeMachine.2026-09-19-153022.local
            com.apple.TimeMachine.2026-09-17-080000.local
            """

            let snapshots = SystemDeepStorageInspector.parseSnapshots(from: mockOutput, volume: "/")
            guard snapshots.count == 3 else { return false }

            // 验证按日期降序排列（最新排前）
            guard snapshots[0].dateString == "2026-09-19-153022" &&
                    snapshots[1].dateString == "2026-09-18-100000" &&
                    snapshots[2].dateString == "2026-09-17-080000" else {
                return false
            }

            guard snapshots[0].name == "com.apple.TimeMachine.2026-09-19-153022.local" else {
                return false
            }

            // 空输出容错
            let emptySnaps = SystemDeepStorageInspector.parseSnapshots(from: "", volume: "/")
            return emptySnaps.isEmpty
        }

        // 2. 休眠模式解析
        check("底层存储深度：pmset 输出中 hibernatemode 提取") {
            let mockPmset = """
            System-wide power settings:
            Currently in use:
             standbydelaylow      10800
             standby              1
             hibernatemode        3
             powernap             1
             gpuswitch            2
            """

            let mode3 = SystemDeepStorageInspector.parseHibernateMode(from: mockPmset)
            guard mode3 == 3 else { return false }

            let mockPmset0 = """
             hibernatemode        0
             sleep                10
            """
            let mode0 = SystemDeepStorageInspector.parseHibernateMode(from: mockPmset0)
            guard mode0 == 0 else { return false }

            let invalidPmset = "no hibernate mode in here"
            return SystemDeepStorageInspector.parseHibernateMode(from: invalidPmset) == nil
        }

        // 3. 休眠建议逻辑推导
        check("底层存储深度：休眠分析建议智能推导") {
            let infoMode0 = VMMemoryInfo(
                sleepimageExists: false,
                sleepimageSize: 0,
                hibernateMode: 0,
                isDesktopMac: false
            )
            guard infoMode0.suggestionText.contains("Mode 0") && infoMode0.suggestionText.contains("最省存储模式") else {
                return false
            }

            let infoDesktop = VMMemoryInfo(
                sleepimageExists: true,
                sleepimageSize: 16 * 1024 * 1024 * 1024,
                hibernateMode: 3,
                isDesktopMac: true
            )
            guard infoDesktop.suggestionText.contains("台式 Mac") && infoDesktop.suggestionText.contains("GB") else {
                return false
            }

            return true
        }

        // 4. 优化 Shell 脚本生成规范
        check("底层存储深度：休眠瘦身 Shell 脚本生成规范") {
            let script = SystemDeepStorageInspector.generateHibernateOptimizationScript(targetMode: 0)
            return script.contains("sudo pmset -a hibernatemode 0") &&
                script.contains("sudo rm -f /var/vm/sleepimage") &&
                script.contains("sudo chflags uchg /var/vm/sleepimage")
        }

        // 5. 真实宿主环境只读探查无崩溃
        check("底层存储深度：真实环境 inspectVMMemory 安全调用无崩溃") {
            let vm = SystemDeepStorageInspector.inspectVMMemory()
            return vm.swapFilesCount >= 0 && vm.totalSwapSize >= 0
        }
    }
}
