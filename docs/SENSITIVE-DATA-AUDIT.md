# MacClean 敏感数据审计报告

> 目的：在把本工作区交给「收集数据用于训练模型 + 共享数据」的 Agent 之前，明确哪些内容需要脱敏、哪些必须去除、哪些属于工作区外的硬边界。
>
> 审计范围：`MacClean/` 工作区全部内容（源码 + 未跟踪文件 + 构建产物 + 发布包 + 完整 git 历史），以及本项目代码在本机读写的运行期数据位置。
>
> 审计方式：模式化密钥扫描、真实密钥反查（用本机实际密钥值在工作区全量反查，含 git 对象、二进制、压缩包）、绝对路径/身份标识统计、持久化代码路径追踪。报告中不含任何真实密钥值。
>
> **本报告含处置结果**：代码已改、文档已修、可再生产物已清理。未完成项集中在第六节。

---

## 结论摘要

| 结论 | 说明 |
|---|---|
| 工作区内**没有**真实凭证泄漏 | 真实 API Key 在工作区全量反查**零命中**（源码、构建产物、发布包、全部 git 对象） |
| git 历史干净 | 45 个提交，作者为 GitHub noreply 邮箱；历史中出现的 `sk-` 均为自检用假数据 |
| 最高风险不在工作区内 | `~/Library/Application Support/MacClean/ai.key` 是本机真实 API Key 的**明文文件** |
| 该风险已从代码层面根除 | Key 改为只写系统钥匙串，永不落盘；钥匙串不可用时仅存进程内内存 |
| 工作区体积 1.8 GB → 约 8 MB | 删除了 5 个内嵌本机绝对路径的可再生产物 |
| **明文密钥已彻底清除** | `ai.key` 已删除，Key 现仅存于系统钥匙串（迁移已完成并端到端验证，见 1.2） |

---

## 一、真实凭证

### 1.1 AI 网关 API Key（最高优先级）

| 项 | 值 |
|---|---|
| 路径 | `~/Library/Application Support/MacClean/ai.key` |
| 内容 | AI 网关 API Key 明文（`sk-` 前缀，67 字节） |
| 权限 | `-rw-------`（0600） |
| 状态 | ✅ **已删除**——Key 已迁入系统钥匙串（service `com.macclean.app` / account `aiApiKey`） |

**代码层面已根除该风险**（`Sources/MacClean/AIService.swift`）：

- 旧实现把 Key 写进上述明文文件（0600），与本项目自己的发布门槛 `docs/RELEASE-CHECKLIST.md`「API Key 不落盘」**直接矛盾**；
- 新实现**只写系统钥匙串**，进程内会话缓存是唯一的内存退路，进程退出即消失；
- 旧明文文件现在只被**读取和删除，永不写入**：`loadAPIKey()` 会把它迁移进钥匙串，成功即删除；钥匙串已有 Key 时也会顺手清掉任何明文残留；
- 迁移采用 **safe-fail**：只有钥匙串写入成功才删除明文，否则保留文件——宁可暂时留文件，也不丢凭据。

### 1.2 迁移已完成（附一次系统级钥匙串故障的排查记录）

**最终结果**：

```
$ swift run MacClean --keymigrate
== MacClean API Key 迁移（旧明文文件 → 系统钥匙串）==
apiKey: 已读取（长度 67）
✅ 明文文件已清除，Key 现仅存于系统钥匙串        [exit 0]
```

**端到端验证**：明文文件删除后**再跑一次**，仍读回 67 字节的 Key。此时文件已不存在，该 Key 只能来自钥匙串；同时确认 `~/Library/Application Support/MacClean/` 下已无任何密钥文件，仅剩 `history.json`。

> 迁移曾连续两次失败，根因是**本机钥匙串子系统一度不可用**（与 MacClean 无关）。排查过程保留在下方，供日后遇到同类症状参考。

#### 故障现象（已解决）

故障期报错：

```
⚠️ 钥匙串写入失败：OSStatus -50（One or more parameters passed to a function were not valid.）
```

**决定性证据**：`SecItemCopyMatching` 读取一个**不存在**的条目返回 `-50`，而正常钥匙串**必须**返回 `-25300 errSecItemNotFound`。连读不存在的条目都报参数错误 ⇒ **钥匙串不可达**，与参数、ACL、超时均无关。

| 调用 | 故障期 | 恢复后 |
|---|---|---|
| `SecItemCopyMatching`（不存在的条目） | ❌ `-50` | ✅ `-25300` |
| `security list-keychains`（搜索列表） | ❌ `-50` | ✅ exit 0 |
| `security list-keychains -d user` / `-d system` | ✅ 正常 | ✅ 正常 |
| `security default-keychain` | ✅ 正常 | ✅ 正常 |
| `security show-keychain-info` | ❌ `-50` | — |
| `security add-generic-password` | ❌ "Unable to obtain authorization" | — |

**已排除「App 自身问题」**：Apple 签名的 `security` CLI 在正常 GUI 终端里同样失败 ⇒ 与 ad-hoc 签名、entitlements 无关，是**系统级钥匙串状态问题**。

**影响范围**：不只 MacClean——Safari 密码、git 凭据等一切走钥匙串的应用都会受影响。

#### 解决方式

**重启后自愈**（本次实际生效的方案）：重启后复测，`SecItemCopyMatching` 恢复返回 `-25300`、`security list-keychains` 恢复 `exit 0`，`--keymigrate` 随即一次成功。

若日后重启无效，按序尝试：解锁登录钥匙串（`security unlock-keychain ~/Library/Keychains/login.keychain-db`）→「钥匙串访问」App 检查锁定状态 → 最后才考虑重建搜索列表或登录钥匙串。
> ⚠️ **重建登录钥匙串会丢失其中已保存的全部密码**，动手前务必备份 `~/Library/Keychains/login.keychain-db`。

#### 复现迁移的命令（供日后参考）

```bash
cd ~/workspace/ai-test/MacClean
SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  swift run MacClean --keymigrate && rm -rf .build .swiftpm
```

> ⚠️ **`SDKROOT` 不能省**。本机是纯 CommandLineTools 环境（无 Xcode），SDK 27.0 的 SwiftUI 引用了只随 Xcode 提供的 `SwiftUIMacros` 插件，不指定 SDKROOT 必然构建失败：
> `error: external macro implementation type 'SwiftUIMacros.StateMacro' could not be found`。
> 此时 `swift run` **根本不会执行到迁移逻辑**，表现为「命令跑完了但 `ai.key` 没变」。`scripts/build-app.sh` 内置了同样的回退，详见 `docs/RELEASE-CHECKLIST.md` 第 0 节。

#### ⚠️ 遗留注意点：ad-hoc 重签后首次读取会弹授权框

钥匙串条目由本次迁移所用的 `.build/debug/MacClean` 创建，其 ACL 绑定该二进制的签名。**当你用 `./scripts/build-app.sh` 打包并运行 `MacClean.app` 时（另一个签名），首次读取 Key 会弹出钥匙串授权框**——选择「始终允许」即可，之后正常。

这是 ad-hoc 签名的固有限制（每次重新构建都会更换签名身份），不是本次改动引入的。彻底消除的唯一方式是使用 Apple 开发者证书——届时数据保护钥匙串可用，ACL 不再依赖签名哈希。

### 1.3 钥匙串遗留条目

- service `com.macclean.app`，account `aiApiKey`。迁移逻辑会在写入成功后清理旧条目；建议迁移完成后用「钥匙串访问」确认没有同一凭据的双份留存。

---

## 二、工作区内已清理的内容（本机绝对路径泄漏）

| 路径 | 体积 | 内嵌 `/Users/<用户名>/...` | 处置 |
|---|---|---|---|
| `.build/` | 1.6 GB | **4070** 个文件 | ✅ 已删除（可再生产物） |
| `.build-wmo/` | 181 MB | **521** 个文件 | ✅ 已删除 |
| `MacClean-1.8.0-macOS.zip` | 3.5 MB | **302** 处（二进制内嵌） | ✅ 已删除 |
| `dist/MacClean-v1.35.0-macOS.zip` | 4 MB | **377** 处（二进制内嵌） | ✅ 已删除 |
| `dist/MacClean.app/` | 18 MB | **377** 处（二进制内嵌） | ✅ 已删除 |
| `LICENSE:3` | — | `Copyright (c) 2026 fangshoufanji` | 保留（账号名，已确认可公开） |

> **勘误**：第一轮报告中我写「`dist/MacClean.app` 二进制绝对路径命中为 0（该产物相对干净）」——**这是错的**。当时用 `strings -a | grep -c` 统计，macOS 的 `strings` 没有扫描到调试信息区段，导致假阴性。改用 `grep -a` 后实测为 **377 处**，与 zip 内的数字一致（因为 zip 装的就是同一个二进制）。该产物因此被一并清除。

**这些文件全部可再生产**：`.build` 由 `swift build` 重建，发布包由 `./scripts/build-app.sh` 重新打包。均已被 `.gitignore` 忽略，不会进入公开仓库。

### ⚠️ 交接前必须重做清理

**每次执行 `swift build` 都会重新生成 `.build/`，并再次写入 4070 处本机绝对路径。** 为验证改动重建过 `.build`，因此**最终交接前需要再删一次**（第七节给了命令）。这是本报告最容易被忽略的一条。

---

## 三、工作区外、但由本项目产生的个人数据

| 路径 | 现状 | 敏感度 |
|---|---|---|
| `~/Library/Application Support/MacClean/ai.key` | ✅ **已删除**（Key 已迁入系统钥匙串） | ~~高~~ → 无 |
| `~/Library/Application Support/MacClean/history.json` | 存在，31 KB，194+ 条 | **低-中**。字段仅 `bytes / categoryName / date / failures / id / itemCount / mode`，**不含文件路径**；但是完整的清理行为画像 |
| `~/Library/Application Support/MacClean/scan_incremental_cache.json` | 当前不存在 | **中**。一旦生成，缓存的是**目录指纹**，会暴露被扫描目录结构 |
| `~/Library/Application Support/MacClean/undo_sessions.json` | 当前不存在 | **高**。一旦生成，含 `(原路径, 废纸篓路径, 大小, 所属项)`，即真实个人文件路径 |
| `~/Library/Preferences/com.macclean.app.plist` | 存在，1.5 KB | **低-中**。含 `MacClean_CustomSearchRoots`（实测为 `~/Downloads`、`~/Pictures`、`~/Documents`、`~/Desktop`）、窗口位置尺寸、AI 配置（baseURL/model，**不含 Key**） |
| `~/Library/Preferences/MacClean.plist` | 存在，1.5 KB | 同上，另一份 suite 副本 |

**新发现**：`history.json` 的修改时间在自检运行后发生变化——**`swift run MacClean --selftest` 会读写真实的 `history.json`**。也就是说 Agent 若被允许跑自检，会碰到真实用户数据。已体现在第五节边界清单中。

---

## 四、代码与文档层面的隐私问题

### 4.1 开启 AI 功能会把完整文件路径发往第三方网关 ⚠️

| 位置 | 内容 |
|---|---|
| `AIService.swift:374`（原） | AI 批量审阅请求体逐行拼接：`序号 \| 文件名 \| item.path \| 大小 \| 结论 \| 使用频率` |
| `AIService.swift:547`（原） | 对话上下文同样携带 `item.path` |
| `AIService.swift:8` | 默认端点为第三方网关 `https://opencode.ai/zen/go/v1` |

即：**只要开启 AI 审阅/对话，用户的真实文件名与完整路径就会离开本机。**

**已处置**：在 `README.md` 的「AI 助手配置」小节加入显著隐私提示，明确告知会发送文件名与完整路径。

### 4.2 文档与实现不一致 ✅ 已修复

| 位置 | 原状 | 现状态 |
|---|---|---|
| `README.md:140` | 「只需粘贴你的 API Key（**存系统钥匙串**）」——与当时的明文文件实现不符 | 已改为准确描述：只写钥匙串、不落盘、钥匙串不可用时仅存内存；并补充 ad-hoc 重签后需重新输入一次 |
| `docs/RELEASE-CHECKLIST.md:97` | 「API Key **不落盘**、不进日志、不进 git（Keychain 存储）」——该检查项当时**必然不通过** | 现已成立，并补充了可执行的验证方法 |

### 4.3 正面结论（无需处理）

- `RiskScanner.swift:160-195`：检测用户 shell 配置中的明文密钥时，**只记录变量名与文件名，不输出密钥值**，并有自检断言守护。
- git 提交作者统一为 GitHub noreply 邮箱，未暴露个人邮箱。
- 源码中出现的 `sk-REPLACE_ME_1234567890abcdef`、`/Users/test/...`、`/Users/x/...` 均为自检夹具。

---

## 五、给数据采集 Agent 的边界清单

### 5.1 硬边界：以下路径一律不得读取、不得上传、不得写入

```
~/Library/Application Support/MacClean/          # ai.key（真实密钥）+ history.json + 各类缓存
~/Library/Preferences/com.macclean.app.plist
~/Library/Preferences/MacClean.plist
~/Library/Keychains/                             # 钥匙串
~/.ssh/  ~/.gnupg/  ~/.aws/  ~/.config/gh/       # 其他凭据目录
```

### 5.2 工作区内排除项

见根目录 `.agentignore`。核心是：`.build/`、`.build-wmo/`、`.build-agent*/`、`dist/`、`*.zip`、`*.dmg`、`.git/`。

### 5.3 运行禁忌

1. **不要运行 `MacClean.app` 本体或 `swift run` 启动 GUI**——它会扫描整个家目录，并可能触发 AI 请求把文件路径发往第三方网关；
2. **不要开启 AI 审阅 / AI 对话功能**（默认端点已指向第三方网关）；
3. **注意 `swift run MacClean --selftest` 会读写真实的 `~/Library/Application Support/MacClean/history.json`**——允许跑自检前请知悉这一点；
4. 允许的操作：读写 `Sources/`、`docs/`、`scripts/`，执行 `swift build`、git 只读操作。

---

## 六、待办清单

已完成：

- [x] **P0** 迁移 Key 到系统钥匙串，删除明文文件（1.2 节，已端到端验证）
- [x] **P1** 清理 `.build` / `.build-wmo` / 内嵌绝对路径的发布产物（1.8 GB → 7.8 MB）
- [x] **P1** 产出 `.agentignore` 作为 Agent 摄入排除清单
- [x] **P1** 修正 `README.md` / `RELEASE-CHECKLIST.md` 与实现矛盾的密钥存储描述
- [x] **P1** 代码层面根除明文落盘 + 新增 5 条自检（188 通过 / 0 失败）

待办：

- [ ] **P0** 轮换该 API Key——它曾以明文形式在磁盘上存留约半个月（2026-09-04 至 2026-09-19），最稳妥的做法是吊销重发
- [ ] **P1** **每次构建后、交接前重删 `.build/`**（第七节命令）——`swift build` 会重新写入 4000+ 处本机绝对路径
- [ ] **P2** 需要发布包时用 `./scripts/build-app.sh` 重新打包（注意重打后二进制仍内嵌绝对路径，不要提交）
- [ ] **P2** 用 `./scripts/build-app.sh` 打包的 App 首次读取 Key 会弹一次钥匙串授权框，选「始终允许」
- [ ] **P3** （可选）交接前清空或移出 `~/Library/Application Support/MacClean/history.json`
- [ ] **P3** （可选）把自检对真实 `history.json` 的读写隔离到临时目录

---

## 七、本轮代码改动

| 文件 | 改动 |
|---|---|
| `Sources/MacClean/AIService.swift` | 密钥存储重写：钥匙串优先 + 内存回退，**永不落盘**；旧明文文件只读+删除；所有钥匙串调用带 3s 超时兜底（防 ACL 失配挂起）；新增 `lastKeychainStatus` 诊断 |
| `Sources/MacClean/MacCleanApp.swift` | 新增 `--keymigrate` 一次性迁移模式（无头、不联网、不打印密钥） |
| `Sources/MacClean/AIChatView.swift` | 保存/测试连接后若钥匙串写入失败，明确提示「本次可用，重启后需重新输入」 |
| `Sources/MacClean/Selftest+AIKeyStorage.swift` | 新增 5 条自检：不产生明文文件、会话可读回、清空无残留、迁移不丢凭据、残留明文自动清除 |
| `Sources/MacClean/Selftest.swift` | 注册新套件 |
| `README.md` / `docs/RELEASE-CHECKLIST.md` | 修正与实现矛盾的密钥存储描述，补隐私提示 |

**验证结果**：`swift run MacClean --selftest` → **188 通过 / 0 失败**。

> 设计取舍：钥匙串不可用时**不做明文回退**，而是要求用户重新输入。这是为了满足「密钥不落盘」的硬要求——代价是 ad-hoc 重签后需要重新粘贴一次 Key。

### 交接前最终清理命令

```bash
cd ~/workspace/ai-test/MacClean
rm -rf .build .build-wmo .swiftpm dist/*.zip
```

---

## 八、复检记录（2026-09-19 15:47）

DSH 会话重启后对工作区做了一次**不依赖前次结论的完整复检**。方法与结果：

| 检查项 | 方法 | 结果 |
|---|---|---|
| 密钥模式扫描 | `grep -raInE`（**`-a` 强制扫描二进制**） | 仅命中自检夹具与 `RiskScanner` 的前缀常量，**无真实密钥** |
| 真实密钥反查 | 用 `ai.key` 实际值全量反查（含 `.git` 对象） | **0 命中**；复检后 `ai.key` 已删除，不再存在可反查的明文 |
| 本机绝对路径 | `grep -ral 'fangshoufanji'` | 仅 `LICENSE`（账号名，已确认可公开）与本报告 |
| 其他用户名形态 | `/Users/<name>` 正则 | 仅 `/Users/Shared`（系统路径）与 `/Users/test`、`/Users/x`、`/Users/xxx`（自检夹具） |
| git 历史 | 全对象 `git log -p --all` | 仅 `sk-REPLACE_ME_...` 夹具；作者为 GitHub noreply 邮箱 |
| 构建产物 | `ls` / `du` | `.build`、`.build-wmo`、`.swiftpm` 均不存在 |
| 运行期数据 | `ls ~/Library/Application Support/MacClean/` | 仅 `history.json`；**无 `ai.key`**、无 `scan_incremental_cache.json`、无 `undo_sessions.json` |
| 钥匙串 | `security list-keychains` + `SecItemCopyMatching` 探针 | ✅ 已恢复（`-25300`） |
| 密钥迁移 | `swift run MacClean --keymigrate` ×2 | ✅ 首次清除明文；**二次从钥匙串读回 67 字节** |

> **方法学教训**：第一轮审计中我曾用 `strings -a \| grep -c` 统计二进制内的绝对路径，得到「0 命中」的**假阴性**（macOS 的 `strings` 未扫描调试信息区段）。改用 `grep -a` 后实测为 377 处。**此后所有二进制内容扫描一律使用 `grep -a`，不再依赖 `strings`。**

**复检结论**：工作区当前状态为**可安全交给数据采集 Agent**——无凭证、无本机路径、无构建产物。唯一保留的身份信息是 `LICENSE` 中的账号名（已确认可公开）。

---

*本报告不含任何真实密钥值。*
