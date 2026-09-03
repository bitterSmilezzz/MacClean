# MacClean — Mac 原生系统清理软件

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS_13+-lightgrey.svg)](https://developer.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-6.3-orange.svg)](https://www.swift.org)

> 把"让 AI 清理 Mac"的规则**固化成本地原生 App**：一键扫描、手动勾选、安全清理。
>
> **个人使用项目**：为本机定制，按需维护，欢迎参考与 fork。
> UI 风格参照 OpenViking 上的 Apple 原生设计稿（`awesome-design-md/apple/DESIGN.md`）。

## 功能

- **6 大清理分类**（对应 [CLEANUP-RULES.md](docs/CLEANUP-RULES.md) 的 23 条固化规则）：
  用户缓存 · 日志与临时文件 · 开发残留 · App 残留 · 大文件与垃圾箱 · 浏览器与系统数据
- **App 卸载器**（融合 Pearcleaner/PureMac）：选 App → 扫描全部关联文件（Preferences/Caches/Containers/Application Support/Logs/LaunchAgents）→ 移废纸篓
- **清理历史**（融合 Mole `mo history`）：记录每次清理的时间/分类/大小/模式，可追溯
- **安全优先**：扫描只读 → 手动勾选 → 二次确认 → 默认移入废纸篓（可恢复）
- **风险分级**：安全（可重建）/ 谨慎（需人眼确认）/ 危险（不可恢复）
- **误删防护**：硬排除白名单（Mail/Keychains/Accounts/Messages/.ssh 等）、跳过运行中应用、bundle-id 前缀与中英文别名识别已安装 App
- **Apple 原生 UI**：SF Pro 字体、Action Blue #0066cc 单一强调色、parchment 米白画布、pill 胶囊按钮、18px 卡片圆角、零阴影零渐变

功能融合来源见 [docs/FUSION-PLAN.md](docs/FUSION-PLAN.md)。

## 构建与运行

本机无 Xcode，使用 SwiftPM + CommandLineTools 构建，手工组装 .app：

```bash
# 进程内 UI 自检（ViewInspector 驱动，零窗口零打断，退出码 0=全过）
swift build
.build/debug/MacClean --selftest

# 无头扫描测试（打印本机可清理项）
.build/debug/MacClean --scan

# 打包完整 .app（自动生成图标 + ad-hoc 签名）
./scripts/build-app.sh
open dist/MacClean.app
```

## 测试策略（零打断方案）

本机无 Xcode/XCTest 框架，采用 **ViewInspector 进程内自检**（`Sources/MacClean/Selftest.swift`）：

- 视图测试在**内存中驱动**（`inspect().find(...).tap()`），不渲染窗口、不抢焦点
- 按钮通过 `accessibilityIdentifier` 定位（label 含 Image 时文本查找不可靠）
- 状态用 `@Binding` 注入而非 `@State`（ViewInspector 在 macOS 上不传播 `@State` 变更）
- 覆盖：格式化、路径展开、安全护栏、勾选逻辑、Cleaner 双模式、风险徽标、弹窗默认/切换/警告、空态禁用态

## 目录结构

```
MacClean/
├── docs/CLEANUP-RULES.md        # 固化规则集合（规则源头，与代码同步维护）
├── scripts/build-app.sh         # .app 打包脚本
├── scripts/make-icon.swift      # 程序化生成 Apple 风格图标
└── Sources/MacClean/
    ├── MacCleanApp.swift        # 入口（--selftest / --scan 无头模式）
    ├── Selftest.swift           # ViewInspector 进程内自检（13 用例）
    ├── CleanPaths.swift         # 路径规则常量
    ├── Scanner.swift            # 6 类扫描引擎（只读）
    ├── Cleaner.swift            # 清理执行（废纸篓/彻底删除）
    ├── FileSystem.swift         # 目录大小/枚举/安全护栏
    ├── AppState.swift           # 全局状态
    └── *.swift                  # Theme / Models / 视图
```

## 规则来源

1. 本机 agent 会话扫描（~/.agents、~/.claude、~/.dimcode 会话记录）——未发现现成"Mac 清理"技能，清理经验散见于代码治理会话与《全机安全审计报告》（Lemon 残留、Parallels keychain、rtk 钩子等卸载残留案例）；
2. 通用 macOS 清理实践（缓存/日志/DerivedData/包管理器缓存/浏览器数据/大文件）。

## 安全设计（CLEANUP-RULES.md G1–G7）

| 护栏 | 说明 |
|---|---|
| G1 | 只扫用户可写目录，权限不足跳过 |
| G2 | 手动勾选 + 二次确认 |
| G3 | 默认移入废纸篓 |
| G4 | 三档风险标记 |
| G5 | 跳过运行中应用 |
| G6 | 硬排除白名单 |
| G7 | 空目录兜底 |
