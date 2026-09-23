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
      macOS 管道缓冲区只有约 64 KB，先 wait 后读会双向死锁
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
- [ ] **网关的记账是"读—改—写"，必须整段串行**：`ResidueDeletionGate.record` 里
      `HistoryStore.load() → insert → save()` 三步之间没有锁保护就等于没有——并发清理时
      后写者把前一个的记录整份覆盖，用户刚清掉的一项既进不了历史也没有撤销快照，
      而界面上 `cleanedCount` 完全正常。`UndoManagerStore` 内部的锁只包住单次 load/save，
      包不住中间那步 insert，所以串行化要放在调用方这一层（`journalLock`）。
      其余 4 个非网关写入口（AppState、AutoCleanService、下载/截图归档、硬链接去重）
      **仍是各自的读改写**，尚未收口。
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
