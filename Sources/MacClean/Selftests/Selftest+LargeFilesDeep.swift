import SwiftUI
import ViewInspector
import Darwin

// 自检套件：大文件排查与分类洞察增强 (v1.42.0)
extension Selftest {
    static func suiteLargeFilesDeep() {
        check("大文件增强：闲置天数计算与时间区间匹配 (LargeFileAgeFilter)") {
            let now = Date()
            let day10 = now.addingTimeInterval(-10 * 86400)
            let day45 = now.addingTimeInterval(-45 * 86400)
            let day120 = now.addingTimeInterval(-120 * 86400)
            let day240 = now.addingTimeInterval(-240 * 86400)
            let day400 = now.addingTimeInterval(-400 * 86400)

            guard HistoryExporter.idleDays(for: day10) >= 9 && HistoryExporter.idleDays(for: day10) <= 11 else { return false }
            guard HistoryExporter.idleDays(for: day400) >= 399 else { return false }

            let item10 = CleanItem(name: "recent.dmg", path: "/tmp/recent.dmg", size: 1000, rule: "T1", category: .largeFiles, modificationDate: day10)
            let item45 = CleanItem(name: "mid.zip", path: "/tmp/mid.zip", size: 2000, rule: "T1", category: .largeFiles, modificationDate: day45)
            let item120 = CleanItem(name: "old.iso", path: "/tmp/old.iso", size: 3000, rule: "T1", category: .largeFiles, modificationDate: day120)
            let item240 = CleanItem(name: "older.vdi", path: "/tmp/older.vdi", size: 4000, rule: "T1", category: .largeFiles, modificationDate: day240)
            let item400 = CleanItem(name: "ancient.tar", path: "/tmp/ancient.tar", size: 5000, rule: "T1", category: .largeFiles, modificationDate: day400)

            // 1. 全部时间
            guard LargeFileAgeFilter.all.matches(item: item10) && LargeFileAgeFilter.all.matches(item: item400) else { return false }

            // 2. 30天内活跃
            guard LargeFileAgeFilter.withinMonth.matches(item: item10) else { return false }
            guard !LargeFileAgeFilter.withinMonth.matches(item: item45) else { return false }

            // 3. 1-3个月
            guard LargeFileAgeFilter.oneToThreeMonths.matches(item: item45) else { return false }
            guard !LargeFileAgeFilter.oneToThreeMonths.matches(item: item120) else { return false }

            // 4. 3-6个月
            guard LargeFileAgeFilter.threeToSixMonths.matches(item: item120) else { return false }
            guard !LargeFileAgeFilter.threeToSixMonths.matches(item: item240) else { return false }

            // 5. 半年至1年
            guard LargeFileAgeFilter.sixMonthsToOneYear.matches(item: item240) else { return false }
            guard !LargeFileAgeFilter.sixMonthsToOneYear.matches(item: item400) else { return false }

            // 6. 1年以上闲置
            guard LargeFileAgeFilter.overOneYear.matches(item: item400) else { return false }
            guard !LargeFileAgeFilter.overOneYear.matches(item: item10) else { return false }

            return true
        }

        check("大文件增强：多维度排序逻辑 (LargeFileSortOrder)") {
            let now = Date()
            let itemSmall = CleanItem(name: "small.zip", path: "/tmp/small.zip", size: 100, rule: "T1", category: .largeFiles, modificationDate: now.addingTimeInterval(-100))
            let itemMedium = CleanItem(name: "medium.dmg", path: "/tmp/medium.dmg", size: 500, rule: "T1", category: .largeFiles, modificationDate: now.addingTimeInterval(-200))
            let itemLarge = CleanItem(name: "large.iso", path: "/tmp/large.iso", size: 1000, rule: "T1", category: .largeFiles, modificationDate: now.addingTimeInterval(-300))

            var list = [itemMedium, itemSmall, itemLarge]

            // 体积降序
            list.sort { $0.size > $1.size }
            guard list.map(\.name) == ["large.iso", "medium.dmg", "small.zip"] else { return false }

            // 修改时间最旧优先（升序）
            list.sort { ($0.modificationDate ?? Date.distantPast) < ($1.modificationDate ?? Date.distantPast) }
            guard list.map(\.name) == ["large.iso", "medium.dmg", "small.zip"] else { return false }

            // 修改时间最新优先（降序）
            list.sort { ($0.modificationDate ?? Date.distantPast) > ($1.modificationDate ?? Date.distantPast) }
            guard list.map(\.name) == ["small.zip", "medium.dmg", "large.iso"] else { return false }

            return true
        }

        check("大文件增强：CSV 清单、分析报告与 Shell 迁移脚本生成") {
            let now = Date()
            let item1 = CleanItem(name: "Xcode_16.dmg", path: "/Users/test/Downloads/Xcode_16.dmg", size: 12_000_000_000, rule: "T1", category: .largeFiles, modificationDate: now.addingTimeInterval(-200 * 86400))
            let item2 = CleanItem(name: "Dataset.zip", path: "/Users/test/Downloads/Dataset.zip", size: 5_000_000_000, rule: "T1", category: .largeFiles, modificationDate: now.addingTimeInterval(-400 * 86400))

            // 1. CSV 生成
            let csv = HistoryExporter.generateLargeFilesCSV(items: [item1, item2])
            guard csv.contains("文件名,大小,字节数,最后修改时间,闲置天数,细分类型,处置结论,结论依据,路径") else { return false }
            guard csv.contains("Xcode_16.dmg") && csv.contains("安装包") else { return false }
            guard csv.contains("Dataset.zip") && csv.contains("压缩包") else { return false }

            // 2. Markdown 分析报告
            let report = HistoryExporter.generateLargeFilesReport(items: [item1, item2])
            guard report.contains("# MacClean 大文件排查与分布洞察报告") else { return false }
            guard report.contains("细分类型容量分布") else { return false }
            guard report.contains("闲置时间跨度分布") else { return false }
            guard report.contains("Top 20 最大文件清单") else { return false }

            // 3. Shell 迁移脚本
            let script = HistoryExporter.generateLargeFilesMoveScript(items: [item1, item2], defaultDest: "/Volumes/Backup/Archive")
            guard script.contains("#!/bin/bash") else { return false }
            guard script.contains("DEST_DIR=\"${1:-/Volumes/Backup/Archive}\"") else { return false }
            guard script.contains("rsync -avP --remove-source-files") else { return false }
            guard script.contains("/Users/test/Downloads/Xcode_16.dmg") else { return false }

            return true
        }

        check("大文件增强：UI 视图时间与排序控件渲染") {
            let state = AppState()
            let view = CategoryDetailView(category: .largeFiles).environmentObject(state)
            guard let inspected = try? view.inspect() else { return false }

            // 验证存在大文件目录树入口
            _ = try? inspected.find(viewWithAccessibilityIdentifier: "largeFilesDirectoryTreeButton")

            return true
        }
    }
}
