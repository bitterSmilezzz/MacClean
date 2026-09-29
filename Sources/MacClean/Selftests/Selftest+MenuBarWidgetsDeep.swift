import Foundation
import Combine
import SwiftUI
import ViewInspector

// 自检套件：菜单栏常驻助手快捷小组件与状态指示深化 (v1.51.0)
extension Selftest {
    static func suiteMenuBarWidgetsDeep() {
        // 「近 7 天释放量/累计量」那两条口径断言已搬进 `suiteDeletionGate`（v1.73.14 复审 P1-6）：
        // 本套件在本机渲染某几个组件时会崩（exit=5），崩之前的断言不计入通过数，
        // 而这两条是纯函数判据、不碰 UI，留在能跑完的套件里才有执法力。

        check("菜单栏系统工具：本地快照与幽灵自启项批量清理边界与状态健壮性") {
            // 1. 空快照批量释放
            let snapRes = SystemDeepStorageInspector.deleteAllLocalSnapshots(snapshots: [])
            guard snapRes.succeededCount == 0 && snapRes.failedCount == 0 else { return false }

            // 2. 空自启项批量清理
            let startupRes = StartupItemManager.shared.cleanAllDangling(items: [])
            guard startupRes.removedCount == 0 && startupRes.freedBytes == 0 else { return false }

            // 3. 幽灵自启项判定
            let danglingMissing = StartupItemStatus.missingExecutable
            let danglingOrphan = StartupItemStatus.orphanedApp
            let validNormal = StartupItemStatus.valid

            guard danglingMissing.isDangling == true else { return false }
            guard danglingOrphan.isDangling == true else { return false }
            guard validNormal.isDangling == false else { return false }

            return true
        }

        check("菜单栏浮窗渲染：底层存储体检组与存储回收趋势微卡 ViewInspector 检验") {
            let app = AppState()
            let menuBarView = MenuBarView().environmentObject(app)

            guard let inspected = try? menuBarView.inspect() else { return false }

            // 检验底层存储体检组存在
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "menuBarSystemToolsGroup")) != nil else {
                return false
            }

            // 检验存储回收趋势微卡存在
            guard (try? inspected.find(viewWithAccessibilityIdentifier: "menuBarRecoveryTrendGroup")) != nil else {
                return false
            }

            return true
        }
    }
}
