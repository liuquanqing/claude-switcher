# 致谢

## 原作者与上游项目

**特别感谢 [Luc Succes](https://github.com/l2succes) 和 [l2succes/claude-switcher](https://github.com/l2succes/claude-switcher)。**

本仓库是 l2succes/claude-switcher 的公开 Fork，基于上游 `main` 分支提交 `011c00797c083530dc8cfa4557416cece86ab2b1` 继续维护。下面这些都来自原作者的工作：菜单栏账号切换器的整体设计、Claude Desktop 账号切换、Claude Code 会话复制窗口，以及桌面与 CLI 登录同步切换。没有这些基础，就没有这个维护版。

- 上游仓库：<https://github.com/l2succes/claude-switcher>
- 许可证：MIT License，Copyright (c) 2026 Luc Succes。原文完整保留在 [LICENSE](LICENSE) 中。

本维护版是社区维护的非官方版本。它和原作者没有隶属关系，原作者也不对本版本的改动负责。本版的问题请提交到本仓库，不要提交到上游。

## 设计参考

以下项目在思路上给了我们启发。我们**没有**合并这些项目的完整代码，它们的作者也**没有**为本项目背书或提供官方支持。

- **[XueshiQiao/CCSwitcher](https://github.com/XueshiQiao/CCSwitcher)**：Claude Code CLI 多账号管理的设计参考。
- **[YOURSJEYO/claude-switcher](https://github.com/YOURSJEYO/claude-switcher)**：启动前做安全检查和地区检查的思路参考。

## 配置互操作

本工具能识别以下工具写入的配置来源，并提供跳转到原工具的入口。识别只是为了避免互相覆盖，本工具不管理这些工具的密钥，也不代表这些项目官方支持本工具。

- **[Magpie](https://github.com/yetone/magpie)**（yetone/magpie）
- **[CC Switch](https://github.com/farion1231/cc-switch)**（farion1231/cc-switch）

注意：CC Switch（farion1231/cc-switch）和上面的 CCSwitcher（XueshiQiao/CCSwitcher）是两个不同的项目。

## 商标

Claude、Claude Code 是 Anthropic 的商标。本项目与 Anthropic 无关。
