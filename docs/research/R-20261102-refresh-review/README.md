# R-20261102-refresh-review

日期：2026-11-02（Asia/Singapore）。状态：审查和复现完成，下一版规划为 draft；此记录不是修复完成或发布结论。

- 问题：重复钥匙串授权、外部 CLI 登录识别滞后、登录恢复后额度未跟进；统一检查触发和频率；为应用检查更新制定下一版草案。
- 来源范围：本仓库候选源码、最近发布记录、已安装应用的版本与签名元数据；CC Switch、XueshiQiao/CCSwitcher、上游 Claude Switcher 的公开固定提交；Apple、GitHub、Sparkle、Claude Code 官方文档。
- 唯一 synthesis：`docs/research/R-20261102-refresh-review/结论.md`。
- 当前 artifact：本文件、`_qa/refresh-audit/` 的假数据复现和公开源码快照。
- done_when：三个用户问题逐项有代码依据与证据边界，频率表和产品对比可回核，下一版草案包含可观察验收。
- return_to：当前用户聊天；不委派 Claude、不调用真实登录命令、不读取真实钥匙串内容、不改账户、会话、网络、守卫或安装应用。
- 规划门：未找到本项目已登记的 delivery profile，因此只产出 draft，不创建或推定确认权威；不创建 Issue/MR/tag/Release。

## 交付

- [唯一审查结论](结论.md)
- [四项假数据复现](假数据复现.json)
- [下一候选规划草案](../../plans/1.3.6-刷新闭环与应用更新规划.md)
- 可重跑入口：`scripts/audits/run-refresh-flow-reproduction.sh`。已从源码独立重建并复现四项现象；此工具不是修复后的通过验收。
- 规划 doctor 与 lint 均返回 `PLAN_DELIVERY_BLOCKED reason=profile_missing:.zhixing/delivery-profile.json`。因此规划保留 draft，未标 confirmed；缺少登记不妨碍本次已完成的源码审查。
- 本轮无生产代码、UI、已安装应用、真实登录、真实会话、网络或守卫变更。
