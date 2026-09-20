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
                    Text("\(bundle.totalPackCount) 语言包")
                        .font(.mcNumeric(10))
                        .foregroundStyle(Ink.tertiary)

                    Text("·")
                        .font(.mcNumeric(10))
                        .foregroundStyle(Ink.quaternary)

                    Text("可省 \(bundle.totalReclaimablePotential.byteStringCN)")
                        .font(.mcNumeric(10, weight: .semibold))
                        .foregroundStyle(Signal.positive)
                }
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
        HStack(spacing: Space.sm) {
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
                        Text("系统保留")
                            .font(Typo.micro)
                            .foregroundStyle(Signal.positive)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Signal.positive.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
                    }
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
