<div align="center">

<img src="assets/icon-candidates/switcher-flow-v6.png" width="88" alt="Claude Switcher">

# Claude Switcher

### 让每一次切换，都保留手上的工作。

为 Claude Desktop 与 Claude Code 打造的 macOS 菜单栏伙伴。<br>
账号、额度、会话与网络状态，在一个安静的入口里衔接起来。

[![Release](https://img.shields.io/github/v/release/liuquanqing/claude-switcher?include_prereleases&label=release)](https://github.com/liuquanqing/claude-switcher/releases)
[![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20%C2%B7%20Apple%20Silicon-lightgrey)](https://github.com/liuquanqing/claude-switcher/releases)
[![License](https://img.shields.io/github/license/liuquanqing/claude-switcher)](LICENSE)
[![macOS checks](https://github.com/liuquanqing/claude-switcher/actions/workflows/ci.yml/badge.svg)](https://github.com/liuquanqing/claude-switcher/actions/workflows/ci.yml)

[下载](#下载) · [核心能力](#核心能力) · [快速开始](#快速开始) · [边界与验证](#边界与验证) · [English](README.en.md)

</div>

<p align="center">
  <img src="docs/images/main.png" width="820" alt="Claude Switcher 主界面">
</p>

> Claude Switcher 是社区维护的非官方工具，与 Anthropic 没有隶属关系。<br>
> 项目基于 [l2succes/claude-switcher](https://github.com/l2succes/claude-switcher) 继续维护，原作者与许可证信息见 [CREDITS.md](CREDITS.md)。

## 为什么是 Claude Switcher？

多个 Claude 账号，通常意味着不断登录、退出、再找回终端里的工作身份。Claude Switcher 把这些重复动作收进菜单栏，同时让切换过程更可解释：先看见当前状态，再决定下一步。

它关注三件事：

- **少打断**：额度和重置时间直接呈现，打开面板只读取本地状态。
- **保持一致**：桌面账号切换后，默认保存的 Claude Code CLI 登录也能继续同步。
- **有依据**：启动与切号前检查代理、TUN、目标地区和 CLI 备份；无法确认时停在原地。

## 核心能力

<table>
<tr>
<td width="50%" valign="top">

**在账号之间从容切换**

为不同工作身份保留独立的 Claude Desktop 数据目录，用更短的路径完成切换。

</td>
<td width="50%" valign="top">

**桌面与 CLI 一起对齐**

切换时同步默认保存的 OAuth 登录，减少桌面一套账号、终端另一套账号带来的割裂。

</td>
</tr>
<tr>
<td valign="top">

**切换前先确认**

检查代理、TUN、Claude 相关域名与目标地区。失败、未知或路由不一致时不继续。

</td>
<td valign="top">

**后台继续观察**

独立守卫管理明确确认过的订阅桌面；关闭面板后，保护设置仍由你决定是否保留。

</td>
</tr>
<tr>
<td valign="top">

**把会话带到下一站**

为适配的桌面会话提供导入、增量、备份、撤销与恢复，默认只处理可核验的本地索引。

</td>
<td valign="top">

**和现有工具共处**

识别 Magpie、CC Switch 写入的配置来源，提供跳转入口，不改写它们的密钥或退出流程。

</td>
</tr>
</table>

## 一次切换，几步完成

```mermaid
flowchart LR
    A[选择目标账号] --> B[检查网络与 CLI 条件]
    B --> C[保存当前账号状态]
    C --> D[切换 Desktop 账号]
    D --> E[同步默认 CLI 登录]
    E --> F[确认结果并继续工作]
```

只有当检查结果明确通过，流程才会继续。API 模式、未知桌面模式、无法确认的 CLI 存储或冲突中的会话，都会停在原状态，等待你处理。

## 界面

<table>
<tr>
<td align="center" width="50%">
<img src="docs/images/main.png" alt="账号与额度面板" width="420"><br>
账号与额度
</td>
<td align="center" width="50%">
<img src="docs/images/settings.png" alt="保护设置" width="420"><br>
网络与保护设置
</td>
</tr>
</table>

界面截图均使用虚构账号与演示数据。

## 下载

前往 [Releases](https://github.com/liuquanqing/claude-switcher/releases) 下载 DMG 或 ZIP，并核对同页的 `SHA256SUMS`。

当前预编译包：

- Apple Silicon（arm64）
- macOS 13 及以上
- 候选版应用名：`Claude Switcher 候选版.app`

> 当前构建使用 ad-hoc 本地签名，未经过 Apple 公证。首次打开方式、升级与卸载步骤见 [安装说明](docs/INSTALL.md)。

## 快速开始

1. 下载并校验安装包。
2. 将 `Claude Switcher 候选版.app` 拖入“应用程序”。
3. 首次启动时，按住 Control 点按应用并选择“打开”。
4. 添加账号，或切换到一个空账号后在 Claude 中完成登录。
5. 如需后台保护，在设置中确认目标地区、代理方式和桌面范围。

安装前建议只保留一个 Claude 账号管理器在运行。候选版与原版 Claude Switcher 共享同一账号目录，不要同时切号。

## 常见问题

<details>
<summary><strong>切换账号会改写云端会话吗？</strong></summary>

不会。工具通过切换 Claude Desktop 的本地数据目录来改变当前账号；适用于导入的本地会话索引也不会被包装成云端迁移。

</details>

<details>
<summary><strong>为什么已经运行的 CLI 任务不一定立即换号？</strong></summary>

Claude Switcher 同步的是默认保存的 CLI 登录。已经启动的任务可能继续使用启动时取得的身份；本工具不会为了切号强制结束这些任务。

</details>

<details>
<summary><strong>当前支持哪些网络检测方式？</strong></summary>

当前版本支持 Shadowrocket 连接状态，以及“自动”模式下的 TUN 网卡。无法确认代理、TUN 或目标地区时，切换和受保护启动会停止。

</details>

<details>
<summary><strong>可以和原版 Claude Switcher 同时安装吗？</strong></summary>

可以并存，但两者共享同一账号目录。请不要同时打开两个管理器切号，也不要同时启用两套守卫。

</details>

## 边界与验证

Claude Switcher 的定位是**切换门禁与周期性状态观察**，与系统级网络策略互补。网络层隔离与即时阻断仍在独立验证中，尚未接入这个预发布版本。

网络检查、CLI 同步和会话导入都以可确认的边界为前提：

- 只同步默认保存的 CLI 登录，不保证已经运行的任务立即换号。
- API 或未知模式的桌面不会自动纳入订阅保护。
- 会话导入面向已适配的桌面索引，不等同于完整云端聊天迁移。
- 后台守卫约每 10 秒检查一次，不能覆盖两次检查之间的全部变化。

当前公开发布源码已通过：

- Core 测试：176 项
- 控制器隔离检查：106 项
- release 构建与 ad-hoc 签名验证

[查看完整验证范围](docs/VALIDATION.md) · [查看最新云端 CI](https://github.com/liuquanqing/claude-switcher/actions/workflows/ci.yml)

## 从源码构建

需要 Xcode 命令行工具（Swift 5.9+）。

```bash
./build.sh          # 构建，不会自动安装或注册服务
./build.sh test     # 运行核心测试
scripts/package-release.sh
```

开发与贡献请先阅读 [AGENTS.md](AGENTS.md)。自动化测试只能使用虚构数据与临时目录，不要使用真实登录、Keychain、账号目录或会话。

## 致谢

感谢 [Luc Succes](https://github.com/l2succes) 创立的 [l2succes/claude-switcher](https://github.com/l2succes/claude-switcher)，它为桌面账号切换、会话复制和 CLI 登录同步提供了基础。

也感谢 [XueshiQiao/CCSwitcher](https://github.com/XueshiQiao/CCSwitcher)、[YOURSJEYO/claude-switcher](https://github.com/YOURSJEYO/claude-switcher)、[Magpie](https://github.com/yetone/magpie) 与 [CC Switch](https://github.com/farion1231/cc-switch) 在账号管理、启动检查和配置互操作方面带来的启发。

完整贡献与许可证说明见 [CREDITS.md](CREDITS.md) 与 [LICENSE](LICENSE)。

<div align="center">

**Claude Switcher**<br>
Switch lightly. Keep working.

</div>
