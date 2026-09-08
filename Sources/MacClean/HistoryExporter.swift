import Foundation
import AppKit
import UniformTypeIdentifiers

/// 清理历史导出器（支持 CSV 表格与纯文本 Markdown 报告）
enum HistoryExporter {

    private static let dateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return df
    }()

    private static let fileDateFormatter: DateFormatter = {
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        return df
    }()

    /// 生成标准 CSV 格式字符串（包含 UTF-8 BOM，杜绝 Excel 打开乱码）
    static func generateCSV(records: [CleanRecord]) -> String {
        var csv = "\u{FEFF}" // UTF-8 BOM
        csv += "记录ID,清理时间,分类,清理模式,清理项数,失败项数,释放字节数,释放大小\n"

        for r in records {
            let dateStr = dateFormatter.string(from: r.date)
            let cat = escapeCSV(r.categoryName)
            let mode = escapeCSV(r.mode)
            let byteStr = escapeCSV(r.bytes.byteStringCN)
            csv += "\(r.id.uuidString),\(dateStr),\(cat),\(mode),\(r.itemCount),\(r.failures),\(r.bytes),\(byteStr)\n"
        }

        return csv
    }

    /// 生成纯文本 Markdown 格式归档报告
    static func generateReport(records: [CleanRecord]) -> String {
        let nowStr = dateFormatter.string(from: Date())
        let totalBytes = records.reduce(Int64(0)) { $0 + $1.bytes }
        let totalItems = records.reduce(0) { $0 + $1.itemCount }
        let totalFailures = records.reduce(0) { $0 + $1.failures }
        let maxSingle = records.map(\.bytes).max() ?? 0

        var report = """
        # MacClean 清理历史归档报告
        生成时间：\(nowStr)

        ## 1. 总体统计概览
        - 清理执行次数：\(records.count) 次
        - 累计释放容量：\(totalBytes.byteStringCN) (\(totalBytes) 字节)
        - 累计处理文件项：\(totalItems) 项
        - 失败项目统计：\(totalFailures) 项
        - 单次最高释放峰值：\(maxSingle.byteStringCN)

        ## 2. 各分类释放分布统计
        """

        // 按分类聚合
        var byCategory: [String: (bytes: Int64, count: Int)] = [:]
        for r in records {
            let cur = byCategory[r.categoryName, default: (0, 0)]
            byCategory[r.categoryName] = (cur.bytes + r.bytes, cur.count + r.itemCount)
        }

        let sortedCategories = byCategory.sorted { $0.value.bytes > $1.value.bytes }
        for (cat, stat) in sortedCategories {
            let percent = totalBytes > 0 ? Double(stat.bytes) / Double(totalBytes) * 100.0 : 0
            report += "\n- **\(cat)**：累计释放 \(stat.bytes.byteStringCN)（\(String(format: "%.1f", percent))%），共清理 \(stat.count) 项"
        }

        report += "\n\n## 3. 详细清理流水记录\n"
        report += "| 时间 | 分类 | 模式 | 项数 | 释放容量 | 状态 |\n"
        report += "| :--- | :--- | :--- | :--- | :--- | :--- |\n"

        for r in records {
            let dateStr = dateFormatter.string(from: r.date)
            let status = r.failures > 0 ? "⚠️ \(r.failures) 项失败" : "✅ 成功"
            report += "| \(dateStr) | \(r.categoryName) | \(r.mode) | \(r.itemCount) 项 | \(r.bytes.byteStringCN) | \(status) |\n"
        }

        return report
    }

    /// 弹出系统级 NSSavePanel 保存文件
    @MainActor
    static func exportWithSavePanel(
        content: String,
        defaultFilename: String,
        fileExtension: String,
        completion: @escaping (Bool, String?) -> Void
    ) {
        let savePanel = NSSavePanel()
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = defaultFilename
        savePanel.allowedContentTypes = fileExtension == "csv" ? [.commaSeparatedText] : [.plainText]

        savePanel.begin { response in
            guard response == .OK, let url = savePanel.url else {
                completion(false, nil)
                return
            }

            do {
                try content.write(to: url, atomically: true, encoding: .utf8)
                completion(true, url.lastPathComponent)
            } catch {
                completion(false, nil)
            }
        }
    }

    /// 辅助方法：生成默认导出文件名
    static func makeDefaultFilename(prefix: String, ext: String) -> String {
        let dateStr = fileDateFormatter.string(from: Date())
        return "\(prefix)_\(dateStr).\(ext)"
    }

    private static func escapeCSV(_ str: String) -> String {
        if str.contains(",") || str.contains("\"") || str.contains("\n") {
            let escaped = str.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return str
    }
}
