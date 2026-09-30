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
> **2026-10-01 复验更正**：上面那句"已不存在"是**当时**的机器状态，现已过期——
> 本机实测 `/Applications/Xcode.app` **存在**，且 `xcode-select -p` 就指向
> `/Applications/Xcode.app/Contents/Developer`。所以"无法回退到 Xcode 工具链"这个前提已经不成立，
> 但结论仍然成立：**发版门禁必须显式把 `DEVELOPER_DIR` 与 `SDKROOT` 设成同源**
> （见下面 §0.3），因为默认选中的 Xcode 工具链配 CLT 的 SDK 会产出跑不起来的二进制。
> 这一条与下一节曾经互相矛盾（一节说 Xcode 不在、另一节说选择器指向 Xcode），
> 是独立复审 `reviewer-r2` 抓出来的文档级红线：**环境事实必须带日期，否则会变成假的"根因"**。

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

**当前对策**：用旧 SDK 构建。**注意：SDK 26.5 只解决"能否编译"，不解决"自检能否跑完"**
——两者是不同的问题，见下面 §0.2。
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

### ⚠️ 只钉 `SDKROOT` 不够：`DEVELOPER_DIR` 必须与它同源（2026-10-01 实测）

§0 上面那条要求 `export SDKROOT=.../CommandLineTools/SDKs/MacOSX26.5.sdk`，但**没要求编译器同源**。
本机 `xcode-select -p` 指向 `/Applications/Xcode.app/...`，于是构建时是
"CLT 的 SDK + Xcode 的编译器"。这样产出的 `.build/debug/MacClean` 里
`@rpath/libXCTestSwiftSupport.dylib` 的搜索路径被写成
`Xcode/…/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx`——
**那个目录里没有这个 dylib**（macOS 的那份在 `MacOSX.platform/Developer/usr/lib/`），
运行时 dyld 直接终止（exit=134），`--selftest` 一条断言都没跑。

- 为什么平时看不出来：增量构建复用旧工具链留下的产物；一旦 `swift package clean`（或换工具链）
  就必现。本轮就是这么踩上的——为了验证脚本改动跑了一次 clean 重建。
- 正确做法：两条一起设。
  `export DEVELOPER_DIR=/Library/Developer/CommandLineTools`
  `export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk`
  设好后 `swift build` 出来的二进制 rpath 指向 `CommandLineTools/usr/lib/swift-6.2/macosx`，
  自检恢复 **696 通过 / 34 失败 / 7 未执行**（与 §0.2 基线逐条相同）。
- 门禁已加诊断：`release.sh` 在全量自检这一步认出这种加载失败并直接给出上面两条 export，
  不再把它当成"产品红灯"去比对失败名集（那只会报一句误导人的"自检红灯不等于环境基线"）。

### 0.2 macOS 27 上 ViewInspector 不兼容：34 条断言失败 + 7 个套件不可执行（2026-09-27 实测）

**背景数字**：macOS ≤26 上同一仓库实测 **649 通过 / 0 失败**。

**根因**：ViewInspector 0.10.3（`git ls-remote --tags` 确认其为上游最新，无修复版本）
靠**猜测 SwiftUI 私有内存布局**来遍历视图树；macOS 27 改了布局，表现有两种：

| 崩溃点 | 机制 | 实测 |
|---|---|---|
| `SwiftUI/GeometryReader.swift:69` | 把 `GeometryProxy` 尺寸硬编码为 48 / 52 字节；`unsafeBitCast` 尺寸不符 → `fatalError` | macOS 27 上实测 **76 字节** |
| `EnvironmentInjection.swift:47` | 对视图结构做原始字节扫描以注入 `@EnvironmentObject`；把一个非指针当对象 `swift_retain` → SIGBUS | 崩在 `swift_retain`，地址 `0x200000008` |

**已验证不可行**：给 `GeometryProxy` 加"按真实尺寸零值构造"的补丁只能让进程多跑一段，
随后仍撞上 `EnvironmentInjection` 的 SIGBUS；而且该补丁依赖未定义行为（零填充的对象位模式），
**可能产生假绿或假红——比截断更危险**。结论：不存在能修好的尺寸补丁。

**当前在 macOS 27 上的实测结果**（编排模式，逐套件子进程）：

```
MacClean 自检完成：602 通过 / 34 失败 / 7 个套件未执行
未执行：SearchAndClean、SystemAndHistory、SpaceVisualizerDeep、SpaceVisualizerDeep2、
        MenuBarWidgetsDeep、SpaceArchiveDeep、GlobalHotkeyDeep（exit=5/10，进程级终止）
```

34 条失败与 7 个未执行套件**全部**属于"依赖 ViewInspector 遍历视图"这一类
（`buttonNotFound` / 渲染类断言）。

**这些与产品改动无关，已用 A/B 证明**（两边都用编排模式、同一台机器）：
撤掉全部产品改动后为 **559 通过 / 34 失败 / 7 未执行**；失败清单与未执行清单
**逐字完全一致**（`diff` 为空），通过数正好多 43 条（即本轮新增的 43 条检查：
ProcessOccupancy 10 + PermissionGate 6 + CleanableAccounting 7 + SystemTweaks 20）。
也就是说：产品改动带来 43 条通过、**0 条新增失败**。

**因此，在 macOS 27 上：**
- 34 条 ViewInspector 断言**无法执行**，7 个套件**无法执行**——换 macOS ≤26 的机器、
  或上游发布兼容版本之前，**不得声称"自检全绿"**；
- 但自检的**可执行范围已经跑满**（602 条），且"未执行"与"通过"分开报，
  不会再出现"没跑到被当成通过了"。

**自检 CLI 口径**（v1.73.11 起）：

| 参数 | 作用 |
|---|---|
| `--selftest` | **默认编排模式**：逐套件开子进程，一个套件崩溃只损失它自己 |
| `--selftest-inproc` | 旧的单进程模式（任一崩溃会吞掉其后全部套件）。怀疑"隔离本身改变了行为"时的对照路径。实测对照：**53 通过 / 7 失败后 fatalError（exit 133）**，而编排模式能跑到 602 通过 |
| `--selftest-suite=<名字>` | 只跑一个套件（子进程模式用的就是它；名字见 `Selftest.suites`，大小写不敏感）。**必须与 `--selftest` 一起传**——编排器拉子进程用的就是 `["--selftest", "--selftest-suite=…"]` 两个参数；只传 `--selftest-suite=…` 不进自检分支，会掉进 SwiftUI GUI 主循环挂住（2026-09-27 实测：主/子代理三个会话同时中招，进程 CPU≈0 停在 `runApp`，看着像"套件很慢"） |
| `--selftest-allow-environment-skips` | 只在"**有套件未执行**"时把退出码放行为 0。**它绝不会掩盖失败**——只要有失败项，退出码仍是 1（判断顺序上失败优先）。在 macOS 27 上因此拿不到 0，这是有意的：34 条失败必须逐条看清 |

**系统体验优化的 CLI 口径**（v1.73.12 起）：

| 参数 | 作用 |
|---|---|
| `--prefs-check` | **只读**体检 11 条系统偏好项（现状 / 推荐 / 收益 / 代价 / 需重启谁）。自检里有真机断言保证它**一条写命令都不发** |
| `--prefs-roundtrip` | 真机读写删**往返**自验。用我们自己的临时域 `com.macclean.selftest.roundtrip`，结束删干净（含空 plist），**不碰任何系统偏好**。存在的理由：`defaults write` 的参数拼法与"删键才算还原"只有真机能验，注入假 runner 验的是逻辑不是机制 |

> `--prefs-roundtrip` 是真值来源，不是装饰：它先后照出两个只靠自检看不见的问题——
> ① macOS 27 对**不存在的域**报的是 `Domain '...' not found.`（第三种措辞，当时不在识别表里，
> 于是"未设置"又被误判成"读不到"）；② `defaults delete <域>` 对只剩空字典的 plist **会失败**
> 并留下一个 42 字节的 `{}` 文件，所以"无残留"当时是假的，现在收尾会显式删掉那个 plist。

**据此的验证口径**：模型层改动（判定引擎 / 权限门 / 可清理量口径 / 偏好读写）由
`Selftest+ProcessOccupancy`、`Selftest+PermissionGate`、`Selftest+CleanableAccounting`、
`Selftest+SystemTweaks` 四套锁定——它们都不碰 ViewInspector，因此在本机仍然能跑；
再用 `--scan` / `--permission-check` / `--prefs-check` 做真机前后对比，
并明确标注哪些断言本轮**没跑到**。


## 1. 代码与测试
- [ ] **两种构建模式都要验**（v1.72.2 起自检代码不进发布产物）：
      ① 开发构建 `swift build` 必须含自检，`--selftest` 的**失败与"未执行"都必须为 0**
         （只看"退出码 0"不够：见 §0.2，macOS 27 上默认会报若干失败与未执行套件，
         那是环境问题、不是产品问题，但**必须逐条看清**再决定是否放行）；
         **2026-09-28 起这条有了机器可查的形式**：`scripts/release.sh` 在退出码非 0 时，
         会把失败用例名与未执行套件名抽出来，跟 `docs/KNOWN-ENV-SELFTEST-FAILURES-MACOS27.md`
         **逐条比对**——多一条（新增产品红灯）少一条（基线过期）都照样 die。
         这不是 `--skip-scan` 式的绕过：比的是具体名字，不是"别看输出"。
         换到 macOS ≤26 的机器（或装上 Xcode）后应当**删掉那份基线**回到"必须为 0"，
         否则基线会把那一类真红也一并供起来。
      ② `./scripts/build-app.sh` 会设 `MACCLEAN_NO_SELFTEST=1` 排除 `Selftests/`，
         打完包必须实测 `dist/MacClean.app/Contents/MacOS/MacClean --selftest`
         **明确报错且退出码非 0**（静默"通过"= 严重问题：会让人以为自检过了）；
      ③ 打开 release 的 .app 实际看一眼界面（自检不在里面了，界面是唯一防线）。
- [ ] `swift build` 无 error **且无 Swift 源码 warning**。v1.72.4 起确实做到 0 条
      （历史遗留的 4 条 + 本轮 14 条全部清零；`MACCLEAN_NO_SELFTEST=1 swift build -c release`
      同样 0 条源码告警）。两类**与源码无关**的残留不算在内，也别去想办法消掉：
      ① 两条 `ld: warning: search path '/Library/Developer/CommandLineTools/Developer/…'
         not found`——§0 那条 SDKROOT 钉版在 CLT 布局下的产物；
      ② release 模式下两条 SwiftPM 的 `dependency 'viewinspector' is not used by any target`——
         package 级依赖声明是**故意留着**的，删掉会让 release 构建顺手删掉被 git 跟踪的
         `Package.resolved`（真发生过）。
- [ ] **`try?`/`?? 0` 兜底的解析代码，必须配一个"输入真的有值"的样本断言**。
      macOS 13 起 AVFoundation 的同步属性（`duration`/`tracks(withMediaType:)`/`naturalSize`/
      `estimatedDataRate`/`formatDescriptions`）全部废弃，只剩 `load(...)` 异步族，
      于是每个字段都得 `try? await … ?? 0`——真要是全部解析失败，代码照编译、
      自检照全绿，界面上却再也显示不出时长/分辨率/码率。
      现在由 `Selftest.makeVideoFixture` 现场用 `AVAssetWriter` 造一个真 H.264 mp4，
      断言解析结果非零并回填缓存。**同类改动（任何"失败即静默降级"的解析）都要照此办。**
      另：`AVAssetWriterInputPixelBufferAdaptor.append` 在 `isReadyForMoreMediaData == false`
      时是**抛 ObjC 异常**而不是返回 false，会把整个进程打断（实测就是这样跑断了自检），
      必须先等 ready。
- [ ] `.build/debug/MacClean --selftest` 全过（退出码 0）。自检会自动把历史/撤销快照/
      增量指纹缓存重定向到临时目录（`MACCLEAN_STATE_DIR`，见 `MacCleanState`），
      **不要**在未隔离的状态下从 `.app` 内跑自检——那会读写用户真实的清理历史与白名单
- [ ] `.build/debug/MacClean --scan` 冒烟（扫描不崩溃、结果合理）
- [ ] **新增治理模块时的四条硬要求（v1.72，G14–G16）**：
      ① 删除必须走 `ResidueDeletionGate`，**禁止**出现 `hasPrefix("/System")` 式字符串护栏
         与裸 `FileManager.removeItem`/`trashItem`；
      ② 触及主目录之外的位置必须先在 `GovernanceDomain` 登记精确根（含最小层级），
         未登记的域网关一律拒绝——这是故意的，不要为了跑通而放宽；
      ③ 外部命令必须走 `SafeProcess`（超时 + 先排空管道 + 启动失败不 wait）；
      ④ "已安装应用"必须取 `AppInventory.current()`，并在 `isComplete == false` 时
         把孤儿结论降级为"需确认"。**不许**自己 `try? contentsOfDirectory` 一份清单，
         读失败会得到空集，进而把全盘残存判成孤儿并默认勾选
- [ ] 治理卡片必须如实呈现网关给的拒绝原因，特别是 `needsPrivilege`
      （真机 `/Library/*` 多为 root 只读：`/Library/Printers`、`/Library/QuickLook`、
      `/Library/Audio/Plug-Ins/HAL` 实测都不可写，只有 `/Library/Fonts` 因属
      `drwxrwxr-t root:admin` 而 admin 可写）。**不许**把"没权限删"报成"已清理"
- [ ] 改动涉及 UI 时：`--selftest` 中视图用例已覆盖或手动确认，并对照 `docs/DESIGN.md`
      检查是否引入了新的"AI 仪表盘"痕迹（图标彩色底板 / 卡片套卡片 / 多强调色 / emoji 文案）
- [ ] **新增确认弹窗（`confirmationDialog` / `.sheet` / `.alert`）时**：present 修饰符必须挂在
      **有尺寸的容器**上。写成 `EmptyView().confirmationDialog(...)` 再塞进 `VStack` 时，
      SwiftUI 可能不呈现它——而 ViewInspector 自检里 `isPresented` 照样会翻转，**测试通过、真机没弹窗**。
      本仓库真踩过：剪贴板「全量净化」的确认自检全绿，人工点开界面前往下点会直接执行删除。
      因此新增确认路径后必须**人工或用 Computer Use 真点一次**，不能只信自检。
- [ ] **卡片的选中态是 `@State` 时，`.tap()` 之后读不回来**（v1.73.10 实测）：ViewInspector 里
      `try button("xxxSelectAllButton", in: card).tap()` 会执行动作，但重新 `inspect()` 渲染的仍是
      **播种时的那份** `@State`（Android 卡片实测点完全选后按钮文案仍为「清理选中 (0 KB)」）。
      于是"点全选会不会把残缺项勾上"这类**只能靠状态迁移才可见**的契约，在视图层写成断言就是**恒绿的假断言**。
      两道替代：① 能观测的部分（按钮禁用态、行内警示文案）留在 UI 用例里，并**同时断言反证**
      （同一份清单换成完整可读必须放开，否则"永远禁用"的坏实现也算过）；
      ② 方法体本身的判据交给源码形状 lint（`Selftest+ScanDiagnostics`「卡片全选必须走 readable」，
      用大括号深度精确截函数体，别让同文件的 `selectableCount` 蹭到 `readable` 而免检）。
      反之，把选中态放在**外部对象**（`scanner.reports`）里的卡片（DiagnosticReport）就能真读回，
      那种用例别照抄成源码 lint。
- [ ] **外层过滤把项挡在删除管道之外时，必须把"为什么没删"显式带出来**（v1.73.10 变异暴露）：
      `item.deletionTargets` 对非孤儿返回空数组是对的方向（健康项的路压根不进网关），但当时
      `clean()` 返回的是 `cleaned=1、rejected=0`——调用方塞进健康项的表现与"什么都没发生"完全一样。
      正确形状：模块侧先攒 `blocked: [Rejection]`、用 `Outcome(rejected: blocked).merging(网关结果)`
      （ClipboardPurger / QuickLook / Screenshots / Downloads 四张面板已经是这个形状，别另起炉灶）。
      写这条自检时要**同时钉 path、reason 与该条目自己的状态文案**——钉成
      "rejected 非空"或"A 或 B 之一"都抓不到"原因挂错条目/文案丢判据"。
- [ ] **"配对两个文件系统对象"时，先确认工具自己按什么配对**（v1.73.10 的 P0）：Android 模块最初按
      `~/.android/avd/<n>.avd` ↔ `<n>.ini` **文件名**配对判孤儿，而 `avdmanager list avd` 实测是按
      描述符**内容里的 `path=`** 定位数据目录的（本机造 `zz-descriptor-name.ini` → `probe.avd`，
      `avdmanager` 照样列出）。后果是一台活的、被工具链认到的 AVD 被判孤儿并**默认勾选**。
      教训：凡"目录 A 没有同名文件 B = 孤儿"式的判据，先拿**该领域自己的官方工具**跑一遍反证，
      别拿文件名当身份；并且要覆盖"描述符读不出来"这一支——读不出来的那一份可能正指向它。
- [ ] **降级/告警文案不许无条件宣称全局事实**（v1.73.10 复审 P1-5）：横幅那句
      "因此没有任何一项被默认勾选"只要是从 `!isResultComplete` 无条件渲染的，就会在
      "一条没读全 + 另一棵确证孤儿已勾上"这个真实形态下当面否认界面上看得见的勾选框。
      写绝对化结论（"没有任何一项""这里没有""全部"）时，判据必须取**实际那个集合**，
      并给该集合非空的情形补一条断言（含反向：可读夹具上必须抽不到这句警示）。
- [ ] **按行解析文本文件时用 `components(separatedBy: .newlines)`，不要用 `split(separator: "\n")`**
      （v1.73.10 二次复审实测）：`String.split(separator:)` 按**字素簇**比对分隔符，而 `\r\n` 在
      Unicode 里是**一个**字素簇——`"a\r\nb\r\n".split(separator: "\n")` 返回 **1** 个元素，
      `components(separatedBy: "\n")` 返回 **3**。后果不是"少一行"而是**整份文件不分行**：
      解析 `key=value` 时第一个 `=` 之后的值会吞掉后面所有行，配对/查找全部落空。
      在 AVD 描述符上这条会直接**把一台活的 AVD 判成孤儿并默认勾选**。
- [ ] **卡片里"能不能勾"的判据必须与 `selectableCount` 完全一致**（v1.73.10 二次复审 P2-10）：
      行内勾选框只判"是孤儿"、而 `selectableCount` 还判 `readable`，就会出现
      "用户勾上一个残缺项 → 点写着「全选」的按钮 → 该项被 `select && readable` 静默取消勾选"。
      判据分叉的另一种表现是按钮标签与实际行为相反。
- [ ] **改动了并发/共享状态时**：跑一遍 Thread Sanitizer，必须零报告
      ```bash
      swift build --sanitize=thread && swift run --sanitize=thread MacClean --selftest
      ```
      （`scanAll` 会把 6 个分类并发丢进全局队列，共享缓存必须加锁或改快照）
      **TSan 轮里有一条已知的稳定假红**：`护栏热路径：一次判定的开销相对单次软链解析的倍数`
      在插桩下必然超阈值（实测普通构建 2.1×，TSan 下更高），**它不是竞争**。
      TSan 轮的判据是 `WARNING: ThreadSanitizer` 命中数为 0，不是"全绿"。
      不要为了让它变绿去调阈值——那是拿放宽护栏换安静；正解是让性能类断言在插桩构建下
      不参与判定（待议，见 `docs/code-review/` 的待议小节）。
- [ ] **新增治理面板（卡片）时**：① 必须**默认收起**，靠细分过滤条上的胶囊展开——不许再出现
      `SystemDeepStorageView()` 那种无条件挂载的写法（v1.72.6 之前它把浏览器分类的页头、
      页脚和列表一起挤出窗口）；② 面板区整体被 `ScrollView + .frame(maxHeight: 340)` 封顶，
      所以新卡片**内部**要有自己的滚动，不要指望页面给它高度；
      ③ 真机把该分类的**所有面板一次全开**截图看过：页头（标题/过滤/扫描）与页脚
      （已选/清理）必须仍在——SwiftUI 对超高 VStack 是**上下两头一起裁**，不是滚动，
      表现就是"这一页点不动了"；
      ④ 还要在**列表很短**（<20 项）的分类上再看一次：`ScrollView + .frame(maxHeight:)` 是
      **贪心**的，里面只剩一排胶囊时也会把限高空间占满，列表上方凭空多出一条空带。
      v1.72.6 给面板区封顶时没注意这条，v1.72.9 的 L3 判据把「日志与临时文件」从 339 项
      压到 11 项才把它暴露出来——现在限高滚动只在真有面板展开时套上（`anyGovernancePanelOpen`）。
- [ ] **改动了子进程调用时**：确认读管道**先于** `waitUntilExit`。
      macOS 管道缓冲区只有约 64 KB，先 wait 后读会双向死锁。
      **尤其注意"只在失败分支才读管道"这种写法**（v1.73.1 修掉的 `SpaceArchiveService` 就是它）：
      它看着像是"成功了就不用管输出"，实际子进程在**还在跑**的时候就把 stderr 写满，
      于是父进程等退出、子进程等写，谁也不动——而且调用方在 `DispatchQueue.global` 上，
      界面表现为"正在归档…"永不复位，还长期占住一个并发池工作线程。
- [ ] **把裸 `Process` 迁到 `SafeProcess` 时**：**必须按这条命令的真实耗时显式设 `timeout`**，
      别拿默认值凑。默认 10 秒是给 `mdutil`/`launchctl` 这类瞬时命令的；`ditto` 打包/复制
      是按体积跑的（几十 GB 要几分钟到几十分钟），沿用默认值只是把"永远卡住"换成"永远失败"，
      同样是缺陷。判据：自检要断言**传进去的 timeout 数值**，而不是只断言"走了 SafeProcess"。
      而且**断言阈值要贴着线上值**：v1.73.1 第一版写的是 `timeout >= 600`，线上是 3600——
      有人把常量缩到 15 分钟照样绿。改成 `== SpaceArchiveService.dittoTimeout` 再加一条
      `dittoTimeout >= 30 * 60` 的绝对值断言，两头都锁住。
- [ ] **注入桩不许让多个判据同时为假**：v1.73.1 第一条超时用例给的是
      `Result(exitCode: -1, output: "", timedOut: true)`，于是把 guard 里的 `!ditto.timedOut`
      整个删掉仍然绿——`exitCode` 那一半替它挡了。被测条件必须**单独**可证伪：
      超时用例应给 `exitCode: 0, timedOut: true`（被 SIGTERM 后自己干净收尾是真实存在的形状）。
- [ ] **断言外部工具的参数组合时，至少跑一次真命令**：`ditto --sequesterRsrc <src> <dst>`
      看着完全合理，实际 ditto 只在该 flag 配 `-c -k`（PKZip）时接受，纯复制形态下它在
      **解析参数阶段**就退出。这条缺陷让"迁移到外接盘"从来没成功过一次，而一条只断言
      "参数长什么样"的自检把它当成契约钉死了（`m.1.contains("--sequesterRsrc")` 恒绿）。
      判据：涉及外部二进制时，至少一条自检要**真的执行它并断言落位结果**。
- [ ] **写"遍历全仓源码"型 lint 时**：`contentsOfDirectory` **不递归**——v1.73.1 第一版漏掉
      `Sources/MacClean/Rules/` 与 `Selftests/` 共 57 个文件，实测往 `Rules/` 放一个真
      `Process()` 照样全绿。要用 `subpathsOfDirectory`，并且：① 排除 `Selftests/` 子树
      （自检代码里就写着被匹配的字面量，且它们不进发布产物）；② **逐行跳过 `//`/`///` 注释**
      （本仓库爱在注释里写"此前是裸 Process()"，整文件子串匹配会被自己的注释撞红）；
      ③ 文件数要设一个下界断言，否则"扫到 0 个文件"会伪装成"零违规"。
- [ ] **改动了重复文件扫描时**：确认硬链接仍被排除在"可节省空间"之外
      （两条硬链接指向同一 inode 时删一条释放 0 字节）
- [ ] **改动了持久化结构时**：确认新增字段不会让老数据解码失败
      （Swift 合成的 `Codable` **不使用属性默认值**，必须手写 `init(from:)` 或 `decodeIfPresent`）
- [ ] **改动了无人值守路径（DiskMonitor 静默清理 / 定时巡检）时**：确认 ①等待扫描真正结束
      而不是固定延时；②低空间告警仍是边沿触发 + 冷却期，不会每次扫描结束都发一条
- [ ] **新增清理规则时先问"这条的判据是什么"**：判据只是**大小或时间**（>1GB、>90 天没动）的，
      必须标 `auditOnly: true` 走「空间审计」，**不进清理页**——带勾选框和「清理已选项」按钮的页面
      本身就是一种承诺，而"很大"不构成"可以删"（决策 D-3 / v1.72.12）。
      分流只收在 `Scanner.scanDetailed` 一处；动它就要同步 `CleanCategory.ruleRef`
      （只算清理页真的会列出的规则）与那条"清理页拿不到只报告项"的自检。
- [ ] **任何"读—改—写"都要有唯一原子入口**（v1.73.2）：`load() → 改 → save()` 三步之间没有
      整段锁，两个写者就 last-writer-wins。更隐蔽的一种是**把整份列表缓存在内存里再写回**——
      `AppState.history` 就是：启动时读一次盘，之后每次 `recordClean` 都拿那份陈旧数组
      `HistoryStore.save(history)`，于是启动期间别的模块追加的记录被整片抹掉。
      **这条不需要并发就能触发**，所以它不是"竞态"而是确定性丢数据。
      判据：① 持久化列表的写入只允许一个函数（`HistoryStore.append` / `clear`），
      其余地方一律不许直接 `save`；② 内存缓存只能由该入口的返回值刷新；
      ③ 自检里要有一条"外部先写一条、缓存方再写一条、断言盘上有两条"的反证，
      并且**把缓存方改回旧写法时它必须变红**。
      **临界区不许包住真实 I/O**：`UndoManagerStore.restore` 旧写法是开头 `load()` 拿一份数组、
      中间逐项 `moveItem` 把文件从废纸篓搬回原位（秒级）、结尾整片 `save()`——窗口比
      `record` 的微秒级大几个数量级，期间任何一次 `record` 都被覆盖，症状是
      **"历史记录还在、撤销快照没了"**，用户点那行得到"未找到对应的清理撤销快照"。
      正确形状：先在只读快照上做搬运并攒结果，最后用一次 `mutate` 重新读盘落账。
- [ ] **两把锁不要混用**：`UndoManagerStore.record` 里事务锁包住整段、内部 `load/save` 各自
      再取 I/O 锁——这要求它们是**两把不同的 `NSLock`**。`NSLock` 不可重入，同一把锁套两次
      是自死锁且**零输出**（进程只是不返回，看不到任何报错）。
- [ ] **改动了常驻轮询（菜单栏 / 定时器）时**：确认后台档位真的比前台慢，
      且"没有动态内容可显示"的模式（如仅图标）**不轮询**
- [ ] **改动了长时间运行的任务时**：确认可取消，且取消不破坏已有结果
- [ ] **改动了带动画的视图时**：一律用 `.motionSafe()` / `.motionSafeTransition()` /
      `.motionSafeNumericTransition()`，不要写裸 `.animation` / `.transition` / `.contentTransition`
      （`Selftest` 会扫源码把关）——这是「减少动态效果」辅助功能的唯一保障
- [ ] **新增大列表视图时**：过滤/分组在 `body` 里算**一次**再向下传，不要写成被反复引用的
      计算属性（实测 548 项时旧写法单帧过滤就花 15.6ms，接近 60fps 全部预算）
- [ ] **写"隔了多久"类判据时**：判据字段必须是**自家探查不会改动的字段**。
      时间戳只用 `mtime`，不要用 atime——本机实测读取不更新 atime（三次独立实验，含一个 atime
      已落后 9.5 天的既有文件，读后等 20 s 仍不动），所以它既没有"谁在读"的信息量，
      而在**会**更新 atime 的卷上，`size(at:)` 的 opendir 会让候选项每轮扫描都被刷成"还在用"，
      那些项就永远清不掉（扫描把自己扫成了证据）。
- [ ] **新增或改动扫描规则时**：必须证明它**真的列出过东西**，不能只证明代码跑通了。
      对照法是 `--scan`（只读）跑旧包与新包各一次再 diff——D19 的 daemon 分支就是这样被发现的：
      它把 `FileSystem.children(of:)`（**返回全路径**）的结果再 `appendingPathComponent` 拼一遍，
      路径永不存在 → `size` 恒 0 → 规则在册、文档在列、自检全绿，而本机 49 MB 从未出现在界面上。
      列表里少一项不像 bug，只像"这里没东西"。
- [ ] **断言记账/历史写入时，别比绝对条数**：`HistoryStore` 有 200 条上限、`UndoManagerStore`
      有 100 条上限，且 `load()` 读的时候就裁。自检的隔离状态目录在 `$TMPDIR` 里跨多次运行累积，
      攒满之后"清一项 → 条数 +1"这种断言必然假红（实测就是这么红的）。改成比对**新记录的身份**
      （`first?.id` 变了、`categoryName`/`mode`/`bytes` 对得上、旧表头仍在新表里）。
- [ ] **源码接线式断言（`SelftestSource.read`）只匹配调用形态的字面量**：写
      `!src.contains("trashItem")` 会被自己那段"旧实现裸调 `trashItem`"的注释撞红。
      用 `FileManager.default.trashItem` 这种带接收者的完整调用形，并在注释里避开它。
- [ ] **变异验证必须挑生产真正走的那条参数路径**：v1.73.0 那条"写历史与撤销快照"的断言，
      第一版显式传了 `journal: .module(...)`，于是把实现的**默认值**改成 `.none` 后自检照旧全绿——
      测试锁住的是一个自己喂进去的实参，而界面调用方吃的是默认值。把测试改成不传参、
      依赖默认值，变异才变红。凡是"默认值即安全策略"的参数，自检一律不要显式传。
- [ ] **改动聚合项（`paths` 多条、主路径是父目录）时**：占用状态按**它自己要删的那批路径**量
      （`FileSystem.usage(ofPaths:)`），不要量父目录——`~/Library/Logs`、`~/.gradle/daemon`
      随时有人在写，量父目录会把"16 个 3 天没动的日志"标成「使用中」，那是**假**的占用证据。
- [ ] **改动人看到的措辞时**：结论与档位标签只许说**量到的东西**。单个 mtime 推不出"频繁/偶尔"，
      而"使用:5 天前 · 频繁使用中"和"确定是垃圾"并排出现时，用户唯一理性的反应是两个都不信
      （v1.72.9 把标签改成"7 天内有写入"这一类事实句）
- [ ] **"并发下只发生一次"这类行为断言，在窗口极窄时是不可证伪的**：给"同一个 key 的查询与占位
      必须在同一次临界区"写自检时，先写了 8 线程 + 起跑屏障、断 body 只跑一次——把实现改成
      check-then-act **照样全绿**（窗口只有几条指令，实测 8 个线程仍然只跑 1 次）。改用"占位那一行
      不许自带一次新的 lock/unlock"的**代码形状**断言才转红。凡是想用行为测试钉"原子性"的，
      先问自己：把锁拆开会观察到什么？如果答案是"大概还是看不出来"，就换成形状断言并写清为什么。
- [ ] **给"没试过的东西"记账之前先分清两种失败**：限流/令牌耗尽后直接返回"读不到"，
      等于对没碰过的目录声称权限不足——那是凭空造告警。超时（真等过）才记盲区，
      没试（额度满）只跳过。这条判据本身有自检钉着（M9）。
- [ ] **改动了清理规则时**：`Selftest` 中的规则一致性用例（条数 / 编号连续 / `ruleRef`）
      必须全过，且 `docs/CLEANUP-RULES.md`、`Rules/CleanupRules.swift`、`Scanner.swift`
      三处同步更新
- [ ] **翻转一个全局开关的默认值，要 grep 出所有读它的自检逐条重钉**：v1.73.3 把
      `FileSystem.proactiveBlindSpotProbe` 默认从 `true` 改成 `false`（无头路径开着会被模态
      授权框挂死），依赖"默认开着"的两条自检当场失效——可当时整轮自检在更早的
      `Scanner.scan` 上卡死，那两条根本没被执行，破口被完整掩盖了一轮，直到卡死修好才露出来。
      凡改默认值：读该开关的自检要么显式设成它所测的那条路径，要么删掉；**别留着当摆设**。
- [ ] **变异脚本必须在 `finally` 里还原源码**：v1.73.4 那个脚本循环中途抛了异常（元组形状不匹配），
      仓库被留在**变异态**，而下一轮运行时它把"已变异的源码"当成了基线备份 —— 于是锚点全部命中 0 次、
      看起来像"变异没生效"，实际是源码已经被上一轮改坏。跑完任何变异脚本都要立刻
      `git diff --stat` 对一遍，确认改动数与预期一致再继续。
- [ ] **给"复审指出的缺陷"写自检之前，先证明那条分支可达**：v1.73.5 复审说"枚举器返回 nil +
      在途额度已满 → 一手失败证据被吞"，我照它写了自检——结果 M30 改坏实现**照样全绿**：
      `FileManager.enumerator` 对 mode 000 目录返回的是**可用的**枚举器，拒绝发生在迭代时、
      由 `errorHandler` 兜住，那条分支实际不可达。代码改动保留了（严格更安全），
      自检**删掉**并把结论写成注释。**不可达的分支不要配自检**——那是一条永远绿、
       yet 声称钉住了什么的假断言，比没有更糟。
- [ ] **计时/缩放比自检不要丢弃被测调用的返回值**：`_ = recordBlindSpotIfNeeded(...)` 把
      "这次到底开成功了没"整个丢掉，于是目录一旦进 `wedgedReads`（TTL 600 s）就短路不 dispatch，
      量到的是"什么都不做"的时间、比值当然漂亮。活性证据就在返回值里：任何一次 true 都说明
      本轮样本不可信，直接判红。**别用"绝对毫秒下界"当活性判据**——那是机器经验值，会重演假红。
- [ ] **写「扫全仓源码」的 lint 时，要按调用的真实排版匹配**：v1.73.6 第一版按单行找
      `.enumerator(at:`，而本仓库的调用全是多行排版（`fm.enumerator(` 一行、`at: URL(...)`
      下一行），于是一条都没匹配上——lint 在**空集上恒真通过**，看起来像"全仓干净"。
      判据：写完这类 lint 必须**故意在某个产品文件里制造一次违规**跑一遍确认它会红。
      匹配不到任何东西的 lint 等于没有 lint，而且更糟，因为它会被读成"已经封住了"。
- [ ] **改求体积入口的契约时必须同时钉消费方**：v1.73.6 把 `calculateDirectoryStats`/
      `calculateDirectoryMetrics` 加了 `recordDeniedAccess` 留痕，但只改了**生产侧**——
      CLICache/QuickLook/Spotlight 三处的消费方仍是 `if size > 0 { isSelected: true }`，
      一次被权限掐断的遍历会得到"3 MB 默认勾选"，用户点删除就等于用残缺事实背书；这是
      G9「读不到 ≠ 干净」在**默认勾选侧**的镜像形态。v1.73.7 把三处 `readable` 补上、
      `isSelected` 以 `readable` 为闸；**并且加了 lint 钉「三处消费方不许把 `isSelected`
      硬编成常量 `true`」**。教训：给求体积入口加契约字段（readable / isComplete /
      unreadableRoots）时，要同一轮把每一条契约在**消费方**都找一遍并各立 lint/行为断言；
      否则契约字段就只是"文档里有、代码里空"。变异验证：把任一处 `isSelected: readable`
      改回 `isSelected: true`，**消费方 lint + 对应的 behavioral 断言**应当同时红
      （atPath 那条 lint 与 `isSelected` 无因果关系，不该被牵进来看似"同时红"——
      v1.73.7 复审抓出上一版本节里那句"两条 lint 与两处 behavioral 应当同时红"是夸大）。
- [ ] **新增治理模块的求体积必须走 `FileSystem.directoryStats`（v1.73.13 起全仓唯一一份模块级递归 walker）**：
      此前 CLICache / Spotlight / AudioHAL / PrinterDriver / Android 五个模块各写一份，
      `fileSize` vs `totalFileAllocatedSize`、跳不跳软链两处口径不一——同一棵树五个面板五个数，
      而删除侧实测释放量只会是其中一种（v1.73.10 复审待议 R2-P2-11）。新模块再写第 6 份
      就是把这道口子重新打开；等值断言的现成模式在四个 Deep 套件里（共享夹具树 +
      「与 `directoryStats` 同树逐项相等」+ 稀疏/软链/mode-000/隐藏各一支），照抄即可。
- [ ] **造稀疏文件夹具时先验证它真的是稀疏的**：APFS 对 ≤8MB 的洞会整段物化
      （实测 seek 8MB 的"稀疏"文件 allocated≈逻辑大小，断言恒绿没牙齿），要用
      `ftruncate` / `truncate(atOffset:)` 撑 **100MB 级尾部洞**（allocated≈4KB），
      且夹具 sanity 断言直接读 `totalFileAllocatedSize`——`?? 0` 兜底会把它吞成 0、
      看起来像稀疏其实是没读到。
- [ ] **夹具要经网关真删时放 `/private/tmp`，别放 `NSTemporaryDirectory()`**：网关的常规
      放行根是主目录与 `/private/tmp`，**不含** per-user 的 `/var/folders/…/T/`——把夹具
      建在后者会让每个候选都被「被基础安全护栏拒绝」，端到端断言全红（v1.73.14 废纸篓
      自动清空自检实测）。生产路径不受影响时（如 `~/.Trash` 在主目录内），这纯粹是
      夹具选址问题；但别为了夹具去放宽网关。
- [ ] **"契约两侧都钉"不包括第三侧的门把手：模型默认值 + 卡片全选**：v1.73.7 第一次复审
      抓出**四条**同族 P1，一条比一条更深：
      ① 生产侧加了 `readable` 只算第一道；② scan 消费方 `isSelected: readable` 是第二道；
      ③ **卡片顶部的 `selectAll(true)` 是第三道**——scan 那一刻已经把残缺项关掉了，
      用户点一次全选就把它翻回来；④ **模型的 `isSelected: Bool = true` 是第四道**——
      调用方把 `isSelected:` 实参整个删掉，就无声走模型默认，两条 lint 与两处 behavioral
      都只盯显式实参、看不见"缺参数"这条路。教训：给求体积/清单类返回值加 `readable` /
      `isComplete` / `unreadableRoots` 时，把这条链一路找到 UI：scan 返回 → item 模型 →
      卡片全选 → 面板顶栏；**模型的默认勾选值必须是 `false`**（默认勾选是安全策略，
      不该由"忘了传"这种编译期过得去的形状展开）。lint 判据也别只看字面 `isSelected:`——
      要求"右值必须引用含 `readable` 的标识符"，这样 `isSelected: isOrphan` 这种"看着
      像闸其实没有"的**自然回退**才抓得住。变异验证要真去删一次实参、真去摘一次 `&& readable`。
- [ ] **lint 的窗口必须按**结构**切，不能按字节数或下一个关键字**：v1.73.7 卡片 lint 的第一版
      写的是"从 `functoggleSelectAll(){` 起取 400 个非空白字符"——同一文件里的
      `privatevarselectableCount:Int{summary.items.filter(\.readable).count}` 就住在
      那 400 字符窗口之内，`readable` 三个字蹭到了，变异里把 `&& items[i].readable`
      摘掉、lint 依然绿。正解：**用大括号深度追踪把方法体精确截出来**，邻居再合规
      也不背书。同理，v1.73.6 那条 `.enumerator(` 判据的"切下一处 `.enumerator(` 之前"
      也是同一族——按关键字近似截窗，永远可能被邻居的同关键字喂饱。
- [ ] **"某某护栏一律删除"的收敛声明也要 lint 到全仓**：G14 文档里写着 `path.hasPrefix("/System")`
      式字符串护栏"一律删除"，实际项目只给 ColorSync 与 PrinterDriver 两个文件各立了一条
      **单文件** lint——剩下 5 处（Screenshots/Downloads/QuickLook/AppLocalization×2 与
      FontCache sibling）一直活着到 v1.73.8。这类"看起来收口了其实只收到被审到的那两个"
      的漏网是**同族问题最容易复发的形态**：写第一条 lint 的时候顺手圈定的范围就是
      "我改过的那两个"，而不是"这个模式可能出现的全部位置"。正解：**立单文件 lint 的那一轮
      就问一句"这条模式在仓库里还有几处？"**，如果 >1，直接改成立**全仓 lint** + `mustBeThere`
      反向哨兵（"必须扫到的文件"、"必须命中的关键字"），否则第二次同族问题一定长回来。
      v1.73.8 的 G18 全仓 lint 是这条教训的第一次补票。
- [ ] **"扫描侧的护栏"与"删除侧的护栏"必须是同一个判据**：本轮 v1.73.8 复审逼出来的教训——
      G8 清单在**删除侧**（`isSafeToClean` / `governanceVerdict`）走 `normalizePath` + `GuardPath.matches`
      （精确或子层级），**扫描侧**却散着 5 处 `path.hasPrefix("/System")` 字符串比较——两份
      判据、两个覆盖面、两个语义（漏 SIP 里 3 条非 `/System` 前缀位置、把假想的 `/SystemFoo`
      过拦）。**同一份 G8 清单被两个判据各读一次**是 `RELEASE-CHECKLIST §"两套标准"` 已经点名的形态。
      正解：扫描侧也调 `FileSystem.isSystemProtected`（内部就是删除侧那套），
      **别自己复制清单**、**别自己写字符串比较**。给任何一条"G 系列护栏"新加消费方时，
      先问一句"这条护栏在扫描侧与删除侧读的是不是同一个函数"。
- [ ] **端到端断言先查结构、再谈因果**（v1.73.8 复审 P1-1 逼出）：给"扫进 SIP 位置 →
      经 permissionIssues 长出要求 FDA 的假告警"写端到端自检，跑一遍才想起
      `FileSystem.deniedAccessSnapshot()` 本身就把 `systemProtected` 位置过滤掉了
      （`FileSystem.swift:191-198`）——**因果链的第二段**在结构上恒假，快照根本不会
      包含 SIP 路径，`permissionIssues` 也就永远不会为它喊狼来了。**这条断言"通过"
      不是因为本轮修复对了，而是因为它测的那条链本来就不成立**。同类还有：本机
      `stat -f` 实测 SIP 位置 `drwxr-xr-x root:wheel` world-readable，`probeDirectory`
      返回 `.readable`——端到端 ③ 在 OLD 版本也绿。**动笔写端到端断言前先追一次
      数据流经过的每一个 filter 与本机 filesystem 实况**，别把"结构上恒真"或
      "本机不可达"的分支吹成"变异验证过的 teeth"；teeth 在哪一层就明写在哪一层的
      注释里，其余层降级为回归护栏。参见 `MEMORY: feedback-test-quality-smells`
      里的"生产不可达分支"与"seam 太低"。
- [ ] **给 lint 立"命中数下界"时要连"允许为 0 的场景"一起想清楚**：v1.73.7 的两条新 lint 都
      加了 `matched >= 1` / `checkedSites >= 3` 的活性证据，是因为上一轮踩过"匹配 0 处 = 空集
      恒真通过"的坑；但下界设太高会挡掉合理的重构（比如某天把 `DiagnosticReportScanner`
      换成 URL 重载，全仓就没有 atPath 了）。**判据**：下界只要挡住"匹配逻辑退化"就够，
      别拿它当"这条模式必须永远存在"的口号——真消失了就删掉这条 lint 并写清理由，
      比让 lint 变成永远需要豁免要诚实。
- [ ] **"UI 侧的护栏"和"服务/删除侧的护栏"也要读同一份判据**：v1.73.9 抓到 `SpaceVisualizerModel.canArchiveOrMigrate`
      自己维护一份 10 条字面的"危险根"清单 + `standardizingPath`——服务侧走的是
      `normalizePath(realPath())` + `coreGuardVerdict` + 卷下深度 ≥2，两套判据**交集之外**就是
      UI 谎报的口子（`/private/var/db` 真在 SIP 清单里，但**不在**UI 那份 10 条字面里，
      UI 把"归档"按钮开放出去、用户点下去才被服务侧拒）。同一份 G8 清单被扫描/UI/服务
      三处各自抄一遍是本仓同族问题的第三条腿（v1.73.6 求体积生产侧、v1.73.7 UI 卡片全选、
      v1.73.8 扫描根字符串护栏、v1.73.9 UI 判据 vs 服务判据）——每次都是"上一轮我以为已经收完
      了的那一族"。判据的**唯一入口**要在文档里明写（G19 行），下一轮加消费点时先看是不是
      复用而不是复制。
- [ ] **端到端"变异性"断言要挑**判别性样本**，两侧都拒的例子不算**：v1.73.9 自检的第一版
      用 `systemProtected.first` 挑样本，落到 `/System`——`/System` 恰好**也**在旧 UI 手写
      清单里，OLD/NEW 都拒 → 断言恒真。按 `MEMORY: feedback-reproduce-reviewer-causality`
      跑一次 OLD 变异才露馅。**规矩**：写"OLD 会红 NEW 会绿"的断言时，样本必须**只在**
      本轮修复的覆盖面里、**不在**被替换掉的旧实现的覆盖面里；否则就是一条"看起来在测、
      其实两个实现都能过"的假绿。`/private/var/db` 对旧 UI 手写清单就是这种判别性样本
      （`/var` 精确匹配不认 `/var/db`）——选它、不是选 `/System`。

- [ ] **lint 的"活性证据"要盯命中数，不只看扫到多少文件**：v1.73.6 复审查出——只断言
      `files.count >= 50` 挡不住匹配逻辑退化：只要模式对不上，`offenders` 依然为空、绿灯
      照样报"全仓干净"。正解是**另加一条命中数下界**（当前产品源码非 atPath 的 `.enumerator(`
      有 11 处，下界设 8 留一点重构余量），并给"必然存在的文件"各自断言至少命中 1 处；
      否则一次改错正则，绿灯就是凭空得来的。**变异验证要真的去改坏正则**（把匹配模式换成
      一个不存在的字符串），别只改产品代码——只测产品侧，等于没测活性证据这一路。
- [ ] **判据窗口不能把注释里出现的关键字算作满足**：v1.73.6 lint 的窗口取自"本行到窗口
      末"，而产品代码里 handler 上方常写着"这里要 recordDeniedAccess"的说明——若窗口含
      注释行，漏记账的实现会因为注释里有这个词而免检。正解：**按物理行取窗口，但每一步
      过滤掉以 `//`/`///` 起头的行**；同时窗口右端切在"下一处 `.enumerator(` 之前"，
      不让邻居遍历的 handler 里的真实调用替本行漏网的背书。变异验证：把某处的
      `FileSystem.recordDeniedAccess(...)` 从 handler 里删掉、只留在注释里，lint 必须红。
- [ ] **性能断言的 fixture 对比度必须盖过"每次调用的固定开销"**：把探测改成"读一遍顶层条目"这个变异，
      在 1:60 的对比下只把比值从 0.98 推到 2.80——每次调用含一次 GCD 派发 + 信号量等待，固定成本
      盖过了条目成本，阈值 4.0 抓不住。改成 1:300 后正确码 1.03、变异码 6~10，界才分得开。
      **写完比率断言一定要拿"它本该抓住的那个退化"真跑一遍变异**，只看"绿"不代表有牙齿。
- [ ] **别拿"跨阶段时间比"当门禁，拿"同一阶段内的缩放比"当门禁**：`探测耗时 ÷ 体积测算耗时 < 0.5`
      这类判据机器一忙就假红（实测 load 9.7 下从 0.04 跳到 0.58，v1.73.4 发布后一轮之内就咬人）；
      换成两侧在同一时刻、同一负载下量的缩放比（条目 1→300 的开销比），负载同时作用于分子分母，稳定得多。
- [ ] **`try? resourceValues` / `try? attributesOfItem` 的 nil 是竞态，不是"读不到"**（2026-09-28 实测）：
      可读目录里放一个 mode 000 的 2 MB 文件，`enumerator(at:)` 的 `errorHandler` 回调 0 次、
      该条目 `resourceValues` 成功、字节全额计入——**stat 不需要读权限**。所以全仓那 17 处
      `try?` 取元数据的站点（MailAttachments/Screenshots/Scanner/SystemDeepStorage/SpaceArchive 等）
      只在"列举与 stat 之间条目消失"或真 IO 错误时才为 nil，把它们统一改成"翻 readable=false"
      是给正常遍历凭空背"残缺"。**别照着 atPath 那一族去"修"它们**——那一族的失效模式是
      子树被拒且**不报错**，与这里不同。权限类盲区由 enumerator 的 errorHandler 与根级
      `isPermissionDenied` 负责。
- [ ] **测量内部知道的事，必须能传到消费方**（2026-09-28）：`measure` 早就算得出"这次遍历被权限截断过"，
      但那个布尔只活在 `incompleteWalks` 里给缓存写入用，用完就 `remove`。结果下游（删除网关、
      Toast、历史）拿到的只有一个看起来精确的 `Int64`。判据：**任何一个"内部知道不确定、对外只给
      确定值"的中间量，都要在加它的那一刻同时问"谁需要知道这是约数"**。同类坑：`readable` 被算出来
      却没随 size 一起交出去。
      另一条同期教训：`chmod 000` 的子目录会让 `removeItem` **本身失败**（枚举不出内容就删不掉），
      所以"测完再解除权限锁然后删"才是可跑的夹具顺序；先删后测的写法只会得到"1 项删除失败"。
- [ ] **改"结果播报"之前先数这句话有几个副本**（2026-09-29）：清理完成那句「释放 X」不是逻辑错而是**动词错**——
      G3 默认把文件移进废纸篓，而同卷 `trashItem` 只是一次 rename，磁盘可用量一分没动
      （本机实测 200 MiB：同卷 rename 后 `volumeAvailableCapacityForImportantUsage` Δ = 0 MiB，
      `removeItem` 后 Δ = +200 MiB），可这句话在 19 处各自手抄了一遍
      （`grep -rnE "(outcome|res|result)\.(freedBytes|releasedBytes)" --include=*.swift Sources/MacClean | grep 释放`）。
      副本 > 1 就别逐处补文案：把动词收进一个构造器（本轮 `SpaceDisposition.claim()`），
      再立一条源码 lint 挡住"第 7 份长回来"。lint **必须自带反向绊线**——喂一段合成违规源码，
      抓不到就说明判据已经死了；另一侧还要有**接线数下界**（`space.claim()` 的调用点数只许变多），
      否则"全部收口"会变成"全部没人用"。
- [ ] **不许把唯一能证伪自己的那一列观测夹平**（2026-09-29）：结果弹窗顶部写「本次释放 +X」，
      同一屏下面的"可用空间前后对比"本可以反驳它，但代码是 `let after = max(before, snapshot.afterAvailable)`
      ——可用空间**永不显示下降**。夹子的动机多半是好意（怕别的程序把盘写满时用户以为清理工具搞坏了），
      但后果是顶部那句话在界面上再没有任何反证。判据：凡是"同一屏两处互相印证"的量，
      只要有一处被 `max/min/clamp` 夹过，就当场问一句"另一处还能不能证伪它"。
      本轮的修法是把差值算术抽成纯函数（`availableDeltaBytes` 可为负 → 自检直接断言 `-10 GB`），
      再用一条字面形状 lint 钉住 `max(before, snapshot.afterAvailable)` 不许回来。
- [ ] **给"只有渲染才看得见"的东西写断言之前，先测这条断言会不会把整条套件带崩**（2026-09-29）：
      本轮在 `Selftest+DeletionGate` 里给 `CleanResultSheet` 加了一条
      `inspect().findAll(ViewType.Text.self)` 断言，实测触发
      `Swift/arm64e-apple-macos.swiftinterface:3272: Fatal error: Can't unsafeBitCast between types of different sizes`
      → 子进程 exit=5 → **该套件 34 条本来通过的断言整体不计**，全量通过数 682 → 654。
      一条本想防假绿的断言，制造了比它守的洞更大的盲区。这**不是** §0.2 那批"按钮/勾选框枚举失效"
      （那类是抛异常、单条红），而是渲染某个视图直接崩进程。判据：加任何 ViewInspector 断言之前，
      先在未变异的树上跑全量、对比"通过数 + 失败名集 + 未执行套件名集"三样；
      只要未执行套件多了一个，就把这条改成「纯函数断言 + 源码接线断言」两条腿。
- [ ] **自检里别留墙钟上界断言**（2026-09-28）：`卸载器：已安装 App 清单并行取体积` 原来是
      `elapsed < 5.0`。它守的两件事——"别退回串行""别每条目重扫一次"——都是**结构**性质的，
      用时间当代理就会在别人的 App 占 CPU 时翻红（实测两次全量跑 34/35 条失败之差就是它）。
      发版门禁现在按失败名集与基线逐条比对，**假红＝拦下发版**，代价比漏报更高。
      已改成结构判据（按大括号深度截 `scanApps` 函数体，要求 `concurrentPerform(iterations:` 在场、
      且求体积调用只出现在并行区内恰好一次），耗时改为只打印不断言；变异（换成 `paths.indices.forEach`
      这种形状等价的串行写法）实测判红。凡是"计时哨兵"，先问一句：它守的是时间还是结构？
- [ ] **备案的粒度必须等于风险的粒度：按文件备案 = 那个文件对该规则永久失明**（2026-10-01，`reviewer-r2` P0）：
      上一轮把"abs 一类不许备案"落成"不许通配 + 必须带 `evidence=<动过该文件的提交>`"，看起来已经
      把豁免面收窄到"具体文件 + 具体提交"。但脱敏扫描的命中单位是**一行内容**，而备案的单位是
      `(scope, file, rule)` —— 粒度不一致，于是豁免面比检测面大：`Sources/f.swift` 里只要有一行
      合法夹具备案过 `private_key`，后来往同一个文件贴一把真 OPENSSH 私钥照样放行
      （`r2` 一次性仓库实测 `rc=0`、打印"✅ 扫描通过"、夹具全绿）。
      现在 abs 一档的 reason 必须**同时**带 `evidence=` 与命中处打印的 `matchsha=<sha1 前 12 位>`：
      **按内容钉**。非 abs 一档写了 `matchsha=` 也按内容钉，没写则退回按文件（既有行仍可用）。
      两个配套细节：
      ① 表里存**指纹**而不是原文——这张表自己也在扫描范围内，抄凭据字面量会让"解释为什么这行是假的"
        那段话自己成为 abs 命中，而 abs 要求"证据提交动过该文件"、新文件不在任何提交里 → 自我死锁；
      ② 未备案命中现在直接打印 `备案需 matchsha=…`，人不用自己算，但也**不能**靠它批量放行：
        每一串都要单独判断凭什么假。
      判据：写任何"豁免/白名单/跳过"机制时，先把**单位的定义**写在注释里（这次按什么豁免？
      文件？行？内容？提交？），再问"这个单位以内还能塞进来多少东西"。
- [ ] **审查者报的"造不出夹具"要逐条复验，不能顺手推广**（2026-10-01）：
      我自己写过"探针那个 die 分支本机造不出可达状态"，`r2` 用一个**跟踪文件全空**的一次性仓库
      就打到了（自测 T29）。同一轮里 `scan_history` 的"有提交而索引为空"确实造不出（每个提交都有正文）。
      判据：一个"不可测"的结论只对它自己那条分支有效；要推广就得为每条分支单独论证一次。
- [ ] **`git grep` 的两个分支要各自有夹具，`--cached` 的语义要造差分才测得到**（2026-10-01，`r2` P1）：
      树侧扫描有工作区档与索引档（`--cached`）。以前所有 `--staged` 用例的内容**同时存在于工作区**，
      于是把 `--cached` 整个去掉也全绿——四条用例其实都在测同一条路径。补的这条是差分夹具：
      先提交干净内容，再把凭据只写进工作区（不 `git add`）→ `--staged` 必须放行、工作区档必须判红
      （自测 T28/T28b）。同一族还有一条：默认档"扫哪些文件"没人守（给非 `--cached` 那支加
      `-- Sources` 仍全绿，而活性探针照样打印"255 个文件搜过"——它数的是文件数，不是范围）。
      判据：**活性证据只能证明命令跑过，不能证明覆盖面**；范围要单独用"种在范围外"的用例守。
- [ ] **门禁类的脚本必须能被夹具反向验证，而且"非零退出码"不等于"拦住了"**（2026-10-01）：
      `scripts/release.sh` 的脱敏扫描此前完全不可测——它只能扫自己的仓库，于是"能不能拦住真凭据"
      全靠读代码相信。现在有了 `--scan-only [--staged]` 入口 + `scripts/scan-selftest.sh`
      （往一次性 git 仓库里种 38 条"该拦 / 该放 / 该中止"的形状，逐条带**归因**参数）。踩到的两件事：
      ① `expect` 最初只看退出码，而**扫描器自己执行失败**（pathspec 指向不存在的目录 →
        `git grep` 以 128 退出）也是非零码，于是"坏了"被当成"拦住了"，测试全绿而门禁是空的。
        现在要求日志里必须出现未备案命中的标记才算拦住。
      ② 自测的临时仓库骨架必须与真仓库**同构**（`Resources`/`Package.swift` 等 pathspec 点名的
        路径都要在），否则测的是一条真发版永远不会走的路径。
- [ ] **写夹具之前先问"它和判据有判别力吗"——等价夹具会造出永久假幸存的断言**（2026-10-01）：
      本轮把"一眼假"从判整行改成判匹配片段，配了断言，然后变异验证（把判据改回判整行）**两轮都全绿**。
      原因不在判据，在夹具：我种的是 `let x = "ghp_…" // test 环境里顺手写的`，
      而 `fixture_shape` 认的是 `test[_-]?(key|token|secret)`——那行注释根本不命中，
      于是"判整行"与"判片段"在它身上**行为完全等价**，断言永远不可能红。
      换成 `let testToken = "ghp_…"`（整行命中、片段不命中）才真正区分两种实现。
      判据：**每条断言都要能说清"哪种错误实现会让它红"**；说不清就是假断言，
      而唯一能发现这件事的手段就是变异验证——它这轮抓出两条假幸存（另一条见下条）。
- [ ] **「判整行」与「判片段」只在单侧可判别：匹配片段永远是其行的子串**（2026-10-01，自己复核出来的第二层）：
      承接上一条。当天为了"对称"又补了一条镜像用例（行里不含占位词、片段含 `PLACEHOLDER`），
      以为它能挡住"把判据放宽成全部阻断"。其实它**从构造上就不可能有判别力**：
      片段 ⊆ 整行，所以 `fixture_shape(片段) ⇒ fixture_shape(整行)`，
      "片段自证为假"这一侧两种判据**恒等**；能区分的只有反方向（行含占位词、片段不含）。
      那条镜像用例已删，原来的阴性对照降级为"别过度阻断"对照并在注释里写明它守不到什么。
      判据：想给判据配"正反一对"夹具之前，先算一下**这两个方向是不是真的互逆**——
      如果一侧是另一侧的蕴含关系，那"对称"只是看起来对称，多出来的夹具是死的。
- [ ] **夹具"红的原因"必须与被测的那一条对应，否则它是噪声、还会掩盖真信号**（2026-10-01，变异矩阵实测）：
      `MC_SCAN_SELFTEST` 那道"必须与 `MC_REPO_DIR` 成对"的闸当时写在 step 1，
      而它前面的"现场核查"要求当前目录是 git 仓库。夹具自测在**复制目录**里跑（变异验证用），
      那个目录不是仓库 → 脚本先死在"不是 git 仓库" → T33 在**每一次**运行里都是红的，
      与有没有变异无关。后果有两层：①基线不自洁，"结果: 36 通过 / 2 失败"这种数字没人当真；
      ②真正该归因到 T33 的那个变异（把成对判据拆掉）跑出来**也只多一条同样的红**，
      分不出是不是它干的——判红被降级成噪声。修法：把那道闸提到参数解析处（与它同族的
      `MC_REPO_DIR` 判据并排），T33 才变成只在拆闸时变红的可用信号。
      判据：任何"环境/前置条件"类断言都要问一句"它在**复制/降级/离线**的跑法里还成立吗"；
      基线里就红的不叫断言，叫常亮告警，必须当场消掉或改成条件断言。
- [ ] **一条断言只能守一条规则；夹具的副作用会吞掉别的用例**（2026-10-01）：
      给门禁写自测时，四条"该拦住"的用例里有三条其实是**空断言**——它们之所以红绿分明，
      是另一条保护顺手兜住的，不是它自己声称的那条规则在起作用：
      ① 备案规则有树侧与历史侧两套代码，而**已提交且仍留在工作区的文件会被两条同时看到**，
        于是"测历史备案"的用例被树侧的未备案命中兜住（改法：测历史侧要把文件从工作区删掉，
        测树侧用 `--staged` 且不提交）；
      ② "abs 不接受通配备案"与"备案必须带合法 evidence"叠在同一形状上，去掉前者仍全绿
        （改法：给通配那条用例配一份**证据合法**的备案，让只剩通配规则能拦它）；
      ③ 反过来也有**永远轮不到**的检查：`evidence` 的十六进制校验挡在 `git cat-file` 之后，
        任何非十六进制值在前一步就已经失败——这种分支不可能有判红的用例，直接删掉它。
      判据：每加一条"该拦住"的断言，就问一句"把哪一处实现改坏会让**它**变红"；答不上来就是空断言。
      另一条同期教训：`mk_repo` 里多加一次骨架提交，会让后面所有"git add -A && git commit"
      变成空提交（nothing to commit），两条种在提交正文里的夹具**根本没进历史**却仍被判为
      "没拦住=通过"——夹具改动必须回看它对其它用例的前置影响。
- [ ] **自测驱动被测脚本 = 递归；结构性改动后要核对主流程有没有被弄丢**（2026-10-01）：
      `release.sh` 现在每轮先跑 `scan-selftest.sh`，而自测的 T11 又会反过来驱动 `release.sh`
      （验证 `--skip-scan` 真会中止）——没有标记就是无限递归，实测刷出 **363 个临时仓库 / 566 MB**。
      现在两边各有一道：自测 `export MC_SCAN_SELFTEST=1`，`release.sh` 见到就不回调。
      同一轮把 `--scan-only` 入口挪到"现场核查"之前时，顺手把主流程的 `run_scan` 调用**弄丢了**
      （扫描一次不跑、"✅ 扫描通过"照打、提交照走）。现在 `run_scan` 自己置位 `SCAN_RAN=1`，
      提交步骤开头 `[ "${SCAN_RAN}" = 1 ] || die`——检查器有没有被执行不能靠读代码相信。
- [ ] **zsh 的 nomatch 会让整条 `rm a.* b.*` 不执行**（2026-10-01）：清理上面那堆临时目录时，
      `rm -rf macclean-scan-selftest.* macclean-release.*` 因为后一个 glob 无匹配而**整条中止**，
      后面的 `wc -l` 却照样报出旧数字，看起来像"删了没删干净"。判据：清理类命令要么只写存在的
      glob，要么 `find -name -print0 | xargs -0 rm -rf`，并且**用第二条命令独立复核剩余数量**。
- [ ] **"0 命中"必须先自证扫描器真的跑过——macOS 自带 bash 3.2 展开空数组就是一次不跑**（2026-10-01，本轮 P0）：
      把扫描范围从"点名五个路径"改成"全部跟踪文件"时，留了个 `TREE_PATHS=()` 占位数组并用
      `"${cached[@]}"` 拼进 `git grep`。bash 3.2 在 `set -u` 下展开**空**数组直接报
      `unbound variable`，命令替换失败、`git grep` 一次都没执行；退出码 1 落在"没命中"那一档，
      于是扫描器安静地看过 0 个文件，然后打印 **"✅ 扫描通过"**。三条教训：
      ① `git grep`/`grep` 这类"退出码 1 = 没找到"的命令，**不能把非零一律当失败，也不能把 1 一律当干净**
        ——必须先有一次必然命中的探测（现在用 `-e '[[:print:]]'`，与凭据规则走同一条命令、同一套 argv 构造），
        探针为空就 `die`，而不是继续往下判；
      ② 修好之后立刻显形 5 条此前被挡住的真命中（备案表自己、自测脚本自己）——**门禁坏了的时候，
        "仓库很干净"这个结论整条作废**，不能拿它当"那轮没引入问题"的证据；
      ③ 那个"留着好加排除项"的空数组就是事故本体，删掉；不要为想象中的将来留未接线的变量。
- [ ] **"拦住了"必须归因到具体哪一侧拦的，否则另一侧兜底会把这条测成空断言**（2026-10-01）：
      树侧坏掉那轮，16 条夹具**全绿**——种在已提交文件里的命中全被历史侧兜住了。现在 `expect`
      多一个参数：拦住它的必须是 `未备案 tree` 还是 `未备案 hist`，找不到就判红。配套补了两条独占用例：
      T15（凭据**只在未提交工作区**，历史侧结构上够不到 → 树侧坏掉它必红）、
      T1c/T9/T10b/T13（`--staged` 分支根本不跑历史侧）。判据同 §"一条断言只能守一条规则"，
      但方向不同：那条讲夹具之间互相掩盖，这条讲**同一份内容被两套实现重复覆盖**。
- [ ] **备案表自己也在扫描范围内；abs 一档"证据提交必须动过该文件"会让新文件永远补不齐证据**（2026-10-01，复审 P1）：
      `scripts/secrets-allowlist.txt` 的理由文本里原样抄过一次 PEM 头（为了说明"只有头、无密钥体"），
      `scripts/scan-selftest.sh` 的 `frag_pem()` 把同一个头写成字面量——两处都在 `scripts/` 下，
      于是**用来解释"这行不是凭据"的那张表自己成了未备案命中**；而 abs 一档要求
      `evidence=<提交>` 且该提交动过这个文件，新脚本此刻不在任何提交里 → 证据永远凑不齐 = 门禁把自己锁死。
      规矩：备案理由只**描述**形状（"ghp_ 之后 40 个字符是 `1234567890` 循环拼接"），不贴原文；
      夹具字符串一律分段拼（`printf '-----%s %s %s-----' "BEGIN RSA" "PRIVATE" "KEY"`）。
      同类：`tree` 档两行的 evidence 写的是文件**挪动前**的提交，`git log --all -- <新路径>` 查不到 →
      下一次真发版必红（复审实测 BLOCKED）。加备案前先跑一次 `git log --all --format=%h -- <那个路径>`。
- [ ] **`x="$(grep -oE … | head -1)"` 的真错不是崩，是"只审第一个片段"**（2026-10-01，两轮复审各抓一半）：
      `matched_fragment` 取"第一个匹配片段"用了 `grep -oE | head -1`。第一轮按 P2 记的原因是
      "同一行两处命中时 `head` 提前收管道 → `grep` 收到 SIGPIPE → pipefail 让整条管道非零 →
      裸赋值在 `set -e` 下当场退出"。
      > **`r2` 复验更正**：那条**复现不出来**（`r2` 在本机 bash 3.2 上同一行放两处命中，rc=0）。
      > 原因是管道缓冲：输出小于一块缓冲时 `grep` 早就写完并正常退出，压根收不到 SIGPIPE。
      > 所以那句"实测 exit=1、零输出"是**我把结构风险写成了已观测事实**——判据：
      > 与缓冲时机/调度有关的故障，要标明"条件性"，不能报成确定性事故。
      > （`RELEASE-CHECKLIST` 顶部那条"构建被打断的假死"是另一族，那条是真复现过的。）
      **真正要紧的后果是语义层的**（`r2` 实测到）：只把**第一个**片段交给"一眼假"，
      同一行里"一个自证假的占位串 + 一个真 key"只要占位串排在前面，整行就被放行——
      实测 `rc=0`，发版标题那一档同样中招。等于把这一轮刚修的"判整行"换成了"判第一个片段"，
      豁免面只是换了个形状。
      判据：`grep -o` 的输出一律**逐条**过审（`while read` 全量），任何一处不自证为假就记账；
      写"取第一个"的助手函数之前先问"第二个怎么办"。顺带这一版不再需要 `|| true`，
      SIGPIPE 那一族风险也一起消失。
- [ ] **"没扫"与"没有历史"必须可区分：给历史侧一个提交数阳性对照**（2026-10-01，复审 P2）：
      旧写法 `if [ ! -s "${HIST_INDEX}" ]; then echo "（无历史可扫）"; return; fi`，而 `build_hist_index`
      的 git 错误被 `2>/dev/null` 吞掉——detached HEAD、git 失败、awk 崩掉全都长得像"这个仓库很干净"。
      现在先取 `git rev-list --count --all`：**有提交而索引为空** → `die`（扫描器坏了），
      **无提交而索引非空** → 也 `die`（两条判据自相矛盾，不猜哪边对）；git 的 stderr 落 `${HIST_ERR}` 并回显。
      同一族的还有 `--skip-scan` 那条：非零退出码、空输出、静默 return 这三种"看起来像安全"的状态，
      必须各自有一句能判红的断言。
- [ ] **脱敏扫描有第三个对象：即将写进 commit 正文、annotated tag 说明和 Release 标题的那个字符串**（2026-10-01，复审 P1）：
      工作区和历史都扫过，但发版流程最后一次扫描发生在 `git commit`/`git tag` **之前**，
      所以凭据写进 `TITLE` 会随本轮 tag 直接推出去、下一轮才红。现在 `scan_text title "${TITLE}"`
      接进 `run_scan`，并且这一档**不接受备案**（备案表的立论是"仓库里有一行必须长得像凭据的夹具，
      由某个提交证明它是假的"；标题不是文件，没有任何证据能为它开脱，只能改标题）。
      入口用 `MC_SCAN_TEXT` 让夹具走同一条代码路径（T16），再加一条接线判据（T16b）。
- [ ] **结构性（grep 源码）判据必须锚行首，否则把那一行注释掉就变异存活**（2026-10-01）：
      T12/T16b/T17 这类"主流程到底有没有调用它"的判据只能 grep 源码，而只 grep 子串时
      `# SCAN_INDEX=1 scan_tree` 依然匹配——实测两条注释形态（`# x` 与 `#x`）都存活。
      改成 `^[[:space:]]*SCAN_INDEX=1[[:space:]]+scan_tree` / `^[^#]*git rev-list`。
      还要在注释里写明它是**结构性**判据、不是行为验证，别让它冒充夹具：
      `scan_history` 的"有提交但索引为空 → die"这一分支本机造不出可达状态（每个提交都有正文，
      正常仓库不会索引为空），所以只有结构性判据守着，行为变异 MU-HISTGUARD2 永久存活——这条要如实写出来。
      > **同日 `reviewer-r2` 更正**：这个"造不出"的结论**只对 `scan_history` 那一支成立**。
      > 同一族的活性探针那一支是能造夹具的——把一次性仓库的跟踪文件**全部置空**，
      > `git grep` 对"任何非空行"就返回 0 命中，探针必须中止（自测 T29 实测到）。
      > 我原来把两处混为一谈，等于给探针的 die 分支留了一个零断言的保护（改坏不判红）。
      > 判据：**"造不出可达状态"是每个分支各自的结论**，不能从一个分支推广到同族的其他分支。
      > 同一轮 `r2` 还抓到结构性判据的第二个洞：只 grep 形状不够——把 staged 复扫**挪到 `git add` 之前**、
      > 把 `scan_text title "${TITLE}"` **接错成 `${VERSION}`**、删掉 `SCAN_RAN` 的 die，三种错法当时都不判红。
      > 现在 T12 比行号、T16b 带上被插值的变量名、T20 两头齐全；但仍然要在注释里承认
      > "比行号"也只是结构判据，不是行为验证。
- [ ] **`FileManager.enumerator` 少写 `errorHandler` 是求体积/清单的谎报形状**：`nil` 的语义是
      "第一个错误就停止遍历且不报告"，于是"有一半没读到"与"真的就这么大"结果一样（实测一个含
      mode 000 子目录的树返回 **0**）；Foundation 里**省略 `errorHandler:` 参数与传 `nil` 语义相同**。
      这一类现在由两条 lint 按**调用点**管（括号配对截参数段，不是"整文件出现过 errorHandler"——
      那种查法会被同文件另一处合规背书）：① `enumerator(at:)` 必须带 errorHandler；
      ② `enumerator(atPath:)` **整类禁用**。②是 v1.73.10 之后这轮补的：`atPath` 重载**没有**
      `errorHandler` 参数，实测它对被拒子树"返回合法枚举器 + 静默跳过 + 不报任何错"
      （mode 000 的 `nested/` 里的 .ips 从未出现，issues 一条不加），所以老 lint 那句"要求 nil 分支
      上报 unreadable"盯的是**错的失效模式**——`DiagnosticReportScanner:105` 在它眼皮底下谎报了三个版本。
      **2026-09-28 实测**：产品源码里省略 errorHandler 的调用点 **0 处**、`atPath` 调用点 **0 处**
      （此处原文写的"另有 5 处"是过期断言，已按实测更正；再核一遍用上面那个按调用点的查法）。
- [ ] **归还并发额度要"占几条还几条"，且"已恢复"的守卫必须看满额**：自检投放 N 条卡在信号量上的
      body 却只 `signal()` 一次，就有 N-1 分令牌在本进程剩余 lifetime 内永久消失，后面所有门禁读取
      静默退化成"本轮没顾上"。更阴的是自带的那句"额度未归还"守卫——它只要还剩 1 分可用就通过，
      而那 1 分往往正是本条自己要用的，等于对自身造成的损害恒不可见。v1.73.4 就是这样一次抓出了
      **上一轮已发版**代码里的两处同类泄漏。
- [ ] **`A || B` 式的"标识符存在性"断言是假断言**：写成 `scope.contains("isScanning")
      || scope.contains("isProcessing")` 之后，实现把守卫挂到错误的那个标识符上（截图卡片把
      "正在读取"挂在只在清理/归档时才为真的 `isProcessing` 上，于是那支成了死代码）断言照样绿。
      要钉就钉**具体那一个**，别写或集。
- [ ] **一处防御有两条例径时，变异要同时改回两条**：归档面板的"读不到"既由有截止的探测拦、
      也由"枚举器返回 nil"那支兜。只回退其中一条，自检照样绿——那不代表断言是假的，
      但也不代表它钉住了本轮的改动。写变异前先问：这条性质有几条实现路径？
- [ ] **"计时一段代码 ÷ 基准"的比率断言，必须另钉一条"这段代码确实干了活"**：
      `盲区探测开销 / 体积测算 < 0.5` 在探测被开头的 guard 直接 early-return 之后照样成立
      ——分子≈0，比值永远漂亮，是一条只会点头的假绿。补的正确性断言用最朴素的反例：
      mode 000 的目录必须被记进盲区清单。
- [ ] **会卡死在内核里的读取，超时后那条线程收不回来**，于是三条连带约束：
      ① 同一目录**一轮只试一次**（`wedgedReads`），否则每轮扫描多漏一条死线程；
      ② 超时的返回值必须与"读到空"分得开（`nil` vs `[]`），否则"没等到"就地变成"没东西"，
      正是 G9 一路在消灭的那个失败模式；
      ③ **不要**给 `children(of:)` 这类热路径统一加截止——它在递归遍历里被调用成千上万次，
      每次跳一趟线程等一趟信号量，会把扫描本身变成瓶颈。只在可能被 TCC 拦住的家目录根
      （下载/文稿/桌面/影片）上加 `childrenBounded` / `canOpenDirectoryBounded`。
- [ ] **验证"永不返回"要传真的会卡死的 body，不要传假返回值**：自检给截止包装函数塞一个
      没人 `signal` 的 `DispatchSemaphore`，测的是"外面那层兜没兜住"；若改成注入一个假的
      阻塞替身，测到的就是替身本身。另：门禁根用了哪一次读取只能靠源码形状字符串钉，
      重命名 `childrenBounded` / 挪动空白都会撞红——改名时把这条一并同步。

## 2. 功能冒烟（手动）
- [ ] 6 大分类均可扫描出结果
- [ ] 勾选 → 清理 → 确认弹窗 → 移入废纸篓链路可用
- [ ] App 卸载器：选 App → 关联文件列表 → 移入废纸篓
- [ ] 清理历史有记录、可清空
- [ ] AI 面板：设置（baseURL/Key/模型）→ 连通性测试 → ✨ 提问 → 回答

## 3. 安全护栏
- [ ] 无新增危险路径（对照 CLEANUP-RULES.md G1–G19）
- [ ] **治理模块内不得出现裸删除调用**（G14）：`grep -rn 'FileManager\.default\.\(removeItem\|trashItem\)\|fm\.\(removeItem\|trashItem\)' Sources/MacClean --exclude-dir=Selftests`
      命中只允许在：① `ResidueDeletionGate` 自己；② `Cleaner`（分类主链路，自带 `isSafeToClean` 与历史/撤销记账）；
      ③ `SpaceArchiveService`（归档后校验完整性才移走原件）；④ `LaunchAgentManager`（只删本 App 自己写的那一个 plist）；
      ⑤ 应用自身状态文件（`AIService` 旧密钥文件、`FileFingerprintCache` 缓存）。
      **任何"扫出候选项再删"的模块出现在名单外，就是又有人绕开了门**——v1.73.0 补掉的两个
      （`DevProjectScanner`、`PreferenceResidueInspector`）正是 v1.72.0 那轮漏的，后者当时连
      `isSafeToClean` 都没调，白名单与 G6/G8 对它完全失效。
      同一条判据还看**调用方有没有偷偷传 `journal: .none`**：那等于把刚接上的历史与撤销又关掉。
      **这条 grep 不是穷举**：`fm\.` 只匹配名为 `fm` 的局部变量，换个名字
      （`let mgr = FileManager.default; mgr.removeItem(...)`）就扫不到，所以它替代不了
      模块自己的源码接线断言（目前只有 5 个模块有：开发工程产物、偏好碎片、ColorSync、
      打印机驱动、音频 HAL）。
- [ ] **网关的记账不再自带锁，也别把 `journalLock` 加回来**（v1.73.2 变更）：
      `ResidueDeletionGate.record` 里的 `HistoryStore.load() → insert → save()` 已换成
      `HistoryStore.append(record)` + `UndoManagerStore.record(session:)`，串行化下沉到两个存储
      各自的 `transactionLock`。v1.73.0 那把它叫 `journalLock` 放在调用方一层，是因为当时
      存储层还没有原子入口——现在有了，调用方再套一层只会把"唯一入口"的论证重新污染成"两层锁"。
      **已知残余**（不要再当作已修）：① 一条记录与它的快照不在同一个临界区，中途进程被终止会
      留下"有历史行、无快照"的记录，界面按"无快照就不给放回按钮"降级；② 见下一条的跨进程限制。
- [ ] **进程内锁不等于跨进程互斥**：`LaunchAgentManager` 装的 plist 里 `ProgramArguments` 是
      `[<binary>, "--autoclean"]` 且**没有** `EnvironmentVariables`，所以 launchd 拉起的无头进程
      与 GUI 用的是**同一份** `history.json` / `undo_sessions.json`。两把 `NSLock` 互不相干，
      `try? data.write(options: .atomic)` 的语义就是 last-writer-wins → **跨进程仍会丢记录**。
      本轮（v1.73.2）消除的是"陈旧内存缓存整片覆盖"这个确定性丢数据，跨进程只收窄成窄窗口。
      要真做成互斥得上 `flock`/`NSFileCoordinator`，或明确记为已知残余风险——二选一，别默认没事。
- [ ] **改动任何"默认值"（默认勾选 / 默认档位 / 默认策略）时**：先查清有哪些地方
      **读这个值来决定要不要动手**。v1.72.10 给 T0 加预勾后，菜单栏「快速安全清理」的
      "把合格的补勾上 → 清理所有已选"就顺带把预勾项全删了——包括它自己门槛要排除的
      "近期还有写入"的项。自动动手的范围必须由那段逻辑自己重算，不能继承上游默认值。
- [ ] **新增"主动打开别人 App 的位置"的探测时**：确认它在**无人值守路径**里是关掉的。
      macOS 的「想访问其他 App 的数据」是**模态**对话框，`DiskMonitor`（每 3 h 自动扫一轮）
      与 `AutoCleanService` 都没人点，会直接挂住整轮扫描。
      判据见 `FileSystem.proactiveBlindSpotProbe`；每个扫描入口都要在开工时显式设一次，
      不要依赖上一轮留下的值。
- [ ] **"读不到"类判定不能只等遍历顺手报错**：`measure(at:)` 的跨会话增量指纹缓存只看
      目录自身的 `lstat`，一次被权限挡住的 0 字节会被永久复用成"干净"。
      要显式探测（`FileSystem.canOpenDirectory`），且**不要用 `access(R_OK)`**——
      TCC 是在**打开**那一刻才拒绝的，`access` 只看 Unix 权限位，正好漏掉这一整类。
- [ ] **性能比值断言要先确认分母没被缓存打空**：v1.72.11 第一条跑出来是"探测 5.13 倍于测算"，
      实际是分母命中了 `measure` 的两级缓存、变成空调用；计时前先 `invalidateMeasurements`
      之后真实比值 0.02。任何"新增 I/O 相对既有工作有多贵"的断言都适用这条。
- [ ] 新增"受限放行"时确认：**只放行具体路径/具名模式，未放行整个父目录**（G10）
- [ ] 新增路径判定时**未使用 `standardizingPath`**——其行为依赖路径是否真实存在
      （`/private/var/db` 存在则被改成 `/var/db`，虚构路径则不变），
      会使同一目录出现两种形态导致判定失效。改用 `FileSystem.normalizePath`
- [ ] 往 `CleanPaths` 的护栏清单（`hardExclude` / `systemProtected` / 放行根）加条目时，
      **清单必须是进程内不变量**：闸门为省开销把它们预归一化缓存在 `FileSystem` 的
      `static let`（`GuardPath`，v1.72.4），运行时改内容不会生效。
      需要运行时增删的判据请走 `GovernanceDomain.register(_:)`（它会置脏 `cachedAll`），
      不要自己再抄一份"每次遍历常量数组"的判定
- [ ] 新增 `~` 相关路径处理时注意：`CleanPaths.expand` **只认前缀 `~`**
      （v1.72.4 之前会把路径中间的 `~` 也换成主目录，导致护栏比对一条不存在的路径）
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
