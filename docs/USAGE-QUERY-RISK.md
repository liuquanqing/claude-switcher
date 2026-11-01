# 额度查询与工具边界核查

核查日期：2026-10-31；更新：2026-11-01。官方 CLI/缓存路径已随 1.3.4 发布。静默主动查询随 1.3.5 发布；隔离测试未使用真实账号，测试通过不代表平台授权或不会触发风控。

2026-11-01 用户选择“静默自动，手动需要授权就授权”。本轮增加仅针对当前完整匹配的订阅身份的低频只读 usage GET，不做全账号轮询或 OAuth 续期；自动读取拿不到权限就保留缓存，显式刷新仍走官方 CLI。请求仍携带账号访问凭据并呈现出口 IP，风险与平台授权边界没有因“不弹窗”而消失。详见 [自动更新方案](账号与额度自动更新.md)。

## 当前实现与风险

1.3.1 的订阅额度来自本机保存的订阅访问凭据，分别请求 `/api/oauth/usage` 与 `/api/oauth/profile`。API 配置下原来跳过这组请求，卡片仅显示订阅缓存。查询不是模型对话，但仍会发送携带账号凭据的请求。

[官方认证说明](https://code.claude.com/docs/en/legal-and-compliance#authentication-and-credential-use)限制第三方产品使用、收集或中转订阅 OAuth 凭据，未明确为第三方额度查询提供例外。因此不能把只读、低频或固定出口当成官方许可，也不能保证账号不会被限制。具体触发条件和概率未公开。

此前选择的官方 CLI 路径已发布：自动读取官方缓存，手动刷新才运行官方 `/usage`。2026-11-01 的静默当前账号查询已完成隔离验证，随 1.3.5 发布；设备端是否更新以安装回执为准。

## 更值得参考的读取边界

[Magpie 当前说明](https://github.com/yetone/magpie/blob/7aa67e9e500e239ce6b589badca4a9b7ab335750/docs/reference.md#L1890-L1922)采用官方 Claude Code `/usage` 读取当前登录账号，不直接向 Anthropic 查询未登录账号。其[实现入口](https://github.com/yetone/magpie/blob/7aa67e9e500e239ce6b589badca4a9b7ab335750/internal/provider/claude_usage_cli.go#L1-L59)将额度解析与官方程序执行分开。

可以参考这个边界：当前官方 CLI 身份能确认时才绑定数据；其他已保存账号保留最后一次可靠缓存和原始时间。不能为了刷新所有账号而临时切遍默认 CLI 登录，也不能根据本地时钟把旧额度自动补满。官方页面 `https://claude.ai/settings/usage` 可作为手动查看入口，账号由用户在官方页面确认。

这仅说明额度读取路径，不为 Magpie 的全部订阅复用或路由功能作授权判断。采用官方 CLI 的实现也需独立验证版本兼容、身份归属、输出解析与失败状态，验收只用假 CLI 和虚构数据。

## 三种工具不要混淆

| 工具 | 核查到的范围 | 对本项目的参考 |
| --- | --- | --- |
| Magpie | “Switch accounts only”切换 Claude Code 登录；Claude Desktop 另有第三方网关接入 | 区分账号切换与路由；官方 CLI 额度读取和缓存边界 |
| farion1231/CC Switch | 新版支持 CLI/IDE 多账号：独立原生配置目录及默认登录切换，不支持 Desktop 多账号。额度采用有效 token 直接查询、失效时官方 CLI/缓存回退；Desktop Official 另用于恢复 `1p` 配置 | 独立配置目录、由官方 CLI 登录和刷新、缓存绑定账号；不要混淆 CLI 与 Desktop 登录 |
| XueshiQiao/CCSwitcher | 管理 Claude Code 的凭据与账号元数据备份、切换；不是桌面数据目录切换器 | CLI 快照、回读与失败还原；不能据此推断任意第三方 OAuth 查询获准 |

来源：[Magpie 切账号说明](https://github.com/yetone/magpie/blob/7aa67e9e500e239ce6b589badca4a9b7ab335750/docs/reference.md#L1867-L1888)、[CC Switch 官方桌面恢复流程](https://github.com/farion1231/cc-switch/blob/e49d12a5f90b70107cc4e69b6621d2e218524890/src-tauri/src/claude_desktop_config.rs#L1248-L1290)、[CCSwitcher 项目说明](https://github.com/XueshiQiao/CCSwitcher/blob/161741556ed983eb257678c4cbed85564a7798b9/README.md)。

## 公开问题检索与 IP 边界

2026-10-31 检索 `/api/oauth/usage` 与 banned、suspended、429 等关键词。可核对的问题包括 [#30930](https://github.com/anthropics/claude-code/issues/30930) 的持续 429，以及 [#32503](https://github.com/anthropics/claude-code/issues/32503) 中官方 `/usage` 同样限流的反馈。这些是用户报告，不是官方限额规格；不能把某条评论的请求次数当作固定阈值。没有找到能确认“仅因查询该接口导致账号封禁”的直接因果证据，这不代表零风险。

[#28091](https://github.com/anthropics/claude-code/issues/28091) 讨论将订阅 OAuth 用于第三方 API 推理遭拒，并非单独查询额度导致封号的证据。

网络请求会向服务端呈现出口 IP；走代理时通常是代理出口，误直连则是本机网络的公网出口。HTTPS 不隐藏这个源 IP。[官方隐私说明](https://privacy.claude.com/en/articles/11186740-does-claude-use-my-location)明确会使用 IP 等信号判断国家/地区，用于平台安全。TUN 存在及另一次国家检查通过，不能证明额度请求逐条受强制代理约束。

## 桌面与 CLI 切换取舍

原版先退出 Desktop、移动账号目录，再尝试 CLI 切换；CLI 失败仍重新打开 Desktop。当前联合事务先验证 CLI 身份和备份，再持久化并回读备份、退出 Desktop、移动目录、恢复 CLI，失败时拒绝继续或还原目录。这解释了旧 CLI 备份未核验时桌面切换被提前拦截。截图已提供显式“仅切换桌面”路径，CLI 保持原样。

建议保留桌面目录切换及安全还原，CLI 后续借鉴 CC Switch 的独立原生配置目录，由官方 CLI 登录、续期，避免让旧 CLI 备份阻断桌面。不能把桌面目录里的凭据直接当作 CLI 登录，也不能宣称已有终端任务均已同步。独立目录是[官方多账号文档](https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts)支持的路径，但会带来每账号独立设置和历史，需要设计共享项目与现有普通 `claude` 命令的兼容。此处仅为方案，未迁移真实登录。

CC Switch 新能力依据：[官方账号指南](https://github.com/farion1231/cc-switch/blob/e49d12a5f90b70107cc4e69b6621d2e218524890/docs/guides/claude-official-accounts-guide-zh.md)、[额度实现](https://github.com/farion1231/cc-switch/blob/e49d12a5f90b70107cc4e69b6621d2e218524890/src-tauri/src/services/subscription.rs)。

## 旧 CLI 备份修复规划（2026-10-31 更新）

授权后的只读结构检查已确认：出错目标有访问令牌、刷新凭据和完整身份信息，访问令牌已过期，缺少本项目新版核验记录。本轮没有进行真实续期、修改默认登录或切换桌面。修复范围与验收见 [CLI 登录备份与联合切换修复方案](plans/CLI登录备份与联合切换修复方案.md)，当前为草案。

补充纠正：XueshiQiao/CCSwitcher 的 README 将续期描述为委派官方 CLI，但固定源码 `161741556ed983eb257678c4cbed85564a7798b9` 中，非活动备份实际由 `AppState.refreshBackupInPlace` 调用 `ClaudeService.refreshOAuthCredentials`，直接 POST OAuth token 接口。我们参考其备份、凭据归属和错误分类，不将这种直接刷新作为拟采用的官方 CLI 续期实现。
