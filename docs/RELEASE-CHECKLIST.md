# MacClean 发版前自检清单（P5 发布规范）

> 每次发版前逐项打勾。本机无 Xcode/CI，靠清单保证质量。

## 0. 构建环境（无 Xcode 的纯 CLT 环境必读）
- [ ] **必须指定 `SDKROOT=MacOSX26.5.sdk`**（见下方说明），否则构建必失败
- [ ] `xcode-select -p` 指向 `/Library/Developer/CommandLineTools`

### ⚠️ 已知问题：SDK 27.0 + CLT 无法编译 SwiftUI `@State`

**现象**：`swift build` 报
```
error: external macro implementation type 'SwiftUIMacros.StateMacro'
could not be found for macro 'State()'; plugin for module 'SwiftUIMacros' not found
```
错误出现在 `UninstallerView.swift` 等**任何使用 `@State` 的文件**，与业务改动无关。

**根因**：macOS 26.x 起 SwiftUI 把 `@State` 等属性包装器实现为**宏**，宏插件
`SwiftUIMacros` **随 Xcode 提供，CommandLineTools 中不含**（CLT 的宏插件目录只有
`libObservationMacros.dylib` 与 `libSwiftMacros.dylib`）。SDK 27.0 的 SwiftUI 接口
引用了该宏，于是纯 CLT 环境编译失败。`/Applications/Xcode.app` 已不存在
（仅残留 `com.apple.pkg.Xcode` 安装回执），故无法回退到 Xcode 工具链。

**验证方法**（5 行最小复现，可确认与本项目代码无关）：
```bash
cat > /tmp/probe.swift <<'EOF'
import SwiftUI
struct ProbeView: View {
    @State private var value = 0
    var body: some View { Text("probe") }
}
EOF
swiftc -typecheck /tmp/probe.swift   # 同样报 SwiftUIMacros 错误
```

**当前对策**：用旧 SDK 构建，已实测可完整通过自检：
```bash
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk swift build
```
`scripts/build-app.sh` 会自动检测：未安装 Xcode 且存在 `MacOSX26.5.sdk` 时，自己导出
`SDKROOT` 后再调用 `swift build`，无需手工传环境变量。

> **踩过的坑**：脚本里原本写的是 `echo "==> Release 构建${SDKROOT:+（SDKROOT=$SDKROOT）}"`，
> 在 `set -u` 下必然报 `SDKROOT?: unbound variable` 并中止。原因是变量引用后面紧跟了一个
> 多字节字符（`）`），bash 会把该字符的首字节并进变量名去查找。
> **结论：`$VAR` 后面只要紧跟中文/全角字符，一律写成 `${VAR}`。** 已修复。

**根治方案**（任选其一）：
1. 安装完整 Xcode（提供 `SwiftUIMacros` 插件）；
2. 或等待 Apple 在 CLT 中补齐 SwiftUI 宏插件。

## 1. 代码与测试
- [ ] `swift build` 无 error **且无 warning**（历史遗留的 4 条 warning 已清零：Scanner 的两处
      死代码、AIReviewState 的两处捕获语义不一致——不要再引入新的）
- [ ] `.build/debug/MacClean --selftest` 全过（退出码 0，当前 115 项）
- [ ] `.build/debug/MacClean --scan` 冒烟（扫描不崩溃、结果合理）
- [ ] 改动涉及 UI 时：`--selftest` 中视图用例已覆盖或手动确认，并对照 `docs/DESIGN.md`
      检查是否引入了新的"AI 仪表盘"痕迹（图标彩色底板 / 卡片套卡片 / 多强调色 / emoji 文案）
- [ ] **改动了并发/共享状态时**：跑一遍 Thread Sanitizer，必须零报告
      ```bash
      swift build --sanitize=thread && swift run --sanitize=thread MacClean --selftest
      ```
      （`scanAll` 会把 6 个分类并发丢进全局队列，共享缓存必须加锁或改快照）
- [ ] **改动了子进程调用时**：确认读管道**先于** `waitUntilExit`。
      macOS 管道缓冲区只有约 64 KB，先 wait 后读会双向死锁
- [ ] **改动了重复文件扫描时**：确认硬链接仍被排除在"可节省空间"之外
      （两条硬链接指向同一 inode 时删一条释放 0 字节）
- [ ] **改动了持久化结构时**：确认新增字段不会让老数据解码失败
      （Swift 合成的 `Codable` **不使用属性默认值**，必须手写 `init(from:)` 或 `decodeIfPresent`）
- [ ] **改动了无人值守路径（DiskMonitor 静默清理 / 定时巡检）时**：确认 ①等待扫描真正结束
      而不是固定延时；②低空间告警仍是边沿触发 + 冷却期，不会每次扫描结束都发一条
- [ ] **改动了常驻轮询（菜单栏 / 定时器）时**：确认后台档位真的比前台慢，
      且"没有动态内容可显示"的模式（如仅图标）**不轮询**
- [ ] **改动了长时间运行的任务时**：确认可取消，且取消不破坏已有结果
- [ ] **改动了带动画的视图时**：一律用 `.motionSafe()` / `.motionSafeTransition()` /
      `.motionSafeNumericTransition()`，不要写裸 `.animation` / `.transition` / `.contentTransition`
      （`Selftest` 会扫源码把关）——这是「减少动态效果」辅助功能的唯一保障
- [ ] **新增大列表视图时**：过滤/分组在 `body` 里算**一次**再向下传，不要写成被反复引用的
      计算属性（实测 548 项时旧写法单帧过滤就花 15.6ms，接近 60fps 全部预算）
- [ ] **改动了清理规则时**：`Selftest` 中的规则一致性用例（条数 / 编号连续 / `ruleRef`）
      必须全过，且 `docs/CLEANUP-RULES.md`、`Rules/CleanupRules.swift`、`Scanner.swift`
      三处同步更新

## 2. 功能冒烟（手动）
- [ ] 6 大分类均可扫描出结果
- [ ] 勾选 → 清理 → 确认弹窗 → 移入废纸篓链路可用
- [ ] App 卸载器：选 App → 关联文件列表 → 移入废纸篓
- [ ] 清理历史有记录、可清空
- [ ] AI 面板：设置（baseURL/Key/模型）→ 连通性测试 → ✨ 提问 → 回答

## 3. 安全护栏
- [ ] 无新增危险路径（对照 CLEANUP-RULES.md G1–G10）
- [ ] 新增"受限放行"时确认：**只放行具体路径/具名模式，未放行整个父目录**（G10）
- [ ] 新增路径判定时**未使用 `standardizingPath`**——其行为依赖路径是否真实存在
      （`/private/var/db` 存在则被改成 `/var/db`，虚构路径则不变），
      会使同一目录出现两种形态导致判定失效。改用 `FileSystem.normalizePath`
- [ ] API Key 不落盘、不进日志、不进 git（只写系统钥匙串；钥匙串不可用时仅存内存）
      验证：`swift run MacClean --selftest` 中「API Key 存储」套件全过，
      且 `~/Library/Application Support/MacClean/ai.key` 不存在
- [ ] 无 `print` 输出密钥/路径敏感信息

## 4. 分发
- [ ] `./scripts/build-app.sh` 成功（ad-hoc 签名）
- [ ] `ditto -c -k --keepParent` 产物 zip 生成
- [ ] README「安装与首次打开」与实际一致（xattr -cr 指引）
- [ ] Release notes 注明：ad-hoc 未公证、TCC 权限说明、**构建所需 SDKROOT**

## 5. 发布
- [ ] git 工作区干净，main 已推送
- [ ] tag 命名 `vX.Y.Z`，annotated
- [ ] `gh release create` 附件 zip + 完整 notes
- [ ] `gh release view` 确认非 draft、资产齐全
