# Code Review 记录

每个版本在**发版之前**由一个独立 reviewer 复审本轮改动，结论落在此目录。

## 为什么单独立一个目录

写代码的那个 agent 不适合审自己的代码：它知道自己的全部理由，审查会退化成给自己的决定背书，
而本项目最怕的恰恰是"理由听起来成立、判据其实不成立"那类问题（见 `../RELEASE-CHECKLIST.md`）。
所以 review 由**另一个全新上下文的 agent** 来做，它只拿到 diff 与仓库文档，拿不到实现者的思路。

## 命名

`v<版本号>-<审查者>.md`，例如 `v1.72.14-dsh.md`、`v1.72.15-qoder-subagent.md`。一轮一份，不追加进旧文件。

## 审查者是谁：运行时探活，不许凭记忆假定可用

按顺序取**第一个实测可用**的，并在文件名与结论里写清用的是哪个：

1. `dsh headless "<任务>"` —— Google 之外的独立 harness，真"另一个软件"。
2. `agy --print "<任务>"` —— Antigravity CLI。
3. **退化**：Qoder 的 Agent 工具派 `general-purpose` 子代理（全新上下文，仍不是写代码那个会话）。
   走这条必须在报告里明写「本轮为退化路径，外部 CLI 不可用 + 原因」。

**探活方式**：正式派审之前，先跑一条最小任务（`dsh headless "回复 OK"`，外层套 60–90 s 看门狗）。
失败就判定不可用、直接下一个，**不要重试**——审查者挂掉只是少一路视角，不该拖住整轮。

### 2026-09-23 实测状态（复验前按此假设，别重复踩）

| 审查者 | 状态 | 症状 |
|---|---|---|
| `dsh headless` | ✖ 不可用 | `dsh: NO_ADAPTER: no adapter registered for provider "dimagent-oauth"`，连续 3 次稳定复现；配置在 `~/.dsh/dimagent-oauth.json` 与 `~/.dsh/llm-deepseek`。偶有一次成功过，不足以当作可用 |
| `agy --print` | ✖ 不可用 | 卡在 `Fetching available models...`；`generativelanguage.googleapis.com` / `accounts.google.com` 从本机连接超时（HTTP 000）。OAuth 凭证在，端点不通 |
| `claude` / `codex` / `opencode` / `gemini` | ✖ 未安装 | `command -v` 全部为空 |

**看门狗要注意**：`perl -e 'alarm N; exec @ARGV'` **不能**当超时用——`alarm` 不跨 `execve` 保留，
定时器会被抹掉，进程能挂到天荒地老。用 `fork` 后在父进程里 `alarm`，或 `( cmd & p=$!; ( sleep N; kill -9 $p ) & wait )`。

## 每份 review 的固定结构

1. **复审范围**：`git diff <上一个 tag>..HEAD` 的文件与行数；本轮声明要做什么（取自提交信息）。
2. **发现**：每条一段，`严重度 / 位置 file:line / 症状 / 为什么是问题 / 建议动作`。
   严重度四档——`P0` 可致误删或越权、`P1` 结论失真或假绿、`P2` 性能与体验、`P3` 措辞与文档。
3. **无发现也要写**：明确写"未发现 P0/P1"，并列出实际检查过哪几处。空文件等于没审。
4. **处置**：每条 P0/P1 标注「已修（提交 sha）/ 不修（理由）/ 转下一轮」。
5. **外部审查未完成时**：写"未完成 + 原因"，本轮代码照常测试与发版——一次工具故障不该被当成代码问题。


## 这个项目的重点检查项

- 有没有绕过 `ResidueDeletionGate` 的删除路径；主目录之外的位置是否先登记了 `GovernanceDomain`
- 外部命令是否走 `SafeProcess`（超时、先排空管道再 wait、启动失败不 wait）
- "已安装应用"是否唯一取自 `AppInventory.current()`，且 `isComplete == false` 时把孤儿结论降级
- 有没有把"读不到 / 没权限"播报成"干净 / 已清理"
- 判据字段是否用了 atime；聚合项是否量了父目录体积当占用证据
- 新增自检断言是否**恒绿**（把被测逻辑改坏，断言必须变红）
- 有没有引入无界后台任务，或在 `body` 里重复计算过滤/分组
- 提交信息/release notes 与实际改动是否一致（**不许谎报做过**）

## 红线：本目录的文件会被提交并公开

review 里只许出现**仓库内路径与代码**。不得写入用户文件名、真实清理历史、真实 API Key、
本机真实目录结构。测试夹具一律用 `/Users/test`、`/Users/example`。
`scripts/release.sh` 的脱敏扫描覆盖 `docs/`，命中即发版失败。
