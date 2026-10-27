# 会话复制交互稿

[打开当前可点击稿](session-transfer.html)。2026-10-28 由本机 Kimi CLI 在既有稿上精简，Codex 只提意见与验证，未代写前端代码。

主界面保留来源、目标、搜索、具体会话清单和底部复制按钮。默认只新增；更新显式开启，涉及更新才确认。说明与结果按操作出现，取消、关闭备份和异常返回各自回到对应层级。默认中文，右上角可切英文。

- [当前主界面](session-transfer-simplified.png) · [当前窄屏](session-transfer-simplified-narrow.png)
- [本轮 22 组浏览器检查记录](session-transfer-simplified-validation.json) · [交互说明](../会话迁移交互设计.md)
- [迁移方案](../会话迁移方案.md) · [引擎与原生接线进度](../会话迁移实现进度.md)
- `session-transfer-fixtures.json`：合成案例；fixtureProof 是演示字段，没有正式格式证据时不能用来放行真实跨段接续。
- `session-transfer-reference.jpg`：原版原生窗口的虚构数据基线。旧截图与 `session-transfer-validation.json`、根目录 `design-qa.md` 保留为 10 月 27 日第一稿历史记录，不能冒充本版验收。

发现并修复了浏览器后退时恢复旧下拉框值造成目标显示不一致的问题，真实浏览器复测通过。bfcache 分支只有事件模拟验证，未宣称实际浏览器命中该缓存路径。

本稿单文件离线，所有复制、备份和恢复只改变虚构内存；网页通过不等于原生功能已启用。真实会话、登录/API配置、CLI和守卫均未操作。
