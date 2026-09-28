# 主流 Mac 清理产品功能对齐表（v1.73.15 时点）

> 目标：把「MacClean 的功能达到市面上主流 Mac 文件清理产品水平」拆成可核对、可执行的清单。
> 对标产品与模块名取自各家公开资料：CleanMyMac X、DaisyDisk、AppCleaner、CCleaner for Mac、
> Pearcleaner、OnyX、BleachBit（macOS）。判据细节的一手调研见 [cleanup-rules-industry.md](cleanup-rules-industry.md)。
> 状态口径：✅ 已覆盖且不弱于对标 ｜ ⚠️ 部分覆盖（写明差什么）｜ ❌ 缺失 ｜ 🚫 明确不做（写明理由）。

## 1. 对齐表

| 主流模块（对标名） | 状态 | MacClean 现状 / 差距 |
|---|---|---|
| Smart Scan 一键体检+清理（CleanMyMac） | ✅ | 全量扫描、一键安全清理、极速微面板（⌃⌥Space）、定时巡检、低空间警戒、无人值守静默清理 |
| System Junk 系统垃圾（CleanMyMac/CCleaner） | ✅ | 用户缓存/日志/开发残留/App 残留/废纸篓/浏览器数据 6 大分类 + 53 条规则 + T0–T3 分档；治理模块判定依据按真机证据逐条重做 |
| Trash Bins 废纸篓治理 | ✅ | 废纸篓分类清理 + **自动清空（v1.73.14）**：可配置「最后修改时间超过 N 天」的顶层条目在无人值守链路彻底删除，开关默认关、判据用 mtime（无公开 API 读丢弃时间，文案如实说）、G9 读不到就明示跳过、删除照走统一网关 |
| Shredder 文件粉碎（CleanMyMac/CCleaner） | ✅ | **文件粉碎器（v1.73.14）**：工具页 + 清理项右键入口，只对用户逐条点名的路径生效；覆写前先过统一护栏裁决（G6/G8/白名单/治理域，复用网关同一套判据）、软链一律拒绝跟随、3 遍覆写（0→随机→0，每遍 fsync，APFS 写时复制卷上如实声明"多遍不提供额外保证"）、最终删除走 `ResidueDeletionGate`（toTrash:false）、写历史「文件粉碎」且无撤销快照、结果成功/拒绝/失败逐条如实 |
| Uninstaller（AppCleaner/CleanMyMac/Pearcleaner） | ✅ | 已装应用清单 + 关联残留 + 孤儿反查 + 偏好碎片 + 插件扩展治理 + 启动项；G14 统一删除网关 |
| Updater 应用更新（CleanMyMac/Pearcleaner） | ✅ | **App 更新检查（v1.73.14）**：默认关闭，开启后只访问 App 自己声明的更新源（Sparkle `SUFeedURL` appcast 解析 + `_MASReceipt` 判别 App Store 来源）；请求不含本机路径（有断言钉住）、每请求 10s 超时、版本比较逐段数值化；只列示与跳转（打开更新页），不代下载不代装；G16 清单不可信时降级明示"可能漏项" |
| Space Lens / 磁盘透视（DaisyDisk/CleanMyMac） | ✅ | 空间透视树图 + 面包屑下钻 + 冷热色谱 + 原位归档 + 外接盘迁移 + 迁移脚本导出 |
| Large & Old Files（CleanMyMac） | ✅ | 大文件 8 类细分 + 闲置时间分档 + 多维排序 + 媒体元数据透视；"大/旧 ≠ 垃圾"按规则 v2 走空间审计不进清理页 |
| Duplicates Finder | ✅ | SHA-256 分块 + 指纹缓存 + 并发流水线 + 硬链接无损去重 + 目录树勾选 |
| Similar Images | ✅ | dHash + 并查集聚类 + EXIF 画质比对 + 双栏决策 |
| Optimization 启动项/后台（CleanMyMac） | ✅ | 启动项全景治理 + LaunchAgents/Daemons + 幽灵自启 + 菜单栏常驻 |
| Maintenance 维护任务（CleanMyMac/OnyX） | ✅ | **系统维护面板（v1.73.15）**：磁盘 First Aid（`diskutil verifyVolume` 走 `SafeProcess` 带超时与卷 ID 白名单解析——本机实测 verify 无需管理员；根卷**修复**在挂载态必须进恢复模式（实测提权无解，与 Apple 磁盘工具的边界一致），如实做成「重启进恢复模式」指引卡而不假装能修）+ DNS 缓存刷新（复用 `NetworkPrivacyInspector` 链路）+ Spotlight 索引重建（复用 `SpotlightScanner` 的 mdutil 链路）。每动作独立确认、结果三态（未执行/成功/失败）原样播报输出摘录。"释放内存"类伪需求明确不做（见 §3） |
| Privacy 浏览器痕迹（BleachBit 式粒度） | ✅ | **浏览器隐私矩阵（v1.73.15）**：按 (浏览器 × 数据类) 一格一判据——Chromium 系（Chrome/Edge/Brave/Arc，含 Cookies 双代布局）+ Firefox（cache2/formhistory/logins/sessionstore）+ Safari（TCC 读不到时按 G9/G13 明示授权引导）。danger 格（savedLogins/sessionRestore）默认全不选、禁止进「全选」、删除需独立确认并逐条带固定警示（BleachBit 的 `<warning>` 范式）；Safari History 在 G6 硬排除内，行照常呈现体积、删除被网关拒并原样展示（对清单服从而非缺陷）；体积走共享 `directoryStats`、G16 清单不可信时降级明示。Wi-Fi 历史治理与风险扫描（SSH 私钥/明文密钥）此前已有 |
| Mail Attachments 邮件附件（CleanMyMac） | ✅ | **邮件附件页（v1.73.15）**：两个 TCC 根（Mail Downloads + `~/Library/Mail` 的 Attachments 结构目录）三态探测，读不到明示 + 授权引导；附件是用户数据——全部「需确认」零默认勾选、无「全选可清理」档，年龄文案只说 mtime；删除走统一网关默认移废纸篓可撤销，确认弹窗写明「邮件在服务器则附件可重下」 |
| Malware Removal（CleanMyMac） | 🚫 | 不做。真防病毒需要特征库分发与常驻拦截，超出个人项目维护能力；谎称"已查杀"比没有更危险。现有「风险提醒」（SSH 私钥权限过宽/明文密钥暴露）是诚实可证的隐私检查 |
| Free RAM / 内存释放（CleanMyMac/CCleaner） | 🚫 | 不做。macOS 内存管理由内核负责，用户态"释放内存"是营销功能；与本仓「结论只说量到的东西」文化直接冲突 |
| 多语种/本地化 | ✅ | 全中文原生 UI（对标产品均为本地化商业产品，此项为个人项目自用不阻塞） |
| 常驻菜单栏助手 | ✅ | 已有且更强（状态指示 + 快捷小组件 + 撤销 + 全局热键） |
| 历史与撤销 | ✅ | 对标产品普遍无撤销；本仓有历史流水 + 撤销快照 + 恢复学习提案（规则 v2） |

## 2. 缺口里 v1.73.14 轮选做的三项（已全部落地）

按「主流标配程度 × 与现有架构相容性 × 诚实可证」排序，实现与验证状态：

1. **文件粉碎器（Shredder）** —— 缺口最显眼的主流标配。设计约束（与 G 系列相容）：
   只对用户**逐条点名**的路径（右键入口 + 拖放/选择面板），不走任何扫描结果默认勾选；
   逐条二次确认且明示**不可恢复、无撤销快照**；覆写策略在 APFS/SSD 上诚实降级
   （多遍覆写对写时复制文件系统没有额外保证，业界同样如此——写明依据而不是装出"军方级安全"）；
   删除仍经 `ResidueDeletionGate` 护栏（路径合法性/系统保护/白名单照样裁决），
   成功后写清理历史（**categoryName=「文件粉碎」，mode 由网关定为「彻底删除」**——历史表的
   mode 是网关内部文案，本模块不另造；不可恢复性由结果摘要与 UI 明示）。
   （落地时把"拖放"收敛为右键入口 + 手动输入路径，见下表 ✅ 行。）
2. **废纸篓自动清空** —— 主流标配，工作量最小：偏好设置里可配置「超过 N 天的废纸篓项自动清空」（默认关），
   并入现有 `AutoCleanService` 无人值守链路；遵守"自动动手的范围自己重算"、写历史、可关闭。
3. **App 更新检查（Updater）** —— 对齐 Pearcleaner/CleanMyMac。设计约束：**默认关闭**；
   开启后只访问 App bundle 自己声明的更新源（Info.plist 的 `SUFeedURL`/Sparkle appcast）与
   App Store 收据判别，不把文件路径发给第三方；只列示「有更新源/来源是 App Store」，
   一键跳转官网/打开 App Store，不代下载不代装。

## 3. 明确不做清单（与主流"功能表"差异的诚实声明）

- **Malware Removal**：见上表 🚫 行。
- **Free RAM**：见上表 🚫 行。
- **擦除剩余空间（Free Space Erasure）**：APFS/SSD 时代无意义且有写放大伤害，CCleaner 等也已弱化；不做。
- **"注册表清理"类**（Windows 概念，部分 Mac 产品生搬）：本仓的偏好碎片治理已按 OS 契约做了更诚实的事；不做玄学优化。
- **App 自更新/代装**：只提示不代装——代装要动用户系统的授权链，超出清理工具的本分。

## 4. 验收口径（对齐目标的完成判定）

- 本表 §1 每一行都有可核对的状态依据（对 ✅/⚠️ 行：README 对应段落；对 ❌→✅ 行：新模块 + 自检 + 文档）。
- §2 三项落地且：`swift build` 0 error 0 Swift warning；`--selftest` 相对基线零新增失败；
  新增模块遵守 RELEASE-CHECKLIST 四条硬要求（G14/G15/G16 + 治理域）与"读不到 ≠ 干净"；
  每条新断言有变异证据。
- 🚫 项在本文件留有理由声明（对"达到主流功能水平"的诚实口径：功能面上对齐主流的**有效**部分，
  营销功能不假装有）。
