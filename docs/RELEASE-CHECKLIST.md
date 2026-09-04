# MacClean 发版前自检清单（P5 发布规范）

> 每次发版前逐项打勾。本机无 Xcode/CI，靠清单保证质量。

## 1. 代码与测试
- [ ] `swift build` 无 error（允许 deprecation warning）
- [ ] `.build/debug/MacClean --selftest` 全过（退出码 0）
- [ ] `.build/debug/MacClean --scan` 冒烟（扫描不崩溃、结果合理）
- [ ] 改动涉及 UI 时：`--selftest` 中视图用例已覆盖或手动确认

## 2. 功能冒烟（手动）
- [ ] 6 大分类均可扫描出结果
- [ ] 勾选 → 清理 → 确认弹窗 → 移入废纸篓链路可用
- [ ] App 卸载器：选 App → 关联文件列表 → 移入废纸篓
- [ ] 清理历史有记录、可清空
- [ ] AI 面板：设置（baseURL/Key/模型）→ 连通性测试 → ✨ 提问 → 回答

## 3. 安全护栏
- [ ] 无新增危险路径（对照 CLEANUP-RULES.md G1–G7）
- [ ] API Key 不落盘、不进日志、不进 git（Keychain 存储）
- [ ] 无 `print` 输出密钥/路径敏感信息

## 4. 分发
- [ ] `./scripts/build-app.sh` 成功（ad-hoc 签名）
- [ ] `ditto -c -k --keepParent` 产物 zip 生成
- [ ] README「安装与首次打开」与实际一致（xattr -cr 指引）
- [ ] Release notes 注明：ad-hoc 未公证、TCC 权限说明

## 5. 发布
- [ ] git 工作区干净，main 已推送
- [ ] tag 命名 `vX.Y.Z`，annotated
- [ ] `gh release create` 附件 zip + 完整 notes
- [ ] `gh release view` 确认非 draft、资产齐全
