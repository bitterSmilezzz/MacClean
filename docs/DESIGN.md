# MacClean 视觉设计规范

> 这份文档是 `Sources/MacClean/Theme.swift` 的文字说明。改 UI 之前先读它，
> 新增界面元素时优先复用这里列出的原语，不要就地手搓。

## 为什么会有这份文档

项目早期的 UI 是一套典型的 **"AI 仪表盘"** 风格——它并不是随便难看，而是踩中了一组
非常具体、非常好认的模板化痕迹：

| 痕迹 | 早期做法 | 为什么像 AI 生成的 |
| --- | --- | --- |
| 图标彩色底板 | 每个 SF Symbol 都坐进一个 `.opacity(0.14)` 的圆角方块 | 来自 SaaS 落地页的"feature icon chip"，macOS 原生列表不这么做 |
| 彩虹分类色 | 六个分类各配蓝/橙/靛/紫/青/绿 | 使用了不止一个强调色；靛+紫是"AI 渐变"的标志性色相 |
| 卡片套卡片 | 汇总条、磁盘、风险、分类各一张描边+阴影卡片 | 每块内容都浮起来 = 没有层级，只有噪声 |
| 等宽卡片网格 | 分类用两列 `LazyVGrid`，六张一样大的卡片 | 信息密度极低，是模板化仪表盘的默认布局 |
| 装饰性副标题 | 每个导航项下挂一句"磁盘与清理总览" | 不携带信息，只为了让行看起来"饱满" |
| emoji 当图标 | `⚠️ ✅ ✨ 👁️ 📁 🗑️ ⭐️` 直接写进文案和导出文件 | 系统级 App 用 SF Symbols，不用 emoji |
| 字号硬编码 | 满项目 9/10/11/12/13/14/15pt 随机组合 | 没有类型阶梯，只有逐处微调 |

重写后的规则如下。

## 四条硬规则

### 1. 只有一个强调色

全 App 唯一的品牌色是 `Accent.tint`（默认 `Color.accentColor`，跟随用户在系统设置里选的
强调色）。分类身份靠 **SF Symbol + 文字** 表达，不靠颜色。

唯一的例外是 `ChartPalette`——它**只**用于数据可视化（Treemap、趋势图、结果分布）里区分
序列。绝不用作图标底板、卡片底色等装饰用途。

### 2. 语义色只表达语义

`Signal.critical` / `caution` / `positive` 只出现在风险等级、错误、成功这些真正有含义的地方。

特别注意：风险等级 `.safe` 映射到 **中性灰**而不是绿色。可清理项是常态，满屏绿色等于没有
信息量。

### 3. 结构靠层级和留白，不靠卡片

容器用 `GroupBox`：一整块中性底色 + 发丝分隔线，**没有描边、没有投影**。这是 macOS
系统设置/访达的做法。

投影只留给真正浮起的层：抽屉、Toast、弹窗。

### 4. 字号来自固定阶梯

用 `Typo.*`，不要写 `.system(size:)`：

| 令牌 | 字号/字重 | 用途 |
| --- | --- | --- |
| `Typo.hero` | 34 semibold | 一屏一个的大数字 |
| `Typo.metric` | 17 semibold | 次级指标 |
| `Typo.title` | 15 semibold | 视图标题 |
| `Typo.section` | 11 semibold | 分组标题（句首大写） |
| `Typo.rowStrong` | 13 medium | 强调的行文本 |
| `Typo.row` / `Typo.body` | 13 regular | 常规行文本 / 正文 |
| `Typo.caption` | 11 regular | 说明、时间戳、元数据 |
| `Typo.micro` | 10 medium | 徽标、极小标注 |

数字一律用 `.mcNumeric(_:weight:)`（等宽数位），避免刷新时宽度跳动。

## 原语清单

写新 UI 时从这些里挑，不要重新发明：

| 原语 | 用途 |
| --- | --- |
| `GroupBox` | inset group 容器，替代"浮空卡片" |
| `GroupedRow` | 分组内的一行，自带底部分隔线 |
| `IconSlot` | 统一的图标槽位（对齐宽度，无底板） |
| `RowActionButton` | 列表行内的图标动作按钮：默认无底色，悬停才浮出高亮 |
| `CapacityBar` | 磁盘/配额横向分段条 |
| `LegendItem` | 色点 + 标签 + 右对齐等宽数值 |
| `Hairline` | 发丝分隔线 |
| `EmptyState` | 空状态（图标 + 标题 + 说明 + 一个动作） |
| `SearchField` | 统一外观的过滤框 |
| `.rowHover(cornerRadius:)` | 行悬停高亮（`cornerRadius: 0` 用于铺满整行的数据行） |
| `.selectionHighlight(_:)` | 选中态高亮 |
| `.pressable()` | 按压变暗反馈 |
| `.barSurface()` | 工具栏/底栏 `.bar` 材质 |
| `.toast(isPresented:text:...)` | 浮层 Toast |

## 色彩令牌

```
Ink.primary / secondary / tertiary / quaternary     文本四档
Surface.window / group / raised / sunken / hairline 表面五档
Surface.emptyTile                                   "空/未占用"色块（不透明、自适应）
Accent.tint / soft / softer                         强调色三档
Signal.critical / caution / positive / neutral      语义色
ChartPalette.color(at:)                             分类图表色（仅数据可视化）
TilePalette.duplicates / system / residual          Treemap 语义色块（不透明）
```

全部来自 `Color(nsColor:)` 语义色，自动适配浅色/深色与"增强对比度"辅助功能。
不要写死 `Color(hex:)`。唯一允许写死的是 `ChartPalette`。

### 色块上叠文字

Treemap / 旭日图这类"彩色块 + 块上文字"的场景有一条硬约束：**色块必须不透明**。

半透明色块的实际呈现色会随底下背景漂移，于是"这块上面该用黑字还是白字"根本无法判定——
项目里就出过"可用空间"浅灰块配硬编码白字、结果完全看不见的问题。正确做法：

```swift
// 模型：色块用不透明色。层次用 shade()，不要用 opacity()。
color: Surface.emptyTile
color: TilePalette.system.shade(1.2)

// 视图：文字颜色由色块亮度决定，并把外观显式传进去
@Environment(\.colorScheme) private var colorScheme
...
.foregroundStyle(tile.node.color.readableForeground(for: colorScheme))
```

`readableForeground(for:)` 的阈值是 0.6 感知亮度：再低，琥珀/浅绿这类中间亮度色块上的白字就开始糊。
`Selftest` 里有三条用例锁住这个行为（亮度翻转、色块全不透明、`shade()` 单调性）。

## 文案

- 不用 emoji。用 SF Symbols。
- 不用感叹号。成功提示要克制，不要"🎉 太棒了！"。
- 句首大写，不用 Title Case。
- 不用"Oops!"这类卖萌措辞。直接说清楚发生了什么、下一步做什么。
- 装饰性的副标题一律删掉；右侧位置留给真正的实时数据。

## 交互

- 所有可点元素都要有 hover 或按下反馈。
- 过渡用 `Motion.micro`（0.12s）/ `Motion.standard`（弹簧）/ `Motion.value`（数值）。
- 动画只动 `transform` 和 `opacity` 相关的属性，不动布局尺寸。
- 键盘可达：可点区域用 `contentShape(Rectangle())` 补全命中范围。

## 迁移已完成

旧令牌层（`Theme.*`，含 `actionBlue` / `inkMuted48` / `radiusMd` / `bodyFont` 等一整套别名）
和它配套的旧修饰符（`macCard` / `modernCard` / `softTag` / `macRowHover` / `macPressable` /
`mcSelection` / `frostedBar` / `hudToast`）**已全部删除**——`Theme.` 在全项目已清零。

新代码请只用本文件列出的令牌与原语。加回任何别名层之前，先想清楚它解决了什么问题。
