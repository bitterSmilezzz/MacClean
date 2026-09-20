import Foundation
import SwiftUI
import ViewInspector
import Carbon

// 自检套件：菜单栏常驻助手全局快捷键呼出与极速一键清理微面板 (v1.56.0)
extension Selftest {
    static func suiteGlobalHotkeyDeep() {
        check("全局快捷键预设枚举与 Carbon 键码映射 (GlobalHotkeyPreset)") {
            // 1. controlOptionSpace (默认)
            let cos = GlobalHotkeyPreset.controlOptionSpace
            guard cos.carbonKeyCode == 49 else { return false }
            let cosExpectedMod = UInt32(controlKey | optionKey)
            guard cos.carbonModifiers == cosExpectedMod else { return false }
            guard cos.shortDisplay == "⌃⌥Space" else { return false }

            // 2. commandOptionC
            let coc = GlobalHotkeyPreset.commandOptionC
            guard coc.carbonKeyCode == 8 else { return false }
            let cocExpectedMod = UInt32(cmdKey | optionKey)
            guard coc.carbonModifiers == cocExpectedMod else { return false }
            guard coc.shortDisplay == "⌥⌘C" else { return false }

            // 3. commandShiftC
            let csc = GlobalHotkeyPreset.commandShiftC
            guard csc.carbonKeyCode == 8 else { return false }
            let cscExpectedMod = UInt32(cmdKey | shiftKey)
            guard csc.carbonModifiers == cscExpectedMod else { return false }

            // 4. f12
            let f12 = GlobalHotkeyPreset.f12
            guard f12.carbonKeyCode == 111 else { return false }
            guard f12.carbonModifiers == 0 else { return false }

            return true
        }

        check("全局快捷键生命周期：注册、注销与重绑 (GlobalHotkeyManager)") {
            let manager = GlobalHotkeyManager.shared

            // 1. 注册默认热键
            let reg1 = manager.register(preset: .controlOptionSpace)
            guard reg1 == true else { return false }
            guard manager.isRegistered == true else { return false }
            guard manager.activePreset == .controlOptionSpace else { return false }

            // 2. 重新绑定为另一预设
            let reg2 = manager.register(preset: .commandOptionC)
            guard reg2 == true else { return false }
            guard manager.activePreset == .commandOptionC else { return false }

            // 3. 注销热键
            manager.unregister()
            guard manager.isRegistered == false else { return false }
            guard manager.activePreset == nil else { return false }

            // 4. setEnabled 切换测试
            manager.setEnabled(true, preset: .controlOptionC)
            guard manager.isRegistered == true else { return false }
            guard manager.activePreset == .controlOptionC else { return false }

            manager.setEnabled(false)
            guard manager.isRegistered == false else { return false }

            return true
        }

        check("全局快捷键触发调度与自定义 Handler (dispatchTrigger)") {
            let manager = GlobalHotkeyManager.shared
            var triggered = false

            manager.setTriggerHandler {
                triggered = true
            }

            manager.dispatchTrigger()

            // 等待主线程派发
            let runLoop = RunLoop.current
            let deadline = Date().addingTimeInterval(0.2)
            while !triggered && runLoop.run(mode: .default, before: deadline) {
                if Date() > deadline { break }
            }

            guard triggered == true else { return false }
            return true
        }

        check("配置持久化与序列化：DiskMonitorConfig 全局热键字段") {
            var config = DiskMonitorConfig()
            guard config.globalHotkeyEnabled == true else { return false }
            guard config.globalHotkeyPreset == .controlOptionSpace else { return false }

            // 修改字段
            config.globalHotkeyEnabled = false
            config.globalHotkeyPreset = .commandShiftC

            // 序列化与反序列化
            guard let data = try? JSONEncoder().encode(config) else { return false }
            guard let decoded = try? JSONDecoder().decode(DiskMonitorConfig.self, from: data) else { return false }

            guard decoded.globalHotkeyEnabled == false else { return false }
            guard decoded.globalHotkeyPreset == .commandShiftC else { return false }

            return true
        }

        check("ViewInspector 交互自检：QuickCleanPanelView 仪表与快捷操作构建") {
            let app = AppState()
            let view = QuickCleanPanelView().environmentObject(app)

            // 1. 查找微面板主容器
            let panelInspect = try? view.inspect().find(viewWithAccessibilityIdentifier: "quickCleanPanel")
            guard panelInspect != nil else { return false }

            // 2. 查找一键极速释放操作按钮
            let actionBtn = try? view.inspect().find(viewWithAccessibilityIdentifier: "quickCleanActionButton")
            guard actionBtn != nil else { return false }

            // 3. 查找刷新 DNS 按钮与打开主面板按钮
            let dnsBtn = try? view.inspect().find(viewWithAccessibilityIdentifier: "quickFlushDNSButton")
            guard dnsBtn != nil else { return false }

            let mainBtn = try? view.inspect().find(viewWithAccessibilityIdentifier: "quickOpenMainButton")
            guard mainBtn != nil else { return false }

            let closeBtn = try? view.inspect().find(viewWithAccessibilityIdentifier: "closeQuickCleanButton")
            guard closeBtn != nil else { return false }

            return true
        }

        check("ViewInspector 交互自检：MenuBarView 极速微面板快捷胶囊渲染与点击") {
            let app = AppState()
            let menuBarView = MenuBarView().environmentObject(app)

            let quickPanelBtn = try? menuBarView.inspect().find(viewWithAccessibilityIdentifier: "menuBarQuickCleanPanelButton")
            guard quickPanelBtn != nil else { return false }

            // 尝试触发点击
            try? quickPanelBtn?.button().tap()

            return true
        }
    }
}
