import Foundation
import SwiftUI
import IOKit

// MARK: - 电池与电源状态监控服务

public final class BatteryMonitor: ObservableObject {
    public static let shared = BatteryMonitor()

    @Published public var info: BatteryInfo = .desktop
    @Published public var isUpdating: Bool = false

    private var timer: Timer?

    public init() {
        refresh()
    }

    /// 立即刷新电池与电源数据
    public func refresh() {
        isUpdating = true
        let newInfo = Self.readCurrentBatteryInfo()
        DispatchQueue.main.async {
            self.info = newInfo
            self.isUpdating = false
        }
    }

    /// 从系统 IOKit 注册表读取真实硬件数据
    public static func readCurrentBatteryInfo() -> BatteryInfo {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else {
            return .desktop
        }
        defer { IOObjectRelease(service) }

        var props: Unmanaged<CFMutableDictionary>?
        let ret = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
        guard ret == KERN_SUCCESS, let dict = props?.takeRetainedValue() as? [String: Any] else {
            return .desktop
        }

        return parseBatteryDictionary(dict)
    }

    /// 解析 IOKit 字典并构造标准 BatteryInfo 模型（支持单元测试解耦）
    public static func parseBatteryDictionary(_ dict: [String: Any]) -> BatteryInfo {
        let installed = (dict["BatteryInstalled"] as? Bool) ?? ((dict["BatteryInstalled"] as? String)?.lowercased() == "yes")
        guard installed else {
            return .desktop
        }

        let designCap = (dict["DesignCapacity"] as? NSNumber)?.intValue ?? 5000
        let rawMax = (dict["AppleRawMaxCapacity"] as? NSNumber)?.intValue
            ?? (dict["NominalChargeCapacity"] as? NSNumber)?.intValue
            ?? designCap
        let rawCur = (dict["AppleRawCurrentCapacity"] as? NSNumber)?.intValue
            ?? (dict["CurrentCapacity"] as? NSNumber)?.intValue
            ?? rawMax
        let curPercent = (dict["CurrentCapacity"] as? NSNumber)?.intValue ?? 100
        let cycles = (dict["CycleCount"] as? NSNumber)?.intValue ?? 0

        // 计算健康度百分比
        let health: Double
        if designCap > 0 {
            let ratio = Double(rawMax) / Double(designCap) * 100.0
            health = min(100.0, max(0.0, ratio))
        } else {
            health = 100.0
        }

        // 状态评级
        let condition: BatteryCondition
        if health >= 80.0 {
            condition = .normal
        } else if health >= 70.0 {
            condition = .fair
        } else {
            condition = .serviceRecommended
        }

        // 摄氏温度解析
        var tempC: Double? = nil
        if let rawTemp = (dict["Temperature"] as? NSNumber)?.doubleValue, rawTemp > 0 {
            if rawTemp > 1000 {
                tempC = rawTemp / 100.0
            } else if rawTemp > 100 {
                tempC = rawTemp / 10.0
            } else {
                tempC = rawTemp
            }
        }

        let voltage = (dict["Voltage"] as? NSNumber)?.intValue ?? 12000
        let amperage = (dict["Amperage"] as? NSNumber)?.intValue ?? 0

        let isCharging = (dict["IsCharging"] as? Bool) ?? ((dict["IsCharging"] as? String)?.lowercased() == "yes")
        let isPluggedIn = (dict["ExternalConnected"] as? Bool) ?? ((dict["ExternalConnected"] as? String)?.lowercased() == "yes")
        let isFull = (dict["FullyCharged"] as? Bool) ?? ((dict["FullyCharged"] as? String)?.lowercased() == "yes")

        let timeRem = (dict["TimeRemaining"] as? NSNumber)?.intValue

        return BatteryInfo(
            hasBattery: true,
            currentPercent: curPercent,
            designCapacity: designCap,
            maxCapacity: rawMax,
            currentCapacity: rawCur,
            cycleCount: cycles,
            healthPercent: health,
            temperatureCelsius: tempC,
            voltageMillivolts: voltage,
            amperageMilliamp: amperage,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            isFullyCharged: isFull,
            timeRemainingMinutes: timeRem,
            condition: condition
        )
    }
}
