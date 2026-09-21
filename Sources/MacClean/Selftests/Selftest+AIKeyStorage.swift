import Foundation

// 自检套件：API Key 存储（钥匙串优先 + 内存回退，绝不落盘）
//
// 背景：v1.35 及以前 Key 明文存 `~/Library/Application Support/MacClean/ai.key`（0600），
// 与本项目自己的发布门槛 docs/RELEASE-CHECKLIST.md「API Key 不落盘」直接矛盾。
// 现已改为只写系统钥匙串；钥匙串不可用（ad-hoc 重签导致 ACL 失配，见提交 4ec2fe5）
// 时退到**进程内会话缓存**并要求用户重新输入，而不是回退去写明文。
//
// 本套件全部使用一次性 keychain service 与临时目录，
// **不碰真实钥匙串条目、不碰真实 Key 文件**。
extension Selftest {
    static func suiteAIKeyStorage() {
        // MARK: - API Key 存储

        let testService = "com.macclean.app.selftest"
        let tmpDir = "/private/tmp/macclean_key_test_\(UUID().uuidString)"
        let legacyPath = tmpDir + "/ai.key"
        let testKey = "sk-selftest-not-a-real-key-0000000000"

        AIConfig.keychainServiceOverride = testService
        AIConfig.legacyKeyFileURLOverride = URL(fileURLWithPath: legacyPath)
        try? FileManager.default.createDirectory(atPath: tmpDir, withIntermediateDirectories: true)
        defer {
            AIConfig.clearAPIKey()                 // 清掉测试钥匙串条目与临时文件
            AIConfig.keychainServiceOverride = nil
            AIConfig.legacyKeyFileURLOverride = nil
            try? FileManager.default.removeItem(atPath: tmpDir)
        }

        check("API Key：保存只写钥匙串，不产生任何明文文件") {
            AIConfig.clearAPIKey()
            AIConfig.saveAPIKey(testKey)
            return !FileManager.default.fileExists(atPath: legacyPath)
        }

        check("API Key：保存后当前会话可读回（钥匙串或会话缓存）") {
            AIConfig.clearAPIKey()
            AIConfig.saveAPIKey(testKey)
            return AIConfig.loadAPIKey() == testKey
        }

        check("API Key：清空后读不到，且无明文残留") {
            AIConfig.saveAPIKey(testKey)
            AIConfig.clearAPIKey()
            AIConfig.resetSessionStateForTesting()
            return AIConfig.loadAPIKey() == nil && !FileManager.default.fileExists(atPath: legacyPath)
        }

        check("API Key：旧明文文件迁移不丢凭据（删文件 ⟺ 钥匙串确已写入）") {
            AIConfig.clearAPIKey()
            try? testKey.write(toFile: legacyPath, atomically: true, encoding: .utf8)
            guard AIConfig.loadAPIKey() == testKey else { return false }   // 迁移必须拿得到 Key
            if AIConfig.legacyKeyFileStillPresent {
                // 钥匙串写入失败 → 明文保留且内容不得被破坏（宁可留文件，也不丢凭据）
                return (try? String(contentsOfFile: legacyPath, encoding: .utf8)) == testKey
            }
            // 明文已删除 → Key 必须真的落在钥匙串里（清掉会话缓存后仍能读回）
            AIConfig.resetSessionStateForTesting()
            return AIConfig.loadAPIKey() == testKey
        }

        check("API Key：钥匙串已有 Key 时，残留明文文件被自动清除") {
            AIConfig.clearAPIKey()
            guard AIConfig.saveAPIKey(testKey) else { return true }   // 钥匙串不可用则跳过
            try? testKey.write(toFile: legacyPath, atomically: true, encoding: .utf8)
            AIConfig.resetSessionStateForTesting()
            _ = AIConfig.loadAPIKey()
            return !AIConfig.legacyKeyFileStillPresent
        }
    }
}
