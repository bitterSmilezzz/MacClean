import Foundation

// MARK: - 下载目录智能时效归档与治理深度自检 (v1.62.0)

extension Selftest {
    static func suiteDownloadsOrganizerDeep() {
        print("--- [Suite] 下载目录智能时效归档与治理深度自检 (v1.62.0) ---")

        // 1. 下载项类型解析
        check("DownloadsOrganizer: 文件后缀与分类类型映射解析") {
            guard DownloadItemKind.from(path: "Chrome.dmg") == .installer else { return false }
            guard DownloadItemKind.from(path: "Node.pkg") == .installer else { return false }
            guard DownloadItemKind.from(path: "Ubuntu.iso") == .installer else { return false }
            guard DownloadItemKind.from(path: "archive.zip") == .archive else { return false }
            guard DownloadItemKind.from(path: "project.tar.gz") == .archive else { return false }
            guard DownloadItemKind.from(path: "movie.mp4") == .media else { return false }
            guard DownloadItemKind.from(path: "doc.pdf") == .document else { return false }
            guard DownloadItemKind.from(path: "data.csv") == .document else { return false }
            guard DownloadItemKind.from(path: "binary.bin") == .other else { return false }
            return true
        }

        // 2. 闲置时效与高推荐清理判定
        check("DownloadsOrganizer: 闲置时效与推荐清理策略校验") {
            let freshInstaller = DownloadItem(
                id: "1", fileName: "app.dmg", path: "/app.dmg", size: 100, kind: .installer,
                modificationDate: Date(), ageDays: 2, isSelected: false
            )
            guard !freshInstaller.isHighlyRecommendedToClean else { return false }

            let oldInstaller = DownloadItem(
                id: "2", fileName: "app.dmg", path: "/app.dmg", size: 100, kind: .installer,
                modificationDate: Date(), ageDays: 8, isSelected: false
            )
            guard oldInstaller.isHighlyRecommendedToClean else { return false }

            let oldArchive = DownloadItem(
                id: "3", fileName: "data.zip", path: "/data.zip", size: 200, kind: .archive,
                modificationDate: Date(), ageDays: 35, isSelected: false
            )
            guard oldArchive.isHighlyRecommendedToClean else { return false }

            let oldDoc = DownloadItem(
                id: "4", fileName: "report.pdf", path: "/report.pdf", size: 50, kind: .document,
                modificationDate: Date(), ageDays: 100, isSelected: false
            )
            guard oldDoc.isHighlyRecommendedToClean else { return false }

            return true
        }

        // 3. 概要指标统计精算
        check("DownloadsOrganizer: 概要指标统计与已选容量精算") {
            let item1 = DownloadItem(id: "1", fileName: "i1.dmg", path: "1", size: 1000, kind: .installer, modificationDate: Date(), ageDays: 10, isSelected: true)
            let item2 = DownloadItem(id: "2", fileName: "i2.zip", path: "2", size: 2000, kind: .archive, modificationDate: Date(), ageDays: 40, isSelected: true)
            let item3 = DownloadItem(id: "3", fileName: "i3.pdf", path: "3", size: 500, kind: .document, modificationDate: Date(), ageDays: 5, isSelected: false)

            let summary = DownloadsSummary(
                items: [item1, item2, item3],
                totalSize: 3500,
                installerSize: 1000,
                installerCount: 1,
                archiveSize: 2000,
                archiveCount: 1,
                staleSize: 3000,
                staleCount: 2
            )

            guard summary.totalSize == 3500 else { return false }
            guard summary.selectedSize == 3000 else { return false }
            guard summary.selectedCount == 2 else { return false }
            guard summary.staleCount == 2 else { return false }

            return true
        }

        // 4. 系统越界与安全性防线
        check("DownloadsOrganizer: 系统目录扫描与清理越界拦截") {
            let sysSummary = DownloadsOrganizerScanner.shared.scan(customDirectory: "/System")
            guard sysSummary.items.isEmpty else { return false }

            let fakeItem = DownloadItem(
                id: "/System/fake.dmg", fileName: "fake.dmg", path: "/System/fake.dmg",
                size: 100, kind: .installer, modificationDate: Date(), ageDays: 10, isSelected: true
            )
            let cleanRes = DownloadsOrganizerScanner.shared.clean(items: [fakeItem], toTrash: true)
            guard cleanRes.cleanedCount == 0 && cleanRes.errorCount > 0 else { return false }

            let archiveRes = DownloadsOrganizerScanner.shared.archive(items: [fakeItem], targetDirectory: "/System/Archived")
            guard archiveRes.movedCount == 0 && archiveRes.errorCount > 0 else { return false }

            return true
        }

        // 5. 模拟下载目录扫描与推荐勾选
        check("DownloadsOrganizer: 模拟下载目录扫描与时效分析") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Downloads_Scan"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let dmgPath = (testDir as NSString).appendingPathComponent("installer.dmg")
            let zipPath = (testDir as NSString).appendingPathComponent("backup.zip")
            try? "dmg data".data(using: .utf8)?.write(to: URL(fileURLWithPath: dmgPath))
            try? "zip data".data(using: .utf8)?.write(to: URL(fileURLWithPath: zipPath))

            // 设置 dmg mtime 为 15 天前（应被判定为高推荐清理）
            let oldDate = Date().addingTimeInterval(-15 * 86400)
            try? fm.setAttributes([.modificationDate: oldDate], ofItemAtPath: dmgPath)

            let summary = DownloadsOrganizerScanner.shared.scan(customDirectory: testDir)
            guard summary.items.count == 2 else { return false }

            let dmgItem = summary.items.first { $0.fileName == "installer.dmg" }
            guard let dmgItem, dmgItem.kind == .installer, dmgItem.ageDays >= 14, dmgItem.isSelected == true else {
                return false
            }

            return true
        }

        // 6. 模拟归档移动与安全清理核验
        check("DownloadsOrganizer: 模拟归档子目录移动与清理核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Downloads_Action"
            let archiveDir = (testDir as NSString).appendingPathComponent("Archived_Test")
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let f1 = (testDir as NSString).appendingPathComponent("doc1.pdf")
            let f2 = (testDir as NSString).appendingPathComponent("doc2.pdf")
            try? "pdf1".data(using: .utf8)?.write(to: URL(fileURLWithPath: f1))
            try? "pdf2".data(using: .utf8)?.write(to: URL(fileURLWithPath: f2))

            let item1 = DownloadItem(id: f1, fileName: "doc1.pdf", path: f1, size: 4, kind: .document, modificationDate: Date(), ageDays: 1, isSelected: true)
            let item2 = DownloadItem(id: f2, fileName: "doc2.pdf", path: f2, size: 4, kind: .document, modificationDate: Date(), ageDays: 1, isSelected: true)

            // 执行归档移动 item1
            let archiveRes = DownloadsOrganizerScanner.shared.archive(items: [item1], targetDirectory: archiveDir)
            guard archiveRes.movedCount == 1 && archiveRes.errorCount == 0 else { return false }
            guard !fm.fileExists(atPath: f1) && fm.fileExists(atPath: (archiveDir as NSString).appendingPathComponent("doc1.pdf")) else {
                return false
            }

            // 执行彻底删除 item2
            let cleanRes = DownloadsOrganizerScanner.shared.clean(items: [item2], toTrash: false)
            guard cleanRes.cleanedCount == 1 && cleanRes.freedBytes == 4 else { return false }
            guard !fm.fileExists(atPath: f2) else { return false }

            return true
        }
    }
}
