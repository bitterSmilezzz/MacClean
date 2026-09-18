import SwiftUI

// MARK: - MacClean 设计系统
//
// 早期版本是一套"AI 仪表盘"风格：每个图标都坐在彩色圆角方块里、每个区块都是描边+阴影的浮
// 空卡片、六个分类各配一种彩虹色、行标题下永远挂一句装饰性副标题、正文里散落 emoji。
// 这套视觉语言来自 SaaS 落地页，不是 macOS。
//
// 重写后的四条硬规则：
//
//   1. 单一强调色。全 App 只有 `Accent.tint` 一个品牌色（默认跟随系统强调色）。
//      分类身份靠 SF Symbol + 文字表达，不靠颜色——六个分类不再有六种颜色。
//   2. 语义色只表达语义。红/橙/绿只出现在风险等级、错误、成功这些真正有含义的地方，
//      绝不用于装饰。
//   3. 结构靠层级和留白，不靠卡片。容器用系统 inset-group 的做法：一块中性底色 +
//      发丝分隔线，没有描边、没有投影。投影只留给真正浮起的层（抽屉、Toast、弹窗）。
//   4. 字号来自固定语义阶梯（见 `Text`），不再逐处硬编码 11/12/13pt。数字一律等宽。

// MARK: - 色彩

/// 文本色阶。四档，够用且不会退化成"到处都是次级灰"。
enum Ink {
    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)
    static let quaternary = Color(nsColor: .quaternaryLabelColor)
}

/// 表面色阶。来自 AppKit 语义色，自动适配浅色/深色与"增强对比度"辅助功能。
enum Surface {
    /// 窗口底色
    static let window = Color(nsColor: .windowBackgroundColor)
    /// inset group 容器底色（靠明度差分层，不靠描边）
    static let group = Color(nsColor: .controlBackgroundColor)
    /// 需要比 group 再高一层时使用（输入框、代码块）
    static let raised = Color(nsColor: .textBackgroundColor)
    /// 凹陷区域（轨道底槽、表头）
    static let sunken = Color(nsColor: .underPageBackgroundColor)
    /// 发丝分隔线
    static let hairline = Color(nsColor: .separatorColor)

    /// "空 / 未占用"色块（Treemap 里的可用空间）。
    ///
    /// 刻意做成**不透明**并随浅色/深色自适应：半透明色块的实际呈现色会随底下背景漂移，
    /// 让"压在上面的文字该用深色还是浅色"无法判定，最终出现白字压浅灰这种不可读的组合。
    static let emptyTile = Color(nsColor: NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return isDark ? NSColor(white: 0.26, alpha: 1) : NSColor(white: 0.90, alpha: 1)
    })
}

/// 强调色。全 App 唯一，默认跟随用户在"系统设置 → 外观"里选的强调色。
enum Accent {
    static let tint = Color.accentColor
    /// 选中态/轻填充背景
    static let soft = Color.accentColor.opacity(0.14)
    static let softer = Color.accentColor.opacity(0.08)
}

/// 语义信号色。**只**用于风险、错误、成功。
enum Signal {
    static let critical = Color(nsColor: .systemRed)
    static let caution = Color(nsColor: .systemOrange)
    static let positive = Color(nsColor: .systemGreen)
    /// "正常/无需注意"。用于风险分级里的最高频档（可安全清理），避免满屏着色。
    static let neutral = Color(nsColor: .tertiaryLabelColor)

    /// 处置结论 → 信号色。
    ///
    /// - `.safe`（可清理）走中性而非绿色：可清理项是常态，不该满屏绿；
    /// - `.inUse`（使用中）用强调色：这是"信息，不是警告"——正在用的东西删了会重建/需重下，
    ///   但并不是危险；
    /// - `.review`（需确认）谨慎色；`.keep`（勿删）红。
    ///
    /// 参数是 `Recommendation.Kind` 而不是旧的 `RiskLevel`：颜色只跟随那**唯一**的结论，
    /// 不再有第二条独立的等级轴可以与之打架。
    static func tint(for kind: Recommendation.Kind) -> Color {
        switch kind {
        case .safe: return Ink.secondary
        case .inUse: return Accent.tint
        case .review: return caution
        case .keep: return critical
        }
    }
}

/// 分类图表色板。
///
/// **只用于数据可视化**（Treemap、历史趋势、清理结果分布）——在这些地方区分序列是有信息量
/// 的。绝不用作图标底板、卡片底色这类装饰用途：那正是"AI 仪表盘"的典型做法。
///
/// 六个色相在 HSL 上均匀铺开，但统一压到同一明度/低饱和度，使整组读起来像一套设计过的
/// 色板而非系统默认色的堆砌。
enum ChartPalette {
    static let series: [Color] = [
        Color(hex: 0x3D7FD4),   // 蓝
        Color(hex: 0x2DA893),   // 青
        Color(hex: 0x6A9E4F),   // 绿
        Color(hex: 0xD9924A),   // 琥珀
        Color(hex: 0xC96A6A),   // 陶红
        Color(hex: 0x8F76C9),   // 靛紫
    ]

    static func color(at index: Int) -> Color {
        series[((index % series.count) + series.count) % series.count]
    }
}

extension CleanCategory {
    /// 分类的图表序列色。**仅**用于数据可视化（Treemap、趋势图、结果分布）。
    ///
    /// 放在 Theme 而不是 Models：颜色是**表现层**概念，领域模型不该知道它。
    /// 早期版本这里是六个系统色（蓝/橙/靛/紫/青/绿），既当图表色又当图标底板与
    /// 卡片装饰色——那是最典型的"AI 仪表盘"指纹，装饰性着色已全部移除。
    var chartColor: Color {
        ChartPalette.color(at: CleanCategory.allCases.firstIndex(of: self) ?? 0)
    }
}

/// Treemap / 旭日图的语义色块。
///
/// 这些颜色比 `ChartPalette` 更进一步：它们**必须不透明**，因为色块上要叠文字，
/// 而文字用深色还是浅色由色块亮度决定（见 `Color.readableForeground`）。
enum TilePalette {
    /// 重复与相似文件：浪费掉的空间，用暖信号色
    static let duplicates = ChartPalette.color(at: 4)
    /// 系统与在用数据：中性灰阶，靠 `shade` 分父子层
    static let system = Color(nsColor: .systemGray)
    /// 残差桶（"其他 N 个项目"）
    static let residual = Color(nsColor: .systemGray).shade(0.8)
}

// MARK: - 字号阶梯

/// 语义字号。每一档都有明确使用场景，新代码不要绕过它直接写 `.system(size:)`。
///
/// 注意：类型名不能叫 `Text`——那会遮蔽 SwiftUI 的 `Text` 视图，导致所有 `Text("...")` 构造失败。
enum Typo {
    /// 一屏一个的大数字（可清理总量、磁盘已用）
    static let hero = Font.system(size: 34, weight: .semibold)
    /// 次级指标数字
    static let metric = Font.system(size: 17, weight: .semibold)
    /// 视图标题
    static let title = Font.system(size: 15, weight: .semibold)
    /// 分组标题（句首大写，不用 tracking 撑开）
    static let section = Font.system(size: 11, weight: .semibold)
    /// 列表行主文本
    static let row = Font.system(size: 13, weight: .regular)
    /// 列表行主文本（需要强调时）
    static let rowStrong = Font.system(size: 13, weight: .medium)
    /// 正文
    static let body = Font.system(size: 13, weight: .regular)
    /// 说明、时间戳、次要元数据
    static let caption = Font.system(size: 11, weight: .regular)
    /// 徽标、极小标注
    static let micro = Font.system(size: 10, weight: .medium)
}

extension Font {
    /// 等宽数字：避免数值刷新时宽度跳动。
    static func mcNumeric(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight).monospacedDigit()
    }
}

// MARK: - 间距与圆角

enum Space {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let sm: CGFloat = 12
    static let md: CGFloat = 16
    static let lg: CGFloat = 24
    static let xl: CGFloat = 32

    /// 内容区左右边距
    static let gutter: CGFloat = 20
}

enum Radius {
    /// 内层小元素（徽标、缩略图）
    static let inner: CGFloat = 5
    /// 行、控件
    static let control: CGFloat = 7
    /// 分组容器
    static let group: CGFloat = 10
    /// 浮层（抽屉、面板）
    static let overlay: CGFloat = 12
}

// MARK: - 动效

enum Motion {
    /// 状态切换、展开收起
    static let standard = Animation.spring(response: 0.32, dampingFraction: 0.86)
    /// 悬停、按压等微交互
    static let micro = Animation.easeOut(duration: 0.12)
    /// 数值滚动、进度推进
    static let value = Animation.easeOut(duration: 0.45)

    /// 开启「减少动态效果」时使用的替代动画。
    ///
    /// 不是"关掉动画"（那会让状态切换显得突兀、反而更难理解），而是换成极短的淡入：
    /// 保留"发生了变化"的视觉提示，去掉位移、缩放与弹簧这类前庭刺激。
    static let reducedDuration: TimeInterval = 0.01
    static let reduced = Animation.easeOut(duration: reducedDuration)
}

// MARK: - 尊重「减少动态效果」

private struct MotionSafeAnimationModifier<V: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let animation: Animation
    let value: V

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? Motion.reduced : animation, value: value)
    }
}

private struct MotionSafeNumericTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        // 数字翻页在开启减少动态效果时退化为直接替换
        content.contentTransition(reduceMotion ? .identity : .numericText())
    }
}

extension View {
    /// 与 `.animation(_:value:)` 等价，但在系统开启「减少动态效果」时自动降级。
    ///
    /// 项目此前**完全没有适配 Reduce Motion** —— 全 App 遍布弹簧、缩放、位移与数字翻页，
    /// 对前庭功能敏感的用户只能忍着。所有动画调用点都应改用这个。
    func motionSafe<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MotionSafeAnimationModifier(animation: animation, value: value))
    }

    /// 与 `.contentTransition(.numericText())` 等价，但尊重「减少动态效果」。
    func motionSafeNumericTransition() -> some View {
        modifier(MotionSafeNumericTransitionModifier())
    }

    /// 与 `.transition(_:)` 等价，但在「减少动态效果」下降级为纯淡入淡出。
    ///
    /// 位移类转场（`.move(edge:)`、抽屉从右侧滑入）是前庭刺激最强的一类动效，
    /// 也是 Reduce Motion 最该处理的对象。淡入淡出保留了"有新内容出现"的提示，
    /// 又不产生空间位移。
    func motionSafeTransition(_ transition: AnyTransition) -> some View {
        modifier(MotionSafeTransitionModifier(transition: transition))
    }
}

private struct MotionSafeTransitionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let transition: AnyTransition

    func body(content: Content) -> some View {
        content.transition(reduceMotion ? .opacity : transition)
    }
}

extension Color {
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255.0,
                  green: Double((hex >> 8) & 0xFF) / 255.0,
                  blue: Double(hex & 0xFF) / 255.0,
                  opacity: alpha)
    }

    /// sRGB 感知亮度（0…1）。
    ///
    /// 动态色（`Color(nsColor:)` 里的语义色、`Surface.emptyTile` 这类自适应色）必须显式指定
    /// 外观再解析——否则解析结果取决于解析那一刻的 `NSAppearance.current`，同一份视图在
    /// 浅色/深色下可能拿到同一个亮度，判定随之失效。
    func perceivedLuminance(for scheme: ColorScheme) -> Double {
        let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        var value = 0.0
        appearance?.performAsCurrentDrawingAppearance {
            guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return }
            value = 0.2126 * Double(ns.redComponent)
                + 0.7152 * Double(ns.greenComponent)
                + 0.0722 * Double(ns.blueComponent)
        }
        return value
    }

    /// 在这个颜色上可读的前景色。用于把文字压在不透明的彩色色块上（Treemap / 旭日图）。
    ///
    /// 前提是底层色块**不透明**——半透明色块的实际呈现色会随底下背景漂移，判定没有意义。
    /// 阈值 0.6 是经验值：再低会让琥珀/浅绿这类中间亮度色块上的白字开始糊。
    func readableForeground(for scheme: ColorScheme) -> Color {
        perceivedLuminance(for: scheme) > 0.6 ? Color.black.opacity(0.88) : Color.white
    }

    /// 同色相下的亮度变体。用于在同一分支内区分父子节点。
    ///
    /// 刻意不用 `.opacity()` 来做层次：半透明会毁掉色块上文字的可读性判定。
    /// `factor < 1` 变暗，`> 1` 变亮，`1` 原样返回，结果始终不透明。
    func shade(_ factor: Double) -> Color {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return self }
        let f = min(max(factor, 0), 2)
        func adjust(_ c: CGFloat) -> CGFloat {
            f <= 1 ? c * CGFloat(f) : c + (1 - c) * CGFloat(f - 1)
        }
        return Color(.sRGB,
                     red: Double(adjust(ns.redComponent)),
                     green: Double(adjust(ns.greenComponent)),
                     blue: Double(adjust(ns.blueComponent)),
                     opacity: 1)
    }
}

// MARK: - 容器：Inset Group
//
// macOS 系统设置 / 访达的做法：一整块中性底色容器，内部行与行之间用发丝线分隔。
// 没有描边、没有投影。这是替代"每块内容一张浮空卡片"的核心原语。

/// 分组容器。
struct GroupBox<Content: View>: View {
    var title: String?
    var footer: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.xs) {
            if let title {
                Text(title)
                    .font(Typo.section)
                    .foregroundStyle(Ink.secondary)
                    .padding(.leading, Space.xxs)
            }

            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .background(
                RoundedRectangle(cornerRadius: Radius.group, style: .continuous)
                    .fill(Surface.group)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Radius.group, style: .continuous)
                    .strokeBorder(Surface.hairline.opacity(0.5), lineWidth: 0.5)
            )

            if let footer {
                Text(footer)
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .padding(.leading, Space.xxs)
                    .padding(.top, 2)
            }
        }
    }
}

/// 分组内的一行。`isLast` 为 true 时不画底部分隔线。
struct GroupedRow<Content: View>: View {
    var isLast: Bool = false
    var padding: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, Space.sm)
                .padding(.vertical, padding)
                .frame(maxWidth: .infinity, alignment: .leading)

            if !isLast {
                Rectangle()
                    .fill(Surface.hairline.opacity(0.45))
                    .frame(height: 0.5)
                    .padding(.leading, Space.sm)
            }
        }
    }
}

// MARK: - 图标
//
// 旧代码到处是「SF Symbol 坐进彩色圆角方块」。macOS 原生列表不这么做——
// 图标就是图标，靠对齐和层级说话。

struct IconSlot: View {
    let systemName: String
    var size: CGFloat = 14
    var weight: Font.Weight = .regular
    var color: Color = Ink.secondary
    var width: CGFloat = 20

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: weight))
            .foregroundStyle(color)
            .frame(width: width, alignment: .center)
    }
}

// MARK: - 数值与容量

/// 磁盘容量条。横向分段条比大圆环更省空间、更易读，也是 macOS 存储面板的做法。
struct CapacityBar: View {
    /// 已用比例 0...1
    let used: Double
    /// 其中"可清理"占全盘的比例（可选，叠加显示）
    var reclaimable: Double = 0
    var height: CGFloat = 8
    var isCritical: Bool = false

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(Surface.hairline.opacity(0.35))

                RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                    .fill(isCritical ? Signal.critical : Accent.tint)
                    .frame(width: max(height, w * min(max(used, 0), 1)))

                if reclaimable > 0 {
                    RoundedRectangle(cornerRadius: height / 2, style: .continuous)
                        .fill(Signal.positive)
                        .frame(width: max(height, w * min(reclaimable, used)))
                }
            }
        }
        .frame(height: height)
        .motionSafe(Motion.value, value: used)
        .motionSafe(Motion.value, value: reclaimable)
    }
}

/// 图例项：小色点 + 标签 + 右对齐等宽数值。
struct LegendItem: View {
    var color: Color
    var label: String
    var value: String
    var emphasized: Bool = false

    var body: some View {
        HStack(spacing: Space.xs) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(label)
                .font(Typo.caption)
                .foregroundStyle(Ink.secondary)
            Spacer(minLength: Space.sm)
            Text(value)
                .font(.mcNumeric(12, weight: emphasized ? .semibold : .regular))
                .foregroundStyle(emphasized ? Ink.primary : Ink.secondary)
        }
    }
}

// MARK: - 行与列表

/// 行悬停高亮。不做缩放/位移——列表行不该"跳"。
struct RowHoverModifier: ViewModifier {
    var cornerRadius: CGFloat = Radius.control
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
            )
            .onHover { hovering in
                withAnimation(Motion.micro) { isHovered = hovering }
            }
    }
}

/// 选中态高亮。
struct SelectionBackground: ViewModifier {
    var isSelected: Bool
    var cornerRadius: CGFloat = Radius.control

    func body(content: Content) -> some View {
        content.background(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(isSelected ? Accent.soft : Color.clear)
        )
    }
}

/// 按压反馈。macOS 原生按钮的动作主要是"变暗"。
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
            .motionSafe(Motion.micro, value: configuration.isPressed)
    }
}

/// 空状态。比"什么都不显示"多一句解释和一条出路。
struct EmptyState: View {
    var icon: String
    var title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: Space.sm) {
            Image(systemName: icon)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Ink.quaternary)
            Text(title)
                .font(Typo.rowStrong)
                .foregroundStyle(Ink.secondary)
            if let message {
                Text(message)
                    .font(Typo.caption)
                    .foregroundStyle(Ink.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .padding(.top, Space.xxs)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Space.xl)
    }
}

// MARK: - 分隔线

/// 发丝线。统一用一个组件，避免各处 `Divider().overlay(...)` 写法不一致。
struct Hairline: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Surface.hairline.opacity(0.5))
            .frame(height: 0.5)
            .padding(.leading, inset)
    }
}

// MARK: - 行内动作

/// 列表行内的图标动作按钮。
///
/// 默认**没有底色**，只在悬停时浮出一层淡淡的圆角高亮。早期版本给每个行内图标都常驻一个
/// 灰底圆角方块，一行里并排三个，视觉噪音远大于它提供的可发现性收益。
struct RowActionButton: View {
    let systemName: String
    var identifier: String? = nil
    var accessibilityText: String? = nil
    var help: String? = nil
    var tint: Color = Ink.tertiary
    /// 常驻强调（例如已展开的折叠箭头）
    var isActive: Bool = false
    var isDisabled: Bool = false
    var size: CGFloat = 12
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(tint)
                .frame(width: 22, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: Radius.inner, style: .continuous)
                        .fill(
                            isHovered ? Color.primary.opacity(0.09)
                                : (isActive ? tint.opacity(0.12) : Color.clear)
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovering in
            withAnimation(Motion.micro) { isHovered = hovering }
        }
        .accessibilityIdentifier(identifier ?? "")
        .accessibilityLabel(accessibilityText ?? "")
        .help(help ?? "")
    }
}

// MARK: - 输入控件

/// 搜索框。统一外观，避免每处自己拼 `TextField` + 背景。
struct SearchField: View {
    var placeholder: String
    @Binding var text: String
    var width: CGFloat? = nil

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Ink.tertiary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(Typo.row)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Ink.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, Space.xs)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Surface.sunken)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Surface.hairline.opacity(0.6), lineWidth: 0.5)
        )
        .frame(width: width)
    }
}

// MARK: - 修饰符
//
// 迁移期的一批旧名字（macCard / modernCard / softTag / macRowHover / macPressable /
// mcSelection / frostedBar / hudToast）随旧令牌层一起下线了——`Theme.*` 已经全项目清零，
// 留着就是死代码。现在只保留真正在用的这几个，名字统一不带历史前缀。

struct BarSurfaceModifier: ViewModifier {
    func body(content: Content) -> some View {
        content.background(.bar)
    }
}

extension View {
    /// 工具栏/底栏材质
    func barSurface() -> some View {
        modifier(BarSurfaceModifier())
    }

    /// 行悬停高亮。`cornerRadius: 0` 用于铺满整行的数据行。
    func rowHover(cornerRadius: CGFloat = Radius.control) -> some View {
        modifier(RowHoverModifier(cornerRadius: cornerRadius))
    }

    /// 选中态高亮
    func selectionHighlight(_ isSelected: Bool, cornerRadius: CGFloat = Radius.control) -> some View {
        modifier(SelectionBackground(isSelected: isSelected, cornerRadius: cornerRadius))
    }

    /// 按压反馈
    func pressable() -> some View {
        buttonStyle(PressableStyle())
    }

    /// 浮层 Toast
    func toast(isPresented: Binding<Bool>, text: String, icon: String = "checkmark.circle.fill", color: Color = Accent.tint) -> some View {
        modifier(ToastModifier(isPresented: isPresented, text: text, icon: icon, color: color))
    }
}

/// Toast。浮层，是少数该有投影的地方。
struct ToastModifier: ViewModifier {
    @Binding var isPresented: Bool
    let text: String
    var icon: String = "checkmark.circle.fill"
    var color: Color = Accent.tint

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content

            if isPresented {
                HStack(spacing: Space.xs) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(color)
                    Text(text)
                        .font(Typo.rowStrong)
                        .foregroundStyle(Ink.primary)
                }
                .padding(.horizontal, Space.sm)
                .padding(.vertical, Space.xs)
                .background(
                    Capsule()
                        .fill(.regularMaterial)
                        .overlay(Capsule().strokeBorder(Surface.hairline.opacity(0.5), lineWidth: 0.5))
                        .shadow(color: .black.opacity(0.16), radius: 12, y: 4)
                )
                .padding(.bottom, Space.lg)
                .motionSafeTransition(.move(edge: .bottom).combined(with: .opacity))
                .motionSafe(Motion.standard, value: isPresented)
                .zIndex(99)
            }
        }
    }
}
