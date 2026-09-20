import Foundation
import SwiftUI

// MARK: - 电池健康状态评级

public enum BatteryCondition: String, Codable, CaseIterable, Identifiable {
    case normal = "良好"
    case fair = "轻度损耗"
    case serviceRecommended = "建议维护"
    case unknown = "未检测到电池"

    public var id: String { rawValue }

    public var badgeColor: Color {
        switch self {
        case .normal: return Signal.positive
        case .fair: return Signal.caution
        case .serviceRecommended: return Signal.critical
        case .unknown: return Ink.tertiary
        }
    }
}

// MARK: - 电源类型

public enum PowerSourceKind: String, Codable, CaseIterable, Identifiable {
    case battery = "内置电池供电"
    case acPower = "外接电源充电中"
    case acConnectedFull = "外接电源 (已充满)"
    case desktopAC = "桌面设备 (交流供电)"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .battery: return "battery.75percent"
        case .acPower: return "battery.100.bolt"
        case .acConnectedFull: return "bolt.badge.checkmark.fill"
        case .desktopAC: return "desktopcomputer"
        }
    }
}

// MARK: - 电池综合信息模型

public struct BatteryInfo: Equatable, Codable {
    public let hasBattery: Bool
    public let currentPercent: Int
    public let designCapacity: Int     // mAh
    public let maxCapacity: Int        // mAh
    public let currentCapacity: Int    // mAh
    public let cycleCount: Int
    public let healthPercent: Double   // 0.0 - 100.0%
    public let temperatureCelsius: Double?
    public let voltageMillivolts: Int
    public let amperageMilliamp: Int   // 正为充电，负为放电
    public let isCharging: Bool
    public let isPluggedIn: Bool
    public let isFullyCharged: Bool
    public let timeRemainingMinutes: Int? // 剩余可用/充满分钟数
    public let condition: BatteryCondition

    public init(
        hasBattery: Bool = true,
        currentPercent: Int = 100,
        designCapacity: Int = 5000,
        maxCapacity: Int = 5000,
        currentCapacity: Int = 5000,
        cycleCount: Int = 0,
        healthPercent: Double = 100.0,
        temperatureCelsius: Double? = nil,
        voltageMillivolts: Int = 12000,
        amperageMilliamp: Int = 0,
        isCharging: Bool = false,
        isPluggedIn: Bool = true,
        isFullyCharged: Bool = false,
        timeRemainingMinutes: Int? = nil,
        condition: BatteryCondition = .normal
    ) {
        self.hasBattery = hasBattery
        self.currentPercent = currentPercent
        self.designCapacity = designCapacity
        self.maxCapacity = maxCapacity
        self.currentCapacity = currentCapacity
        self.cycleCount = cycleCount
        self.healthPercent = healthPercent
        self.temperatureCelsius = temperatureCelsius
        self.voltageMillivolts = voltageMillivolts
        self.amperageMilliamp = amperageMilliamp
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
        self.isFullyCharged = isFullyCharged
        self.timeRemainingMinutes = timeRemainingMinutes
        self.condition = condition
    }

    /// 实时充放电功率（瓦特 W）
    public var wattage: Double {
        let v = Double(voltageMillivolts) / 1000.0
        let a = Double(amperageMilliamp) / 1000.0
        return abs(v * a)
    }

    /// 剩余时间格式化（如 "2小时39分"）
    public var timeRemainingString: String? {
        guard let minutes = timeRemainingMinutes, minutes > 0, minutes < 1440 else { return nil }
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 {
            return "\(h)小时\(m)分"
        } else {
            return "\(m)分钟"
        }
    }

    /// 默认无电池配置（桌面台式 Mac）
    public static let desktop = BatteryInfo(
        hasBattery: false,
        currentPercent: 100,
        designCapacity: 0,
        maxCapacity: 0,
        currentCapacity: 0,
        cycleCount: 0,
        healthPercent: 100.0,
        temperatureCelsius: nil,
        voltageMillivolts: 0,
        amperageMilliamp: 0,
        isCharging: false,
        isPluggedIn: true,
        isFullyCharged: true,
        timeRemainingMinutes: nil,
        condition: .unknown
    )
}
