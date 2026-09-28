# 本机自检环境失败基线（macOS 27 + ViewInspector 0.10.3）

> 这份清单**不是豁免名单**，是给 `scripts/release.sh` 逐条比对用的基线。
> 规则：发版时自检的**失败名集**与**未执行套件集**必须与下面两份完全相同——
> 多一条 = 新红灯，照旧拦下来；少一条 = 基线过期（环境或代码变了），同样拦，
> 必须人工重新确认后再刷新本文件。
>
> 根因见 `docs/RELEASE-CHECKLIST.md` §0.2：ViewInspector 靠猜 SwiftUI 私有内存布局遍历视图树，
> macOS 27 改了布局——`findAll(ViewType.Button/Toggle.self)` 整体失效，另有
> `GeometryProxy` 尺寸 `unsafeBitCast`（实测 76 字节 ≠ 硬编码 48/52）与
> `EnvironmentInjection` 原始字节扫描后 `swift_retain` SIGBUS 两处进程级终止。

**采集现场**：macOS 27.0（26A428）/ arm64 / Swift 6.4（swiftlang-6.4.0.34.1）/
`SDKROOT=MacOSX26.5.sdk` / ViewInspector revision `e9a06346499a3a889165647e3f23f8a7b2609a1c` /
2026-09-28 实测 `MacClean 自检完成：675 通过 / 34 失败 / 7 个套件未执行`。
同一份 HEAD 单独克隆重编重跑，失败集一致 → 与任何人的未提交改动无关。

## 提取口径（脚本与本文件必须同步）

- 失败名：自检输出中以 `  ❌ ` 开头的行，去掉全角括号起的说明后 `sort -u`。
  同一份清单会被内联与汇总各打一遍，**只能比名集，不能数行数**。
- 未执行套件：`⚠️ <套件名>：子进程异常终止` 里的套件名。
- 权威数字只认 `MacClean 自检完成：… 通过 / … 失败 / … 个套件未执行` 那一行。

## 失败用例名（34 条）

```text
Android UI: 只剩残缺孤儿时「全选」「清理」两键禁用
Android UI: 清理进行中按钮禁用，防重复提交
Android UI: 结果零默选、受保护行不给勾选框
Android UI: 证据不足时「全选」「清理」两键禁用
AudioHAL UI: 扫描结果零默选，受保护行不给勾选框
AudioHAL UI: 清理进行中禁止重复提交
AudioHAL UI: 证据不足时全选与清理按钮一起禁用
DiagnosticReport UI: 批量勾选跳过需确认与 root 托管项
DiagnosticReport UI: 报告列表零默选，未勾选时批量释放禁用
DiagnosticReport UI: 清理进行中批量释放禁用，防重复提交
ItemRow Quick Look 预览唤起
ItemRow 勾选回调
ItemRow 行内「问 AI」禁用态
PrinterDriver UI: 扫描结果零默选，受保护行不给勾选框
PrinterDriver UI: 清理进行中按钮禁用，防重复提交
PrinterDriver UI: 证据不足
ViewInspector 交互自检：DevProjectInspectorCard 渲染与批量治理控件
偏好碎片视图联动：UninstallerView 三段式 Tab 与偏好反查面板 ViewInspector 检验
分类详情空态与清理按钮禁用
双栏比对界面与交互快捷决策渲染
多语言瘦身 UI: 「全选外语包」不勾母语与 Base
多语言瘦身 UI: 清理进行中两个删除按钮都禁用
多语言瘦身 UI: 进入页面零勾选，两个删除按钮都禁用
孤儿排查：UI 模式分段与组件渲染
底层存储 UI: 未逐条点名勾选时释放按钮禁用
步骤7：空间审计页只有证据与去处，没有任何删除入口
浏览器分类：底层存储面板默认收起，且收起后清理列表仍然渲染
照片对比组件：PhotoCompareSheet 渲染与快速决策
目录树组件：DirectoryTreeSheet 与 DirectoryFilterBadge 渲染
确认弹窗切换彻底删除
确认弹窗默认废纸篓
端到端：勾选后清理按钮可用
网络隐私视图渲染：NetworkPrivacyView 与 RiskView 标签切换 ViewInspector 检验
规则 v2 步骤3：「确定是垃圾」分组真的渲染出来
```

## 未执行套件名（7 个）

```text
GlobalHotkeyDeep
MenuBarWidgetsDeep
SearchAndClean
SpaceArchiveDeep
SpaceVisualizerDeep
SpaceVisualizerDeep2
SystemAndHistory
```
