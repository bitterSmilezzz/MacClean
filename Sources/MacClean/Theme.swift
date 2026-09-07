import SwiftUI

// MARK: - Apple Design Tokens & macOS HIG System Tokens

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: alpha)
    }
}

enum Theme {
    // Brand & Accent (Apple HIG 原生标准强调色)
    static let actionBlue = Color(hex: 0x0071e3)          // macOS 系统级交互蓝
    static let focusBlue = Color(hex: 0x0071e3)           // 聚焦框色
    static let skyLinkBlue = Color(hex: 0x2997ff)         // 链接蓝

    // Surfaces
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let parchment = Color(nsColor: .windowBackgroundColor)
    static let pearl = Color(nsColor: .controlBackgroundColor)
    static let pureBlack = Color(hex: 0x000000)

    // Text & Labels (原生语义支持浅/深色自适应)
    static let ink = Color(nsColor: .labelColor)
    static let bodyMuted = Color(nsColor: .secondaryLabelColor)
    static let inkMuted80 = Color(nsColor: .labelColor).opacity(0.8)
    static let inkMuted48 = Color(nsColor: .secondaryLabelColor)

    // Hairlines & Separators
    static let dividerSoft = Color(nsColor: .separatorColor).opacity(0.4)
    static let hairline = Color(nsColor: .separatorColor)

    // Risk accents (macOS HIG 系统级语义色)
    static let dangerRed = Color(nsColor: .systemRed)
    static let warningOrange = Color(nsColor: .systemOrange)
    static let textDanger = Color(nsColor: .systemRed)
    static let textWarning = Color(nsColor: .systemOrange)
    static let successGreen = Color(nsColor: .systemGreen)

    // Typography helpers (严格对齐 Apple SF Pro 原生规范)
    static func displayFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func bodyFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func monoFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // Radii (macOS 原生克制圆角：采用标准 6/10/12px)
    static let radiusSm: CGFloat = 6
    static let radiusMd: CGFloat = 10
    static let radiusLg: CGFloat = 12
    static let radiusPill: CGFloat = 9999

    // Spacing (macOS 桌面级紧凑间距)
    static let spaceXs: CGFloat = 8
    static let spaceSm: CGFloat = 12
    static let spaceMd: CGFloat = 16
    static let spaceLg: CGFloat = 20
    static let spaceXl: CGFloat = 28

    // HIG 标准内容边距
    static let contentPadding: CGFloat = 20

    // MARK: - Adaptive Semantic Colors (macOS 13+)
    static let windowBackground = Color(nsColor: .windowBackgroundColor)
    static let controlBackground = Color(nsColor: .controlBackgroundColor)
    static let secondaryControlBackground = Color(nsColor: .controlColor)
    static let labelPrimary = Color(nsColor: .labelColor)
    static let labelSecondary = Color(nsColor: .secondaryLabelColor)
    static let labelTertiary = Color(nsColor: .tertiaryLabelColor)
    static let separator = Color(nsColor: .separatorColor)
}

// MARK: - macOS HIG 原生容器与修饰符（取代 AI 塑料感 ModernCard）

/// macOS 原生分组容器（对齐系统设置、Xcode 分组框质感：纯净底色 + 极细单像素边框 + 极其克制的 1px 微阴影）
struct MacCardModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    var cornerRadius: CGFloat = Theme.radiusMd
    var isHovered: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color(nsColor: .controlBackgroundColor).opacity(0.65)
                            : Color(nsColor: .controlBackgroundColor)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(
                        Color(nsColor: .separatorColor).opacity(colorScheme == .dark ? 0.45 : 0.65),
                        lineWidth: 0.8
                    )
            )
            .shadow(
                color: Color.black.opacity(colorScheme == .dark ? 0.18 : (isHovered ? 0.05 : 0.02)),
                radius: isHovered ? 2 : 1,
                x: 0,
                y: 1
            )
    }
}

/// macOS 标准工具栏/底栏背景（摒弃浮夸的 Web 弥散模糊，回归 macOS 原生半透平整质感）
struct MacBarModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                Rectangle()
                    .fill(
                        colorScheme == .dark
                            ? Color(nsColor: .windowBackgroundColor).opacity(0.92)
                            : Color(nsColor: .windowBackgroundColor).opacity(0.96)
                    )
            )
    }
}

/// macOS 原生行悬停交互
struct MacRowHoverModifier: ViewModifier {
    @State private var isHovered = false
    var cornerRadius: CGFloat = Theme.radiusSm

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.045) : Color.clear)
            )
            .onHover { hovering in
                isHovered = hovering
            }
    }
}

/// 保持 API 兼容的软标签修饰符
struct SoftTagModifier: ViewModifier {
    var bg: Color
    var fg: Color
    var radius: CGFloat = Theme.radiusSm

    func body(content: Content) -> some View {
        content
            .font(Theme.monoFont(11, weight: .medium))
            .foregroundColor(fg)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(bg.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(fg.opacity(0.2), lineWidth: 0.5)
            )
    }
}

extension View {
    /// 原生 macOS 卡片容器（纯正系统控件底色 + 1px 细微边框）
    func macCard(cornerRadius: CGFloat = Theme.radiusMd, isHovered: Bool = false) -> some View {
        modifier(MacCardModifier(cornerRadius: cornerRadius, isHovered: isHovered))
    }

    /// 兼容已有 modernCard 调用的桥接方法，内部全面重构为原生 MacCard
    func modernCard(cornerRadius: CGFloat = Theme.radiusMd, isHovered: Bool = false) -> some View {
        modifier(MacCardModifier(cornerRadius: cornerRadius, isHovered: isHovered))
    }

    /// 原生 macOS 栏修饰符
    func frostedBar() -> some View {
        modifier(MacBarModifier())
    }

    /// 行悬停微光效果
    func macRowHover(cornerRadius: CGFloat = Theme.radiusSm) -> some View {
        modifier(MacRowHoverModifier(cornerRadius: cornerRadius))
    }

    /// 原生标签徽章
    func softTag(bg: Color, fg: Color, radius: CGFloat = Theme.radiusSm) -> some View {
        modifier(SoftTagModifier(bg: bg, fg: fg, radius: radius))
    }

    /// 原生系统 Toast HUD 浮层提示
    func hudToast(isPresented: Binding<Bool>, text: String, icon: String = "checkmark.circle.fill", color: Color = Theme.actionBlue) -> some View {
        modifier(HudToastModifier(isPresented: isPresented, text: text, icon: icon, color: color))
    }
}

/// 原生 Toast HUD 浮层
struct HudToastModifier: ViewModifier {
    @Binding var isPresented: Bool
    let text: String
    var icon: String = "checkmark.circle.fill"
    var color: Color = Theme.actionBlue

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content

            if isPresented {
                HStack(spacing: 8) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(color)
                    Text(text)
                        .font(Theme.bodyFont(13, weight: .medium))
                        .foregroundColor(Theme.labelPrimary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(Color(nsColor: .windowBackgroundColor))
                        .overlay(
                            Capsule()
                                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 0.8)
                        )
                        .shadow(color: Color.black.opacity(0.12), radius: 8, x: 0, y: 3)
                )
                .padding(.bottom, 20)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .zIndex(99)
            }
        }
    }
}
