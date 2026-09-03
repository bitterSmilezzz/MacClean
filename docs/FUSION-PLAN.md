# MacClean 开源工具融合方案（v2 规划）

> 调研日期：2026-09-03。来源：GitHub 三款主流开源 Mac 清理工具 README/文档 + 用户历史清理经验（全机安全审计报告、CLEANUP-RULES.md）。

---

## 一、开源工具功能盘点

### 1. Mole（tw93/Mole，GPL v3，CLI 免费开源）
- **Deep cleaning**：缓存/日志/残留/孤儿数据，`mo clean`（含 `--dry-run` 预览、`--whitelist` 保护）
- **Smart uninstaller**：卸载 App 连同 launch agents、preferences、**隐藏残留**
- **Disk insights**：磁盘可视化、大文件查找、`mo analyze`
- **Live monitoring**：CPU/GPU/内存/磁盘/网络实时状态（`mo status`）
- **操作日志**：`mo history` 记录清理活动（`~/Library/Logs/mole/operations.log`）
- **purge**：清理项目构建产物

### 2. Pearcleaner（alienator88/Pearcleaner，Apache 2.0 + Commons Clause）
- **App 卸载 + 孤儿文件搜索**（核心）
- **Finder 扩展**：右键 → 卸载
- **Sentinel Monitor**：App 拖入废纸篓时自动清理其残留（~2MB 内存常驻）
- **搜索敏感度可调**、主题系统、剪枝无用翻译/多架构

### 3. PureMac（momenbasel/PureMac，MIT）
- **Smart Care**：一键并行扫描全部分类
- **App 卸载器**：10 级匹配引擎（bundle ID、team ID、entitlements、Spotlight 元数据、容器发现、公司名启发式、部分路径匹配）找全部关联文件
- **Orphan Finder**：遍历 ~/Library 找已删除 App 的残留
- **System Cleaner 分类**：系统垃圾/用户缓存/AI Apps/Mail 附件/垃圾箱/大文件/Xcode/Brew/Node/Docker
- **定时自动清理**（可配置间隔 + 阈值）
- **FDA 权限引导**（首次启动引导授权，权限缺失自动重试）
- **诚实原则**：不虚报 "47GB 垃圾"、不夸大 "purgeable space"

### 4. 用户自己的清理经验（全机审计报告 + 规则集合）
- 卸载残留三案例：Lemon（LaunchDaemons）、Parallels（keychain）、rtk（钩子）
- 清理 ~/.claude 整目录、死代理配置、残留文件服务器进程
- 既有 CLEANUP-RULES.md：6 类 23 条规则 + 7 条安全护栏（G1-G7）

---

## 二、融合决策（v2 实施范围）

| 功能 | 来源 | 实施 | 说明 |
|------|------|------|------|
| **App 卸载器** | Pearcleaner/PureMac | ✅ v2 | 选 App → 扫关联文件（AS/Preferences/Caches/Containers/LaunchAgents/Logs）→ 移废纸篓 |
| **清理历史** | Mole history | ✅ v2 | 记录每次清理：时间/分类/大小/项数，可查看 |
| **Smart Care 一键扫描** | PureMac | ✅ v2 | 全部分类并行扫描 + 汇总报告（已有 scanAll，补汇总 UI） |
| **whitelist 保护** | Mole/PureMac | ⏳ v2.1 | 用户自定义保护路径，扫描时跳过 |
| **Finder 右键卸载** | Pearcleaner | ⏳ v2.1 | 需要扩展/插件，暂缓 |
| **Sentinel 常驻监控** | Pearcleaner | ⏳ v2.1 | 常驻进程 + 授权复杂度高，暂缓 |
| **定时清理** | PureMac | ⏳ v2.1 | 后台调度 + LaunchAgent，暂缓 |
| **磁盘可视化** | Mole analyze | ⏳ v2.1 | 交互复杂，暂缓 |
| **系统监控仪表** | Mole status | ❌ | 超出清理工具定位 |
| **虚假紧迫感** | — | ❌ 明确拒绝 | 遵循 PureMac 诚实原则：不虚报垃圾量、不夸大 |

---

## 三、App 卸载器设计

### 匹配关联文件（借鉴 PureMac 10 级匹配的简化版）
对选中 App，按 bundle id 与 app 名在两个维度匹配：
1. **bundle id 精确/前缀匹配**：`com.tencent.xinWeChat` → `~/Library/Containers/com.tencent.xinWeChat*`、`~/Library/Preferences/com.tencent.xinWeChat*`
2. **名称归一化匹配**（沿用 A1 的 installedApps 逻辑）：
   - `~/Library/Application Support/<App名>`（及别名）
   - `~/Library/Caches/<bundle id>`
   - `~/Library/Logs/<App名>`
   - `~/Library/LaunchAgents/*<App名>*`
   - `~/Library/WebKit`、`~/Library/HTTPStorages`、`~/Library/Saved Application State`
   - `~/Library/Containers/<bundle id>`

### 安全
- 复用 G1/G6 护栏与 `Cleaner`（默认移废纸篓）
- 系统 App（com.apple.*）不可卸载；运行中的 App 提示先退出
- 不匹配"共享数据"（其他已装 App 仍引用的路径跳过，沿用 A1 的"宁可漏报"原则）

---

## 四、清理历史设计

- 存储：`~/Library/Application Support/MacClean/history.json`
- 字段：时间、分类、项数、释放字节、模式（废纸篓/彻底删除）、失败数
- UI：侧边栏「历史」页，列表 + 总计

---

## 五、诚实原则（写进 README 与 UI）

1. 不显示虚假的 "XX GB 垃圾" 红色警报（只显示扫描真实结果）
2. 不声称可清理 APFS purgeable space（macOS 自己管理，参考 PureMac）
3. 每个删除动作默认可恢复（废纸篓），危险项显式标注

---

## 六、协议声明（MIT 合规说明）

- 本项目整体采用 **MIT 协议**（见根目录 LICENSE），代码全部自研。
- 唯一第三方依赖 [ViewInspector](https://github.com/nalexn/ViewInspector)（MIT）。
- 本方案中借鉴的 Mole（GPL）、Pearcleaner（Apache 2.0 + Commons Clause）、PureMac（MIT）均**仅借鉴功能思路**（见上表），未复制任何源代码，不构成衍生作品，与 MIT 协议无冲突。
- 设计参考（Apple DESIGN.md）为设计 token 参考，非代码引用。
