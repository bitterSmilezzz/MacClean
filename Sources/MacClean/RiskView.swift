import SwiftUI

/// 电脑风险提醒页：检查敏感数据泄露 / 网络暴露 / 系统安全 / 启动项等风险
/// 与文件清理并列的第二功能模块：只读检查，不做删除
struct RiskView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)

            // 风险扫描错误横幅
            if let err = app.riskLastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.textDanger)
                    Text(err)
                        .font(Theme.bodyFont(14, weight: .medium))
                        .foregroundColor(Theme.textDanger)
                    Spacer()
                    Button("重试") { app.scanRisks() }
                        .buttonStyle(.borderless)
                        .font(Theme.bodyFont(14, weight: .medium))
                        .foregroundColor(Theme.actionBlue)
                }
                .padding(.horizontal, Theme.contentPadding)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.dangerRed.opacity(0.06))
            }

            if app.isRiskScanning {
                scanningView
            } else if !app.riskScanned {
                introView
            } else if app.riskItems.isEmpty {
                allClearView
            } else {
                riskList
            }
        }
        .background(Theme.parchment)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Theme.spaceMd) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(Theme.textWarning)
                .frame(width: 44, height: 44)
                .background(RoundedRectangle(cornerRadius: Theme.radiusMd).fill(Theme.warningOrange.opacity(0.1)))

            VStack(alignment: .leading, spacing: 2) {
                Text("电脑风险提醒")
                    .font(Theme.displayFont(28, weight: .semibold))
                    .tracking(-0.3)
                    .foregroundColor(Theme.ink)
                Text("检查敏感数据泄露、网络暴露、系统安全与可疑启动项 · 只读检测，不删除任何文件")
                    .font(Theme.bodyFont(12))
                    .foregroundColor(Theme.inkMuted48)
            }
            Spacer()

            if app.riskScanned && !app.riskItems.isEmpty {
                HStack(spacing: 6) {
                    Text("\(app.riskCounts[.high, default: 0]) 高")
                        .font(Theme.monoFont(13, weight: .semibold))
                        .foregroundColor(Theme.textDanger)
                    Text("· \(app.riskCounts[.medium, default: 0]) 中")
                        .font(Theme.monoFont(13, weight: .semibold))
                        .foregroundColor(Theme.textWarning)
                    Text("· \(app.riskCounts[.low, default: 0]) 低")
                        .font(Theme.monoFont(13, weight: .semibold))
                        .foregroundColor(Theme.inkMuted48)
                }
            }

            Button {
                app.scanRisks()
            } label: {
                Label(app.riskScanned ? "重新检查" : "开始检查", systemImage: "stethoscope")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(Theme.textWarning)
            .accessibilityIdentifier("riskScanButton")
            .disabled(app.isRiskScanning)
        }
        .padding(.horizontal, Theme.contentPadding)
        .padding(.vertical, Theme.spaceMd)
        .background(Theme.canvas)
    }

    // MARK: - 状态视图

    private var scanningView: some View {
        VStack(spacing: Theme.spaceMd) {
            ProgressView()
                .controlSize(.large)
                .tint(Theme.textWarning)
            Text("正在检查风险项…")
                .font(Theme.bodyFont(14))
                .foregroundColor(Theme.inkMuted48)
            Text("只读检测：SSH 权限 / 明文密钥 / 防火墙 / FileVault / 启动项等")
                .font(Theme.bodyFont(12))
                .foregroundColor(Theme.inkMuted48.opacity(0.8))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var introView: some View {
        VStack(spacing: Theme.spaceMd) {
            Image(systemName: "exclamationmark.shield")
                .font(.system(size: 42, weight: .light))
                .foregroundColor(Theme.inkMuted48.opacity(0.6))
            Text("电脑风险提醒")
                .font(Theme.displayFont(24, weight: .semibold))
                .foregroundColor(Theme.ink)
            Text("检查可能泄露敏感数据的风险项：SSH 私钥权限、明文密钥环境变量、\n防火墙与磁盘加密状态、可疑启动项等。全程只读，不删除任何文件。")
                .font(Theme.bodyFont(13))
                .foregroundColor(Theme.inkMuted48)
                .multilineTextAlignment(.center)
            Button {
                app.scanRisks()
            } label: {
                Label("开始风险检查", systemImage: "stethoscope")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.textWarning)
            .padding(.top, Theme.spaceXs)
            .accessibilityIdentifier("riskStartButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var allClearView: some View {
        VStack(spacing: Theme.spaceSm) {
            Image(systemName: "checkmark.shield")
                .font(.system(size: 40, weight: .light))
                .foregroundColor(Theme.actionBlue.opacity(0.8))
            Text("未发现风险项")
                .font(Theme.displayFont(24, weight: .semibold))
                .foregroundColor(Theme.ink)
            Text("敏感数据、网络暴露、系统安全与启动项检查全部通过")
                .font(Theme.bodyFont(13))
                .foregroundColor(Theme.inkMuted48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 风险列表（按严重度分组）

    private var riskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.spaceLg) {
                ForEach([RiskSeverity.high, .medium, .low], id: \.self) { severity in
                    let group = app.riskItems.filter { $0.severity == severity }
                    if !group.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.spaceSm) {
                            // 分组标题（eyebrow 模式）
                            HStack(spacing: 8) {
                                Circle()
                                    .fill(severityColor(severity))
                                    .frame(width: 8, height: 8)
                                Text("\(severity.label)（\(group.count) 项）")
                                    .font(Theme.bodyFont(12, weight: .semibold))
                                    .tracking(1.2)
                                    .foregroundColor(Theme.inkMuted80)
                                Spacer()
                            }
                            .padding(.horizontal, 2)

                            ForEach(group) { item in
                                RiskRow(item: item)
                            }
                        }
                    }
                }
            }
            .padding(Theme.spaceLg)
        }
        .background(Theme.parchment)
    }

    private func severityColor(_ severity: RiskSeverity) -> Color {
        switch severity {
        case .high: return Theme.dangerRed
        case .medium: return Theme.warningOrange
        case .low: return Theme.hairline
        }
    }
}

// MARK: - 单条风险行

struct RiskRow: View {
    let item: RiskItem
    @State private var isExpanded = false

    private var color: Color {
        switch item.severity {
        case .high: return Theme.textDanger
        case .medium: return Theme.textWarning
        case .low: return Theme.inkMuted48
        }
    }

    private var bg: Color {
        switch item.severity {
        case .high: return Theme.dangerRed
        case .medium: return Theme.warningOrange
        case .low: return Theme.hairline
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Theme.spaceSm) {
                Image(systemName: iconName)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(color)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(bg.opacity(0.12)))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.title)
                            .font(Theme.bodyFont(15, weight: .semibold))
                            .foregroundColor(Theme.ink)
                            .lineLimit(1)
                        Text(item.severity.label)
                            .font(Theme.bodyFont(11, weight: .semibold))
                            .foregroundColor(color)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(bg.opacity(0.12)))
                    }
                    Text(item.category.label)
                        .font(Theme.bodyFont(11))
                        .foregroundColor(Theme.inkMuted48)
                    if isExpanded {
                        Text(item.detail)
                            .font(Theme.bodyFont(13))
                            .foregroundColor(Theme.inkMuted80)
                            .padding(.top, 4)
                            .textSelection(.enabled)
                        // 修复建议
                        HStack(alignment: .top, spacing: 6) {
                            Image(systemName: "lightbulb")
                                .font(.system(size: 11))
                                .foregroundColor(Theme.textWarning)
                            Text(item.suggestion)
                                .font(Theme.bodyFont(13, weight: .medium))
                                .foregroundColor(Theme.inkMuted80)
                        }
                        .padding(.top, 6)
                        if let path = item.path {
                            Text(path)
                                .font(Theme.monoFont(11))
                                .foregroundColor(Theme.inkMuted48)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        }
                    }
                }
                Spacer()

                Button {
                    withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Theme.inkMuted48)
                        .frame(width: 22, height: 22)
                        .background(Circle().fill(Theme.parchment))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "收起详情" : "查看详情与建议")
            }
            .padding(.horizontal, Theme.spaceMd)
            .padding(.vertical, Theme.spaceSm)
        }
        .background(
            RoundedRectangle(cornerRadius: Theme.radiusMd)
                .fill(Theme.canvas)
        )
    }

    private var iconName: String {
        switch item.category {
        case .sensitiveData: return "lock.shield"
        case .networkExposure: return "network"
        case .systemSecurity: return "gearshield"
        case .startupItems: return "terminal"
        }
    }
}
