import SwiftUI

// MARK: - 多语言瘦身视图组件 (v1.60.0)

/// 应用多语言列表项
struct LocalizationAppRow: View {
    let bundle: AppLocalizationBundle
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Space.sm) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: bundle.appPath))
                .resizable()
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(bundle.appName)
                    .font(isSelected ? Typo.rowStrong : Typo.row)
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)

                HStack(spacing: Space.xs) {
                    if let block = bundle.blockReason {
                        // 整株阻断：只给定位与建议，不给删除名额
                        Text(block)
                            .font(.mcNumeric(10))
                            .foregroundStyle(Signal.caution)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("\(bundle.totalPackCount) 语言包")
                            .font(.mcNumeric(10))
                            .foregroundStyle(Ink.tertiary)

                        Text("·")
                            .font(.mcNumeric(10))
                            .foregroundStyle(Ink.quaternary)

                        Text("最多可省 \(bundle.totalReclaimablePotential.byteStringCN)")
                            .font(.mcNumeric(10, weight: .semibold))
                            .foregroundStyle(Signal.positive)
                    }
                }
                .lineLimit(1)
            }

            Spacer(minLength: Space.xxs)
        }
        .padding(.horizontal, Space.sm)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .selectionHighlight(isSelected)
        .rowHover()
    }
}

/// 语言包单行展示组件
struct LanguagePackRow: View {
    let item: LanguagePackItem
    let onToggle: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Space.sm) {
            if item.isProtected {
                Image(systemName: "lock.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(Signal.positive)
                    .frame(width: 18)
            } else {
                Button(action: { onToggle(!item.isSelected) }) {
                    Image(systemName: item.isSelected ? "checkmark.square.fill" : "square")
                        .font(.system(size: 14))
                        .foregroundStyle(item.isSelected ? Accent.tint : Ink.tertiary)
                }
                .buttonStyle(.plain)
                .frame(width: 18)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: Space.xs) {
                    Text(item.displayName)
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)

                    if item.isProtected {
                        Text("已保留")
                            .font(Typo.micro)
                            .foregroundStyle(Signal.positive)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Signal.positive.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    } else {
                        // 可删项必须自带代价说明：本模块不提供"顺手一键瘦身"
                        Text("破坏签名")
                            .font(Typo.micro)
                            .foregroundStyle(Signal.caution)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Signal.caution.opacity(0.14))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
                }

                if let reason = item.protectionReason {
                    Text(reason)
                        .font(Typo.caption)
                        .foregroundStyle(Signal.positive)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text(item.deletionRisk)
                        .font(Typo.caption)
                        .foregroundStyle(Signal.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text(item.path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Ink.quaternary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Space.sm)

            Text(item.size.byteStringCN)
                .font(.mcNumeric(12, weight: .medium))
                .foregroundStyle(item.isProtected ? Ink.tertiary : Ink.primary)
        }
        .padding(.vertical, 4)
    }
}

/// 模块级风险横幅：多语言瘦身页面顶部常驻，说清"这里删的是签名过的东西"。
struct LocalizationRiskBanner: View {
    /// 本轮扫描不完整时的补充说明（"权限不足 / 读不到"），nil = 本轮结论完整
    var banner: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            HStack(spacing: Space.xs) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Signal.caution)
                Text(AppLocalizationBundle.moduleRiskText)
                    .font(Typo.caption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let banner {
                HStack(spacing: Space.xs) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(Signal.caution)
                    Text(banner)
                        .font(Typo.caption)
                        .foregroundStyle(Signal.caution)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text("所有语言包默认不勾选：请逐项确认后再清理。母语、Base 与运行中的 App 已由工具强制保留。")
                .font(Typo.caption)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Space.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Surface.sunken)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .accessibilityIdentifier("localization-risk-banner")
    }
}
