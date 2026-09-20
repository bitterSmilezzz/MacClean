import Foundation
import AppKit
import Carbon

// MARK: - 全局快捷键预设枚举

enum GlobalHotkeyPreset: String, Codable, CaseIterable, Identifiable {
    case controlOptionSpace = "⌃⌥Space (推荐)"
    case commandOptionC = "⌥⌘C"
    case controlOptionC = "⌃⌥C"
    case commandShiftC = "⇧⌘C"
    case f12 = "F12"

    var id: String { rawValue }

    var shortDisplay: String {
        switch self {
        case .controlOptionSpace: return "⌃⌥Space"
        case .commandOptionC: return "⌥⌘C"
        case .controlOptionC: return "⌃⌥C"
        case .commandShiftC: return "⇧⌘C"
        case .f12: return "F12"
        }
    }

    /// Carbon Key Code
    var carbonKeyCode: UInt32 {
        switch self {
        case .controlOptionSpace: return 49   // kVK_Space
        case .commandOptionC:     return 8    // kVK_ANSI_C
        case .controlOptionC:     return 8    // kVK_ANSI_C
        case .commandShiftC:      return 8    // kVK_ANSI_C
        case .f12:                return 111  // kVK_F12
        }
    }

    /// Carbon Modifiers
    var carbonModifiers: UInt32 {
        switch self {
        case .controlOptionSpace: return UInt32(controlKey | optionKey)
        case .commandOptionC:     return UInt32(cmdKey | optionKey)
        case .controlOptionC:     return UInt32(controlKey | optionKey)
        case .commandShiftC:      return UInt32(cmdKey | shiftKey)
        case .f12:                return 0
        }
    }
}

// MARK: - 全局快捷键管理器 (Carbon 原生零权限机制)

final class GlobalHotkeyManager {
    static let shared = GlobalHotkeyManager()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var isHandlerInstalled = false
    private let hotKeySignature: OSType = 0x4D434C4E // 'MCLN' (MacClean)
    private let hotKeyIDValue: UInt32 = 1

    private var currentPreset: GlobalHotkeyPreset?
    private var isEnabled: Bool = true
    private var onTrigger: (() -> Void)?

    private init() {}

    /// 初始化绑定（与 AppState 联动）
    func setup(with app: AppState) {
        let config = app.diskMonitor.config
        self.isEnabled = config.globalHotkeyEnabled
        self.currentPreset = config.globalHotkeyPreset

        self.onTrigger = { [weak app] in
            DispatchQueue.main.async {
                guard let app else { return }
                QuickCleanPanelController.shared.toggle(with: app)
            }
        }

        if isEnabled {
            register(preset: config.globalHotkeyPreset)
        }
    }

    /// 设置自定义触发回调（主要供测试或直接调用）
    func setTriggerHandler(_ handler: @escaping () -> Void) {
        self.onTrigger = handler
    }

    /// 注册指定的全局热键
    @discardableResult
    func register(preset: GlobalHotkeyPreset) -> Bool {
        // 先注销原有热键
        unregister()

        installCarbonHandlerIfNeeded()

        let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: hotKeyIDValue)
        var ref: EventHotKeyRef?

        let status = RegisterEventHotKey(
            preset.carbonKeyCode,
            preset.carbonModifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &ref
        )

        if status == noErr, let ref = ref {
            self.hotKeyRef = ref
            self.currentPreset = preset
            self.isEnabled = true
            return true
        } else {
            return false
        }
    }

    /// 注销当前全局热键
    func unregister() {
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
            hotKeyRef = nil
        }
    }

    /// 切换热键使能状态
    func setEnabled(_ enabled: Bool, preset: GlobalHotkeyPreset? = nil) {
        self.isEnabled = enabled
        if enabled {
            let targetPreset = preset ?? currentPreset ?? .controlOptionSpace
            register(preset: targetPreset)
        } else {
            unregister()
        }
    }

    /// 安装 Carbon 事件分发监听器
    private func installCarbonHandlerIfNeeded() {
        guard !isHandlerInstalled else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerBlock: EventHandlerUPP = { _, inEvent, _ -> OSStatus in
            guard let inEvent = inEvent else { return noErr }

            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                inEvent,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            if status == noErr, hotKeyID.signature == GlobalHotkeyManager.shared.hotKeySignature {
                GlobalHotkeyManager.shared.dispatchTrigger()
                return noErr
            }
            return noErr
        }

        let status = InstallEventHandler(
            GetEventDispatcherTarget(),
            handlerBlock,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        if status == noErr {
            isHandlerInstalled = true
        }
    }

    /// 触发回调
    func dispatchTrigger() {
        DispatchQueue.main.async { [weak self] in
            self?.onTrigger?()
        }
    }

    var activePreset: GlobalHotkeyPreset? {
        return hotKeyRef != nil ? currentPreset : nil
    }

    var isRegistered: Bool {
        return hotKeyRef != nil
    }
}
