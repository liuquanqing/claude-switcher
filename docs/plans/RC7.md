---
schema: zhixing.delivery-plan/v1
id: PLAN-claude-switcher-rc7
project: claude-switcher
planning_unit: milestone
status: confirmed
delivered_ref: repo:_qa/rc6-release/published.json
delivered_verified_at: 2026-11-05
runtime_ref: repo:_qa/guard-upgrade-incident/snapshot.json
runtime_verified_at: 2026-11-05
candidate_ref: repo:docs/plans/RC7.md
candidate_verified_at: 2026-11-05
source_refs: ["repo:App/Protection.swift", "repo:App/CLIProfileActions.swift", "repo:App/ApplicationUpdater.swift", "repo:docs/design/unified-controls/README.md"]
conflicts: []
needs_user: false
confirmed_by: user
confirmed_at: 2026-11-05
supersedes: null
next_gate: 完成本地候选复核；签名包跨版本安装与原生操作仍为发布前独立门
---

## 当前判断

已交付 RC6；运行侧上次只读核对为 RC6。RC6 只完成独立目录命令复制和安装包下载，尚无完整的关联向导与更新安装。用户要求保留现有登录、历史和守卫，先做除失效登录恢复以外的体验。

## 价值

日常操作只有「开启/暂停保护」「打开 CLI」「更新并重启」。不需要复制命令、理解目录结构或手动反复关闭开启保护。

## 目标

1. 保护：等待本次开启产生的新回报；超时给一个重试入口。网络诊断属于可选排查。重试沿用已保存设置，不隐式保存表单草稿。
2. CLI：按桌面账号与组织保存打开方式。可沿用现有默认目录，或选择独立目录；只有官方报告匹配才显示一致。未登录、账号不同、检查失败分别呈现。直接打开官方终端，旧默认登录和历史不迁移；旧兼容替换移到高级入口。
3. 更新：校验完整签名包，正常退出切换器，原子替换并重启。拒绝退出、安装失败或启动确认失败时有明确结果与回退路径；不关闭 Claude/CLI。识别守卫路径是否与被更新 App 一致，协调保护准备，不能默默更新别的旧 App。
4. Kimi 实现界面和产品文案；Codex 负责后端、集成、假数据测试及复核。
5. 文档说明现有登录如何沿用、多目录何时创建、旧历史在哪里，以及首次安装自动更新支持的引导边界。

## 非目标

不恢复或续期 Personal 的失效备份，不复制真实凭据，不代登录，不迁移真实历史，不改现有守卫注册、代理或网络，不用真实急停作验收。本轮不发布/安装候选版。尚未完成的关联不能标为已登录。

## 验收

- [x] 保护从开启至新鲜回报不出现假绿灯；重试无需先暂停；旧回报不能确认新操作。假守卫与回报夹具通过。
- [x] 账号不同或组织不同不能配对；目录存在/终端打开不能证明登录成功；默认与独立目录的控制器流程用虚构环境验证。
- [x] 更新的校验拒绝、旧构建、错误 Bundle ID、无法退出、替换失败、重启失败、恢复旧版用临时 App 和注入验证；没有真实账号或守卫夹具。
- [x] 正常操作不引入新的后台 CLI 登录/续期；用户已有默认目录和历史保持原样。假数据验证关联元数据和历史哨兵。
- [x] 中英文与紧凑窗口的 22 张离屏渲染通过；首次选择面板的目标身份及账号变化后关闭已复测。原生交互另列未测项。
- [ ] 真实签名、公证候选包的跨版本安装与回退。当前仅编译，签名验证拒绝使用注入结果，不能替代实际信任链验收。
- [ ] 原生键盘、鼠标和 VoiceOver 操作复核；离屏渲染不能替代。

## 风险与冲突

CLI 官方报告可能不提供完整账号字段，不能用目录名或邮箱单独强行配对。独立目录与默认目录的历史并非同一个列表。守卫仍指向其他旧目录时，不能把 GUI 更新冒充守卫已更新。真实键盘/鼠标验收受原生工具稳定性限制，单列未测项。

## 待决

没有阻止本地开发的用户问题。私钥、公证上传、生产安装和服务交接在候选可核验后按授权范围处理，不由本规划自动执行。

## 下一门

本地候选的具体证据和未测项见 [验收记录](../design/unified-controls/verification.md)。完成本地截图复核后，再进入签名候选的隔离安装验收；本轮不发布、不替换运行版。

## 来源

以上 source_refs 为现有仓库代码及已整理的交互方案。用户在本聊天明确要求完整开发、Kimi 前端、假数据验证，并保留真实账号/守卫；失效备份恢复暂不做。
