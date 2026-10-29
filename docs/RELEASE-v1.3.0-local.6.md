<div align="center">

### 让每一次切换，都保留手上的工作。

**1.3.0 预览版 6** · Apple Silicon · macOS 13+

**[下载 macOS DMG](https://github.com/liuquanqing/claude-switcher/releases/download/v1.3.0-local.6/ClaudeSwitcher-1.3.0-local.6-arm64.dmg)** · [下载应用 ZIP](https://github.com/liuquanqing/claude-switcher/releases/download/v1.3.0-local.6/ClaudeSwitcher-1.3.0-local.6-arm64.zip) · [SHA256 校验文件](https://github.com/liuquanqing/claude-switcher/releases/download/v1.3.0-local.6/SHA256SUMS)

[下载安装](#下载安装) · [本版变化](#这一版把切换做得更完整) · [验证范围](#验证范围)

</div>

> 这是 [l2succes/claude-switcher](https://github.com/l2succes/claude-switcher) 的社区维护版，与 Anthropic 没有隶属关系。感谢原作者 Luc Succes，详见 [CREDITS.md](https://github.com/liuquanqing/claude-switcher/blob/v1.3.0-local.6/CREDITS.md)。

## 这一版，把切换做得更完整

Claude Switcher 仍然是一个轻量的菜单栏工具。`local.6` 在账号切换之外，补齐了网络确认、CLI 登录衔接、会话导入和更安静的状态呈现。

### 切换之前，先看清条件

- 检查代理、TUN 与 `claude.ai`、`api.anthropic.com`、`claude.com` 的出口国家。
- 结果失败、未知或各域名不一致时停止操作。
- 桌面的订阅配置或模式无法确认时，不自动接管。

### 桌面与 CLI，尽量保持一致

- 切换前核验 CLI 身份与可恢复备份。
- 在默认 Keychain 项或 `.credentials.json` 中，只改写本工具管理的 OAuth 字段。
- 写入失败时先回读，必要时还原。
- 已经在运行的 CLI 任务不会被强制停止。

### 后台保护，少一点打扰

- 独立用户级 LaunchAgent 管理明确确认过的订阅桌面。
- 关闭面板或界面不会自动停止守卫。
- API、Magpie、CC Switch 的配置来源会被识别；本工具不接管它们的密钥与退出流程。

### 会话可以带走，也可以回来

适配的桌面本地会话支持导入、可验证增量、备份、撤销与恢复。默认只处理可以核验的索引，不会把它包装成完整的云端聊天迁移。

### 打开面板时，界面保持安静

打开面板只读取本地状态。启动、周期性检查与手动刷新会完成整轮核验，再一次性更新界面；手动检查入口收在 ⓘ 中。

## 下载安装

1. 下载 arm64 的 `.dmg` 或 `.zip`，以及 `SHA256SUMS`。
2. 校验文件哈希。
3. 把 `Claude Switcher 候选版.app` 拖进“应用程序”。
4. 首次打开时按住 Control 点按应用，选择“打开”。

完整步骤见 [INSTALL.md](https://github.com/liuquanqing/claude-switcher/blob/v1.3.0-local.6/docs/INSTALL.md)。

当前构建使用 ad-hoc 本地签名，没有 Developer ID 签名，也未经过 Apple 公证。请勿关闭 Gatekeeper 或批量移除隔离属性。

## 兼容与边界

- 预编译包仅提供 Apple Silicon（arm64），需要 macOS 13 或更高版本。
- Intel 与 universal 构建没有做原生交互验收。
- 候选版和原版 Claude Switcher 共享账号目录，不要同时用两个管理器切号。
- 网络检查是启动门禁与周期性观察，不替代主机级网络控制。
- CLI 同步只处理默认保存的登录，不保证已经运行的任务立即换号。
- 会话导入不是完整的云端聊天迁移，也不提供跨 CLI 账号的自动接续。

## 验证范围

公开发布源码已通过：

- Core：176 项
- 控制器隔离检查：106 项
- release 构建与 ad-hoc 签名验证

真实急停、真实账号 A→B→A 往返、菜单栏嵌套弹层、VoiceOver 与 Intel 原生交互仍未作为本版验收依据。

详见：

- [验证范围](https://github.com/liuquanqing/claude-switcher/blob/v1.3.0-local.6/docs/VALIDATION.md)
- [云端 CI](https://github.com/liuquanqing/claude-switcher/actions/runs/40747931686)

## 版本信息

- 版本：`1.3.0-local.6`
- 内部构建：`20261029.6.7`
- 安装包源码提交：`74cc9d3480ba4f09585ec488fa3e4249456133a8`
- 上游基线：`011c00797c083530dc8cfa4557416cece86ab2b1`

下载文件哈希见 `SHA256SUMS`，构建信息见 `RELEASE-MANIFEST.json`。

## 许可证

MIT。原始版权 © 2026 Luc Succes，许可证原文见 [LICENSE](https://github.com/liuquanqing/claude-switcher/blob/v1.3.0-local.6/LICENSE)。
