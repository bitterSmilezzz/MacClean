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
- [ ] **两种构建模式都要验**（v1.72.2 起自检代码不进发布产物）：
      ① 开发构建 `swift build` 必须含自检，`--selftest` 全绿；
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
- [ ] **给 lint 立"命中数下界"时要连"允许为 0 的场景"一起想清楚**：v1.73.7 的两条新 lint 都
      加了 `matched >= 1` / `checkedSites >= 3` 的活性证据，是因为上一轮踩过"匹配 0 处 = 空集
      恒真通过"的坑；但下界设太高会挡掉合理的重构（比如某天把 `DiagnosticReportScanner`
      换成 URL 重载，全仓就没有 atPath 了）。**判据**：下界只要挡住"匹配逻辑退化"就够，
      别拿它当"这条模式必须永远存在"的口号——真消失了就删掉这条 lint 并写清理由，
      比让 lint 变成永远需要豁免要诚实。
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
- [ ] **`FileManager.enumerator(..., errorHandler: nil)` 是求体积的谎报形状**：`nil` 的语义是
      "第一个错误就停止遍历且不报告"，于是"有一半没读到"与"真的就这么大"结果一样（实测一个含
      mode 000 子目录的树返回 **0**）。已有一条 lint 钉住 `errorHandler:nil` / `{_,_ in false}` 两种字面量，但**钉不住整个类别**：Foundation 里省略 `errorHandler:` 参数语义完全相同，当前产品源码另有 5 处就是这么写的。别把那条 lint 的绿色读成「求体积已收口」。
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
- [ ] 无新增危险路径（对照 CLEANUP-RULES.md G1–G17）
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
