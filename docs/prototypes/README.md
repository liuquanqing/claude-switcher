# 会话复制交互稿

[打开当前可点击稿](session-transfer.html)。2026-10-28 由本机 Kimi CLI 在既有稿上精简，Codex 只提意见与验证，未代写前端代码。

主界面保留来源、目标、搜索、具体会话清单和底部复制按钮。默认只新增；更新显式开启，涉及更新才确认。说明与结果按操作出现，取消、关闭备份和异常返回各自回到对应层级。默认中文，右上角可切英文。

- [当前主界面](session-transfer-simplified.png) · [当前窄屏](session-transfer-simplified-narrow.png)
- [已接入的原生窗口](native-session-transfer-final.jpg) · [原生更新确认](native-session-transfer-confirm.jpg) · [原生验证](native-session-transfer-validation.json)
- [本轮 22 组浏览器检查记录](session-transfer-simplified-validation.json) · [交互说明](../会话迁移交互设计.md)
- [迁移方案](../会话迁移方案.md) · [引擎与原生接线进度](../会话迁移实现进度.md)
- `session-transfer-fixtures.json`：合成案例；fixtureProof 是演示字段，没有正式格式证据时不能用来放行真实跨段接续。
- `session-transfer-reference.jpg`：原版原生窗口的虚构数据基线。旧截图与 `session-transfer-validation.json`、根目录 `design-qa.md` 保留为 10 月 27 日第一稿历史记录，不能冒充本版验收。

发现并修复了浏览器后退时恢复旧下拉框值造成目标显示不一致的问题，真实浏览器复测通过。bfcache 分支只有事件模拟验证，未宣称实际浏览器命中该缓存路径。

网页稿仍为单文件虚构内存演示。原生 local.6 已按此接入并完成独立临时目录验收，额外提供“复制给 Claude”备用命令；详见实现进度。原生使用文件引擎，不以网页检查替代其验证。真实会话、登录/API配置与守卫均未操作；现用安装未替换。

2026-10-28 后续：Kimi 完成选择/页脚精简与导入命名，[当前原生截图](local6-import-selected.jpg)及[验证与候选安装记录](local6-import-selection-validation.json)。独立候选已升级，未启动；旧图和旧计数保留为前阶段证据。
