import Foundation
import AppKit

// MARK: - 剪贴板历史与大文件临时缓冲区治理深度自检 (v1.63.0)

extension Selftest {
    static func suiteClipboardDeep() {
        print("--- [Suite] 剪贴板历史与大文件临时缓冲区治理深度自检 (v1.63.0) ---")

        // 1. 数据类型与枚举判定
        check("Clipboard: 数据格式与分类枚举校验") {
            let item = PasteboardItemSummary(
                id: "public.utf8-plain-text",
                typeName: "public.utf8-plain-text",
                dataType: .text,
                size: 1024,
                preview: "Hello World",
                isLarge: false,
                isSensitive: false
            )
            guard item.dataType == .text && !item.isLarge && !item.isSensitive else { return false }
            guard PasteboardDataType.allCases.count >= 5 else { return false }
            return true
        }

        // 2. 敏感凭据正则表达式识别
        check("Clipboard: 敏感凭据与 API Key 正则拦截校验") {
            let purger = ClipboardPurger.shared

            let sensitiveKeys = [
                "sk-proj-abc123456789012345678901234567890",
                "ghp_123456789012345678901234567890123456",
                "AKIAIOSFODNN7EXAMPLE",
                "Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9",
                "-----BEGIN RSA PRIVATE KEY-----",
                "password = MySecretPassword123"
            ]
            for key in sensitiveKeys {
                guard purger.checkSensitivity(text: key) else {
                    print("    ❌ 未能识别敏感凭据: \(key)")
                    return false
                }
            }

            let normalTexts = [
                "Hello world, this is a normal text snippet.",
                "https://github.com/apple/swift",
                "let x = 100",
                "192.168.1.1"
            ]
            for text in normalTexts {
                guard !purger.checkSensitivity(text: text) else {
                    print("    ❌ 误报常规文本为敏感凭据: \(text)")
                    return false
                }
            }
            return true
        }

        // 3. 报告指标精算
        check("Clipboard: 报告指标与释放潜力精算") {
            let i1 = PasteboardItemSummary(id: "1", typeName: "t1", dataType: .image, size: 6 * 1024 * 1024, preview: "Image", isLarge: true, isSensitive: false)
            let i2 = PasteboardItemSummary(id: "2", typeName: "t2", dataType: .sensitiveCredential, size: 50, preview: "Key", isLarge: false, isSensitive: true)

            let c1 = ClipboardCacheItem(id: "c1", name: "cache1", path: "/tmp/c1", size: 4000, note: "note")

            let report = ClipboardReport(
                items: [i1, i2],
                cacheItems: [c1],
                totalMemorySize: 6 * 1024 * 1024 + 50,
                totalCacheSize: 4000,
                hasSensitiveData: true,
                changeCount: 10
            )

            guard report.totalMemorySize == (6 * 1024 * 1024 + 50) else { return false }
            guard report.totalCacheSize == 4000 else { return false }
            guard report.totalReclaimableSize == (6 * 1024 * 1024 + 4050) else { return false }
            guard report.hasSensitiveData == true else { return false }
            guard !report.isEmpty else { return false }

            return true
        }

        // 4. 系统越界与安全性防线
        check("Clipboard: 系统目录清理越界拦截") {
            let fakeCache = ClipboardCacheItem(
                id: "/System/Library/pboard",
                name: "pboard",
                path: "/System/Library/pboard",
                size: 1000,
                note: "test"
            )
            let res = ClipboardPurger.shared.cleanClipboardCaches(items: [fakeCache])
            guard res.cleanedCount == 0 && res.freedBytes == 0 else { return false }

            return true
        }

        // 5. 模拟临时缓存清理核验
        check("Clipboard: 模拟剪贴板临时置换文件清理核验") {
            let fm = FileManager.default
            let testDir = "/tmp/MacCleanTest_Clipboard_Clean"
            try? fm.removeItem(atPath: testDir)
            try? fm.createDirectory(atPath: testDir, withIntermediateDirectories: true)
            defer { try? fm.removeItem(atPath: testDir) }

            let dummyFile = (testDir as NSString).appendingPathComponent("pasteboard_temp.dat")
            try? "dummy pasteboard buffer data".data(using: .utf8)?.write(to: URL(fileURLWithPath: dummyFile))

            let cacheItem = ClipboardCacheItem(
                id: dummyFile,
                name: "pasteboard_temp.dat",
                path: dummyFile,
                size: 29,
                note: "test"
            )

            let res = ClipboardPurger.shared.cleanClipboardCaches(items: [cacheItem])
            guard res.cleanedCount == 1 && res.freedBytes == 29 else { return false }
            guard !fm.fileExists(atPath: dummyFile) else { return false }

            return true
        }

        // 6. 真实系统剪贴板读取无崩溃
        check("Clipboard: 真实系统剪贴板与临时缓存安全探测") {
            let report = ClipboardPurger.shared.inspect()
            // 无论当前剪贴板是否有内容，均应安全返回有效报告，无崩溃
            guard report.changeCount >= 0 else { return false }
            return true
        }
    }
}
