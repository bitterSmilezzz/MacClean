# 清理规则重排规格（v2 草案）

> 输入：`docs/research/cleanup-rules-industry.md`（含本机实测证据）。
> 本文只定"规则怎么排"，不含实现代码。落地顺序见 §5。

## 1. 已定决策（owner 2026-09-21）

| # | 决策 | 影响 |
|---|---|---|
| D-1 | **T0 允许默认勾选** | 现有 G2「一律不默认勾选」要改成"仅 T0 例外"，并配一条自检守住"非 T0 永不默认勾" |
| D-2 | **申请完全磁盘访问权限（FDA），分权限口径** | C6/B3/B1 保留；所有受权限影响的规则必须显式产出 `ScanIssue`，禁止把"读不到"报成"干净" |
| D-3 | **凭大小/年龄判的项迁出清理** → 独立「空间审计」 | T2/T3/T5（Downloads、大文件、iOS 备份）从清理页移除 |
| D-4 | **不允许联网探测重建代价** | 无契约依据的下载缓存一律降 T2；有工具自带 prune 语义的按该契约定档 |

owner 未表态、我按推荐默认执行的四条（可随时推翻）：

- **L2/L7 崩溃报告**：降 T2。理由：它是用户向 Apple/开发者取证的唯一凭据，属"不可重建的历史事实"。
- **采纳 Apple 自己的 3 天阈值**作为 L3/L4 的公开基线（依据：`confstr` 手册页原文 + `com.apple.bsd.dirhelper.plist` 的 `CLEAN_FILES_OLDER_THAN_DAYS=3`，两者本机已复核）。
- **规则表不外置为 JSON**：外置会让"声明与实现一一对应"这条自检失效（自检要能在编译期穷举全部 53 条）。改为在 `CleanupRules.Rule` 上加显式维度字段。
- **采纳"从废纸篓恢复学习"**：完全本地，只记 `(规则id, 路径前缀)` 的删除/恢复计数，不记文件内容；写进隐私说明。

## 2. 判定模型

**四维权度**（不再合并成单一"风险级"，每一维单独可解释）

1. `contract` 契约 — 是否落在 Apple 声明的可丢弃区（`~/Library/Caches`、user cache dir、`$TMPDIR`），
   或被**该工具自己的 prune 语义**认定为未引用（`brew cleanup`、`docker system prune`、`docker buildx prune`）。
   `Application Support` 默认是**数据**，除非命中具名模式。
2. `ownership` 归属 — 能否唯一解析到 bundle id / 包名；不触 G6/G8、不触"永不归属词元表"。归属失败即不得进任何自动档。
3. `hostState` 宿主 — `installed` / `uninstalled`（需正向证据，G16）/ `unknown` / `system`。`unknown` 一律不升级。
4. `restore` 重建代价 — `none` / `auto-cheap`（重编译、重生成）/ `auto-expensive`（重下 GB 级、需特定镜像源）/
   `state-loss`（能重建但丢状态，例：`atsutil databases -remove` 丢字体注册状态）/ `impossible`。

**档位**

| 档 | 含义 | 默认勾选 | 界面 |
|---|---|---|---|
| **T0** | 确定是垃圾 | **是** | 置顶组「确定是垃圾」，一键处理 |
| **T1** | 可清理、有代价 | 否 | 「可清理」组，提供本层全选 |
| **T2** | 需你裁决 | 否 | 「需确认」，逐条给缺哪一维 |
| **T3** | 只报告不删 | 否 | 只读洞察面板 |
| **不列出** | G6/G8 + 永不归属词元表 | — | 完全不出现 |

**T0 的四条硬要求（同时成立才算）**

① `contract ≠ userData`；且契约本身要能独立成立（Apple 原文声明的可丢弃区、
该工具自己的 prune 语义、或文件系统层面的确定结构标记）；
② `restore ∈ {none, auto-cheap}`，且不丢状态；
③ `hostState ≠ installedRunning`；
④ 判据是**结构标记**（`.ShipIt.`、`*.log.N`、`.savedState`、未被 `opt` 链接引用、
Apple 的 3 天阈值），**不能是"某人不用了"**。

第 ④ 条就是"换台电脑、换个人也得对"的落点：它把判定绑在文件系统结构和 OS 契约上，而不是习惯上。
归属（`ownership`）只用于**排除**（`userData` 一律不得 T0），不用于**准入**——
理由见 §3 末尾的修订记录。

## 3. 53 条规则重新归档（步骤 5 后：D19 拆成 D19 + D24）

标 **变更** 的是与现状不一致的。`—` 表示维持。

### C 用户缓存
| 规则 | 现状 | v2 | 依据 |
|---|---|---|---|
| C1 `~/Library/Caches/*` 兜底 | 可清理 | **T1** 变更 | 契约满足，但整片粒度太粗、逐 app 重建代价未测 |
| C2 Xcode 缓存（未运行） | 可清理 | **T1** 变更 | 重建=重编译，`auto-expensive` |
| C3 pip 缓存 | 可清理 | **T2** 变更 | 重下依赖镜像源；D-4 下无契约依据 |
| C4 Homebrew 缓存 | 可清理 | **T1** ✅ 步骤 5 落地 | 按 `brew cleanup` 契约：只碰 >120 天**已完成**下载，不动已装 formulae 的下载物 |
| C5 浏览器缓存 | 可清理 | **T1** 变更 | 收窄到确属 cache 的子路径（整目录 ≠ 网页缓存） |
| C6 沙盒容器缓存 | 可清理(实为 0 项) | **T1** 变更 | 有 FDA 才出现；无 FDA 报 `ScanIssue`，不报"干净" |
| C7 应用内旧安装包 | 可清理 | **T0** 变更 | 位置具名（`updates/*.dmg`）+ 用途已完成 + `restore=none` |

### L 日志与临时
| 规则 | 现状 | v2 | 依据 |
|---|---|---|---|
| L1 `~/Library/Logs/*` 顶层 | 可清理 | **T1** 变更 | 未轮转的日志可能正在被写；只有"已轮转"才是结构证据 |
| L2 DiagnosticReports | 可清理 | **T2** 变更 | 取证价值，不可重建 |
| L3 `/private/tmp`、`/var/tmp` | 需确认 | **T0** ✅ 步骤 5 落地 | 判据改为「属主==当前用户 **且** mtime 超过 3 天」（Apple 自己的阈值）；"当前用户可写"用错判据（sticky(7)：删除权来自文件属主） |
| L4 TemporaryItems | 可清理 | **T0** ✅ 步骤 5 落地 | 同 L3，逐子项；另外"名字看得出属于某个 App"的一律不列（自动恢复草稿） |
| L5 已轮转旧日志 | 可清理 | **T0** ✓ | 结构标记 + 用途已完成 |
| L6 `.ShipIt.` 更新残留 | 可清理 | **T0** ✓ | 结构标记，且不清整个 `$TMPDIR` |
| L7 CrashReporter 目录 | 可清理 | **T2** 变更 | 同 L2 |

### D 开发残留
| 规则 | 现状 | v2 | 依据 |
|---|---|---|---|
| D1 DerivedData | 可清理 | **T1** ✓ | 重建=全量重编译 |
| D2 Xcode Archives | 需确认 | **T3** 变更 | 归档是上传凭证/历史构建产物，属数据，不删 |
| D3 CoreSimulator/Caches | 可清理 | **T1** ✓ | 契约位置 |
| D4 npm `_cacache` | 可清理 | **T2** 变更 | 无网络探测；`npm cache verify` 才是官方语义，本工具不代跑 |
| D5 yarn cache | 可清理 | **T2** 变更 | 同 D4 |
| D6 pnpm store | 可清理 | **T2** 变更 | 内容寻址硬链接库，删了可能破坏已装项目链接完整性，需单独风险标注 |
| D7 gradle caches | 可清理 | **T2** 变更 | 重下代价 |
| D8 maven `*.lastUpdated` | 需确认 | **T0** 变更 | 失败标记，删掉它正是官方重试手段；`restore=none` |
| D9 cargo registry | 可清理 | **T2** 变更 | 重下代价 |
| D10 swiftpm 缓存 | 可清理 | **T1** ✓ | 契约位置（`~/Library/Caches`） |
| D11 `__pycache__` | 可清理 | **T0** ✓ | 目录名即结构标记，自动重编译 |
| D12 Cellar 旧版本 | 可清理 | **T0** ✓ | 未被 `opt` 链接引用 = brew 自己的 stale 定义，结构证据 |
| D13 Clang ModuleCache | 可清理 | **T0** ✓ | 位于 user cache dir（Apple 明说系统不自动清）+ 自动重编译 |
| D14 node-compile-cache | 可清理 | **T0** ✓ | 同上 |
| D15 全局 node_modules 废弃副本 | 可清理 | **T1** 变更 | `.old-/.bak-` 命名是**用户自己起**的，不是工具契约——换个人可能拿它存东西 |
| D16 CocoaPods caches + repos | 可清理 | **T2** 变更 | `repos` 是整个 spec 仓库克隆，重下极贵 |
| D17 buildx cache + Docker log | 可清理 | **T1** ✓ | `docker buildx prune` 是官方契约 |
| D18 cargo git checkouts/db | 可清理 | **T2** 变更 | 重下代价 |
| D19 gradle daemon log + wrapper dists | 可清理 | **已拆分** ✅ 步骤 5 落地 | D19 = daemon log → T0（3 天内没再写入才算）；`wrapper/dists` → 新增 **D24**，T2，且跳过仍有活跃守护进程的版本。拆分时顺带发现 daemon 分支**从未生效**（`children(of:)` 全路径被再 join 一次，路径永不存在） |
| D20 JetBrains 索引/日志 | 可清理 | **T1** ✓ | 索引重建 auto-expensive，历史版本目录需宿主判定 |
| D21 DeviceSupport | 可清理 | **T1** 变更 | 连真机会自动重下（未验证），代价可量化 → 不 T0 |
| D22 Xcode `UserData/Previews` | 可清理 | **T2** 变更 | 路径在 `UserData` 下，名字就是数据 |
| D23 `Docker.raw` | 需确认 | **T3** 变更 | 卷的后备存储，按 Docker 口径永不自动 prune；只报告并链到 `docker system df` |

### A 应用残留
| 规则 | 现状 | v2 | 依据 |
|---|---|---|---|
| A1 `Application Support/<已卸载>` | 需确认 | **T2** ✓ | 归属与宿主都成立，但内容是数据、不可重建 |
| A2 `Preferences/<bundle>.plist` | 需确认 | **T2** ✓ | 同上 |
| A3 `LaunchAgents` 指向已卸载 | 需确认 | **T3** 变更 | 启动项属系统配置面，且常需提权；只报告 |
| A4 `Saved Application State` | 需确认 | **T0** 变更 | `.savedState` 后缀 + 宿主已卸载 ⇒ 无人再读；`restore=none` |
| A5 `Preferences/ByHost` | 需确认 | **T2** ✓ | 业界（Pearcleaner）把 `byhost` 列入永不归属名单，保守处理 |

### T 大文件与垃圾箱
| 规则 | 现状 | v2 | 依据 |
|---|---|---|---|
| T1 `~/.Trash` | 可清理 | **T1** 变更 | 位置即用户意图，但仍留在清理页、不进"一键处理"（刚扔的东西要能找回） |
| T2 `~/Downloads` 大/旧 | 需确认 | **迁出** | D-3：进「空间审计」 |
| T3 大文件 >1GB | 需确认 | **迁出** | D-3 |
| T4 模拟器设备 >90 天 | 需确认 | **迁出** | 整个模拟器（含其内数据），属审计对象；与 v1.73 的 Android AVD 议题同类 |
| T5 iOS 备份 >180 天 | 需确认 | **迁出** | 不可重建的用户数据 |

### B 浏览器与系统数据
| 规则 | 现状 | v2 | 依据 |
|---|---|---|---|
| B1 Safari WebsiteData | 需确认 | **T3** 变更 | 登录态/本地存储是数据，删了要重新登录，且可能跨设备 |
| B2 Chromium `Default/Cache` | 可清理 | **T1** ✓ | 契约位置 + 宿主未运行 |
| B3 Safari 容器缓存 | 可清理(实为 0 项) | **T1** 变更 | 需 FDA；无 FDA 时报缺权限 |
| B4 `component_crx_cache` | 可清理 | **T2** 变更 | 无网络探测 → 不 T1 |
| B5 WidevineCdm/TTS/语言包 | 需确认 | **T2** ✓ | `redownloadable`，删了功能立即可感知 |

**T0 的四条硬要求（同时成立才算）**

① `contract ≠ userData`——位置语义是"数据"的永远不能进 T0；其余契约按各自强度成立
（`appleCaches`/`userCacheDir`/`tempDir` 来自 Apple 原文，`toolPrune` 来自该工具自己的 prune 语义，
`namedPattern` 必须是文件系统层面的确定标记：`.ShipIt.`、`*.log.N`、`.savedState`、`__pycache__`）；
② `restore ∈ {none, auto-cheap}`，且不丢状态；
③ `hostState ≠ installedRunning`（G5 已保证运行中的宿主不列，这里只是不许反向绕过）；
④ 判据是**结构标记**，**不能是"某个人不用了"**。

> 修订记录：①原来的写法是"归属必须唯一"，但逐条填维时发现那是错的——
> `/private/tmp/*`（L3）、`__pycache__`（D11）、Clang 模块缓存（D13）都**不需要知道属于哪个 app**，
> 位置/名字本身就是 Apple 承认的可丢弃契约；把它们卡在"归属唯一"外面，反而会把依据最硬的几条
> 挡在 T0 之外，而真正危险的 A1/A2（"属于某个已卸载 app 的数据"）却因归属唯一而够格。
> 所以约束改成"**契约不得是数据**"。归属只用于**排除**，不用于**准入**。

**汇总**（步骤 5 后）：T0 共 12 条（C7、L3、L4、L5、L6、D8、D11、D12、D13、D14、D19、A4）；
T1 16 条；T2 17 条（D19 出、D24 进）；T3 8 条（D2、A3、D23、B1、T2、T3、T4、T5，全部 `contract = userData`）。
相比现状，**默认勾选面从"无"变成 11 条有结构证据的规则**，同时 12 条原来"可清理"的被降级。


## 4. 永不归属词元表（新增护栏，建议 G17）

业界（Pearcleaner `skipReverse`，约 200 词元）与本仓库教训一致的做法：一份**词元黑名单**，
命中即不得归属给任何 app，也不得进 T0/T1。首批至少含
`crashreporter`、`diagnostic`、`byhost`、`globalpreferences`、`knowledge`、`mobilesync`、
`trash`、`databases`、`spotlight`、`symbols`、`swiftpm`、`sparkle`、`sentry`、`crashlytics`、
`webkit`、`coresimulator`、`cef`、`clang`、`python`。
理由：这些目录名字看着像某个 app 的残留，实际是**系统级或多 app 共享**的状态。

## 5. 落地顺序（每步都要能独立验证，不允许半成品）

> **硬顺序约束（步骤 5 已完成，约束解除）**：步骤 4（T0 默认勾选）**必须晚于**步骤 5（L3/L4 判据改写）。
> 原因：L3/L4 当时的实现是"`/private/tmp` 里当前用户可写的项"，没有按
> 「属主==当前用户 **且** mtime 超过 3 天」过滤。它们的档位登记为 T0，但**实现配不上这个档位**——
> 先开默认勾选，就等于把"刚被某个进程写过的临时文件"也自动勾上。
> 步骤 5 之后实现与档位对齐，步骤 4 可以开工。

1. **加维度、不改行为**：`CleanupRules.Rule` 增 `contract/ownership/hostState/restore/tier` 五个字段，
   52 条全部显式填；新增自检穷举"每条都填了、且 tier 与四维不矛盾"。此步**不改任何删除决策**。
   ✅ 已完成（4 条自检：全表自洽 / T0 名单点名 / 档位分布 11-16-17-8 / 反证含"反证的反证"）。
2. **永不归属词元表**（G17）+ 自检穷举。
   ✅ 已完成，并**必须早于步骤 6（FDA）**。理由本机验证过：
   `~/Library/Application Support/Knowledge` 现在是 `Operation not permitted` → `size == 0`
   → A1 的 `guard size > 0` 自然跳过，所以 G17 今天在列表上**一个项都没改变**。
   但一旦按 D-2 授予 FDA，`Knowledge`、`MobileSync`、Safari 容器这些目录全部变得可读，
   A1 就会把它们当成"某个 app 的残留"列出来——`Knowledge` 的 mtime 已经是 2025-12-21，
   远超 A1 的 180 天门槛。**G17 是给 FDA 之后兜底的，顺序反了就等于先开门再装锁。**
   过程中 G17 自己引入过一个错：表里放了 `shipit`，而 `.ShipIt.` 恰恰是 L6 的 T0 结构标记，
   两条规则互相矛盾（A/B 实测：App 残留从 10 项被压成 1 项）。已移除该词元，
   并加反证自检"`com.*.ShipIt` 不得被 G17 吞掉"把这条边界钉住。

3. **档位接进 `Recommendation`** ✅ 已完成（v1.72.8）。落地方式与原文略有不同，且是**更好**的写法：
   没有替换原有四档，而是新增 `garbage` 档并做**双向钳制**——T0 把 `safe` 升级为 `garbage`，
   T2 把 `safe/garbage` 降为 `review`，T3 降为 `keep`；升降级都必须在 `reason` 里写明依据来自哪一维。
   原 4 档继续存在，避免把 20 多条既有断言一次性推翻。
   过程中发现自己实现的一个错误：`verdict()` 起初只挂在产出 `safe` 的三处，
   于是 `inferredUnused`（D23）这类根本不经过钳制——钳制必须覆盖**所有**结论分支。
4. **T0 默认勾选**（D-1）：✅ 已完成（v1.72.10）。G2 改成"仅 T0 例外"：`Scanner.applyDefaultSelection`
   只把结论为「确定是垃圾」的项预勾，`可清理/使用中/需确认/勿删` 一律不勾；二次确认不动。
   自检两条：五档各造一项过一遍（只有 garbage 被勾）、以及**T0 但宿主在跑**不得被预勾
   （运行时事实压过档位，这条写反就等于"依据很硬"被当成"现在就能删"）。
   顺序上必须晚于步骤 5——先开默认勾选，勾的就是"刚被某个进程写过的临时文件"。
5. **L3/L4 判据改写**（属主 + 3 天阈值）+ **C4 对齐 brew 契约** + **D19 拆分**。
   ✅ 已完成（v1.72.9）。三处判据都换成了实测证据，另外修掉三个探查失真：
   ① D19 的 daemon 分支因 `children(of:)` 全路径被二次 join 而**从未列出过任何文件**；
   ② 聚合项的占用状态原本量**父目录**，于是 16 个 3 天没动的日志被标成"几秒前还有写入 → 使用中"
   （现改用量自己的那批路径，`FileSystem.usage(ofPaths:)`）；
   ③ 档位标签从单个 mtime 宣称"频繁使用中"，与同行结论互相打架（现只写"7 天内有写入"这类事实）。
   本机效果：「日志与临时文件」339 项/357.6 MB → 11 项/36.1 MB；`Gradle 历史守护进程日志` 首次出现（35.8 MB）。
6. **FDA 引导**（D-2）：✅ 已完成（v1.72.11）。权限缺失产出 `ScanIssue`，界面区分"读不到"与"干净"。
   落地时发现原文低估了难度：**根目录可读 ≠ 里面可读**。本机实测 16 处盲区全在可读的根下面
   （`~/Library/Caches/CloudKit`、逐个沙盒容器的 `Data/Library/Caches` 等），
   而 `probeRoot` 只看根，于是一条都报不出来。三处补强：
   ① 遍历与 `children(of:)` 撞到的 `EPERM`/`EACCES` 全部记账（父子合并、封顶、
     **G6/G8 主动硬排除的位置不算盲区**）；
   ② 增量指纹缓存会把"被拒的 0 字节"固化成"干净"（指纹只看目录自身 lstat，之后永不重走），
     所以 C1/C6/A1 判定候选目录时**主动问一次** `canOpenDirectory`——
     不能用 `access(R_OK)`，TCC 是在打开那一刻才拒绝的；
   ③ 措辞按权限口径分开：`needsFDA` 原先查的是那份**四条** `tccProtected` 清单，
     Safari 容器这类同样要 FDA 的位置不在表内，用户拿到的是一句没有下一步的话。
   **未预见的副作用**（真机验证时撞见）：主动 open 别的 App 容器会让 macOS 弹
   「想访问其他 App 的数据」**模态**对话框，而 `DiskMonitor` 每 3 小时无人值守扫一轮、
   `AutoCleanService` 也会自己扫 → 没人点就挂住整轮。新增 `FileSystem.proactiveBlindSpotProbe`，
   无人值守路径关闭。产品含义：**授权对话框由用户亲手扫描时触发**，不由后台触发。
7. **空间审计**（D-3）：T2/T3/T4/T5 迁出，清理页不再出现"凭大小年龄判"的项。
8. **恢复学习**：`(规则, 路径前缀)` 计数 + 超阈值降档，写进隐私说明。


## 6. 待验证（不要当结论用）

- CleanMyMac X / OnyX / AppCleaner 的**具体删除清单**没拿到一手来源（PDF 超限、站点抓取失败）。
  调研里出现的 `titaniumsafe.com` **不是** OnyX 官网（域名交易页），不要写进 README。
- Xcode 是否真的会连真机自动重下 DeviceSupport（影响 D21 能否升 T0）。
- Maven `*.lastUpdated` 的官方措辞（D8 升 T0 目前依据是社区共识 + 语义自证）。
- iCloud「桌面与文稿」开启时删除 `~/Desktop` 的跨设备扩散细节（D-3 迁出后风险下降，但仍要标未验证）。
- **步骤 5 留下的两个候选**（都没做，因为代价没算过）：
  ① 用 `lsof <path>` 作"有没有进程握着它"的正向证据，取代现在的 10 分钟 mtime 窗
  （`AIService.detectProcesses` 已经在用 lsof，但只在 AI 上下文那条路上，扫描期不跑）；
  一次 8 s 超时，逐 item 跑的代价需要先量。
  ② Gradle 守护进程日志可以按文件名里的 PID 判活（`daemon-<pid>.out.log` + `kill(pid, 0)`），
  但 PID 会复用，且 lsof 更准——所以 ① 优先。
