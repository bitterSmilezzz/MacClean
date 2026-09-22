# MacClean 清理规则集合（固化版 v1.2）

> 本文件是 MacClean 的**规则源头文档**：App 内置的扫描/清理逻辑严格对应本集合。
> 修改规则 = 修改此文档 + `Sources/MacClean/Rules/CleanupRules.swift`（规则登记与元数据）
> + `Sources/MacClean/Scanner.swift`（扫描实现），**三处必须同步**。
> `Selftest` 内置一致性校验：规则条数、编号连续性、`ruleRef` 区间都会自动断言。
>
> - v1.0（2026-09-03）：固化 6 大类 23 条规则，来源：本机 agent 会话与《全机安全审计报告》清理经验 + 通用 macOS 清理实践。
> - **v1.1（2026-09-12）**：新增 6 条规则（C7 / L6 / D13 / D14 / D15 / B4），补齐 G8、G9 两条安全护栏；
>   来源：本机全盘深度清理实测（含 4 个并行只读扫描与交叉验证）。
> - **v1.2（2026-09-17）**：**判定模型重构**。原「风险级（safe/review/danger）」由每条规则手写、
>   与另算的「使用频率」互不调和，必然产出「安全 + 频繁使用中」这种自相矛盾的标注。
>   现改为 **本质（`ItemNature`：删了会怎样）× 占用状态（`UseState`：此刻是否在用）
>   → 唯一结论（`Recommendation`）**。同时把原 B4 拆成 B4（下载缓存）/ B5（按需下载的功能组件），
>   修掉"把 WidevineCdm 这类 DRM 组件标成安全"的误判。**当前共 6 大类 53 条规则**
>   （v1.72.9 起；此前 52 条，D19 拆成 D19/D24）。
> - **v1.44.0（2026-09-19）**：新增 L7（CrashReporter 历史崩溃诊断）、A4（Saved Application State 窗口恢复状态）、A5（ByHost 硬件绑定偏好碎片）。

---

## 0. 安全护栏（所有规则必须遵守）

| # | 护栏 | 说明 |
|---|------|------|
| G1 | 只扫用户可写目录 | 不扫描/不清理 `/System`、`/Library`、`/var` 中需要 root 的区域；遇权限不足跳过并提示 |
| G2 | 手动勾选 + 确认（**v1.72.10 起有一条例外**） | 扫描结果默认不勾选；点「清理」前二次确认。**唯一例外**：结论为「确定是垃圾」（规则 v2 的 T0 档）的项扫描后**自动勾上**——它的依据是 OS 契约/结构标记 + 实测占用，换台机器也成立，且宿主在跑或刚被写过时会掉回「使用中」而不再被预勾。`可清理`（依据只是"这类东西通常能重建"）**一律不勾**；二次确认对所有档都保留 |
| G3 | 默认移入废纸篓 | 清理默认 `trash`（可恢复），用户可选「彻底删除」 |
| G4 | **唯一结论（v1.2 重写）** | 每项只带**一个**结论：`可清理` / `使用中` / `需确认` / `勿删`。由 `ItemNature × UseState` 推导，并附一句「为什么」。**不变量：`可清理` 蕴含所属应用未在运行** —— 界面上永远不会再同时出现「可清理」与"刚刚还在写"这类互相打架的组合。v1.72.9 起，档位标签也只显示量到的事（`7 天内有写入`），不再用单个 mtime 宣称"频繁使用" |
| G5 | **在用检测（v1.2 加强）** | 三重证据取并集：① 所属 App 正在运行；② 目录在 10 分钟内被写过；③ 规则本身标记为需确认。① 的匹配集合覆盖 bundle id、本地化名、**CFBundleName**、可执行名与 `.app` 目录名——只比对本地化名会漏掉"目录名英文、App 显示中文"这一大类（实测 Tabbit Browser） |
| G6 | 白名单排除 | 永远不删：`~/Library/Mail`、`~/Library/Keychains`、`~/Library/Accounts`、`~/Library/Messages`、`~/Library/Safari`（书签）、`.ssh`、`.gnupg`；**v1.1 新增**：`~/Library/Group Containers`（应用共享数据）、`~/Library/Mobile Documents`（iCloud）、`~/Library/CloudStorage`（云盘） |
| G7 | 空目录兜底 | 删目录前先确认大小>0 或文件数>0；保留 `.DS_Store` 之外的系统占位 |
| **G8** | **系统级硬保护（v1.1）** | `/System`、`/System/Volumes`、`/Library/Updates`、`/private/var/vm`、`/private/var/db`、`/private/var/folders/zz` 一律不列为可清理项。判据见 §7 |
| **G9** | **TCC 权限显式判定（v1.1）** | 受隐私保护目录（`~/.Trash`、照片图库等）读取会返回 `Operation not permitted`。**必须区分「读不到」与「真的空」**，见 §7.2 |
| **G10** | **受限放行原则（v1.1）** | 需要触及常规允许根目录之外的目标时，只能**精确放行到具体路径/具名模式**，禁止放行整个父目录，见 §8 |
| **G11** | **不跟随符号链接（v1.2）** | 判定、遍历、删除三处都不得跟随软链。①`isSafeToClean` 先解析真实位置再判定，末段是软链一律拒绝；②递归遍历用 `isRealDir`（`lstat`）而非 `isDir`（`stat`）；③软链不计体积（删掉它释放 0 字节，不是目标的体积）。**理由**：家目录里放一个指向 `/System` 的软链，任何只看路径字符串的护栏都会被绕过去 |
| **G12** | **校验与删除作用于同一路径（v1.2）** | `Cleaner` 先把路径解析到真实位置，再对**同一个字符串**做校验与删除。若两边各自解析一次，中间被换成软链就出现 TOCTOU 缝隙 |
| **G13** | **读不到 ≠ 很干净（v1.2）** | 扫描根目录存在但不可读时**必须**产出 `ScanIssue` 并在界面明示"结果不完整"，禁止让整类静默变成 0 项。`FileSystem.isPermissionDenied` / `hasFullDiskAccess` 是这条护栏的判定基础 |
| **G14** | **删除只有一个入口（v1.72）** | 任何删除动作都必须经 `ResidueDeletionGate`。主目录**之外**的目标必须先声明所属**治理域**（`GovernanceDomain`：精确根 + 最小层级 + 可选入口名单），由 `FileSystem.governanceVerdict(_:domain:)` 做唯一裁决：软链防跳板 → G8 → G6 → 用户白名单 → 域内且深度足够 → `canUnlink`。<br>**背景**：v1.53–v1.71 的十余个治理模块扫的是 `/Library/Fonts`、`/Library/Printers` 等主目录外位置，而 `isSafeToClean` 的常规允许根只有主目录与临时目录，于是各模块自造 `hasPrefix("/System")` 字符串护栏——**用户白名单与 G6 对它们完全失效**，且软链可绕。现在这些弱护栏一律删除。<br>**永不授权删域根本身**；`/Library/*` 在真机多为 root 只读，网关返回 `needsPrivilege`，UI 必须如实说明"本工具不提权"而不是含糊报"清理失败" |
| **G15** | **子进程必须受控（v1.72）** | 外部命令一律走 `SafeProcess`：① 读端先挂后台排空再等退出（macOS 管道缓冲仅约 64 KB，反序即父子互等死锁）；② 必须有超时（TERM→KILL）；③ 启动失败绝不 `waitUntilExit()`（在未启动的 `Process` 上调用会抛异常崩溃）；④ 命令可用性先 `isAvailable` 判定，**没执行就不算成功**。自检经 `SafeProcess.runner` 注入，断言命令与参数而不真改系统状态 |
| **G16** | **孤儿判定必须有正向证据（v1.72）** | "宿主已卸载"这类结论只能来自**可信清单**。`AppInventory.current()` 除集合外还导出 `unreadableRoots` / `isComplete`：根目录读不到时集合会是空的，若照旧比对"不在清单里 = 孤儿"，一次权限失败就会让**全盘残存一夜之间全成孤儿**。清单不可信时一律降级"需确认"，绝不默认勾选（`OrphanScanner.isInstalledOrProtected` 顶部即此守卫） |
| **G17** | **永不归属词元表（v1.72.7，规则 v2 步骤 2）** | `CleanupRules.neverAttributionTokens` 是一份"看着像某个 app 的残留、其实是系统级或多 app 共享状态"的名字表（`MobileSync` iOS 备份、`Knowledge` 系统知识库、`CrashReporter` 取证材料、`swiftpm`/`clang`/`symbols` 工具链状态、`sparkle`/`sentry`/`keystone` 更新与崩溃 SDK…）。命中即**不得判为孤儿**。归属在这里只用于**排除**，不用于**准入**。必须早于"申请 FDA"落地：这些目录现在多数读不到（`size == 0` 被自然跳过），一旦授予 FDA 就全部可读，届时没有这张表就会把 iOS 备份当成残留列出来。依据：Pearcleaner 的 `skipReverse`（约 200 词元）+ 本仓库 A/B 实测（表里误放 `shipit` 时，App 残留被从 10 项压成 1 项，与 L6 的 `.ShipIt.` = T0 直接冲突） |

---

## 1. 用户缓存 `~/Library/Caches`

| 规则 | 路径模式 | 条件 | 本质 | 清理方式 |
|------|----------|------|------|----------|
| C1 | `~/Library/Caches/*` | 所有子目录，跳过 G6 白名单与运行中应用 | 可重建缓存 | trash/删除 |
| C2 | `~/Library/Caches/com.apple.dt.Xcode` | Xcode 未运行时 | 可重建缓存 | trash |
| C3 | `~/Library/Caches/pip` / `~/.cache/pip` | 存在 | 可重建缓存 | trash |
| C4 | `~/Library/Caches/Homebrew` | 只收 mtime >120 天的**已完成**下载（对齐 `HOMEBREW_CLEANUP_MAX_AGE_DAYS`）；跳过 `.part/.lock/.downloading`、软链与 `api/` | 可重建缓存 | trash |
| C5 | 浏览器缓存 | `~/Library/Caches/com.apple.Safari`、`com.google.Chrome`、`com.microsoft.Edge`、`com.brave.Browser`、`com.operasoftware.Opera`、`com.vivaldi.Vivaldi` | 可重建缓存 | trash |
| C6 | 沙盒容器缓存 | `~/Library/Containers/*/Data/Library/Caches/*`（跳过运行中应用） | 可重建缓存 | trash |
| **C7** | **应用内旧安装包** | `~/Library/Application Support/*/updates/*.{dmg,pkg,iso}`（**仅列安装包文件本身，不动同目录其余内容**） | 历史产物 | trash |

> **C7 实测依据（v1.1）**：输入法类 App 常把更新包静默下载到 `updates/` 并在安装后不删
> （本机 `QianwenIME/updates/*.dmg` 180 MB）。已安装完成即无用途，属纯冗余。

## 2. 日志与临时文件

| 规则 | 路径模式 | 条件 | 本质 | 清理方式 |
|------|----------|------|------|----------|
| L1 | `~/Library/Logs/*` | 顶层项 | 可重建缓存 | trash |
| L2 | `~/Library/Logs/DiagnosticReports/*` | 崩溃/诊断报告 | 可重建缓存 | trash |
| L3 | `/private/tmp/*`、`/private/var/tmp/*` | 逐子项：**属主==当前用户** 且 mtime 超过 Apple 的 3 天阈值；跳过软链与 socket/FIFO | 历史产物 | trash |
| L4 | `~/Library/TemporaryItems/*` | 逐子项，同 L3；**名字看得出属于某个 App 的一律不列**（自动恢复草稿） | 可重建缓存 | trash |
| L5 | 旋转旧日志 | `~/Library/Logs` 内递归深度 ≤3，`*.log.N` / `*.N.log` / `*.gz` 且 >30 天 | 历史产物 | trash |
| **L6** | **应用更新残留（ShipIt）** | `$TMPDIR/<bundle-id>.ShipIt.<字母数字后缀>`（**仅顶层直接子项**） | 历史产物 | trash |
| **L7** | **CrashReporter 历史崩溃诊断与排查记录** | `~/Library/Application Support/CrashReporter/*` | 超过 30 天的历史崩溃记录 | 历史产物 | trash |

> **L6 实测依据（v1.1）**：Squirrel/ShipIt 自动更新框架在替换 App 后留下旧版本副本，
> 本机清出 **2.24 GB**（DimAgent 657 MB、Vokie 791 MB ×2），零风险。见 §8.1 的放行约束。
>
> **⚠️ 与 L3 的关键区别**：`$TMPDIR`（`/private/var/folders/xx/xxx/T`）与 `/private/tmp` **不是一回事**。
> 实测 `/private/tmp` 中的 3.1 GiB 全部是**当日活跃的构建/agent 工作流产物**（并非垃圾），
> 而 `$TMPDIR` 中的 ShipIt 残留才是真残留。因此 L6 **只认 ShipIt 命名模式**，绝不整体清理 `$TMPDIR`。
>
> **v1.72.9 的呼应**：上面那句"3.1 GiB 全是当日活跃产物、并非垃圾"当时只是观察，没有变成判据——
> L3 依旧把整个 `/private/tmp` 逐子项列成"可清理/需确认"。现在它变成了判据：
> **属主==当前用户**（`sticky(7)`：粘滞目录里删除权来自文件属主，"目录可写"不是）
> **且 mtime 超过 3 天**（Apple 自己清临时目录用的阈值，`confstr(3)` + `dirhelper.plist` 本机已复核）。
> 时间字段只用 mtime：本机实测**读取不更新 atime**，而且判据字段必须是自家扫描不会改动的字段——
> `size(at:)` 要 opendir，在会更新 atime 的卷上，每轮扫描都会把候选项刷成"还在用"，那些项就永远清不掉。
> 实测效果：本机「日志与临时文件」从 **339 项 / 357.6 MB** 降到 **11 项 / 36.1 MB**，
> 剩下的 11 项里 `/private/var/tmp/xcrun_db`、`swift-generated-sources` 这类 3 天没动的项
> 第一次拿到「确定是垃圾」，而 1 小时前刚写的 `mimo-asar`（169.9 MB）不再出现。

## 3. 开发残留（构建产物 / 包管理器缓存 / 工具链）

| 规则 | 路径模式 | 条件 | 本质 | 清理方式 |
|------|----------|------|------|----------|
| D1 | `~/Library/Developer/Xcode/DerivedData/*` | Xcode 未运行 | 需重新生成 | trash |
| D2 | `~/Library/Developer/Xcode/Archives/*` | 超过 90 天的归档 | 用户数据 | trash |
| D3 | `~/Library/Developer/CoreSimulator/Caches/*` | 存在 | 需重新生成 | trash |
| D4 | `~/.npm/_cacache` | 存在 | 可重建缓存 | trash |
| D5 | `~/.yarn/cache` | 存在 | 可重建缓存 | trash |
| D6 | `~/.pnpm-store` | 存在 | 可重建缓存 | trash |
| D7 | `~/.gradle/caches` | 存在 | 可重建缓存 | trash |
| D8 | `~/.m2/repository`（只清 `*.lastUpdated` 与 `_remote.repositories`） | 存在 | 推断未用 | trash |
| D9 | `~/.cargo/registry` | 存在 | 可重建缓存 | trash |
| D10 | `~/Library/Caches/org.swift.swiftpm` | 存在 | 可重建缓存 | trash |
| D11 | `__pycache__` 目录 | 限定 `~/workspace`、`~/projects`、`~/dev`、`~/code`，深度 ≤5 | 需重新生成 | 删除 |
| D12 | Homebrew Cellar 旧版本 | `/opt/homebrew/Cellar/<formula>/` 下非当前 `opt` 链接版本；软链解析失败时保守跳过 | 推断未用 | trash |
| **D13** | **Clang 模块缓存** | `$TMPDIR` 同级 `C/clang/ModuleCache` | 可重建缓存 | trash |
| **D14** | **Node 编译缓存** | `$TMPDIR/node-compile-cache` | 可重建缓存 | trash |
| **D15** | **全局 CLI 工具废弃版本副本** | `/opt/homebrew/lib/node_modules/{<pkg>,\@scope/<pkg>}` 名字含 `.old-` / `.retired-` / `.bak-` / `.disabled-` | 推断未用 | trash |
| **D16** | **CocoaPods 缓存与规格库** | `~/Library/Caches/CocoaPods` 与 `~/.cocoapods/repos` | 可重建缓存 | trash |
| **D17** | **Docker 构建缓存与日志** | `~/.docker/buildx/cache` 与容器守护运行日志 | 可重建缓存 | trash |
| **D18** | **Cargo Git 源码检出库** | `~/.cargo/git/checkouts` 与 `~/.cargo/git/db` | 可重建缓存 | trash |
| **D19** | **Gradle 守护进程历史日志** | `~/.gradle/daemon/<版本>/*.log`、`*.out`，且 3 天内没有再写入 | 历史产物 | trash |
| **D20** | **JetBrains 历史版本日志与索引缓存** | `~/Library/Caches/JetBrains/*` 与 `~/Library/Logs/JetBrains/*` | 对应 IDE 未运行 | 可重建缓存 | trash |
| **D21** | **Xcode DeviceSupport 过时设备调试符号** | `~/Library/Developer/Xcode/* DeviceSupport/*` | 超过 60 天未修改且 Xcode 未运行 | 历史产物 | trash |
| **D22** | **Xcode SwiftUI Previews 画布与模拟器缓存** | `~/Library/Developer/Xcode/UserData/Previews/*` | Xcode 未运行 | 需重新生成 | trash |
| **D23** | **Docker 桌面虚拟机磁盘镜像与未用卷** | `~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw` | Docker 虚拟磁盘（包含本地容器与镜像） | 推断未用 | trash（需确认） |
| **D24** | **Gradle Wrapper 发行包** | `~/.gradle/wrapper/dists/*`；**跳过仍有活跃守护进程的版本**（同版本号 3 天内写过 = 正在用） | 需重新下载 | trash（需确认） |

> **D13/D14 实测依据（v1.1）**：Clang 模块缓存 1.2 GB、Node 编译缓存 103 MB，均为自动重建的编译中间产物。
>
> **D15 实测依据（v1.1）**：`@deepseek-ai/dsh.old-0.1.2-*` ×3 与 `dsh.global-retired-20260906` 共 1.06 GB
> 废弃副本。**风险级为 review 而非 safe** —— 该命名可能出自人工重命名，需用户确认。
> 放行约束见 §8.2。
>
> **D20–D23 实测依据（v1.43.0）**：
> - **JetBrains (D20)**：IntelliJ / PyCharm / GoLand / WebStorm 历史版本往往残留多个年度的索引缓存（单个 3–8 GB），运行中对应的 IDE 会动态标记为「使用中」；
> - **Xcode DeviceSupport (D21)**：真机调试符号包单版本 2–5 GB，超过 60 天未更新的旧版本支持包安全回收；
> - **SwiftUI Previews (D22)**：动态预览缓存与临时模拟器容器，Xcode 退出后可无损重建；
> - **Docker.raw (D23)**：Docker Desktop 虚拟磁盘镜像为增长型大文件，删除将重置环境，严格保持「需确认（review）」不变量。
>
> **⚠️ 构建产物删除前置条件**：删 `.build` / `android/app/build` 等目录前，必须确认
> ①无编译进程在跑（`.lock` 文件的 mtime）；②无进程持有句柄（`lsof +D <dir>`）；
> ③Gradle 需先 `./gradlew --stop`（daemon 会持有 `intermediates/dex/**` 句柄导致删除失败）。

## 4. App 残留与卸载残留（A1–A5）

> 审计报告经验：Lemon（LaunchDaemons 残留）、Parallels（keychain 残留）、rtk（钩子残留）均为典型卸载残留案例。

| 规则 | 路径模式 | 条件 | 本质 | 清理方式 |
|------|----------|------|------|----------|
| A1 | `~/Library/Application Support/<name>` | 对应 app 不在 `/Applications`、`~/Applications`，且非 G6 白名单，且 180 天未更新，且 >10 MB | 孤儿残留 | trash |
| A2 | `~/Library/Preferences/<bundle>.plist` | 对应 app 已卸载、bundle id 不属于系统、>180 天未更新 | 孤儿残留 | trash |
| A3 | `~/Library/LaunchAgents/*` | 指向已卸载 app 的 plist | 关键组件 | trash（用户重点确认） |
| **A4** | **已卸载应用的窗口恢复状态** | `~/Library/Saved Application State/<bundle>.savedState` | 对应 app 已卸载、bundle 不属于系统 | 孤儿残留 | trash |
| **A5** | **ByHost 硬件绑定偏好碎片** | `~/Library/Preferences/ByHost/<bundle>.<UUID>.plist` | 对应 app 已卸载、bundle 不属于系统 | 孤儿残留 | trash |

> **A 类的判定强化（v1.1）**：实测发现「App 已卸载」不能只看 `/Applications`——
> 主程序可能已被拖入废纸篓。应交叉核对 `mdfind` / LaunchServices 注册记录，
> 并注意「数据目录最后修改时间」：停在卸载日期前后的才是真孤儿。

## 5. 大文件与垃圾箱

| 规则 | 路径模式 | 条件 | 本质 | 清理方式 |
|------|----------|------|------|----------|
| T1 | `~/.Trash/*` | 废纸篓内容 | 用户数据 | 彻底删除（已在废纸篓） |
| T2 | `~/Downloads/*` | 大于 500MB 或超过 180 天未访问 | 用户数据 | trash |
| T3 | 大文件扫描 | `~/Downloads`、`~/Documents`、`~/Desktop`、`~/Movies` 中 >1GB 文件，深度 ≤2 | 用户数据 | trash |
| T4 | `~/Library/Developer/CoreSimulator/Devices/*` | 未使用模拟器（按最后使用时间 >90 天） | 推断未用 | trash |
| T5 | `~/Library/Application Support/MobileSync/Backup/*` | 超过 180 天未更新的设备备份 | 用户数据 | trash |

> **T4 补充（v1.1）**：Android AVD 的 `userdata-qemu.img.qcow2` 是**动态磁盘，只增不减**，
> 模拟器跑得越多占用越大；且删除 AVD 会丢失设备配置，故保留 danger 级。
> 判断「模拟器是否在跑」需同时检查 `qemu` / `emulator` 进程。

## 6. 浏览器与系统数据

| 规则 | 路径模式 | 条件 | 本质 | 清理方式 |
|------|----------|------|------|----------|
| B1 | `~/Library/Safari/LocalStorage`、`~/Library/Safari/WebsiteData` | Safari 未运行 | 用户数据 | trash |
| B2 | Chrome/Edge/Brave/Opera/Vivaldi 的 `Default/Cache`、`Default/Code Cache` | 对应浏览器未运行 | 可重建缓存 | trash |
| B3 | `~/Library/Containers/com.apple.Safari/Data/Library/Caches` | Safari 未运行 | 可重建缓存 | trash |
| **B4** | **Chromium 组件下载缓存** | `~/Library/Application Support/*/component_crx_cache` | 可重建缓存 | trash |
| **B5** | **Chromium 按需下载的功能组件** | `~/Library/Application Support/*/{WidevineCdm, WasmTtsEngine, SODALanguagePacks}` | 需重新下载 | trash（需确认） |

> **B4/B5 实测依据**：**内嵌 Chromium 的不只是浏览器** —— Electron/CEF 宿主同样会生成这些目录，
> 实测命中 QQ / ima.copilot / Codex / Tabbit Browser / 千问输入法等。
>
> **⚠️ v1.2 修正（重要）**：这两类东西原本合在一条 B4 里、**一律标 `safe`**，是本工具历史上
> 最严重的一处误判。它们的性质完全不同：
>
> - `component_crx_cache` 是**下载缓存**——删了重新下载，用户无感 → 可重建缓存；
> - `WidevineCdm`（DRM 播放）、`WasmTtsEngine`（端上语音合成）、`SODALanguagePacks`（语言包）
>   是**按需下载的功能组件**——删掉不是"缓存被重建"，而是**该功能直接不可用，直到应用重新下载完**。
>   实测中它们被标成"安全"，用户照做后 DRM 视频就播不了。
>
> 现在按本质拆成两条规则，B5 永远落在「需确认」，并且所属应用正在运行时理由里会点名是哪个 App。

---

## 7. 已知不可清理（硬排除）

### 7.1 用户数据（G6，永远不删）

```
~/Library/Mail              ~/Library/Keychains        ~/Library/Accounts
~/Library/Messages          ~/Library/Safari/Bookmarks.plist
~/Library/Safari/History.db（用户选择）                 ~/.ssh      ~/.gnupg
~/Library/Group Containers（应用共享数据，v1.1 新增）
~/Library/Mobile Documents（iCloud Drive 本地副本，v1.1 新增）
~/Library/CloudStorage（第三方云盘挂载，v1.1 新增）
```

### 7.2 系统级硬保护（G8，v1.1）——`sudo` 也无解，不要白费力气

| 路径 | 保护机制（实测） | 说明 |
|------|------------------|------|
| `/System`、`/System/Volumes` | SIP + 只读系统卷 | 系统本体 |
| `/Library/Updates` | **`restricted` 标志 + `com.apple.rootless` 扩展属性 + SIP** | Software Update 产品元数据。`sudo rm -rf` 会逐个报 `Operation not permitted`。**且系统会自行回收**——实测 508 MB 在更新装完后自动降为 588 KB |
| `/private/var/vm`（`sleepimage` + `swapfile*`） | root-only + 运行必需 | 休眠镜像与交换分区，删除会导致休眠失败/内存不足 |
| `/private/var/db` | root-only | 系统数据库（`uuidtext` / `receipts` / `powerlog`） |
| `/private/var/folders/zz/**` | **`sunlnk`（SF_NOUNLINK）标志** | 系统守护进程临时目录。**关键**：`sunlnk` / `restricted` **不在 `chflags` 的可设置关键字列表中**，是内核专有标志，root 同样无法清除——不要浪费时间尝试 |
| `/System/Volumes/Data/.{DocumentRevisions-V100, Spotlight-V100, fseventsd}` | 系统保护 | 文档版本历史 / Spotlight 索引 / 文件系统事件 |
| `/Library/Developer/CommandLineTools` | 运行必需（若 `xcode-select -p` 指向它） | 编译工具链 |

### 7.3 TCC 隐私保护（G9，v1.1）——**读不到 ≠ 空**

需「完全磁盘访问权限」才能读取：

```
~/.Trash                                     ~/Pictures/Photos Library.photoslibrary
~/Library/Caches/CloudKit                    ~/Library/Daemon Containers
```

> **⚠️ 实测踩坑记录（必读）**：判断目录是否为空时，
> `ls "$dir" 2>/dev/null | wc -l` 在**权限被拒**时 stdout 为空，被 `wc` 计成 `0`，
> 于是「读不到」被误读成「空目录」，进而误判「废纸篓没东西可清」。
> 正确做法：用 `FileSystem.isPermissionDenied(_:)` 显式判定，
> 用 `FileSystem.hasFullDiskAccess()` 判断是否具备权限，并**在 UI 上区分提示**。

### 7.4 不要手动重复系统自带的清理

| 系统机制 | 作用 | 结论 |
|----------|------|------|
| `com.apple.bsd.dirhelper` | 按 **3 天周期**自动清理 `/var/folders` | 手动清理收益接近零 |
| Software Update | 自动回收 `/Library/Updates` | 同上（实测已验证） |
| `tmutil listlocalsnapshots` | 本地 APFS 快照 | 无 Time Machine 配置时本就为空，**不占空间**，不必处理 |

> **危险操作禁令（v1.1）**：禁止 `sudo find /private/var/folders/*/*/T -type f -delete`。
> 实测该命令会**越界扫到 `/private/var/folders/zz`（系统守护进程）与其他账户的 `kx` 目录**，
> 并真实删除了其中的文件。用户级清理只应针对 `$TMPDIR` 自身，且不加 `sudo`。

---

## 8. 受限放行原则（G10，v1.1）

当规则需要触及常规允许根目录（`$HOME`、`/private/tmp`、`/private/var/tmp`）之外的目标时，
**只能精确放行到具体路径或具名模式，禁止放行整个父目录**。现有三处放行：

### 8.1 `$TMPDIR` 内的已知残留（L6 / D13 / D14）

```
✅ 放行： <TMPDIR>/<bundle-id>.ShipIt.<字母数字后缀>     （L6，仅顶层直接子项）
✅ 放行： <TMPDIR>/node-compile-cache                    （D14）
✅ 放行： <TMPDIR 同级>/C/clang/ModuleCache              （D13）
❌ 禁止： <TMPDIR> 本身、<TMPDIR>/ 任意其他子项
```

约束理由：`$TMPDIR` 混有**正在运行的构建与工具活跃产物**，整体清理会误伤（见 L6 说明）。
判定实现：`FileSystem.isKnownTempResidue(_:)`。
注意 `/var/folders/...` 与 `/private/var/folders/...` 互为符号链接别名，比较前须归一化。

### 8.2 全局 `node_modules` 下的废弃副本（D15）

```
✅ 放行： <root>/<pkg>                 且 pkg 名命中废弃标记
✅ 放行： <root>/@scope/<pkg>          且 pkg 名命中废弃标记
❌ 禁止： <root> 本身、<root>/@scope 目录、pkg 的深层子路径
```

约束理由：只能删除整个包目录，不能误删 scope 下仍在用的同级包。
判定实现：`FileSystem.isRetiredGlobalPackage(_:)`。

### 8.3 Homebrew Cellar 具体版本（D12）

```
✅ 放行： /opt/homebrew/Cellar/<formula>/<version>  （version 以数字或 v 开头）
❌ 禁止： Cellar 根、<formula> 目录本身
```

---

## 9. 清理执行规范

1. 扫描阶段**只读**：枚举目录、计算大小（`FileManager` + 目录递归，失败目录跳过不中断）。
2. 清理阶段：按勾选项逐条执行；单条失败记录错误，**不中断其余项**。
3. 默认 `trashItem`；「彻底删除」需在确认弹窗中再次选中。
4. 清理后立即重扫该分类，展示释放空间与失败项。
5. **执行前二次护栏校验**：`Cleaner` 对每个路径再次调用 `FileSystem.isSafeToClean`。

## 10. 数据安全：备份 → 校验 → 再删除（v1.1 新增）

涉及**不可重建的用户数据**（聊天记录、照片、文档）时，清理前必须走完整流程：

### 10.1 复制前预检

- 目标盘为 exFAT/FAT 时，检查非法字符文件名（`: * ? " < > |`）与路径长度上限（255）；
- 确认**源端应用已完全退出**，判据不是「窗口关了」，而是：
  ①相关进程数为 0；②**数据库 WAL 文件（`*-wal`）的 mtime 不再变化**；③`lsof +D <dir>` 无句柄。
  > 实测：QQ 关闭窗口后仍有 13 个进程，`nt_msg.db-wal` 每秒仍在写入——此时复制到的数据库可能不一致。

### 10.2 复制后**必须逐文件校验**，不能只比文件数

- **macOS 自带 `openrsync` 存在 EINTR 缺陷**：大量小文件复制时会**静默跳过文件并报
  `Interrupted system call`**，且退出码可能仍为 0。实测漏掉 24 个文件，**含聊天记录库 `collection.db`**。
  对策：**重试至文件数归零**，或改用其他工具。
- **校验必须比对内容**：文件数一致不等于内容一致，应逐文件比对 `size` + 哈希（MD5/SHA-256）。
  > `rsync -c`（校验和模式）同样可能触发上述 EINTR 缺陷，实测在 13949 个文件的目录上失败，
  > 因此**建议用独立脚本**（如 Python 逐文件哈希）完成最终校验。
- 校验报告应输出：`MD5 一致数 / 缺失 / 大小不符 / 内容不符 / 读失败`，全零才算通过。

### 10.3 exFAT 簇放大系数

外置盘常见 **512 KB 簇**：大量小文件的实际占用可达逻辑大小的数倍。
> 实测：23,255 个文件、逻辑 5.85 GB，在盘上实占 **28 GB（约 4.8 倍）**，
> 另有 9,278 个 `._*` AppleDouble 元数据文件（校验时须排除，否则文件数会虚高近一倍）。

### 10.4 只删「数据」不删「索引」，或改用应用内清理

删除应用缓存（可重建）与删除应用数据库（丢失索引/历史）后果完全不同。
> 实测：QQ 删除 `nt_data/Pic`（图片，服务端可重拉）安全；但删 `nt_db`（聊天记录库）
> 会导致客户端内聊天记录消失。**推荐优先使用应用内置的存储管理功能**。

---

## 11. 变更记录

- **v1.0（2026-09-03）**：固化 6 大类 23 条规则，来源：本机 agent 会话/审计报告经验 + 通用实践。
- **v1.1（2026-09-12）**：本机全盘深度清理实测后更新。
  - **新增规则 6 条**：C7 应用内旧安装包 · L6 ShipIt 更新残留 · D13 Clang 模块缓存 ·
    D14 Node 编译缓存 · D15 全局 CLI 废弃版本副本 · B4 Chromium 内嵌组件缓存。
  - **新增护栏 3 条**：G8 系统级硬保护 · G9 TCC 权限显式判定 · G10 受限放行原则。
  - **新增章节**：§10 数据安全（备份→校验→再删除）。
  - **修复脱节**：新建 `Sources/MacClean/Rules/CleanupRules.swift`（此前文档引用但文件不存在）；
    `ruleRef` 改为从规则源头动态派生（此前硬编码的 `B1–B4` 是幽灵规则）；
    规则条数统一为 **41 条**（此前 README 写 23、文档实为 32、代码 35）。
  - **实测数据来源**：本机 228 GB 数据卷，4 个并行只读扫描 + 交叉验证，
    累计清理约 12 GB（含 ShipIt 2.24 GB、构建产物 2.9 GB、QQ 缓存 5.5 GB、Edge 孤儿数据 1.25 GB）。
- **v1.72（2026-09-21）**：**不新增清理规则**，而是把 v1.53–v1.71 陆续加上的十余个治理模块
  重新纳入护栏。新增 G14（删除只有一个入口）· G15（子进程必须受控）· G16（孤儿判定必须有正向证据）。
  - **根因**：`isSafeToClean` 的常规允许根只有主目录与临时目录，治理模块扫的却是 `/Library/Fonts`、
    `/Library/Printers`、`/Library/Audio/Plug-Ins/HAL` 等位置，于是各自写了
    `path.hasPrefix("/System")` 式字符串护栏。这类护栏**软链可绕**，且让 G6 硬排除与
    用户自定义白名单对这 12 个模块完全失效。
  - **真机实测到的三个具体后果**：① `/etc/cups/printers.conf` 权限 `-rw------- root:_cups`
    永远读不到 → 打印机模块的"在用关键词"恒为空集 → **所有驱动都被判废弃并默认勾选**；
    ② 音频 HAL 用"是否等于某个已安装 `.app` 的 bundle id"判在用，而本机
    `BlackHole2ch.driver`、`SteamStreaming*.driver` 等是 pkg 安装、无 `.app` → 全部误判孤儿；
    ③ `~/.npm` 的缓存路径带兜底根，本机 `~/.npm` 下确实没有 `_cacache` → 退化成删掉
    `~/.npm` 的**全部子项**，而关键字保护只校验父路径、从不校验真正要删的子路径。
  - **顺带修掉两个"看起来在把关其实一直空转"的自检**：无障碍源码 lint 用相对路径 +
    `try? … else continue`（工作目录不是仓库根就一个文件都读不到、恒真通过），
    且名单只列 18 个视图；改为穷举源码目录后立即抓到 2 处真实违规。
    另有十余处 `removeAllRules()` 直接写 `UserDefaults.standard`，若从 `.app` 内跑自检会清空用户白名单。
- **v1.72.1（2026-09-21）**：v1.72 收敛之后的一轮交叉复核，**不新增清理规则**。
  - **G3 极性回归**：`ClipboardPurger.cleanClipboardCaches` / `purgeAll` 与
    `QuickLookThumbnailPurger.purge` 的 `toTrash` 默认值是 `false`，而卡片调用时不显式传参
    → 主按钮实际语义是"直接彻底删除、无撤销"。剪贴板那条已改回 `true`
    （`~/Library/TemporaryItems` 混着自动恢复草稿）；QuickLook 保留 `false` 但理由已写在代码里
    （缩略图缓存可再生，且该卡片本来就有确认弹窗）——**两者区分对待，不要一刀切**。
  - **菜单栏缺确认**：整个 `MenuBarView` 原先没有任何 `confirmationDialog`，
    "释放本地快照"点一下就执行。本地快照在备份盘长期未接时可能是近期改动的唯一副本。
  - **G6 补照片图库**：`~/Pictures/Photos Library.photoslibrary` 原先只在 `tccProtected`，
    那是"读得到吗"的判据、**不构成删除拦截**；授予完全磁盘访问权限后库内真实文件即可通过
    主目录护栏被判可清理。现同时进 `hardExclude`（`tccProtected` 管可读性，`hardExclude` 管可删性）。
  - **动态治理域必须登记**：QuickLook 的 darwin 缓存域根是运行时发现的，原先就地构造
    `GovernanceDomain` 而不进注册表 → 所有"遍历 `GovernanceDomain.all`"的穷举断言永远扫不到它，
    "未登记一律拒绝"成了空承诺。现提供 `GovernanceDomain.register(_:)`。
  - **历史上限**：200 条上限原先只写在 `AppState` 里，而写历史的入口已有 6 个 → 磁盘文件只增不减。
    上限移到唯一写入口 `HistoryStore.save`。
  - **本轮自己引入的两个回归**（记录以免重犯）：`ThumbnailCache` 只设条数上限未设体积上限
    （1024px 单张 ≈7.8 MB × 500 → 峰值 ~3.9 GB）；`SafeProcess.invokedCommands` 无条件 append
    而只有自检 reset（常驻进程下无界增长，且留存用户路径）。
- **v1.72.2（2026-09-21）**：发布产物瘦身，**不涉及清理规则**。
  - 56 个自检文件共 15,674 行（约占仓库 24%），且只有它们 `import ViewInspector`
    （纯测试库）。此前全部链进 `dist/MacClean.app`——用户机器上的二进制带着整套测试代码。
  - `Package.swift` 按 `MACCLEAN_NO_SELFTEST` 整目录排除 `Selftests/`、去掉依赖、
    取消 `MACCLEAN_SELFTEST` 标记；`scripts/build-app.sh` 打包时自动设置。
    发布产物 **24.5 MB → 19.7 MB（−19.8%）**。
  - 没有改成独立 test target 的原因：自检要读每个类型的内部成员，同 module 才做得到；
    拆出去就得把大量内部 API 改 `public`，那是更糟的封装。
  - 剥离后的二进制跑 `--selftest` 明确报错、退出码 2 —— **不能静默通过**，
    那等于让人以为"自检过了"而实际一个断言都没跑。
- **v1.72.3（2026-09-21）**：G5 运行态判定的取数方式，**不涉及清理规则**。
  - `runningBundleIDs` / `runningDisplayNames` / `runningAppNamesByBundleID` 每次访问都重新
    枚举 `NSWorkspace.shared.runningApplications`，而 `ownerApp(of:)` 对**每个清理项**都要查
    归属。本机一次 `--scan` 的 1260 个日志项 = 2500+ 次枚举，该分类实测 4.5 s（占整轮近一半）。
  - 四个访问器合并为一份 5 秒 TTL 快照（与 `runningAppAliases` 原有新鲜度一致），
    并且**每轮扫描开始时主动丢弃快照**——保证"先启动 Xcode、再点扫描"必定被看见。
  - 实测：日志与临时文件 4.3–4.6s → 2.4–3.1s；用户缓存 0.93–1.15s → 0.53–0.59s。
  - 新增断言同时守住复用（性能）与 invalidate 后重取（安全），并校验合并没有把
    "每个在跑的 bundle id 都必须进别名集合"这条语义弄丢——丢了就会重现
    "目录名英文、App 显示中文"那一类漏判。
- **v1.72.8（2026-09-22）**：结论引擎接上规则 v2 的档位（步骤 3）。**清理范围一条没放宽，反而收紧了。**
  - 新增置顶分组**「确定是垃圾」**：与「可清理」的区别不是更安全，而是**依据来源不同**——
    必须有 OS 目录契约、工具自身 prune 语义或文件系统结构标记背书，换机器换人依然成立。
    结论原文带依据，例：`ModuleCache — 901.6 MB —（确定是垃圾的依据：Apple 明说系统不会自动清理此目录）`。
  - **双向钳制**：T2 把「可清理」降为「需确认」、T3 降为「勿删」，并在理由里写明缺哪一维。
    实测降级样本：`Gradle Wrapper 152.4 MB` → `需确认（降级依据：重建要重下 GB 级内容，
    而本工具不探测网络可达性）`；`D22`（Xcode `UserData/Previews`）、`L7`（崩溃报告，
    不可重建的取证材料）→ 需确认；`D23`（`Docker.raw`，卷的后备存储）→ 勿删。
  - **运行时事实压过档位**：宿主在跑或刚被写过的项即使所属规则是 T0，也仍是「使用中」。
    这条方向如果写反，就等于"依据很硬"被误用成"现在就能删"。
  - G2（默认不勾选）**本版本未动**：T0 的默认勾选是步骤 4，且按规格必须晚于步骤 5
    （L3/L4 的实现还没换成「属主==euid 且 >3 天未访问」，先开默认勾选会勾上刚被写的临时文件）。
  - 自检 537 → 542：新增升级/降级矩阵、运行时压制、分组真的渲染出标题与副标题、
    以及一条**如实记录缺口**的断言——T0 名单里 `L3/D8/D12/A4` 四条的 `nature` 还停在
    "推断/孤儿"，今天不会出现在「确定是垃圾」组，必须显式承认而不是改 nature 让名单"看起来"生效。
- **v1.72.10（2026-09-22）**：规则 v2 **步骤 4——T0 默认勾选**（owner 决策 D-1），G2 从此有一条例外。
  `Scanner.applyDefaultSelection` 在扫描收尾时只预勾结论为「确定是垃圾」的项，
  `可清理 / 使用中 / 需确认 / 勿删` 一律不勾，二次确认对所有档保留。
  这一步**必须晚于步骤 5**：步骤 5 之前 T0 里最危险的就是临时目录——那时 L3 的判据还是
  "当前用户可写"，先开默认勾选就等于把几秒前刚被写的文件自动勾上。
  本机效果：「日志与临时文件」11 项里 2 项预勾（`swift-generated-sources`、`xcrun_db`），
  「开发残留」9 项里 3 项预勾（`ModuleCache` 902 MB、`Gradle 历史守护进程日志` 35.8 MB、
  `node-compile-cache` 9.3 MB）；宿主在跑的 T0 项（如 `Antigravity` 日志）不预勾。
  自检 548 → 550：五档各造一项过一遍（只有 garbage 被勾）+ **T0 但宿主在跑不得被预勾**
  （运行时事实压过档位，这条写反就等于把"依据很硬"当成"现在就能删"）。
  过程中发现预勾会**撑大另一条自动路径的范围**：菜单栏「快速安全清理」原先是"把合格的补勾上"
  再清理**所有已选**项——扫描一旦预勾，那些过不了它自己第二道门槛（近期还有写入）的垃圾项
  就会被顺带删掉。改成对每项重算勾选（`AppState.applyQuickCleanSelection`），
  并加反证自检：预勾 + `.active` 的项必须被自动清理排除，而合格的预勾项不得被误伤（550 → 551）。
- **v1.72.9（2026-09-22）**：规则 v2 **步骤 5——把判据从"猜"换成"量"**，同时修掉三个只读探查的失真。
  用户诉求是「丰富探查准确度」，落下来是三处判定加一处接线：
  - **L3/L4 判据改写**（T0 从此名副其实）：`/private/tmp`、`/var/tmp`、`TemporaryItems` 改为逐子项要求
    「属主==当前用户 **且** mtime 超过 Apple 的 3 天阈值」；`TemporaryItems` 另外要求
    "名字看不出属于哪个 App"（自动恢复草稿在里面，3 天没写不等于可丢，与 `ClipboardPurger`
    对同一目录的"认不出就保留"口径合并）。本机「日志与临时文件」**339 项/357.6 MB → 11 项/36.1 MB**。
  - **C4 对齐 brew 自己的契约**：从"目录存在就整目录进废纸篓"改成只收 mtime >120 天
    （`HOMEBREW_CLEANUP_MAX_AGE_DAYS`）的**已完成**下载，跳过 `.part/.lock/.downloading`、软链与 `api/`。
  - **D19 拆分**：守护进程日志（T0）与 `wrapper/dists` 发行包（新增 **D24**，T2）。
    顺带发现 D19 的日志分支**从未生效过**——它把 `FileSystem.children(of:)`（返回全路径）
    的结果再 `appendingPathComponent` 拼一遍，得到 `.../8.10.2/Users/…/daemon-x.log` 这种永不存在的
    路径，`size` 恒为 0，本机 49 MB 日志一条都没列出来过；列表里少一项不像 bug，只像"这里没东西"。
    拆开后 `gradle-8.10.2-bin` 也不再被称作"过时 Wrapper"：该版本 3 天内还在写 = 正在用 → 不列。
  - **聚合项的占用状态改按自己要删的路径量**（`FileSystem.usage(ofPaths:)`）：原先一律量主路径
    （= 父目录），而 `~/Library/Logs`、`~/.gradle/daemon` 这种位置随时有人在写，于是
    "16 个 3 天没动的日志"被标成「几秒前还有写入 → 使用中」。那不是保守，是假。
  - **档位标签只说量到的事**：`频繁使用中/偶尔使用` → `7 天内有写入/30–90 天内有写入`…；
    单个 mtime 推不出"频率"，而"使用:5 天前 · 频繁使用中"和"确定是垃圾"并排出现时，
    用户唯一理性的反应是两个都不信（这正是最初那条抱怨的下半段）。
  - 判据字段的选型依据是实测：本机**读取不更新 atime**（POSIX read、`/bin/cat`、以及一个 atime 已落后
    9.5 天的既有文件 + 20 s 等待，三次都没动），所以 atime 不参与门槛，只用 mtime——
    顺带保证"自家扫描不会改动自己所依据的字段"。`docs/research/cleanup-rules-industry.md` 里
    原先"实测读取后 atime 确实更新"那句是**错的**，已按本次测量改写。
  - 顺带暴露并修掉一处布局回归：v1.72.6 给治理面板区套的 `ScrollView + .frame(maxHeight: 340)` 是
    **贪心**的，里面只剩一排胶囊时也会占满 340 pt。以前每类几百项看不出来，列表一短
    （日志类 11 项）就在列表上方多出一条近 300 pt 的空带。现在限高滚动只在真有面板展开时套上，
    真机复验：收起时列表紧贴胶囊条，三块面板全开时页头/页脚仍在。
  - 自检 542 → 548：`idleVerdict` 四维各挡一次、3 天硬边界两侧各测、探查一次后判定不得翻转、
    C4 只收 120 天外已完成下载（含闸门外路径一项不收的反证）、聚合项不得被父目录牵连、
    以及 `children(of:)` 双 join 的死路径反证。规则 52 → 53 条，T0/T1/T2/T3 = 12/16/17/8。
    步骤 5 完成后**步骤 4（T0 默认勾选）的阻塞条件解除**。
- **v1.72.6（2026-09-21）**：修「浏览器与系统数据」这一页**点开后没法用**，规则一条没改。
  成因是布局而不是判定：全站每个分类的治理面板都是"点胶囊才展开"，只有这一块
  `SystemDeepStorageView()`（473 行 UI，内部无滚动、无高度上限）是**无条件挂载**在清理列表上方的。
  它和另外两张卡片一起把页面撑得比窗口还高，而 SwiftUI 对超高的 `VStack` 不是给滚动条、
  是**上下两头一起裁**——分类标题、过滤/扫描那一排、底部「已选 / 清理」全部消失，
  看起来就是"点了没反应 / 这页用不了"。三处收口：
  ① 该面板改成与同页另两块一致的折叠式（新增「底层存储」胶囊，默认收起）；
  ② 整个面板区套一层 `ScrollView` 并封顶 `maxHeight: 340`，用户一次开三块也不会顶掉列表；
  ③ 新增自检：默认状态下面板正文不得出现在视图树里，且**列表正文必须在**
  （只断言前者会漏掉"面板拿掉了但列表也没了"这种坏法）。
  真机验证：三块面板全开时截图，页头 / 权限横幅 / 胶囊条 / 列表 7 项 / 页脚同时可见。
- **v1.72.5（2026-09-21）**：分类详情列表的**渲染结构**，清理规则一条没动。
  外层 `LazyVStack` 的每个直接子项原本是"某个结论分组的整组行"（组内是普通 `VStack`），
  于是该组一进视口就一次性构造整组——本机 1233 项的「日志与临时文件」实测：
  重新进入该分类后读一次界面树 **7.9 s**（改造前另一次采样甚至连续两次超时 >60 s），
  摊平成"标题 / 行"一维序列后 **1.1 s**。
  省的是**主线程构造视图的成本**：无障碍树行数（两边都只 vend 视口内 12 行）与 RSS
  （185 → 181 MB）基本不变，所以别拿这两个指标判断有没有生效。
  排布按截图逐项比对一致。造大样本注意：L1 只列 `size > 0` 的项，空目录不会被列出；
  `/private/tmp` 里把时间戳回改的假目录会被 macOS 自身的 tmp 清理收走，用 `~/Library/Logs` 顶层。
- **v1.72.4（2026-09-21）**：删除护栏（G1/G6/G8/D12/D13/D14/D15 共用的 `isSafeToClean`）
  的**取数方式**，规则本身一条没改。用一段临时插桩把单次判定拆开计时（量完即删），
  结果是 **299 µs/项**，而它要对每个候选项都跑一遍：
  - **清单常量被反复归一化**是主因：G6 的 13 条 + G8 的 6 条 + 放行根 3 条 +
    受限放行根（Cellar 2、全局 node_modules 若干）每次判定都重新 `normalizePath` 一遍，
    仅 `hardExclude` 一项就占 81 µs。清单内容进程内不变、`normalizePath` 又是
    完全不触碰文件系统的纯字符串函数，因此改为 `GuardPath` 预归一、并预先备好
    `+ "/"` 形态，运行时只剩前缀比较，不再临时拼新串。
  - **`CleanPaths.expand` 会替换路径中间的 `~`**（本轮唯一一处判定结果变化）：
    原先是 `replacingOccurrences(of: "~", with: NSHomeDirectory())`，于是
    `/tmp/a~b` 被换成 `/tmp/a/Users/<me>/b`——护栏拿去与清单比对的是一条**根本不存在**
    的路径，G6/G8/白名单是在拿错的东西做前缀匹配。现在只认前缀 `~`。
    顺带省下绝对路径上每次一趟全串搜索替换 + 一次 `NSHomeDirectory()`。
  - **白名单查表重复解析软链**：`isSafeToClean` 已经把路径解析到真实位置，
    `isWhitelisted` 内部又解析一次。`normalizePath ∘ realPath` 是幂等的，
    第二次只会多付一次全路径逐段 lstat（实测 9.5 µs/项，且用户白名单规则越多越贵）。
    新增 `isWhitelisted(resolvedPath:)` 供闸门使用，原公开入口行为不变。
  - 实测：单次判定 **299 µs → 54 µs**；`--selftest` 全程 35.9 s → 19.1 s；
    一次 `--scan` 的「日志与临时文件」分类 2.4–3.1 s（1382 项）→ 0.86–1.96 s（**1478 项**，
    项数还更多）。Thread Sanitizer 复验 0 告警。
  - 新增两条不变量自检：① `normalizePath` 的快速通道与完整消解流程**逐条同结果且幂等**
    （23 个边界输入，含 `/a//b`、`/a/.../b`、`/private/`、路径中间的 `~`）；
    ② 闸门判定开销相对**单次软链解析 ≤ 3 倍**——用比值而不是绝对阈值，与机器负载无关，
    改动前实测 14.6 倍。
  - **同一版顺手把编译告警清零（14 条 → 0 条，两种构建模式都是 0）**，其中一条与删除判据有关：
    `PluginExtensionItem.isSafeToClean` 是与 `FileSystem.isSafeToClean` **同名异义**的废弃属性，
    两处调用（扩展残留"全选"与"已全选"判定）迁到 `isDeletableVerdict` 后连 shim 一起删除。
    `Locale.current.languageCode` → `language.languageCode.identifier` 经 8 种 locale 实测同值，
    "多语言瘦身要保留用户自己的语言"这条判据不变。
  - **音视频元数据（时长/分辨率/码率徽标）改后台预热**：AVFoundation 在 macOS 13 起
    只剩异步 `load(...)`，而解析原先在 SwiftUI `body` 与 `sort` 比较器里同步跑。
    徽标因此会**晚一帧**出现、按码率/时长排序在预热完成后才稳定；解析链路新增一条
    用 `AVAssetWriter` 现场编出的真实 mp4 作样本的端到端断言（否则"每个字段都被
    `try?` 兜成 0"这种坏法能拿到全绿）。清理规则本身不受影响——这些字段只用于展示与排序。


