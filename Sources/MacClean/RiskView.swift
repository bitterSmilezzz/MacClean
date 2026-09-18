import SwiftUI

/// 电脑风险提醒页：检查敏感数据泄露 / 网络暴露 / 系统安全 / 启动项等风险
/// 与文件清理并列的第二功能模块：只读检查，不做删除
///
/// 重写要点：
///  - 表头去掉「44pt 图标 + 橙色圆角底板 + 26pt 大标题 + 装饰性副标题」，只留一个
///    `Typo.title` 标题；右侧依次是实时的高/中/低计数（语义色在这里是有含义的）和检查按钮。
///  - 三个空状态改用 `EmptyState`；只有"开始检查"那个必须自己搭——因为
///    `riskStartButton` 这个 accessibilityIdentifier 必须留在 `Button` 上，`EmptyState` 内部
///    的按钮无法挂载标识符。
///  - 每个严重度分组的"描边浮空卡片"改成 `GroupBox` inset group，行分隔交给 `GroupedRow`。
///  - `RiskRow` 去掉图标彩色底板与严重度胶囊：图标直接进 `IconSlot`，严重度用彩色文字表达，
///    展开箭头换成带按压反馈的 `IconSlot` 尺寸。
struct RiskView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            header
            Hairline()

            // 风险扫描错误横幅
            if let err = app.riskLastError {
                errorBanner(err)
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
        .background(Surface.window)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: Space.sm) {
            Text("电脑风险提醒")
                .font(Typo.title)
                .foregroundStyle(Ink.primary)

            Spacer(minLength: Space.md)

            if app.riskScanned && !app.riskItems.isEmpty {
                HStack(spacing: Space.sm) {
                    severityCount(app.riskCounts[.high, default: 0], label: "高", color: Signal.critical)
                    severityCount(app.riskCounts[.medium, default: 0], label: "中", color: Signal.caution)
                    severityCount(app.riskCounts[.low, default: 0], label: "低", color: Ink.tertiary)
                }
                .padding(.trailing, Space.xxs)
            }

            Button {
                app.scanRisks()
            } label: {
                Label(app.riskScanned ? "重新检查" : "开始检查", systemImage: "stethoscope")
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .accessibilityIdentifier("riskScanButton")
            .disabled(app.isRiskScanning)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.sm)
        .barSurface()
    }

    /// 高/中/低计数：数字等宽，颜色承载严重度含义。
    private func severityCount(_ count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 3) {
            Text("\(count)")
                .font(.mcNumeric(12, weight: .semibold))
                .motionSafeNumericTransition()
            Text(label)
                .font(Typo.caption)
        }
        .foregroundStyle(color)
    }

    private func errorBanner(_ err: String) -> some View {
        HStack(spacing: Space.xs) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Typo.caption)
                .foregroundStyle(Signal.critical)
            Text(err)
                .font(Typo.row)
                .foregroundStyle(Signal.critical)
            Spacer(minLength: Space.sm)
            Button("重试") { app.scanRisks() }
                .pressable()
                .font(Typo.rowStrong)
                .foregroundStyle(Accent.tint)
        }
        .padding(.horizontal, Space.gutter)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Signal.critical.opacity(0.08))
    }

    // MARK: - 状态视图

    private var scanningView: some View {
        VStack(spacing: Space.sm) {
            ProgressView()
                .controlSize(.large)
            Text("正在检查风险项…")
                .font(Typo.row)
                .foregroundStyle(Ink.secondary)
            Text("只读检测：SSH 权限 / 明文密钥 / 防火墙 / FileVault / 启动项等")
                .font(Typo.caption)
                .foregroundStyle(Ink.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// 说明部分交给 `EmptyState` 原语；动作按钮单独放在下面——`riskStartButton`
    /// 这个 accessibilityIdentifier 必须留在 `Button` 上，无法挂到 `EmptyState` 内部的按钮。
    private var introView: some View {
        VStack(spacing: 0) {
            EmptyState(
                icon: "exclamationmark.shield",
                title: "电脑风险提醒",
                message: "检查可能泄露敏感数据的风险项：SSH 私钥权限、明文密钥环境变量、防火墙与磁盘加密状态、可疑启动项等。全程只读，不删除任何文件。"
            )

            Button {
                app.scanRisks()
            } label: {
                Label("开始风险检查", systemImage: "stethoscope")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .accessibilityIdentifier("riskStartButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var allClearView: some View {
        EmptyState(
            icon: "checkmark.shield",
            title: "未发现风险项",
            message: "敏感数据、网络暴露、系统安全与启动项检查全部通过"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 风险列表（按严重度分组）

    private var riskList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Space.lg) {
                ForEach([RiskSeverity.high, .medium, .low], id: \.self) { severity in
                    let group = app.riskItems.filter { $0.severity == severity }
                    if !group.isEmpty {
                        // 严重度含义写在分组标题文字里，不再额外点一颗彩色圆点
                        GroupBox(title: "\(severity.label)（\(group.count) 项）") {
                            ForEach(Array(group.enumerated()), id: \.element.id) { index, item in
                                GroupedRow(isLast: index == group.count - 1) {
                                    RiskRow(item: item)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, Space.gutter)
            .padding(.vertical, Space.md)
        }
        .background(Surface.window)
    }
}

// MARK: - 单条风险行

struct RiskRow: View {
    let item: RiskItem
    @State private var isExpanded = false

    private var color: Color {
        switch item.severity {
        case .high: return Signal.critical
        case .medium: return Signal.caution
        case .low: return Ink.secondary
        }
    }

    var body: some View {
        HStack(spacing: Space.sm) {
            IconSlot(systemName: iconName, size: 13, color: color, width: 18)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(item.title)
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)
                        .lineLimit(1)
                    Text(item.severity.label)
                        .font(Typo.caption)
                        .foregroundStyle(color)
                }
                Text(item.category.label)
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                if isExpanded {
                    Text(item.detail)
                        .font(Typo.caption)
                        .foregroundStyle(Ink.secondary)
                        .padding(.top, Space.xxs)
                        .textSelection(.enabled)
                    // 修复建议
                    HStack(alignment: .top, spacing: Space.xxs) {
                        IconSlot(systemName: "lightbulb", size: 11, color: Signal.caution, width: 14)
                        Text(item.suggestion)
                            .font(Typo.caption)
                            .foregroundStyle(Ink.secondary)
                    }
                    .padding(.top, Space.xxs)
                    if let path = item.path {
                        Text(path)
                            .font(Typo.caption)
                            .foregroundStyle(Ink.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .padding(.top, 2)
                    }
                }
            }
            Spacer(minLength: Space.sm)

            Button {
                withAnimation(Motion.micro) { isExpanded.toggle() }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(Typo.micro)
                    .foregroundStyle(Ink.tertiary)
                    .frame(width: 20, height: 20)
                    .contentShape(Rectangle())
            }
            .pressable()
            .accessibilityLabel(isExpanded ? "收起详情" : "查看详情与建议")
        }
        .padding(.horizontal, Space.xxs)
        .rowHover()
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
