# Claude Switcher v1.3.0-local.6（预发布）

- 版本：`1.3.0-local.6`，内部构建 `20261029.6.7`
- 类型：**预发布**
- 平台：Apple Silicon（arm64），macOS 13+
- 上游：[l2succes/claude-switcher](https://github.com/l2succes/claude-switcher)，基线提交 `011c00797c083530dc8cfa4557416cece86ab2b1`

> 这是 l2succes/claude-switcher 的社区维护版，**非官方**，与 Anthropic 无关。感谢原作者 Luc Succes，详见 [CREDITS.md](../CREDITS.md)。

## 本版新增

- **切换前网络门禁**：轮换桌面账号目录前，先检查代理/TUN，再观察 `claude.ai`、`api.anthropic.com`、`claude.com` 的出口国家。失败、未知或各域名不一致时不放行。
- **CLI 身份与备份核验**：切换前核验身份并确认备份。备份失败会在退出或移动桌面目录之前被发现。
- **最小范围写入凭据**：在默认 Keychain 项或 `.credentials.json` 里只改写本工具管理的 OAuth 字段。遇到冲突、拒绝读取或格式未知时停止；写入失败时回读并还原。
- **独立守卫**：用户级 LaunchAgent，约每 10 秒复查一次。它只管理通过本入口打开的桌面，或你明确确认过的订阅桌面。关闭界面不会停止守卫。
- **API/未知模式不自动纳入保护。**
- **Magpie / CC Switch 配置来源识别**，并提供跳转到原工具的入口。本工具不管理这些工具的密钥，也不接管它们的退出流程。
- **会话导入**（已适配的桌面索引）：原文共享、不改写；默认只新增，可验证时做同段增量；支持备份、撤销和恢复。
- **静默刷新**：打开面板只读本地状态。启动时、每 5 分钟、手动刷新时更新，结果完成后一次性发布，检查过程中不会先降级显示。原来顶部的大核验按钮移到 ⓘ 里，强门禁规则不变。
- 安装包改为候选版 `Claude Switcher 候选版.app`（Bundle ID `dev.claudeswitcher.candidate`），默认不会覆盖原版。

## 限制与注意事项

- 只提供 **arm64** 预编译包。**Intel 和 universal 构建都没有在真机上验收过。**
- 只有 **ad-hoc 本地签名**，**没有 Developer ID 签名，也没有经过公证**。首次打开需要手动确认，方法见 [INSTALL.md](INSTALL.md)。请不要关闭 Gatekeeper。
- 候选版和原版**共享同一个账号目录**，不要同时用两个管理器切号。
- 网络探测只是本程序对几个主要域名的观察结果，不是防火墙，也不能证明每条连接的出口。
- CLI 部分只核验和同步默认保存的登录，不会强行停止正在运行的任务，也不保证旧任务会立刻换成新账号。
- 会话导入不是完整的云端聊天迁移，也不能跨 CLI 会话段自动接续。
- 不承诺账号安全或防封号，也不承诺所有情况都能恢复。

## 验证状态

自动化测试只使用虚构数据、注入的 worker 和临时目录。公开源码副本已重新运行：Core 176 项、控制器检查 106 项通过，release 构建与签名验证通过。真实急停、真实账号 A→B→A 往返、菜单栏嵌套弹层、VoiceOver、Intel 等场景**尚未验收**。详见 [VALIDATION.md](VALIDATION.md)。

## 安装

1. 从本 Release 下载 arm64 的 `.dmg` 或 `.zip`，以及 `SHA256SUMS`，校验哈希值。
2. 把 `Claude Switcher 候选版.app` 拖进“应用程序”文件夹。不要直接在磁盘映像或临时目录里长期运行。
3. 首次打开时，按住 Control 点按 App 选择“打开”，或到“系统设置 → 隐私与安全性”里点“仍要打开”。

完整步骤与卸载方法见 [INSTALL.md](INSTALL.md)。

## 许可证

MIT。原始版权 © 2026 Luc Succes，许可证原文见 [LICENSE](../LICENSE)。
