# MacClean 深度优化方案（v1.73.14 之后）

生成于 2026-09-29，基于 v1.73.14 已发布状态。来源：6 路独立只读审计（删除安全 / 谎报剩余面 /
自检执法力 / 架构重复 / 新模块候选 / 文档与发布卫生）+ 本会话对高危条目的**逐条代码复现**。

## 0. 怎么读这份方案

- **它不是待办清单，是判据 + 队列**。每一轮仍然按 `AGENTS`/cron 里的优先级自己挑，
  只是这里把"已知真实问题"摆到台面上，避免重复发现。挑中哪条就做哪条，做完划掉并补新证据。
- 每条都带 `file:line` 与**复现状态**：
  - `已复现` = 本会话亲自读过那段代码或跑过命令确认；
  - `审计提出` = 只读审计给的，位置可信但我没逐字复核；
  - `待验证` = 需要先造夹具/真机读数才能判定是否成立，**不许据此直接改护栏**。
- **脱敏约定**：本文只写仓库内路径与代码形状。涉及第三方应用的位置一律写成
  `<vendor>` / `<name>.<ts>.old` 这类占位形式——本机装了哪些软件本身就是个人数据。
- 一轮的体量上限：**一条带 `file:line` 的真实问题 + 会判红的自检 + 变异验证**。
  下面的「轮次编排」就是按这个粒度切的。

## 1. 现状底数（实测，不是估计）

| 维度 | 数 | 说明 |
|---|---|---|
| 规模 | 144 产品文件 + 65 自检文件 / 85,357 行 | 最大：`CategoryDetailView.swift` 2389、`Scanner.swift` 1952、`UninstallerView.swift` 1925 |
| 自检 | 784 条 `check(` | 本机跑到并绿 **696**；**34** 条红灯被 §0.2 基线"按名赦免"；**54** 条随 7 个崩溃套件整片没跑 |
| 执法力 | 逻辑层约九成；**删除动作的"界面→网关"那一层约三分之一** | 18 张卡片/视图在自检里名字都不出现 |
| 结果面 | 8 份包装类型（6 结构体 + 2 元组）/ 51 个转发成员 | 加一个字段要改 10 处转发；**元组那 2 处编译期不报错** |
| 本轮代价 | v1.73.14 的 `trashedBytes/space` 改了 **34 个产品文件** | 这就是"结果面没收口"的直接成本 |
| 门禁 | `release.sh` 只比失败**名集**，不比通过数 | 崩溃点前移、吞掉几十条绿是免费的 |
| 定时任务 | 每小时自动优化 cron **当前停用**（`pauseReason=manual`） | 且其选题指令仍写着"已知优选：Android AVD 孤儿"——该模块 v1.73.10 已发布 |

## 2. P0 队列（误删 / 不可恢复 / 数据外泄方向）

### P0-1 无人值守清理丢弃撤销快照 —— `已复现`

`DiskMonitor.swift:281-296`：`Cleaner.clean(..., permanently: false)` 之后只 `recordClean(...)`
写了一行历史，**`result.trashedSnapshots` 被整个丢掉**，从不 `UndoManagerStore.record`。
对照三条同类路径都写了：`ResidueDeletionGate.swift:273`、`AppState.swift:593-597`、
`AutoCleanService.swift:131-135`。

→ 后果：唯一"没人看着也会删"的链路留下一行永远点不动的「放回原位」；
若同时开着"废纸篓自动清空"（彻底删除、无快照），这批文件**永久找不回**。

修法：把"历史行 + 撤销快照"收成**一个出口**（网关 `record()` 已经是这个形状），
静默清理、卸载器、归档三处一起复用。自检两条腿：
① 行为——隔离状态目录下跑一次静默清理，断言每条 `mode` 含"废纸篓"的历史记录都能在
`UndoManagerStore.load()` 找到同 `recordID` 的会话且条目数相等；
② 源码 lint——穷举 `Cleaner.clean(` 调用点，其所在函数体必须引用 `UndoManagerStore.record`，
除非该调用点的 `permanently` 可静态证真。现状下 `DiskMonitor` 与 `Uninstaller` 两处都会判红。

### P0-2 卸载器与归档/迁移整条链路不记账、不留快照 —— `审计提出`（位置可信）

- `Uninstaller.swift:288-327`（入口 `UninstallerView.swift:125/517`）对
  `HistoryStore` / `UndoManagerStore` **零引用**，而它删的常是 `Application Support/<App>`（真数据）。
- `SpaceArchiveService.swift:192/278`：归档/迁移成功后 `trashItem` 移走原件，
  护栏齐（`:375`）但**不写历史、不写快照**；且裁决用 `path`、动手用未解析的 `expanded`。

→ 用户侧表现为"应用不知道发生过什么"：历史虚低、无法放回、大文件归档后原件在废纸篓这件事没有记录。
修法与 P0-1 同一个出口，因此**合并成一轮**。

### P0-3 主链路的软链防跳板第一层是死的 —— `已复现`

`Cleaner.swift:51` 先 `realPath(path)`，`:54` 把**已解析串**交给 `isSafeToClean`；
而 `FileSystem.swift:1374` 的第一道判断是 `if isSymlink(path) { return false }`——
对已解析结果恒不成立。网关侧这一层是活的（它拿原始 `candidate.path` 判）。

→ 后果：扫描与删除之间被换成软链（或面板列出的本来就是软链）时，主链路删的是
**链指向的真目录**，而 `size(at:)` 对软链返回 0，界面显示 0 字节、实际清掉一整棵树。
`permanently: true` 时直接消失。

修法：在 `Cleaner` 里对**原始** `item.paths` 元素先 `isSymlink` 再解析（把网关那两层顺序抄齐）。
自检：真机造一个"面板项是软链、指向另一棵主目录内真树"的夹具，断言主链路拒绝且文件原样。
注意这条会牵动既有 `realPath` 单次解析的 TOCTOU 论证，**必须连注释一起改**，
否则下一个人会把它"修回去"。

### P0-4 用户数据目录上的默认勾选被一条纯年龄规则破掉 —— `已复现（形状）`

`DownloadsOrganizerModels.swift:77`：`if ageDays >= 90 { return true }`（默认勾选推荐判据），
赋值点在 `DownloadsOrganizerScanner.swift:106-108`。
  > **R3 复核更正**：截图侧那句不是同一个 bug。`CaptureType` 只有 screenshot / recording 两个取值，
  > 满 90 天的项必然已经被「截图 ≥30」或「录制 ≥7」覆盖，所以它在那侧**从未影响任何判定**（死代码）。
  > R3 两侧都删以保形状一致，但真正的 P0 只在下载侧：那边 `kind` 有 document / media / other，
  > 纯年龄兜底会把 pdf / docx / 照片**默认勾上**，而卡片删除按钮直接吃 `filter(\.isSelected)`。
卡片删除按钮直接吃 `filter(\.isSelected)`（`DownloadsOrganizerCard.swift:392`）。

→ G2「默认不勾用户数据」在 `~/Downloads`、`~/Desktop`、`~/Pictures` 上被"放够 90 天"这一条
年龄证据破掉，而年龄不是"这是垃圾"的证据（pdf/docx/mp4 是文档与照片）。
修法：兜底档（纯年龄、无所有权/无引用证据）降为「需确认」，**不参与默认勾选**；
`<vendor>` 类"名字就写着 backups / 宿主在装"的目录要进 C1 反例名单（见 P1-6）。

### P0-5 脱敏门禁可被同形词与备案表静默放行 —— `已复现`

公开仓库 + 天生读全盘的软件，这一条按红线优先级排进 P0：

1. `scripts/release.sh:146` `if fixture_shape "${v}"` 判的是**整行内容**——
   真凭据只要与 `test` / `fake` / `dummy` / 连续数字 / `{xxx}` 同行，就只打印不计数，
   **绝对零命中那五类也照样豁免**。
2. `report_hit`（`:126`）**先查备案表再计数**，所以"abs 类不许备案"只是文案（`:228`）；
   而 `scripts/secrets-allowlist.txt` 里已经有一行 `hist * private_key`——
   文件为 `*` 的 scope 让**整条私钥规则对全部 git 历史失效**。
3. `--skip-scan`（`:217`）只 `warn` 然后照常 commit / push / release。
4. 历史扫描只吃 `git log -p`，不扫 commit/tag message；`git grep` 只扫索引内文件，
   而 `git add` 在第 6 步 → **本轮新增的未跟踪文件本轮不扫**；标题参数 `TITLE` 进 tag 也不扫。
5. 规则形状缺口：`gh[pousrIw]_` 不匹配细粒度 PAT（`github_pat_…`）、私钥头大小写敏感、
   base64/跨行拼接无覆盖、identity 扫描只 grep 当前 `id -un`。

修法（一轮内可全做完，纯脚本 + 一条会判红的自检）：abs 类在 `report_hit` 里**先判类型再谈备案**，
命中即 die；`fixture_shape` 只允许作用于**匹配片段**且 abs 类禁用该豁免；
`--skip-scan` 改为"跳过即 die，除非同时 `--dry-run`"；扫描 pathspec 与 `git add` pathspec 对齐、
`add` 之后再扫一遍 staged；补 `github_pat_`、`-i`、commit/tag message 三类；
备案表禁 `file=*` 且每条必须带证据行号。

## 3. P1 队列

### 族 A：结论仍然与真相不符的地方

| # | 位置 | 症状 → 后果 | 状态 |
|---|---|---|---|
| P1-1 | `AIService.swift:733` + `:718` + `:661` | `lsof` 不存在/超时/失败一律返回 `[]`，界面渲染成「占用进程：无（本地 lsof 检测）」，而 systemPrompt 明写"为空说明当前无进程占用" → **把"没探到"当权威证据喂给外部模型判删**，可能建议删正在写的文件 | `已复现` |
| P1-2 | `DiskInfo.swift:7` + `AppState.swift:117` | 「可用」取 `volumeAvailableCapacityForImportantUsage`（含 purgeable，最讨好的一档），`已用 = total − 可用` → 仪表盘/菜单栏同屏的已用/可用比 Finder、`df` 各偏约 3 GB（本机实测三档跨 14.3 GB），`DiskMonitor:312` 低空间告警**晚 3 GB 才响** | `已复现` |
| P1-3 | 动作**之前**的 10 处手写动词：`QuickCleanPanel:325`、`DashboardView:255`、`DiagnosticReportCard:151/386`、`Spotlight:173`、`PrinterDriver:170`、`ColorSync:153`、`AndroidEmulator:193`、`NotificationManager:69/72` | v1.73.14 只收了"结果句"，**承诺侧没收**：默认落点是 `toTrash`，用户点「极速释放 X」之后磁盘一分不动 | `审计提出` |
| P1-4 | `HardlinkDedupService.swift:409` | `freed = st_size`：APFS **克隆**对（nlink=1、共享 extent）link+rename 后复核照过 → 报「释放 N」而 Δdisk=0；稀疏/压缩文件同错。`DuplicateScanner.wastedBytes` 同口径 | `待验证`（需 `cp -c` 夹具 + reflink 计数或删前删后 `df` 差值） |
| P1-5 | `HistoryExporter.swift:312/353`、`SpaceArchiveService.swift:332` | 生成的迁移脚本把**生成时**的总和写死成「释放本地空间 X」，与实际 rsync 成功数无关；`--remove-source-files` 不删空目录、不复核 | `审计提出` |
| P1-6 | `LoginItemCleaner.swift:77`、`QuickLookThumbnailPurgerCard.swift:145`、`CLICacheOptimizerCard.swift:190` | `try? contentsOfDirectory else continue` 不留痕；`unreadablePaths` 被采集却**从不渲染**（注释还写着"卡片顶栏据此说…"）→ 空态直陈"系统启动项健康 / 数据库极小或已重置 / 系统非常干净"。同类：C1（`~/Library/Caches/*` 各子目录，`CleanupRules.swift:249`，tier T1）**没有任何 backups/数据目录反例名单**，真机存在名为 `…/BundleMigration/backups` 的宿主数据子目录会被当缓存列出 | `已复现（规则形状）` + 具体目录待真机确认 |
| P1-7 | `SystemDeepStorageInspector.swift:158/161` + `Selftest+SystemDeepStorage.swift:83` | 「切 Mode 0 释放 <sleepimage>」：工具只生成脚本，Mode 0 本身不删 sleepimage，`rm` 后下次休眠又写回；自检只 `contains("台式 Mac") && contains("GB")`，**动词换成什么我都照绿** | `审计提出` |

### 族 B：假绿与自检执法力

| # | 位置 | 症状 → 后果 | 状态 |
|---|---|---|---|
| P1-8 | `Selftest+DeletionGate.swift:149` | `guard reason != .userWhitelisted \|\| true else { return false }` —— **`A \|\| true` 恒真**，"域根被白名单放行"这条永远不会红。位置就在本轮刚改过的文件里 | `已复现` |
| P1-9 | `AIReview.swift:70` | `lastError != nil \|\| reviews.isEmpty` 后项恒真 → "必须明确报错"没闸 | `审计提出` |
| P1-10 | skip-as-pass 12 处：`AIKeyStorage:65`、`Duplicates:115`、`RulesAndVerdicts:147`、`DeletionGate:250/794/835/837`、`DiagnosticReportDeep:350`、`StartupItemsDeep:298`、`AppLocalizationDeep:554`、`SpotlightDeep:416` | "造不出夹具"时 `else { return true }` 记进**通过**——与 §0.2 的"未执行 ≠ 通过"是同一族，但这里连未执行都不报。正写法已在 `SpaceVisualizerDeep2:197` | `审计提出` |
| P1-11 | `Selftest+Accessibility.swift:30` | 动效 lint 用非递归 `contentsOfDirectory` → `Rules/` 整片不扫（`DeletionGate:710` 已实测过这个漏洞） | `审计提出` |
| P1-12 | 崩溃套件吞断言 | `Selftest.swift:319 runOrchestrated` 缺 `##SELFTEST_RESULT` 就整片记未执行，**已打 ✅ 的也全丢**。按被吞条数排序：`SystemAndHistory` 16（崩在 `:48`）＞`SearchAndClean` 11（崩在 `:77`，丢掉唯一的 `cleanSelected` 闭环 `:131`）＞`SpaceArchiveDeep` 9（崩在最后 `:263`，8 条纯逻辑）＞`GlobalHotkeyDeep` 6 ＝ `SpaceVisualizerDeep2` 6（`:171`「归档/迁移 UI 判据与 SIP 服务判据同源」＝**当前完全无执法力的最高价值单条**）＞`SpaceVisualizerDeep` 4 ＞`MenuBarWidgetsDeep` 2 | `已复现（机制）` |
| P1-13 | 主链空洞 top8（产品被调、自检 0 引用） | `AppState.cleanSelectedAcrossCategories:626`、`confirmQuickClean:857`＋`quickCleanSafeItems:887`＋`quickCleanSmartRecommendations:898`、`restoreCleanRecord:923`、`proceedScanWithoutFullDiskAccess:267`＋`replayScan:276`、`scanRisks:511`＋`riskCounts:526`、`diskUsed/usedRatio:117`、`scanProgress:58`＋`incrementalHits:62`＋`lastScanDuration:60`、`DiskMonitor.performSilentAutoClean`。全仓仅 9 个文件有接线判据，且**没有"UI 层禁现删除原语"的全仓 lint** | `审计提出` |
| P1-14 | 形状断言：`Selftest+RiskAndWhitelist:259/:141/:90`、`Selftest+Foundation:344` | `contains("5 GB") && contains("15 GB")` 可对调、`contains("100 MB")` 不查动词、`contains("占用进程：无")` **恰好把 P1-1 锁成恒绿** | `已复现（P1-1 那条）` |
| P1-15 | `scripts/mutate.sh` 不存在 | 变异验证只活在 `RELEASE-CHECKLIST` 的散文里，每轮手写、且我这两轮的脚本都有缺陷（共享状态目录导致附带红点被误归因） | `已复现` |

### 族 C：口径与架构重复（每一轮的成本来源）

| # | 位置 | 症状 → 后果 | 状态 |
|---|---|---|---|
| P1-16 | 8 份结果包装（`ClipboardModels:112`、`DownloadsOrganizerModels:141`、`ScreenshotsOrganizerModels:152`、`QuickLookThumbnailModels:97`、`LoginItemCleaner:241`、`PluginExtensionInspector:480`、`PreferenceResidueInspector:274` 元组、`SpotlightScanner:325` 元组） | 51 个转发成员；新字段要改 10 处，**元组那 2 处漏改不报错**（v1.73.14 的 `space` 就是手动补的）；`PluginExtension` 还改名（`succeeded`/`releasedBytes`）→ 同一件事三套名字 | `已复现（计数）` |
| P1-17 | 字符串当契约 | journal 名 22 处 `categoryName:"…"` 字面；`AppState:347/406/587` 写 `cat.title`，`HistoryView:367` 用 `$0.title == name` 反查 + `contains("重复"/"卸载")` 映射图表色；`CleanItem.rule` 是 String（53 条规则 + `Scanner` ~50 处 `rule:"X"` + `Scanner:15 implementedRuleIDs` 第三份清单）；`CategoryDetailView:1540-1543/1562-1565` 两处各算一遍 `rule == "A1" \|\| path.contains("/Application Support/")`；护栏清单三份合一（`FileSystem:1139` ≡ `HardlinkDedupService:153` ≡ `CLICacheScanner:35`，已记 v1.73.8 待议 3）本轮**又长出第 4 处** `SpaceVisualizerModel:338` | `审计提出` |
| P1-18 | 体积口径两轴（= 既有待议 #15） | 实测裂口：`du -sk -A ~/.cargo` = 295,547 KiB，其中点号条目 35,456 KiB（12%）——`directoryStats`（跳隐藏、下钻包）与网关 `measure`（不跳、不下钻）在同一棵树上就是两个数；面板与记账谁对谁错**逐模块决定**，一刀切已被 v1.73.11 复审实测驳回 | `已复现（数字）` |
| P1-19 | 待议 #18 / #20 | ①"只读到下限"接进主链路（本机 `--scan` 实测 0 命中 → 分支可达性靠不住，但**夹具可测**，见 `Selftest+DeletionGate` 的 mode-000 夹具）；②历史 `pendingTrashBytes` 从不与废纸篓现状对账：清空废纸篓会另记一条「彻底删除」、放回原位后两个数同时错，于是"累计释放 + 另有 X 未释放"会互相否定 | `已复现（本轮遗留）` |

## 4. P2 队列（新模块与体验）

**新模块候选（真机量过，按"量大 + 判据可自证 + 误删代价可控"排）**

| 候选 | 真机实测 | 判据怎么自证 | 误删代价 | 现有覆盖差集 |
|---|---|---|---|---|
| rustup 组件治理 | 单组件文档件约 **909 MiB** | `lib/rustlib/components` 列已装组件，`manifest-<component>-<target>` 逐行给出该组件**拥有**的 `dir:`/`file:` —— 这是工具自己的账本 | 零用户数据，`rustup component add …` 一条命令还原 | `CleanPaths` 无任何 rustup 路径；D9 只管 `~/.cargo/registry` |
| CLI 自升级 `.old` 二进制 | 约 **178 MiB** | 同目录存在更新的同名 `<name>`，本文件是 `<name>.<纳秒>.old` 替换前副本 | 无，升级器不再引用 | D15 只管全局 node_modules 前缀 |
| cargo `registry/src/` 解包重复 | 约 **209 MiB**（336 包 ↔ 336 `.crate` 全配对） | 逐包要求 `cache/<r>/<pkg-ver>.crate` 同名字节存在，src 只是它的解压 | 下次构建重解包（秒级） | D9 整片粗判会连带 index |
| Chromium 系新位缓存（**这是修 bug 不是新增**） | 单 Profile 数十 MB～近 GB | 宿主 bundle 未跑 + 以 `<Profile>/Cache` 结尾 | 重下网页资源 | **B2 扫的是 `Application Support` 下的 `Cache`，现代 Chromium 已搬家 → 实测该路径不存在 ⇒ B2 恒 0**（"规则在册但界面从未列过某项"＝P1 类） |
| `confstr DARWIN_USER_CACHE_DIR` 其余条目 | 约 600 MiB / 763 条目（多数目录名就是 bundle id） | bundle id 反查已装 App + 未跑 + `lsof` 无持有者；文档明说系统不自清 | 单 App 冷启动重建 | D13/D14 只放行两个具名模式 |

**明确不做（含理由，别再提议）**：名为 `backups` 且宿主在装的迁移目录（是数据不是缓存，反而要进反例名单）；
Maven/rustc 按需解析、不留引用表的"旧版本构件"；签名克隆类活跃临时树（量最大但无活引用证据）；
`/private/var/folders/**/T` 整片放开；游戏平台库目录（用户数据）；
以及既有否决项：IM/协作媒体缓存、云盘占位、Mail/Messages 附件、照片图库内部、CoreDuet/`/var/db`、需 sudo 或触发 SIP 的一切。

**体验/性能**：`body` 里重复计算的过滤/分组（v1.72.5 只修了分类列表）、常驻轮询未降档、
`--scan` 是最大耗时项（无头扫描按分类计时无基线可查——先把耗时写进 `--scan` 输出再谈优化）。

## 5. P3 队列（文档与卫生）

| # | 位置 | 症状 → 后果 |
|---|---|---|
| P3-1 | 90 条版本标注中 **61 条首入 tag = v1.73.10**（`TrashAutoEmptyService:3`、`AppUpdateScanner:5`、`ShredderService:5`、`AIChatView:639`、`DiskMonitor:57`、`CategoryDetailView:184/1178/1442`、`README:68/86/326`、`mainstream-parity:14-17`、`RELEASE-CHECKLIST:92/101/374/387`） | 用户按 release notes 找不到功能；"无撤销快照"这类**安全口径被记晚四轮**。改标注会让 blame 指向今天的 docs 提交、更不可审计 → 正确做法是新增 `docs/VERSION-ANNOTATIONS.md` 差集表（脚本可复现）+ 在下版 notes 点名 |
| P3-2 | `README:27/398-399/486/495` 仍称"唯一 `enumerator(atPath:)` 豁免点"，实测产品源码已 **0 处调用**；自检计数四处互斥（README 713/700/666、KNOWN-ENV 675、CHECKLIST 649/602/559）；规则数 53 vs README 写 52；`space.claim()` 实测 18 处 vs 文档"19 副本/约 20 处" | **可数声明失真即谎报**。全部改成"取当前值"或由 lint 钉住 |
| P3-3 **(部分已处理 2026-10-01：v1.73.15 那份已改名 `untagged-2026-09-28-mainstream-parity-zcode-subagent.md`，命名规则也补进了 `code-review/README.md`；剩下的 `v1.73.13-14`、6 份时间戳稿与 ERRATA 未动)** | ~~`docs/code-review/v1.73.15-zcode-subagent.md`~~（复审稿先于 tag 存在，且它复审的是被并入 v1.73.10 的工作）、`v1.73.13-14-zcode-subagent.md`、6 份时间戳命名稿违反 `code-review/README.md:13`；`1fc2415` message 复制自 `ddb0a66`；三个 tag 提交的 diff 只有 VERSION 一行却写整轮功能 | 历史错账。**不改写已发布历史**：新增 `docs/ERRATA.md`（短哈希 → 实际内容），并立规"bump 提交只写 bump、复审稿不得早于 tag" |
| P3-4 | `docs/SENSITIVE-DATA-AUDIT.md:139-143/183` 公开了开发者本机 `history.json` 的体量与内容画像，且 `:138`「已删除」与 `:183`「含真实密钥」口径互斥 | 自查文档自己踩红线；改成区间口径 |
| P3-5 | cron 指令：规模数字（170 文件/5 万行）与 P2 选题（Android AVD 已发布）都过期；cron 当前 `enabled=false` | 未来自动轮会回退到已完成方向。改成"判据 + 已否决清单"，不写具体待办 |
| P3-6 | `release.sh:263-281` 基线侧与实测侧归一规则不一致（只有一侧 `sed 's/（.*//'`）；11 处固定 `/tmp/mc-release-*` 路径 | 基线粘全称会每次假拦；并行发版会互相覆盖失败集 |

## 5bis. R2 实测中**新发现**的两条（写在这里，免得下一轮重新审计）

| 级别 | 位置 | 症状 | 触发条件 | 建议判据 |
|---|---|---|---|---|
| **P1** | `DeletionLedger.write` 里 `trashedBytes > 0 ? trashedBytes : nil` + `History.swift` 的 `pendingTrashBytes`（mode 回推那一支）+ `Cleaner.swift:39` 的 `item.permanentDelete || permanently` | 一条 mode 写「废纸篓」的记录，若**每一项都被强制彻底删除**（源本来就在废纸篓里），`trashedBytes` 记成 nil → 回推把**整批**算成"还压在磁盘上等清空废纸篓"，而磁盘上一分不欠：历史页与导出把它算进「待落定」，「累计释放」相应偏低，界面那句"清空废纸篓才算数"对这批字节是**假的** | 清理一批已经在废纸篓里的条目（废纸篓分类、以及"清空 N 天前"那两条链路都会造出这个形状） | 区分「测出来是 0」（写 0）与「老记录不知道」（写 nil）；`Selftest+DeletionGate` 里已有一条相邻的"混合落点"夹具可以照着扩 |
| **P2** | `ScreenshotsOrganizerScanner.swift:360`、`DownloadsOrganizerScanner.swift:326`、`HardlinkDedupService.swift:418` 与 `:472`（共 4 处 `HistoryStore.append`）| G20 的 lint 只覆盖 `Cleaner.clean` 与点名的 5 个文件；这三处仍**自己** `HistoryStore.append` 造行，mode 字面量、200 条上限、Optional 字段约定各抄一份 | 下次改 `CleanRecord` 字段语义时要同步 4 份写入点，漏一处就是口径分裂 | 并进 `DeletionLedger.write`（归档类已有 `modeOverride` 这条路），然后把 lint 升级成"产品源码里 `HistoryStore.append` 只允许出现在 `DeletionLedger.swift`" |
| **P1** | `Cleaner.swift` 的 `clean` 仍是 `internal`：任何文件都能直接调它，而"唯一出口"目前只由**文本 lint** 兜（needle 已做到"去括号 + 挤空白"，判据是"出口内 ≥1 处、出口外 = 0 处"的归属形式） | 只要有一条产品路径直接调 `Cleaner.clean`，删除就发生而历史与快照都没有——即本轮修的那个 P0 形状，只是换了成因 | **下一次发版前的硬条件**：把 `Cleaner` 的 `clean` 并进出口文件、设 `private`，让"除出口外调不到"由编译器保证、lint 退成兜底。代价是 `Cleaner.Result` 的可见性与 20+ 处类型引用要一起理。**本轮已做到的部分**：注入缝 `deleter` 用 `#if MACCLEAN_SELFTEST` 关出 release 产物（实测 `MACCLEAN_NO_SELFTEST=1` 构建的二进制里 `deleter` 符号数 = 0），并加一条 lint 钉住"产品文件不许引用 `.deleter`" |
| **P1（R3 新增，实测残留）** | `Cleaner.swift:57`（新加的软链判据）只判**原路径自身**是不是软链 | 中间某一级目录是软链时（`~/Downloads/x` → `~/ elsewhere/`），`realPath` 仍会跳出去，闸门链是对"跳出去之后的目标"做的：目标在主目录内就算安全，于是删的是**列表上没写的那个位置**里的文件。扫描侧靠 `isRealDir`（不跟随软链）不下钻，所以只有**卡片自己拼出来的路径**（下载归档、截图归档、去重、重复组）可能撞上 | 逐段 `lstat` 走完 `path` 的每一级祖先，任一级是 `S_IFLNK` 即拒（成本：每项多次 lstat，可与现有的祖先属主判定合并成一次遍历）；先用一次性夹具目录把"中间级是软链"的形状造出来，证明断言会红再动手 |
| **P1（实测存活，本轮未修）** | "把两处调用改接一个**同名同标签的空实现**"：`LedgerHook.recordTrashedOriginal(categoryName: "大文件归档", …)` | 字面量全留、一行账都不落，而 `707 通过 / 34 失败` 与基线一字不差（变异 MU-N6 实测）→ 归档/迁移这条链路将来可以静默退回"只删不记" | 接线判据是文本级的（presence 与计数都看不见控制流）。封死只有两条路：同上一条的编译器保护，或真跑一次 `archiveInPlace`（会 `ditto` 并把原件扔进**真废纸篓**，自动轮里不该动用户文件，而唯一覆盖它的 `SpaceArchiveDeep` 在本机崩溃未执行）。**本轮正因这一条修不掉而不打 tag** |
| **P1（三次复审 P1-2，口径未定）** | 保留的「安装包 ≥7 天 / 压缩包 ≥30 天」两档，内部**仍是纯年龄翻转** | 用户自制的 `.zip/.dmg/.iso` 满 30/7 天会被默认勾选并一键移入废纸篓；而而 `Selftest+DownloadsOrganizerDeep` 里 `preselected != byRule` 那一支（现 :561-564）把「200 天的 c.zip 必须预勾」钉成了规矩——下一轮照 G2「只剩 T0 一条例外」推理就不会再查它 | 二选一：①把徽章 + 默认勾选降到「类别之外还要所有权/引用证据」并改掉那两条断言；②维持现状，但 G2/README 必须明说这两档的依据只有类别 + 年龄（**本轮已按 ② 把措辞改成与实样一致**）。落点是废纸篓、可撤销，所以没到 G21 那种程度 |
| **P2（三次复审 P2-2）** | `Cleaner.swift:57` 拒软链之后只 `append + continue`，没有「这是软链，请点名目标」的出口 | 缓存类里的合法软链会永远报失败且无路可走；另外同一 item 多路径时任一路径失败就不计整个 item 的 `releasedBytes`（`Cleaner.swift:105-113`），于是「实际删了一个路径却少报字节」 | 文案分档（软链 ≠ 删不动）+ 可选的手动删除入口 + 逐路径入账；需要产品决定，本轮未动 |

## 6. 轮次编排（每轮 30–60 分钟一刀，含依赖）

| 轮 | 做什么 | 为什么先它 | 会不会打红既有自检 |
|---|---|---|---|
| ~~R1~~ **已做（2026-10-01）** | **P0-5 脱敏门禁**（abs 先判类型、fixture 只判片段、skip-scan 即 die、pathspec 对齐、补 `github_pat_`/大小写/commit-tag message） | 唯一"一旦错了就删不回来"的一类；纯脚本，零产品行为 | 否（新增脚本自检） |
| ~~R2~~ **已做（2026-10-01，v1.73.15）** | **P0-1 + P0-2 合并**：删除记账与撤销快照收成单一出口 `DeletionLedger`，静默清理/卸载器/去重/孤儿/归档五处复用 + 三条腿自检（全仓 lint / 接线 lint / 行为） | 无人值守链路正在每天删用户文件且不可放回 | 实测只需同步 3 处 `recordClean` 调用（`Selftest+SystemAndHistory`、`+Foundation`、`+DeletionGate`）；计划里点的 `Selftest+Undo` 与 `PreferenceResidueDeep:191` **不用改**（前者自己造快照、不依赖 AppState 写手） |
| ~~R3~~ **已做（2026-10-01，随 v1.73.15 发出）** | **P0-3 软链 + P0-4 默认勾选降级** | 两条都是「界面上没说错但删多了」 | 实测只红一条断言：`Selftest+DownloadsOrganizerDeep` 里那条**把 P0 钉成规矩**的 `guard oldDoc.isHighlyRecommendedToClean`（100 天的 pdf 断它为真）。截图侧那条同形兜底是死代码，已按实测更正（见 §5bis）。**三次复审**（退化路径：qoder `general-purpose` 子代理，理由见 review 文档）在副本里跑出的四条都已处置：**P1-1**（行为判据只钉 `permanently: true`，`guard !(forcePermanent && isSymlink(path))` 两支全绿）→ 已补默认支。
          ⚠ 第一版补法是我自己造的一条**假绿**：夹具用了悬挂软链，推理是"门控变异会让它静默跳过"，
          实测悬挂软链的 `realPath` 按词法返回软链自己、变异随后被 `isSafeToClean` 第一层的 `isSymlink`
          顺手拒掉，`failedPaths` 照旧——**拒绝来自别人**，判据死了也不红（是我重跑变异才看见的）。
          终版夹具改用**活目标**，并照仓里「混合落点」那条的既有做法只清自己建的东西、
          删除清单取返回的 `trashedSnapshots`（实现正确时它是空的，用户废纸篓一分不脏）；**P2-1**（顺序判据比的是「整档第一次」，被 `isSymlink(realPath(path))` 与一句永不执行的 `if false { _ = isSymlink(path) }` 双双绕过）→ 已改成按 `for path in item.paths` **循环体**切、并要求 `guard` 形状；**P1-2 / P2-2** 属产品口径 → 已搬进上面的 §5bis 待议；**P3** 注释与文档例子形状不一致 → 已统一。另按同一条线找到第三处同族死判据并一起修（G21b，`HardlinkDedupService.preflight`，定 P1：扫描侧已滤软链，可达路径是 TOCTOU 替换与非扫描调用方）。变异复测：`Cleaner` 三条 MU-R2a/b/c、去重三条 MU-D1/2/3——其中「判据整块挪到解析之后」这一档**只红顺序判据**（行为等价，这正是顺序 lint 的设计目的），语义回归与整块删除两支顺序 + 行为双红，**无存活**。⚠ 更正：先前报过一条「MU-R2 变异存活」，实测是我自己的锚点错了（把判据挪过一行**注释**而不是挪过 `realPath`），它既不是回归也不是存活；重跑后已按真形状重做 |
| R4 | **P1-1 lsof 三态 + P1-14 形状断言**（含把 `contains("占用进程：无")` 改成方向断言） | AI 建议的输入正确性；顺带拆掉替旧实现兜底的恒绿 | 否 |
| R5 | **P1-12 崩溃套件隔离**：新建 `Selftest+UIRenderQuarantine.swift`，把 7 个崩溃套件里会崩的渲染 check 整块搬进去 | 约 **44 条断言立刻回到记分板**（696→≈740），恢复 `cleanSelected` 闭环与并发记账写入的执法力；这是后续每一轮的地基 | 要同步刷新 KNOWN-ENV 的 S 段（`release.sh` 会强制） |
| R6 | **P1-8/P1-9/P1-10/P1-11 恒绿清扫** + `scripts/mutate.sh` 落地（rsync 副本、一次性状态目录、打印三集合差、锚点命中数≠1 判 ERROR） | 执法力本身；脚手架让后面每一轮都省事 | 否 |
| R7 | **P1-16 元组先收口**（`SpotlightScanner:325`、`PreferenceResidueInspector:274` 改回返回 `Outcome`） | 全仓唯一"新字段完全无法沿用"的形状；结果面 8→6、转发成员 51→42；**不碰任何 `#filePath` 文件名 needle** | 只红 `PreferenceResidueDeep:191` 字段名断言 |
| R8 | **P1-3 承诺侧收口**：新增 `SpaceDisposition.promise(bytes:defaultToTrash:)`，10 处动作前文案改走它 | 与 v1.73.14 同一族的另一半 | 会红若干文案断言 |
| R9 | **P1-6 空态谎报 + B2 恒 0 规则**（`unreadablePaths` 渲染通道、C1 反例名单、Chromium 新位） | "读不到被讲成干净"是本项目第一优先级族 | 否 |
| R10 | **P1-2 磁盘口径同屏标注 + P1-18/#15 逐模块口径决定**（先量后改） | 需要产品决策，放在实数据之后 | 否 |
| R11 | **P2 新模块：rustup 组件治理**（判据来自 rustup 自己的 manifest 账本；D25；`~/.rustup` 进 CleanPaths；5 条自检） | 唯一"量大 + 可自证 + 一条官方命令还原 + 零用户数据"的新模块 | 新文件，无既有断言受影响 |
| R12 | **P3-1..P3-6 卫生包**（`VERSION-ANNOTATIONS.md` + `ERRATA.md` + README 可数声明 + cron 指令 + `release.sh` 归一/mktemp） | 纯文档/脚本，适合任何一轮的尾巴 | 否 |
| 待验证 | P1-4 APFS 克隆 `freed`、P1-19 两项、`.trashDirectory` 跨卷解析、`item.permanentDelete` 全部赋值点 | 需要先造夹具/读数，**不许据此直接改护栏** | — |

## 7. 三条元规则（从本轮踩到的坑提炼）

1. **改口径之前先数副本**。"释放 X"这句话有 19 个手写副本，所以修一处漏 18 处；
   副本 > 1 就把动词收进一个构造器 + 一条带反向绊线的源码 lint，而不是逐处补文案。
2. **加断言之前先证明它能红、并证明它所在套件会跑完**。本轮一条 ViewInspector 渲染断言
   崩掉整条套件（682→654 通过），而 `Selftest+DeletionGate.swift:149` 的 `|| true`
   说明"写在能跑的套件里"也不等于"会红"。
3. **门禁的豁免面比检测面更值得审**。`fixture_shape` 判整行、备案表先于计数、
   `hist * private_key` 豁免全历史——这三条都不是"漏检"，是"检到了但被自己放走"。
   R1 已按此做完，并补了 `scripts/scan-selftest.sh`（38 条夹具，含"扫描器自己坏了"与
   "真拦住了"的区分，以及"哪一侧拦的"归因）。**新学到的三条判据**：夹具必须与判据有判别力
   （等价夹具造出的断言永远不可能红，变异验证两轮都抓不出来——abs 一档在片段判据之前就返回，
   所以它**永远**测不到"判整行 vs 判片段"，得另配非 abs 的正反一对）；驱动被测脚本的自测必须
   带递归标记；结构性 grep 判据必须锚行首，否则把那一行注释掉就变异存活。
   实测数字（分两批，别混成一个漂亮总数）：
   - **实现者自查**（补 r2 之前）：15 个变异，14 个判红，1 个（`scan_history` 的"有提交但索引为空 → die"
     分支）本机造不出可达状态、**永久存活**，已在 `RELEASE-CHECKLIST` 里如实标注。
   - **独立复审 `reviewer-r2`** 另做 18 个变异，**10 个存活** → 暴露的是我那批矩阵根本没碰的面：
     四条规则零覆盖、默认档范围无人守、`--cached` 语义、备案粒度、探针 die、`mask`、`SCAN_RAN`。
     这十条本轮全部补了保护 + 夹具（自测从 22 条涨到 38 条）。
   两批不是同一批变异，所以"判红率"不可横向比较；写在一起只为了说明一件事：
   **自建矩阵只会覆盖"自己想到的错法"**，豁免面的缺口要靠另一双眼睛。

4. **"出现过"与"出现几次"都不是判据，点名"这一处调用长什么样"才是**（R2，2026-10-01，变异实测）：
   给"五条链路都接上了出口"写判据时，第一版数的是 `recordTrashedOriginal(` 出现次数（≥2），
   因为归档与迁移共用一个私有 helper。结果变异把其中**一处调用删掉**，文件里仍剩
   "helper 定义 1 次 + 另一处调用 1 次 = 2 次"，判据不响——**计数把定义当成了调用点**。
   同一轮里另一条同类教训：`Cleaner.clean(` 的全仓 lint 如果只判"不许出现"，
   那么把出口里那一句整个删掉会让命中数变成 0，"无人违规"于是等于"合规"。
   两条改法：① 判**恰好等于 N 处**并把 N 的来源写在注释里（0 也判红 = 活性证据）；
   ② 接线判据点每一处调用自己的关键字面量（`categoryName: "跨卷迁移"` 这种），
   删任一处必红，且不会被定义、注释或同名的另一处调用冒充。
