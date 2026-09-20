import Foundation
import SwiftUI

// MARK: - 诊断报告类型

/// 诊断报告与系统转储的类别
public enum DiagnosticReportKind: String, CaseIterable, Codable, Identifiable {
    case crash = "应用崩溃 (Crash)"
    case spinHang = "卡死与无响应 (Spin/Hang)"
    case coreDump = "系统核心转储 (Core Dump)"
    case diagnostics = "聚合与系统诊断 (Diagnostic)"

    public var id: String { rawValue }

    public var iconName: String {
        switch self {
        case .crash: return "exclamationmark.triangle.fill"
        case .spinHang: return "hourglass"
        case .coreDump: return "memorychip.fill"
        case .diagnostics: return "waveform.path.ecg"
        }
    }

    public var badgeColor: Color {
        switch self {
        case .crash: return Signal.critical
        case .spinHang: return Signal.caution
        case .coreDump: return Color.purple
        case .diagnostics: return Accent.tint
        }
    }
}

// MARK: - 单项诊断报告模型

/// 单个崩溃转储或诊断日志明细
public struct DiagnosticReportItem: Identifiable, Equatable, Codable {
    public let id: String
    public let fileName: String
    public let path: String
    public var size: Int64
    public let creationDate: Date
    public let ageDays: Int
    public var appName: String
    public var bundleID: String?
    public var kind: DiagnosticReportKind
    public var exceptionSummary: String?
    public var isOrphan: Bool
    public var isSelected: Bool

    public init(id: String = UUID().uuidString,
                fileName: String,
                path: String,
                size: Int64,
                creationDate: Date = Date(),
                ageDays: Int = 0,
                appName: String,
                bundleID: String? = nil,
                kind: DiagnosticReportKind = .crash,
                exceptionSummary: String? = nil,
                isOrphan: Bool = false,
                isSelected: Bool = false) {
        self.id = id
        self.fileName = fileName
        self.path = path
        self.size = size
        self.creationDate = creationDate
        self.ageDays = ageDays
        self.appName = appName
        self.bundleID = bundleID
        self.kind = kind
        self.exceptionSummary = exceptionSummary
        self.isOrphan = isOrphan
        self.isSelected = isSelected
    }

    /// 是否为 30 天以上的陈旧报告
    public var isStale: Bool {
        ageDays > 30
    }

    /// 是否为 7 天内近期生成的报告（通常建议保留以排查当前问题）
    public var isRecent: Bool {
        ageDays <= 7
    }

    /// 状态徽章文案
    public var statusBadgeText: String {
        if isOrphan {
            return "👻 已卸载孤儿"
        } else if isStale {
            return "🍂 陈旧 (\(ageDays)天)"
        } else if isRecent {
            return "🔥 近期 (\(ageDays)天)"
        } else {
            return "\(ageDays) 天前"
        }
    }

    /// 状态徽章色彩
    public var statusBadgeColor: Color {
        if isOrphan {
            return Color.purple
        } else if isStale {
            return Signal.caution
        } else if isRecent {
            return Accent.tint
        } else {
            return Ink.tertiary
        }
    }
}
