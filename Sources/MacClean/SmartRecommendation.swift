import Foundation

// MARK: - 推荐等级

/// 推荐清理等级划分
enum RecommendationTier: String, Codable, Comparable, CaseIterable {
    /// 强烈推荐：高价值、极高安全度、长期闲置的无损数据
    case high
    /// 建议清理：常规安全项，适度闲置
    case medium
    /// 普通清理：较新缓存或小体积项，可由用户自主决定
    case low
    /// 需确认 / 暂不推荐：需用户仔细确认或属于使用中/不建议删除
    case manual

    var title: String {
        switch self {
        case .high: return "强烈推荐"
        case .medium: return "建议清理"
        case .low: return "普通清理"
        case .manual: return "需确认"
        }
    }

    /// 排序权重（高优先级在前）
    private var sortOrder: Int {
        switch self {
        case .high: return 4
        case .medium: return 3
        case .low: return 2
        case .manual: return 1
        }
    }

    static func < (lhs: RecommendationTier, rhs: RecommendationTier) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }
}

// MARK: - 打分结果

/// 推荐清理打分明细
struct RecommendationScore: Equatable {
    /// 综合得分 (0.0 ~ 100.0)
    let totalScore: Double
    /// 评定等级
    let tier: RecommendationTier
    /// 推荐理由摘要
    let summary: String
    /// 分项得分 (safety: 0~45, idle: 0~30, roi: 0~25)
    let factors: FactorBreakdown

    struct FactorBreakdown: Equatable {
        let safety: Double
        let idle: Double
        let roi: Double
    }
}

// MARK: - 智能推荐打分引擎

/// 负责根据项目本质、占用状态和空间收益进行多维加权打分
enum RecommendationScorer {
    /// 对清理项进行综合打分
    static func score(item: CleanItem) -> RecommendationScore {
        let rec = item.recommendation

        // 硬边界 1: 凡是判定为 keep (勿删) 或 inUse (使用中)，得分直接归零，标记为 manual
        guard rec.kind != .keep && rec.kind != .inUse && !item.use.ownerIsRunning && !item.use.isBeingWrittenNow else {
            let reason = rec.kind == .keep ? "系统或关键数据，不建议删除" : "关联应用正在运行或正在写入"
            return RecommendationScore(
                totalScore: 0.0,
                tier: .manual,
                summary: reason,
                factors: .init(safety: 0, idle: 0, roi: 0)
            )
        }

        // 1. 安全与本质权重 (Safety Factor: 0 ~ 45 分)
        let safetyScore: Double
        if rec.kind == .safe {
            switch item.nature {
            case .losslessCache, .staleArtifact:
                safetyScore = 45.0
            case .rebuildable:
                safetyScore = 36.0
            default:
                safetyScore = 32.0
            }
        } else {
            // review (需确认) 项给保底分，但无法达到高推荐分
            switch item.nature {
            case .orphanedResidue:
                safetyScore = 20.0
            case .redownloadable:
                safetyScore = 15.0
            case .inferredUnused:
                safetyScore = 12.0
            case .userData:
                safetyScore = 5.0
            default:
                safetyScore = 8.0
            }
        }

        // 2. 闲置度与时间衰减 (Idle Factor: 0 ~ 30 分)
        let idleScore: Double
        let idleDays = calculateDaysAgo(from: item.use.lastUsed)

        if let days = idleDays {
            if days >= 90 {
                idleScore = 30.0
            } else if days >= 30 {
                idleScore = 24.0 + Double(days - 30) / 60.0 * 6.0
            } else if days >= 7 {
                idleScore = 16.0 + Double(days - 7) / 23.0 * 8.0
            } else if days >= 1 {
                idleScore = 6.0 + Double(days - 1) / 6.0 * 8.0
            } else {
                idleScore = 2.0
            }
        } else {
            // 未能取得准确最后使用时间，根据使用级别推断
            switch item.use.level {
            case .dormant:
                idleScore = 26.0
            case .occasional:
                idleScore = 16.0
            case .recent:
                idleScore = 6.0
            case .active:
                idleScore = 1.0
            case .unknown:
                idleScore = 14.0
            }
        }

        // 3. 空间释放收益 (ROI Factor: 0 ~ 25 分)
        let roiScore: Double
        let bytes = item.size
        if bytes >= 5 * 1024 * 1024 * 1024 { // >= 5 GB
            roiScore = 25.0
        } else if bytes >= 1024 * 1024 * 1024 { // 1 GB ~ 5 GB
            let ratio = Double(bytes - 1024 * 1024 * 1024) / Double(4 * 1024 * 1024 * 1024)
            roiScore = 20.0 + ratio * 5.0
        } else if bytes >= 100 * 1024 * 1024 { // 100 MB ~ 1 GB
            let ratio = Double(bytes - 100 * 1024 * 1024) / Double(924 * 1024 * 1024)
            roiScore = 15.0 + ratio * 5.0
        } else if bytes >= 10 * 1024 * 1024 { // 10 MB ~ 100 MB
            let ratio = Double(bytes - 10 * 1024 * 1024) / Double(90 * 1024 * 1024)
            roiScore = 10.0 + ratio * 5.0
        } else if bytes >= 1024 * 1024 { // 1 MB ~ 10 MB
            roiScore = 5.0
        } else {
            roiScore = 1.5
        }

        let total = min(100.0, max(0.0, safetyScore + idleScore + roiScore))

        // 评定等级
        let tier: RecommendationTier
        if rec.kind == .safe && total >= 72.0 {
            tier = .high
        } else if rec.kind == .safe && total >= 48.0 {
            tier = .medium
        } else if rec.kind == .safe {
            tier = .low
        } else {
            tier = .manual
        }

        let summary: String
        switch tier {
        case .high:
            summary = "强烈推荐：高收益无损数据，已长期闲置"
        case .medium:
            summary = "建议清理：安全可释放空间"
        case .low:
            summary = "普通清理：近期产生或占用较小"
        case .manual:
            summary = rec.reason
        }

        return RecommendationScore(
            totalScore: total,
            tier: tier,
            summary: summary,
            factors: .init(safety: safetyScore, idle: idleScore, roi: roiScore)
        )
    }

    private static func calculateDaysAgo(from date: Date?) -> Int? {
        guard let date = date else { return nil }
        let diff = Date().timeIntervalSince(date)
        return max(0, Int(diff / 86400))
    }
}

// MARK: - CleanItem 扩展

extension CleanItem {
    /// 该清理项的智能推荐评分
    var recommendationScore: RecommendationScore {
        RecommendationScorer.score(item: self)
    }
}
