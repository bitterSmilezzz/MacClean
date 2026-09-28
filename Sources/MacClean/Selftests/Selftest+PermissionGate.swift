import Foundation

// 自检套件：扫描前的权限门
//
// 背景：用户的原话是「不提示权限不够，我扫描的时候它自动应该让我加权限」。
// 在此之前，缺「完全磁盘访问权限」时：不报错、不拦、扫描前不提示，
// 只是安静地少看到一批位置——界面上和"这里本来就没东西"完全一样。
//
// 这一套锁住三件事：
//   ① 真值表：只有"交互式 + 无 FDA + 本会话未确认过"这一种组合才允许拦；
//   ② **无人值守绝不被拦**——否则定时扫描会弹出一个没人应答的模态框，
//      把整轮扫描永久挂住（这正是 `scanAll(unattended:)` 存在的理由）；
//   ③ 接线：拦下时必须"没有真的开始扫描"，且确认过之后不得反复拦（防无限弹窗）。
extension Selftest {
    static func suitePermissionGate() {

        check("权限门真值表：无人值守永不拦截，其余按三条件穷举") {
            var bad: [String] = []
            for unattended in [true, false] {
                for hasFDA in [true, false] {
                    for acknowledged in [true, false] {
                        let gate = PermissionGuide.scanGate(unattended: unattended,
                                                           hasFullDiskAccess: hasFDA,
                                                           acknowledgedWithoutFDA: acknowledged)
                        let label = "unattended=\(unattended) fda=\(hasFDA) ack=\(acknowledged)"
                        // ① 无人值守那一路（DiskMonitor 定时巡检 / 后台自愈）无论如何都要放行
                        if unattended, gate != .proceed {
                            bad.append("\(label)：无人值守被拦下了——会弹出没人应答的模态框")
                        }
                        // ② 已有 FDA，或本会话已确认过 → 放行
                        if (hasFDA || acknowledged), gate != .proceed {
                            bad.append("\(label)：本应放行")
                        }
                        // ③ 只有这一种组合该拦
                        if !unattended, !hasFDA, !acknowledged, gate != .needsFullDiskAccess {
                            bad.append("\(label)：缺 FDA 且未确认，却放行了")
                        }
                    }
                }
            }
            if !bad.isEmpty { print("      " + bad.joined(separator: "\n      ")) }
            return bad.isEmpty
        }

        check("权限门接线：缺 FDA 时 scanAll 被拦下，且没有真的开始扫描") {
            let app = AppState()
            PermissionGuide.fdaProbeOverride = false
            defer { PermissionGuide.fdaProbeOverride = nil }

            guard app.wouldGateInteractiveScan else { return false }
            app.scanAll()
            // 拦下的判据：门就位 + 范围是"全部"
            guard let gate = app.permissionGate, gate.category == nil else {
                print("      scanAll 没有被拦下")
                return false
            }
            // 关键：不能留下"正在扫描"的假状态，也不能有任何分类被标成扫描中
            guard !app.isScanningAll else {
                print("      被拦下却把 isScanningAll 置了真")
                return false
            }
            guard app.categories.allSatisfy({ !$0.isScanning }) else {
                print("      被拦下却把某个分类标成了扫描中")
                return false
            }
            return app.scannedCount == 0
        }

        check("权限门接线：单类扫描被拦下时带上具体分类，且该分类未开始扫描") {
            let app = AppState()
            PermissionGuide.fdaProbeOverride = false
            defer { PermissionGuide.fdaProbeOverride = nil }

            app.scan(.userCaches)
            guard let gate = app.permissionGate, gate.category == .userCaches else {
                print("      单类扫描没有被拦下，或分类丢失")
                return false
            }
            guard !app.state(for: .userCaches).isScanning else { return false }
            // 按钮文案要说清这次要扫的范围，而不是一句泛泛的"继续"
            return gate.actionLabel.contains("用户缓存")
        }

        check("权限门：确认过『仍然扫描』之后不得反复拦（防无限弹窗）") {
            let app = AppState()
            PermissionGuide.fdaProbeOverride = false
            defer { PermissionGuide.fdaProbeOverride = nil }

            guard app.wouldGateInteractiveScan else { return false }   // 前提：会被拦
            app.acknowledgeFullDiskAccessAbsenceForTesting()
            guard !app.wouldGateInteractiveScan else {
                print("      确认过之后仍在拦 → 用户会被反复弹窗")
                return false
            }
            return true
        }

        check("权限门：选『稍后』只关弹窗，不启动扫描、也不冒充已确认") {
            let app = AppState()
            PermissionGuide.fdaProbeOverride = false
            defer { PermissionGuide.fdaProbeOverride = nil }

            app.scanAll()
            guard app.permissionGate != nil else { return false }
            app.dismissPermissionGate()
            guard app.permissionGate == nil, !app.isScanningAll else { return false }
            // 有意的行为：不落盘、不静音，下次还会问——缺权限是"这一次"的事，
            // "上次我点了算了"不该变成永久静音。
            return app.wouldGateInteractiveScan
        }

        check("权限门：已有 FDA 时不拦，且与 remedy 的 needsFDA 口径一致") {
            let app = AppState()
            PermissionGuide.fdaProbeOverride = true
            defer { PermissionGuide.fdaProbeOverride = nil }

            guard !app.wouldGateInteractiveScan else { return false }
            return PermissionGuide.scanGate(unattended: false, hasFullDiskAccess: true,
                                            acknowledgedWithoutFDA: false) == .proceed
        }
    }
}
