# 会话复制交互稿

[打开可点击交互稿](session-transfer.html)。Kimi CLI已完成设计与一轮问题修正，主会话29项浏览器交互/响应式检查通过，控制台错误0。单文件可离线打开，不读取真实账号或会话。

保留来源、目标、搜索和勾选列表；默认仅新增，更新显式开启。预览准确显示新增/更新、自动备份和其他未纳入项。API空间、退出后重新预览、失效计划、两类恢复和撤销冲突均是虚构内存演示。

- [选择页截图](session-transfer-select.png) · [预览截图](session-transfer-preview.png) · [窄屏截图](session-transfer-narrow.png) · [恢复状态截图](session-transfer-recovery.png)
- [交互说明](../会话迁移交互设计.md) · [方案草案](../会话迁移方案.md) · [QA记录](../../design-qa.md)
- `session-transfer-fixtures.json`：合成案例；fixtureProof不是官方Claude字段。HTML内嵌fixture与其精确一致。
- `session-transfer-reference.jpg`：既有原生窗口的Store(demo:true)基线；新稿是功能扩展，不宣称1:1像素复刻。
- `session-transfer-validation.json`：本轮真实执行的原型检查、修正与边界记录。

原预约19:50的单次续办实际于22:41触发；初次Kimi限额记录保留，恢复后使用同一Kimi默认配置，未替换前端作者。源代码/生产入口未改；新迁移引擎仍未实现，真实会话、登录/API配置、CLI和守卫均未操作。本轮按约只提交本地，不推送GitLab。
