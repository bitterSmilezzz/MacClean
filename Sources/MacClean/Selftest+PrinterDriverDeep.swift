import Foundation

// MARK: - 废弃打印机驱动与 PPD 描述文件治理深度自检 (v1.71.0)

extension Selftest {
    static func suitePrinterDriverDeep() {
        print("--- [Suite] 废弃打印机驱动与 PPD 描述文件治理深度自检 (v1.71.0) ---")

        // 1. 驱动分类、图标与健康状态枚举判定
        check("PrinterDriver: 驱动分类、图标与健康状态枚举判定") {
            guard PrinterDriverKind.vendorDriverBundle.icon == "printer.fill" else { return false }
            guard PrinterDriverKind.ppdResource.icon == "doc.text.fill" else { return false }
            guard PrinterDriverKind.cupsQueue.icon == "list.bullet.rectangle" else { return false }
            guard PrinterDriverKind.scannerDriver.icon == "scanner.fill" else { return false }

            guard PrinterDriverStatus.orphanUnused.isOrphanOrCorrupted == true else { return false }
            guard PrinterDriverStatus.corrupted.isOrphanOrCorrupted == true else { return false }
            guard PrinterDriverStatus.activeConfigured.isOrphanOrCorrupted == false else { return false }
            guard PrinterDriverStatus.systemProtected.isOrphanOrCorrupted == false else { return false }

            return true
        }

        // 2. 概要指标统计与已选释放容量精算
        check("PrinterDriver: 概要指标统计与已选释放容量精算") {
            let date = Date()
            let item1 = PrinterDriverItem(
                id: "/p1", name: "hp", vendor: "惠普 (HP)", path: "/p1",
                kind: .vendorDriverBundle, status: .orphanUnused,
                size: 2048, fileCount: 15, modificationDate: date, isSelected: true
            )
            let item2 = PrinterDriverItem(
                id: "/p2", name: "corrupted.ppd", vendor: "通用/第三方厂商", path: "/p2",
                kind: .ppdResource, status: .corrupted,
                size: 0, fileCount: 0, modificationDate: date, isSelected: true
            )
            let item3 = PrinterDriverItem(
                id: "/p3", name: "Canon_MF4700", vendor: "佳能 (Canon)", path: "/p3",
                kind: .cupsQueue, status: .activeConfigured,
                size: 4096, fileCount: 2, modificationDate: date, isSelected: false
            )

            let summary = PrinterDriverSummary(
                items: [item1, item2, item3],
                totalSize: 6144,
                orphanCount: 2,
                orphanSize: 2048,
                activeCount: 1
            )

            guard summary.totalSize == 6144 else { return false }
            guard summary.orphanCount == 2 else { return false }
            guard summary.orphanSize == 2048 else { return false }
            guard summary.activeCount == 1 else { return false }
            guard summary.selectedSize == 2048 else { return false }
            guard summary.selectedCount == 2 else { return false }

            return true
        }

        // 3. 活动打印机白名单与系统防线越界拦截
        check("PrinterDriver: 活动打印机白名单与系统防线越界拦截") {
            // 厂商推导校验
            guard PrinterDriverScanner.inferVendor(from: "Hewlett-Packard.bundle") == "惠普 (HP)" else { return false }
            guard PrinterDriverScanner.inferVendor(from: "Canon_MF_Series") == "佳能 (Canon)" else { return false }
            guard PrinterDriverScanner.inferVendor(from: "EpsonNet_Config") == "爱普生 (Epson)" else { return false }

            // 活动打印机配置识别
            let configured = PrinterDriverScanner.evaluateDriverEntry(
                name: "Canon",
                path: "/Library/Printers/Canon",
                size: 5000,
                activeKeywords: ["canon", "mf4700"]
            )
            guard configured.status == .activeConfigured else { return false }

            // 未连接废弃驱动识别
            let unused = PrinterDriverScanner.evaluateDriverEntry(
                name: "Xerox",
                path: "/Library/Printers/Xerox",
                size: 5000,
                activeKeywords: ["canon", "mf4700"]
            )
            guard unused.status == .orphanUnused else { return false }

            // 系统目录拦截
            let sysItem = PrinterDriverItem(
                id: "/System/Library/Printers/Sys", name: "Sys", vendor: "Apple",
                path: "/System/Library/Printers/Sys", kind: .vendorDriverBundle,
                status: .systemProtected, size: 1000, fileCount: 1, modificationDate: Date(), isSelected: true
            )
            let resSys = PrinterDriverScanner.shared.clean(items: [sysItem], toTrash: false)
            guard resSys.cleanedCount == 0 && resSys.errorCount > 0 else { return false }

            // 活动受保护项拦截
            let activeItem = PrinterDriverItem(
                id: "/Library/Printers/Canon", name: "Canon", vendor: "佳能 (Canon)",
                path: "/Library/Printers/Canon", kind: .vendorDriverBundle,
                status: .activeConfigured, size: 1000, fileCount: 1, modificationDate: Date(), isSelected: true
            )
            let resActive = PrinterDriverScanner.shared.clean(items: [activeItem], toTrash: false)
            guard resActive.cleanedCount == 0 && resActive.errorCount > 0 else { return false }

            return true
        }

        // 4. 模拟打印机驱动目录扫描与废弃驱动识别
        check("PrinterDriver: 模拟打印机驱动目录扫描与废弃驱动识别") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Printer_Scan"
            let printersDir = (testDir as NSString).appendingPathComponent("Printers")
            let userPrintersDir = (testDir as NSString).appendingPathComponent("UserPrinters")
            let cupsDir = (testDir as NSString).appendingPathComponent("cups")
            let cupsPPD = (cupsDir as NSString).appendingPathComponent("ppd")

            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: printersDir, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: userPrintersDir, withIntermediateDirectories: true)
            try? fm.createDirectory(atPath: cupsPPD, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            // 创建活动打印机 PPD (Canon)
            let canonPPD = (cupsPPD as NSString).appendingPathComponent("Canon_Office.ppd")
            try? "*PPD-Adobe: 4.3".data(using: .utf8)?.write(to: URL(fileURLWithPath: canonPPD))

            // 创建废弃厂商驱动 (hp)
            let hpDir = (printersDir as NSString).appendingPathComponent("hp")
            try? fm.createDirectory(atPath: hpDir, withIntermediateDirectories: true)
            let f1 = (hpDir as NSString).appendingPathComponent("hp_driver.bin")
            try? "mock_hp_bytes".data(using: .utf8)?.write(to: URL(fileURLWithPath: f1))

            // 创建废弃用户队列 (Old_Epson_Queue)
            let oldQueue = (userPrintersDir as NSString).appendingPathComponent("Old_Epson_Queue")
            try? "mock_queue".data(using: .utf8)?.write(to: URL(fileURLWithPath: oldQueue))

            let summary = PrinterDriverScanner.shared.scan(
                customPrinterDirs: [printersDir],
                customUserPrinterDirs: [userPrintersDir],
                customCupsDir: cupsDir
            )

            guard summary.items.count == 2 else { return false }
            guard summary.orphanCount == 2 else { return false }
            guard summary.totalSize > 0 else { return false }

            let hpItem = summary.items.first(where: { $0.name == "hp" })
            guard let hpItem, hpItem.status == .orphanUnused && hpItem.vendor == "惠普 (HP)" else { return false }

            return true
        }

        // 5. 模拟安全清理与文件移除核验
        check("PrinterDriver: 模拟安全清理与文件移除核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Printer_Clean"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let orphanDir = (testDir as NSString).appendingPathComponent("Brother_Legacy")
            try? fm.createDirectory(atPath: orphanDir, withIntermediateDirectories: true)
            let file = (orphanDir as NSString).appendingPathComponent("driver.pkg")
            try? "mock_brother_data".data(using: .utf8)?.write(to: URL(fileURLWithPath: file))
            let fileSize = Int64((try? fm.attributesOfItem(atPath: file)[.size] as? UInt64) ?? 0)

            let item = PrinterDriverItem(
                id: orphanDir,
                name: "Brother_Legacy",
                vendor: "兄弟 (Brother)",
                path: orphanDir,
                kind: .vendorDriverBundle,
                status: .orphanUnused,
                size: fileSize,
                fileCount: 1,
                modificationDate: Date(),
                isSelected: true
            )

            guard fm.fileExists(atPath: orphanDir) else { return false }

            let res = PrinterDriverScanner.shared.clean(items: [item], toTrash: false)
            guard res.cleanedCount == 1 else { return false }
            guard res.freedBytes == fileSize else { return false }
            guard res.errorCount == 0 else { return false }
            guard !fm.fileExists(atPath: orphanDir) else { return false }

            return true
        }

        // 6. 空目录与非驱动杂项文件鲁棒性断言
        check("PrinterDriver: 空目录与非驱动杂项文件鲁棒性断言") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Printer_Filter"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            // 写入隐藏文件
            let hidden = (testDir as NSString).appendingPathComponent(".DS_Store")
            try? "hidden".data(using: .utf8)?.write(to: URL(fileURLWithPath: hidden))

            let summary = PrinterDriverScanner.shared.scan(
                customPrinterDirs: [testDir],
                customUserPrinterDirs: [testDir + "/empty"],
                customCupsDir: testDir + "/nocups"
            )

            guard summary.items.isEmpty else { return false }
            guard summary.totalSize == 0 else { return false }

            return true
        }
    }
}
