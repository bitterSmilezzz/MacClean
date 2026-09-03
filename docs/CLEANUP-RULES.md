# MacClean 清理规则集合（固化版 v1.0）

> 本文件是 MacClean 的**规则源头**：App 内置的扫描/清理逻辑严格对应本集合，
> 修改规则 = 修改此文档 + `Sources/MacClean/Rules/CleanupRules.swift`（两处必须同步）。
> 来源：本机 agent 会话与《全机安全审计报告》清理经验 + 通用 macOS 清理实践，2026-09-03 固化。

---

## 0. 安全护栏（所有规则必须遵守）

| # | 护栏 | 说明 |
|---|------|------|
| G1 | 只扫用户可写目录 | 不扫描/不清理 `/System`、`/Library`、`/var` 中需要 root 的区域；遇权限不足跳过并提示 |
| G2 | 手动勾选 + 确认 | 扫描结果默认全不勾选；点「清理」前二次确认 |
| G3 | 默认移入废纸篓 | 清理默认 `trash`（可恢复），用户可选「彻底删除」 |
| G4 | 分级标记 | 每项带风险级：`safe`（缓存/日志，可重建）· `review`（残留/大文件，需人眼确认）· `danger`（不可恢复/可能有用） |
| G5 | 排除运行中应用 | 正在运行的 App 对应的缓存目录跳过（按 `NSRunningApplication` 匹配） |
| G6 | 白名单排除 | 永远不删：`~/Library/Mail`、`~/Library/Keychains`、`~/Library/Accounts`、`~/Library/Messages`、`~/Library/Safari`（书签）、`.ssh`、`.gnupg` |
| G7 | 空目录兜底 | 删目录前先确认大小>0 或文件数>0；保留 `.DS_Store` 之外的系统占位 |

---

## 1. 用户缓存 `~/Library/Caches`

| 规则 | 路径模式 | 条件 | 风险 | 清理方式 |
|------|----------|------|------|----------|
| C1 | `~/Library/Caches/*` | 所有子目录，跳过 G6 白名单与运行中应用 | safe | trash/删除 |
| C2 | `~/Library/Caches/com.apple.dt.Xcode` | Xcode 未运行时 | safe | trash |
| C3 | `~/Library/Caches/pip` / `~/.cache/pip` | 存在 | safe | trash |
| C4 | `~/Library/Caches/Homebrew` | 存在 | safe | trash |
| C5 | 浏览器缓存 | `~/Library/Caches/com.apple.Safari`、`com.google.Chrome`、`com.microsoft.Edge`、`com.brave.Browser`、`com.operasoftware.Opera`、`com.vivaldi.Vivaldi` | safe | trash |
| C6 | 沙盒容器缓存 | `~/Library/Containers/*/Data/Library/Caches/*`（跳过运行中应用） | safe | trash |

## 2. 日志与临时文件

| 规则 | 路径模式 | 条件 | 风险 | 清理方式 |
|------|----------|------|------|----------|
| L1 | `~/Library/Logs/*` | 存在 | safe | trash |
| L2 | `~/Library/Logs/DiagnosticReports/*` | 崩溃/诊断报告 | safe | trash |
| L3 | `/private/tmp/*`、`/private/var/tmp/*` | 仅当当前用户可写；跳过正在使用的 socket/锁文件 | review | trash |
| L4 | `~/Library/TemporaryItems/*` | 存在 | safe | trash |

## 3. 开发残留（DerivedData / 包管理器缓存）

| 规则 | 路径模式 | 条件 | 风险 | 清理方式 |
|------|----------|------|------|----------|
| D1 | `~/Library/Developer/Xcode/DerivedData/*` | Xcode 未运行 | safe | trash |
| D2 | `~/Library/Developer/Xcode/Archives/*` | 超过 90 天的归档 | review | trash |
| D3 | `~/Library/Developer/CoreSimulator/Caches/*` | 存在 | safe | trash |
| D4 | `~/.npm/_cacache` | 存在 | safe | trash |
| D5 | `~/.yarn/cache` | 存在 | safe | trash |
| D6 | `~/.pnpm-store` | 存在 | safe | trash |
| D7 | `~/.gradle/caches` | 存在 | safe | trash |
| D8 | `~/.m2/repository`（只清 `*.lastUpdated` 与 `_remote.repositories`） | 存在 | review | trash |
| D9 | `~/.cargo/registry` | 存在 | safe | trash |
| D10 | `~/Library/Caches/org.swift.swiftpm` | 存在 | safe | trash |
| D11 | `__pycache__` 目录 | 限定 `~/workspace`、`~/projects`、`~/dev` 等已知代码目录 | safe | 删除 |

## 4. App 残留与卸载残留

> 审计报告经验：Lemon（LaunchDaemons 残留）、Parallels（keychain 残留）、rtk（钩子残留）均为典型卸载残留案例。

| 规则 | 路径模式 | 条件 | 风险 | 清理方式 |
|------|----------|------|------|----------|
| A1 | `~/Library/Application Support/<name>` | 对应 app 不在 `/Applications`、`~/Applications`，且非 G6 白名单 | review | trash |
| A2 | `~/Library/Preferences/<bundle>.plist` | 对应 app 已卸载且 bundle id 不属于系统 | review | trash |
| A3 | `~/Library/Caches/<bundle>` | 对应 app 已卸载 | review | trash |
| A4 | `~/Library/LaunchAgents/*` | 指向已卸载 app 的 plist | danger | trash（用户重点确认） |

## 5. 大文件与垃圾箱

| 规则 | 路径模式 | 条件 | 风险 | 清理方式 |
|------|----------|------|------|----------|
| T1 | `~/.Trash/*` | 废纸篓内容 | review | 删除（已在废纸篓） |
| T2 | `~/Downloads/*` | 大于 500MB 或超过 180 天未访问 | review | trash |
| T3 | 大文件扫描 | `~/Downloads`、`~/Documents`、`~/Desktop`、`~/Movies` 中 >1GB 文件 | review | trash |
| T4 | `~/Library/Developer/CoreSimulator/Devices/*` | 未使用模拟器（按最后使用时间 >90 天） | danger | trash |

## 6. 浏览器与系统数据

| 规则 | 路径模式 | 条件 | 风险 | 清理方式 |
|------|----------|------|------|----------|
| B1 | `~/Library/Safari/LocalStorage`、`~/Library/Safari/WebsiteData` | Safari 未运行 | review | trash |
| B2 | Chrome/Edge/Brave/Opera/Vivaldi 的 `Default/Cache`、`Default/Code Cache` | 对应浏览器未运行 | review | trash |
| B3 | `~/Library/Containers/com.apple.Safari/Data/Library/Caches` | Safari 未运行 | safe | trash |

---

## 7. 已知不可清理（硬排除）

```
~/Library/Mail ~/Library/Keychains ~/Library/Accounts ~/Library/Messages
~/Library/Safari/Bookmarks.plist ~/Library/Safari/History.db（用户选择） ~/.ssh ~/.gnupg
/Library/LaunchDaemons（需 root，不碰） /System /usr/bin 等系统路径
```

## 8. 清理执行规范

1. 扫描阶段**只读**：枚举目录、计算大小（`FileManager` + 目录递归，失败目录跳过不中断）。
2. 清理阶段：按勾选项逐条执行；单条失败记录错误，**不中断其余项**。
3. 默认 `trashItem`；「彻底删除」需在确认弹窗中再次选中。
4. 清理后立即重扫该分类，展示释放空间与失败项。

## 9. 变更记录

- v1.0（2026-09-03）：固化 6 大类 23 条规则，来源：本机 agent 会话/审计报告经验 + 通用实践。
