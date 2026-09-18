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
>   修掉"把 WidevineCdm 这类 DRM 组件标成安全"的误判。**当前共 6 大类 41 条规则。**

---

## 0. 安全护栏（所有规则必须遵守）

| # | 护栏 | 说明 |
|---|------|------|
| G1 | 只扫用户可写目录 | 不扫描/不清理 `/System`、`/Library`、`/var` 中需要 root 的区域；遇权限不足跳过并提示 |
| G2 | 手动勾选 + 确认 | 扫描结果默认全不勾选；点「清理」前二次确认 |
| G3 | 默认移入废纸篓 | 清理默认 `trash`（可恢复），用户可选「彻底删除」 |
| G4 | **唯一结论（v1.2 重写）** | 每项只带**一个**结论：`可清理` / `使用中` / `需确认` / `勿删`。由 `ItemNature × UseState` 推导，并附一句「为什么」。**不变量：`可清理` 蕴含所属应用未在运行** —— 界面上永远不会再同时出现「可清理」与「频繁使用中」 |
| G5 | **在用检测（v1.2 加强）** | 三重证据取并集：① 所属 App 正在运行；② 目录在 10 分钟内被写过；③ 规则本身标记为需确认。① 的匹配集合覆盖 bundle id、本地化名、**CFBundleName**、可执行名与 `.app` 目录名——只比对本地化名会漏掉"目录名英文、App 显示中文"这一大类（实测 Tabbit Browser） |
| G6 | 白名单排除 | 永远不删：`~/Library/Mail`、`~/Library/Keychains`、`~/Library/Accounts`、`~/Library/Messages`、`~/Library/Safari`（书签）、`.ssh`、`.gnupg`；**v1.1 新增**：`~/Library/Group Containers`（应用共享数据）、`~/Library/Mobile Documents`（iCloud）、`~/Library/CloudStorage`（云盘） |
| G7 | 空目录兜底 | 删目录前先确认大小>0 或文件数>0；保留 `.DS_Store` 之外的系统占位 |
| **G8** | **系统级硬保护（v1.1）** | `/System`、`/System/Volumes`、`/Library/Updates`、`/private/var/vm`、`/private/var/db`、`/private/var/folders/zz` 一律不列为可清理项。判据见 §7 |
| **G9** | **TCC 权限显式判定（v1.1）** | 受隐私保护目录（`~/.Trash`、照片图库等）读取会返回 `Operation not permitted`。**必须区分「读不到」与「真的空」**，见 §7.2 |
| **G10** | **受限放行原则（v1.1）** | 需要触及常规允许根目录之外的目标时，只能**精确放行到具体路径/具名模式**，禁止放行整个父目录，见 §8 |
| **G11** | **不跟随符号链接（v1.2）** | 判定、遍历、删除三处都不得跟随软链。①`isSafeToClean` 先解析真实位置再判定，末段是软链一律拒绝；②递归遍历用 `isRealDir`（`lstat`）而非 `isDir`（`stat`）；③软链不计体积（删掉它释放 0 字节，不是目标的体积）。**理由**：家目录里放一个指向 `/System` 的软链，任何只看路径字符串的护栏都会被绕过去 |
| **G12** | **校验与删除作用于同一路径（v1.2）** | `Cleaner` 先把路径解析到真实位置，再对**同一个字符串**做校验与删除。若两边各自解析一次，中间被换成软链就出现 TOCTOU 缝隙 |
| **G13** | **读不到 ≠ 很干净（v1.2）** | 扫描根目录存在但不可读时**必须**产出 `ScanIssue` 并在界面明示"结果不完整"，禁止让整类静默变成 0 项。`FileSystem.isPermissionDenied` / `hasFullDiskAccess` 是这条护栏的判定基础 |

---

## 1. 用户缓存 `~/Library/Caches`

| 规则 | 路径模式 | 条件 | 本质 | 清理方式 |
|------|----------|------|------|----------|
| C1 | `~/Library/Caches/*` | 所有子目录，跳过 G6 白名单与运行中应用 | 可重建缓存 | trash/删除 |
| C2 | `~/Library/Caches/com.apple.dt.Xcode` | Xcode 未运行时 | 可重建缓存 | trash |
| C3 | `~/Library/Caches/pip` / `~/.cache/pip` | 存在 | 可重建缓存 | trash |
| C4 | `~/Library/Caches/Homebrew` | 存在 | 可重建缓存 | trash |
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
| L3 | `/private/tmp/*`、`/private/var/tmp/*` | 仅当当前用户可写；跳过正在使用的 socket/锁文件 | 推断未用 | trash |
| L4 | `~/Library/TemporaryItems/*` | 存在 | 可重建缓存 | trash |
| L5 | 旋转旧日志 | `~/Library/Logs` 内递归深度 ≤3，`*.log.N` / `*.N.log` / `*.gz` 且 >30 天 | 历史产物 | trash |
| **L6** | **应用更新残留（ShipIt）** | `$TMPDIR/<bundle-id>.ShipIt.<字母数字后缀>`（**仅顶层直接子项**） | 历史产物 | trash |

> **L6 实测依据（v1.1）**：Squirrel/ShipIt 自动更新框架在替换 App 后留下旧版本副本，
> 本机清出 **2.24 GB**（DimAgent 657 MB、Vokie 791 MB ×2），零风险。见 §8.1 的放行约束。
>
> **⚠️ 与 L3 的关键区别**：`$TMPDIR`（`/private/var/folders/xx/xxx/T`）与 `/private/tmp` **不是一回事**。
> 实测 `/private/tmp` 中的 3.1 GiB 全部是**当日活跃的构建/agent 工作流产物**（并非垃圾），
> 而 `$TMPDIR` 中的 ShipIt 残留才是真残留。因此 L6 **只认 ShipIt 命名模式**，绝不整体清理 `$TMPDIR`。

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

> **D13/D14 实测依据（v1.1）**：Clang 模块缓存 1.2 GB、Node 编译缓存 103 MB，均为自动重建的编译中间产物。
>
> **D15 实测依据（v1.1）**：`@deepseek-ai/dsh.old-0.1.2-*` ×3 与 `dsh.global-retired-20260906` 共 1.06 GB
> 废弃副本。**风险级为 review 而非 safe** —— 该命名可能出自人工重命名，需用户确认。
> 放行约束见 §8.2。
>
> **⚠️ 构建产物删除前置条件**：删 `.build` / `android/app/build` 等目录前，必须确认
> ①无编译进程在跑（`.lock` 文件的 mtime）；②无进程持有句柄（`lsof +D <dir>`）；
> ③Gradle 需先 `./gradlew --stop`（daemon 会持有 `intermediates/dex/**` 句柄导致删除失败）。

## 4. App 残留与卸载残留（A1–A3）

> 审计报告经验：Lemon（LaunchDaemons 残留）、Parallels（keychain 残留）、rtk（钩子残留）均为典型卸载残留案例。

| 规则 | 路径模式 | 条件 | 本质 | 清理方式 |
|------|----------|------|------|----------|
| A1 | `~/Library/Application Support/<name>` | 对应 app 不在 `/Applications`、`~/Applications`，且非 G6 白名单，且 180 天未更新，且 >10 MB | 孤儿残留 | trash |
| A2 | `~/Library/Preferences/<bundle>.plist` | 对应 app 已卸载、bundle id 不属于系统、>180 天未更新 | 孤儿残留 | trash |
| A3 | `~/Library/Caches/<bundle>` | 对应 app 已卸载 | 孤儿残留 | trash |
| A3 | `~/Library/LaunchAgents/*` | 指向已卸载 app 的 plist | 关键组件 | trash（用户重点确认） |

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
