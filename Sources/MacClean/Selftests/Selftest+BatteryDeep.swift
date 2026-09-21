import Foundation
import SwiftUI
import ViewInspector

// MARK: - 自检套件：系统电池健康度与充放电循环深度体检 (v1.59.0)

extension Selftest {
    static func suiteBatteryDeep() {
        print("==> 运行系统电池健康度与充放电循环深度体检自检 (v1.59.0)...")

        check("BatteryInfo 数据模型与功率推导算法 (BatteryModels)") {
            // 1. 放电状态功率计算：12V * 2A = 24W
            let infoDischarging = BatteryInfo(
                hasBattery: true,
                currentPercent: 80,
                designCapacity: 5000,
                maxCapacity: 4500,
                currentCapacity: 3600,
                cycleCount: 120,
                healthPercent: 90.0,
                temperatureCelsius: 32.5,
                voltageMillivolts: 12000,
                amperageMilliamp: -2000,
                isCharging: false,
                isPluggedIn: false,
                isFullyCharged: false,
                timeRemainingMinutes: 108,
                condition: .normal
            )
            guard abs(infoDischarging.wattage - 24.0) < 0.01 else { return false }
            guard infoDischarging.timeRemainingString == "1小时48分" else { return false }

            // 2. 充电状态功率计算：12.5V * 3A = 37.5W
            let infoCharging = BatteryInfo(
                hasBattery: true,
                currentPercent: 50,
                designCapacity: 5000,
                maxCapacity: 4500,
                currentCapacity: 2250,
                cycleCount: 120,
                healthPercent: 90.0,
                temperatureCelsius: 35.0,
                voltageMillivolts: 12500,
                amperageMilliamp: 3000,
                isCharging: true,
                isPluggedIn: true,
                isFullyCharged: false,
                timeRemainingMinutes: 45,
                condition: .normal
            )
            guard abs(infoCharging.wattage - 37.5) < 0.01 else { return false }
            guard infoCharging.timeRemainingString == "45分钟" else { return false }

            return true
        }

        check("电池健康状态评级与色彩语义映射 (BatteryCondition)") {
            // 80%+ 良好 (positive 绿色)
            let c1 = BatteryCondition.normal
            guard c1.rawValue == "良好" else { return false }

            // 70%-79% 轻度损耗 (caution 黄色)
            let c2 = BatteryCondition.fair
            guard c2.rawValue == "轻度损耗" else { return false }

            // <70% 建议维护 (critical 红色)
            let c3 = BatteryCondition.serviceRecommended
            guard c3.rawValue == "建议维护" else { return false }

            // 无电池 (unknown)
            let c4 = BatteryCondition.unknown
            guard c4.rawValue == "未检测到电池" else { return false }

            return true
        }

        check("IOKit 字典解析与硬件遥测转换 (parseBatteryDictionary)") {
            let mockDict: [String: Any] = [
                "BatteryInstalled": true,
                "DesignCapacity": 4629,
                "AppleRawMaxCapacity": 4325,
                "CurrentCapacity": 85,
                "CycleCount": 84,
                "Temperature": 3150, // 31.5°C
                "Voltage": 12366,
                "Amperage": -1500,
                "IsCharging": false,
                "ExternalConnected": false,
                "FullyCharged": false,
                "TimeRemaining": 150
            ]

            let info = BatteryMonitor.parseBatteryDictionary(mockDict)
            guard info.hasBattery == true else { return false }
            guard info.designCapacity == 4629 else { return false }
            guard info.maxCapacity == 4325 else { return false }
            guard info.cycleCount == 84 else { return false }
            guard abs(info.healthPercent - (4325.0 / 4629.0 * 100.0)) < 0.1 else { return false }
            guard info.condition == .normal else { return false }
            guard let temp = info.temperatureCelsius, abs(temp - 31.5) < 0.01 else { return false }
            guard info.voltageMillivolts == 12366 else { return false }
            guard info.amperageMilliamp == -1500 else { return false }
            guard info.isCharging == false else { return false }
            guard info.isPluggedIn == false else { return false }

            return true
        }

        check("桌面设备无电池优雅降级与兜底逻辑 (desktop)") {
            // 模拟桌面 Mac (未安装电池)
            let emptyDict: [String: Any] = [
                "BatteryInstalled": false
            ]
            let infoEmpty = BatteryMonitor.parseBatteryDictionary(emptyDict)
            guard infoEmpty.hasBattery == false else { return false }
            guard infoEmpty.condition == .unknown else { return false }

            let desktopDefault = BatteryInfo.desktop
            guard desktopDefault.hasBattery == false else { return false }
            guard desktopDefault.designCapacity == 0 else { return false }

            return true
        }

        check("真实环境 IOKit 硬件读取安全调用无崩溃 (readCurrentBatteryInfo)") {
            // 在真实机器环境下调用，验证无论当前是 MacBook 还是 Mac mini，都不会崩溃
            let realInfo = BatteryMonitor.readCurrentBatteryInfo()
            if realInfo.hasBattery {
                guard realInfo.designCapacity > 0 else { return false }
                guard realInfo.currentPercent >= 0 && realInfo.currentPercent <= 100 else { return false }
                guard realInfo.healthPercent >= 0.0 && realInfo.healthPercent <= 100.0 else { return false }
            } else {
                guard realInfo.condition == .unknown else { return false }
            }
            return true
        }

        check("ViewInspector 交互自检：BatteryInsightCard 视图渲染") {
            let card = BatteryInsightCard()
            guard let view = try? card.inspect() else { return false }
            guard (try? view.find(text: "电池健康与电源体检")) != nil else { return false }
            return true
        }
    }
}
