# 清理规则的行业与 OS 契约调研（MacClean 规则重构输入）

> 回答两件事：①"确定是垃圾"能否不依赖某个用户的习惯；②规则如何按 **时间/安全/影响** 分层。
> `[实测]` = 本机执行命令得到；`[man]` = macOS 自带手册页；其余给一手链接；`（未验证）` = 未取得一手来源。

## 1. Apple 的目录契约（合法性的唯一来源）

- `~/Library/Caches`：放"**app 能轻松重建**"的文件，但"**内容由该 app 负责管理**"；系统在磁盘极度不足时可能整体删除，"**绝不在 app 运行期间发生**"。`~/Library/Application Support`：放 **app 的数据文件**，语义是数据不是缓存。[FSPG, Table 1-3]
- `_CS_DARWIN_USER_CACHE_DIR`："适合放用户缓存数据，**因为系统不会自动清理它**"。`_CS_DARWIN_USER_TEMP_DIR` 是临时目录。[confstr(5)]
- 粘滞目录里"只有文件属主/目录属主/root 能删除或改名"[sticky(7)]；`~/.Trash` 是 `drwx------`（0700，**无粘滞位**），`/private/tmp`、`/private/var/tmp` 是 `drwxrwxrwt`（**有**）——两者保护机制不同 [实测]。
- 无 Full Disk Access 时读 `~/Library/Containers/com.apple.Safari/Data/Library/Caches`、`~/.Trash`、`~/Library/Application Support/Knowledge` 均 `Operation not permitted` [实测]。
- `mdutil -E` 擦除索引、"合适时自动重建"[man]；`atsutil databases -remove` 会**丢失字体注册状态**（标准目录外激活的字体、被禁字面、字体库），需注销/重启重建 [man]——"可重建 ≠ 无损"的 Apple 自证例子。
- `tmutil` 有 `listlocalsnapshots / deletelocalsnapshots / thinlocalsnapshots <mnt> <amount> <urgency>`，部分动词需 root+FDA；本机快照为空 [实测]。
- `com.apple.bsd.dirhelper.plist` 里 `CLEAN_FILES_OLDER_THAN_DAYS = 3`，每日 03:35 + RunAtLoad；而 `dirhelper(8)` 手册页只自称"特殊目录创建助手"，**不记载清理职责** [实测]。
- 磁盘"可用空间"多口径并存：`df` 92.0 GB vs `diskutil` Container Free Space 94.2 GB；Apple 未公开定义磁盘侧 purgeable space `（未验证）`。

**atime 可用性**：Data 卷挂载参数无 `noatime`（`/System/Volumes/VM`、`xarts` 有），实测读取后 atime 确实更新；抽样 `~/Library/Caches` 400 文件：338 个 `atime==mtime`、60 个 `>mtime`、2 个 `<mtime` [实测]。可用但**不可单独作证据**（外接卷可能 noatime；`kMDItemLastUsedDate` 本机仅 134 个文件有值）。

## 2. 同行怎么做（可核查部分）

**Pearcleaner**（Swift，source-available/fair-code；README 自述已无法主动开发 → 当参考不当依赖）
- 扫描位置是显式白名单表（`Locations.swift` 约 38 条），含 MacClean 未覆盖的 `~/Library/HTTPStorages`、`WebKit`、`Application Scripts`、`com.apple.LSSharedFileList.ApplicationRecentDocuments`、各 SDK 目录（`SentryCrash`/`com.crashlytics`/`Amplitude`/`Rollbar`/`org.sparkle-project.Sparkle`/`com.google.Keystone`）。
- **`skipReverse`（约 200 词元）＝永不归属给任何 app 的名字黑名单**：含 `crashreporter`、`byhost`、`globalpreferences`、`caches`、`clang`、`swiftpm`、`python`、`sparkle`、`sentry`、`knowledge`、`mobilesync`、`coresimulator`、`webkit`、`databases`、`spotlight`、`symbols`、`cef`、`trash`、`diagnostic`。另有 `skipDeepSearch`（约 90 个"绝不含第三方文件"的 Library 子目录）。
- **per-app 例外表** `conditions: [Condition]`：按 bundle id 给 include/exclude + `includeForce`/`excludeForce` 绝对路径（Xcode、VS Code、JetBrains、Arc、Steam）；另有用户可见的 `SearchSensitivityLevel`（默认 `.strict`）。
- **卸载当事件抓**：`PearcleanerSentinel`——`.app` 进废纸篓的当下完成归属，事后不猜；Steam 的 `steamapps/common/<game>` 特判永不当残留。

**BleachBit**：清理单元是 **`(app, 数据类)` 选项**而非目录——`chromium.xml` 把 `cache`/`cookies`/`crash_reports`/`form_history`/`history`/`search_engines` 拆成 6 个独立开关，危险项带 `<warning>`（firefox："This option will delete your saved passwords."），共 108 个 cleaner。其 macOS 的 FDA 探测点精确设为 `~/Library/Safari/`、`~/Library/Caches/com.apple.Safari/`、`~/Library/Containers/com.apple.Safari/`，并区分 `EPERM`（TCC）与 `EACCES`（"不是 TCC 信号"）。

**工具自带语义优先**：`brew cleanup` ＝"移除 stale lock 文件、过期下载、已装 formulae 的旧版本"，**保留 120 天内的下载**（`HOMEBREW_CLEANUP_MAX_AGE_DAYS`）、`--prune <days>` 按天清缓存；`brew autoremove` 只删"作为依赖装的、现已无人需要"的包。Docker 的定义是引用闭包："A dangling image is one that isn't tagged, and isn't referenced by any container"，破坏性命令前置 `WARNING! This will remove all stopped containers.`／`…anonymous local volumes not used by at least one container.`。npm 推荐 `cache verify`，`clean` 必须 `--force`（该页正文抓取受限）。

**未取得一手资料** `（未验证）`：CleanMyMac X 各模块的删除清单（用户指南 PDF 11 MB 超抓取上限，只有 SEO how-to 页）；AppCleaner 的搜索路径（只公开"拖 app"交互）；OnyX 清理项（`titanium.dk` 抓取失败，而结果里的 `titaniumsafe.com` 已跳转域名交易页，**不是** OnyX 官网，勿写入 README）；iCloud「桌面与文稿」对删除的跨设备扩散细节；Maven `*.lastUpdated` 与 Xcode 自动重下 DeviceSupport 的官方措辞。

## 3. 与 MacClean 现规则的冲突

- **C6 / B3 事实上执行不了**：无 FDA 读他人容器 `EPERM` [实测]。不是"0 项"而是"看不见"，G13 必须在这两条产出 `ScanIssue` 并引导授权。
- **C4 比工具自己更激进**：brew 保留 120 天内下载且不动已装 formulae 的下载，C4 是"存在即 trash"。改为对齐 `--prune` 语义。
- **C3/D4/D9/D16/D18 的"无损"前提不成立**：可重建的前提是重建可达。本机 brew/ghcr 近乎不可用、HF 需镜像 → 本质应是"可重建 **+ 重建成本**"，成本按本机探测。
- **L7 与业界相反**：`Application Support/CrashReporter/*` 现判 `staleArtifact→可清理`，而 Pearcleaner 把 `crashreporter` 列入永不归属名单。L2 同理：崩溃报告是用户向 Apple/开发者取证的唯一凭据，删除有外部性（不可重建的历史事实）。建议降 T1，并要求"已成功上报/已被取走"作正向证据。
- **D23 分类错**：`Docker.raw` 是卷的后备存储，按 Docker 口径属永不自动 prune 一类 → 归"只报告"，并链到 `docker system df` / `image prune`。
- **L3 判据用错**：条件写"当前用户可写"，但粘滞目录里删除权来自**文件属主**[sticky(7)]；应为"属主==当前用户 && `lsof` 无句柄"。
- **§7.4 表述要改写**：dirhelper 是"文件年龄 > 3 天即清，每日 03:35 跑一次"，不是"每 3 天清一次"，且唯一凭据是 plist。这恰好给出可复用范式：**系统自己承认"3 天无人使用的临时文件即垃圾"**。
- **T2/T3 的"大/旧"不是证据**：`>500MB`/`>1GB`/`>180 天未访问` 与"是垃圾"无因果；`~/Desktop`（T3）在 iCloud「桌面与文稿」下是跨设备副本 `（未验证）`——G6 保护了 `~/Library/Mobile Documents` 却把 `~/Desktop` 当本地数据卖出去，口径不一致。建议移出"可清理"，改走空间审计。
- **D8 是被低估的确定垃圾** `（未验证）`：Maven `*.lastUpdated` 是失败标记，删掉它正是重试手段；若确认应从 `inferredUnused` 升 T0。**D21 同理** `（未验证）`：DeviceSupport 由 Xcode 连真机时自动重下，成本可量化，宜 T1 而非"可清理"。
- **A5/A2**：Pearcleaner 同时永不归属 `byhost` 与 `globalpreferences`；Apple 自身的 ByHost 分片须靠 G16 正向清单排除。
- **C5 粒度过粗**：业界按数据类拆，`~/Library/Caches/com.google.Chrome` 整目录 ≠ 网页缓存（真缓存已由 B2 覆盖），C5 应只保留确属缓存的部分。
- **现规则里站得住、应保留的**：D13/D14 位于 user cache dir，而 Apple 明说该目录"系统不会自动清理"[man] → 合法性最强；L6 只认 `.ShipIt.` 片段、不清整个 `$TMPDIR`；G9/G13 与 BleachBit 的 EPERM/EACCES 区分同向；G16 与 Pearcleaner 的 `isValidBundleIdentifier` + Sentinel 同向。

## 4. 判定模型提案

**四维权度（不再合并成单一"风险级"）**
1. `contract` 契约：是否落在 Apple 声明的可丢弃区（`~/Library/Caches`、user cache dir、`$TMPDIR`），或由工具自身 prune 语义认定为未引用；`Application Support` 默认是数据，除非命中具名模式。
2. `ownership` 归属：能否**唯一**解析到 bundle id/包名，且不在 `skipReverse` 式词元黑名单、不触 G6/G8。归属失败即不得进入任何自动档。
3. `hostState` 宿主：`installed` / `uninstalled(正向证据)` / `unknown` / `system`；`unknown` 一律不升级。
4. `restore` 重建代价：`none` / `auto-cheap` / `auto-expensive`（重下 N GB、需联网可达、重编译）/ `state-loss`（重建但丢状态，如 `atsutil`）/ `impossible`。**必须在本机测量**，不由规则作者宣称。

**分层**
- **T0 确定是垃圾**：四条同时成立——①契约满足或工具自证未引用；②归属唯一且宿主未运行；③`restore ∈ {none, auto-cheap}` 且无状态丢失；④依据是**结构标记**（`.ShipIt.`、`*.log.N`、未被任何 `opt` 链接引用的 Cellar 版本、dirhelper 式系统阈值），而不是"某人不用了"。**唯一可默认勾选的层。**
- **T1 可清理、有代价**：契约满足但 `auto-expensive`（DerivedData、JetBrains 索引、C3/C4 类下载缓存）。默认不勾，提供"本层全选"。
- **T2 需你裁决**：归属或宿主为 `unknown`、`state-loss`、影响跨设备。
- **T3 只报告**：用户数据、备份、`Docker.raw`、APFS 快照、归档。
- **不列出**：G6/G8 + 词元黑名单。

**让 T0 不依赖个人习惯的三个装置**
- **适配性门控**：规则先声明触发证据（本机存在该 bundle id、`brew` 可执行且 `HOMEBREW_PREFIX` 解析成功、存在 `~/Library/Developer/Xcode`）。证据缺失则该规则**不出现**，而非出现为 0 项——"换一台机器"自然得到不同规则集，判定逻辑不用改。
- **策略覆盖按 `(规则, 归属对象)` 双键**：默认值来自契约，用户只写例外（Pearcleaner `conditions` 的做法）。
- **从撤销行为学习**：默认 trash + 已有 `UndoSnapshot`/历史，"删后从废纸篓恢复"是本机真实发生的信号；按 `(规则, 路径前缀)` 统计 restore 率，超阈值即降出 T0 并说明原因，"清过两次且从未恢复"才可升。这把"我不需要"换成"这台机器的行为证明不需要"。
- **不确定性外显**：每条结论列出用了哪几维、缺哪一维（借 BleachBit 的 `<warning>`＋选项粒度、Docker 的 `WARNING!` 前缀范式）；读不到 ≠ 干净。

## 5. 需要 owner 拍板

1. T0 是否允许**默认勾选**（现 G2 是全不勾选）？不允许的话，"确定是垃圾，直接处理"怎么在产品上兑现？
2. 是否申请 Full Disk Access？不申请就删 C6/B3/B1，申请则 §7 权限口径要重写。
3. `restore` 维度允许做网络可达性探测吗（决定 C3/C4/D4 能否留在 T1）？探测本身隐私敏感。
4. L2/L7 崩溃报告：跟业界走（保留取证价值）还是维持"可清理"？
5. T2/T3（Downloads、大文件、Desktop）留在"清理"里，还是迁到独立"空间审计"？
6. 是否把 **Apple 自己的 3 天临时文件阈值**写成 MacClean 的公开基线，替代主观判断？
7. 规则表是否外置为 JSON/plist + 例外表？会影响 `CleanupRules.swift` 与自检的一致性校验方式。
8. 采纳"从废纸篓恢复学习"＝在本机积累使用统计，是否接受（可完全本地化，但需写进隐私说明）？

## 参考来源

- File System Programming Guide · FileSystem Overview（Library 目录表）：https://developer.apple.com/library/archive/documentation/FileManagement/Conceptual/FileSystemProgrammingGuide/FileSystemOverview/FileSystemOverview.html
- App Sandbox：https://developer.apple.com/documentation/security/app-sandbox ｜ volumeAvailableCapacityForImportantUsageKey：https://developer.apple.com/documentation/foundation/urlresourcekey/volumeavailablecapacityforimportantusagekey
- 手册页 `confstr(5)`、`sticky(7)`、`mdutil(8)`、`atsutil(8)`、`tmutil(8)`、`dirhelper(8)`；`/System/Library/LaunchDaemons/com.apple.bsd.dirhelper.plist`
- Pearcleaner：https://github.com/alienator88/Pearcleaner （`Logic/Locations.swift`、`Logic/Conditions.swift`、`Logic/AppPathsFetch.swift`、`PearcleanerSentinel/`）
- BleachBit：https://github.com/bleachbit/bleachbit （`cleaners/chromium.xml`、`cleaners/firefox.xml`、`bleachbit/Mac.py`）
- Homebrew：https://docs.brew.sh/Manpage ｜ Docker pruning：https://docs.docker.com/engine/manage-resources/pruning/ ｜ npm：https://docs.npmjs.com/cli/commands/npm-cache
- MacClean 现状：`docs/CLEANUP-RULES.md`、`Sources/MacClean/Rules/CleanupRules.swift`、`Sources/MacClean/Models.swift`（`ItemNature × UseState → Recommendation`）
