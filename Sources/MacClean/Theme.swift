import SwiftUI

// MARK: - Apple Design Tokens (from awesome-design-md/apple/DESIGN.md)

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
    // Brand & Accent
    static let actionBlue = Color(hex: 0x0066cc)          // primary — 唯一交互色
    static let focusBlue = Color(hex: 0x0071e3)           // focus ring
    static let skyLinkBlue = Color(hex: 0x2997ff)         // dark surface 上的链接蓝

    // Surfaces
    static let canvas = Color(hex: 0xffffff)
    static let parchment = Color(hex: 0xf5f5f7)           // 标志性 Apple 米白
    static let pearl = Color(hex: 0xfafafc)
    static let tile1 = Color(hex: 0x272729)
    static let tile2 = Color(hex: 0x2a2a2c)
    static let tile3 = Color(hex: 0x252527)
    static let pureBlack = Color(hex: 0x000000)

    // Text
    static let ink = Color(hex: 0x1d1d1f)
    static let bodyMuted = Color(hex: 0xcccccc)
    static let inkMuted80 = Color(hex: 0x333333)
    // M7（WCAG AA）：#7a7a7a 白底仅 4.3:1 → 加深至 #6f6f6f（≈4.6:1）
    static let inkMuted48 = Color(hex: 0x6f6f6f)

    // Hairlines
    static let dividerSoft = Color(hex: 0xf0f0f0)
    static let hairline = Color(hex: 0xe0e0e0)

    // Risk accents (system red/orange for danger semantics)
    static let dangerRed = Color(hex: 0xff3b30)
    static let warningOrange = Color(hex: 0xff9500)
    // M7：风险色用于文字时用深色变体（#ff3b30 白底 3.5:1 / #ff9500 2.2:1 均不达标）
    static let textDanger = Color(hex: 0xd70015)      // ≈5.9:1
    static let textWarning = Color(hex: 0xb25000)     // ≈4.6:1

    // Typography helpers
    static func displayFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    static func bodyFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }
    // Vercel 借鉴：路径/数字/标签用 monospace，开发者工具质感
    static func monoFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // Radii
    static let radiusSm: CGFloat = 8
    static let radiusMd: CGFloat = 12
    static let radiusLg: CGFloat = 18
    static let radiusPill: CGFloat = 9999

    // Spacing（2026-09-04 精修：放大一档，缓解全局密度过高）
    static let spaceXs: CGFloat = 12
    static let spaceSm: CGFloat = 16
    static let spaceMd: CGFloat = 20
    static let spaceLg: CGFloat = 28
    static let spaceXl: CGFloat = 36

    // HIG 标准内容边距（macOS 原生窗口内容距边缘）
    static let contentPadding: CGFloat = 24
}
