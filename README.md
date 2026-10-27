# Claude Switcher · 本地维护版

一个菜单栏应用管理 Claude 桌面账号、终端登录同步和网络地区守护。基于 [l2succes/claude-switcher](https://github.com/l2succes/claude-switcher) 的 MIT 代码开发；上游说明保存在 [UPSTREAM-README](docs/UPSTREAM-README.md)。

当前为 `v1.3.0-local.2` 本地开发候选，**没有替换已安装应用，也没有部署新的守卫**。真实账号切换及异常网络急停还需要真机验收。

![虚构账号界面预览](docs/panel-local.png)

*截图使用虚构账号，不代表已部署保护。*

本轮界面由 Kimi CLI 在原有双列账号布局上局部融合：窄保护条、网格添加卡、退出常驻真实保护状态；主代理负责后端与评审。

## 本轮功能

- 桌面账号切换与终端凭据同步，保留原来的用量面板。
- 打开、切换前检查代理、TUN 和出口国家；未知也不放行。完成切换后，打开 Claude 前再检查一次。
- 用户级独立守卫每 10 秒执行一次。检测到网络异常或国家不符时关闭 Claude，退出界面后仍继续运行。
- 明确区分“退出界面，保留后台保护”和“停止保护”。不会自动更改系统语言、时区、IPv6 或代理规则。
- 账号移动失败时还原原目录；终端同步失败时报告部分完成，不冒充两端成功。

**会话复制/迁移本轮不启用。** 已有索引原型，但需先回查过去的订阅到订阅、订阅与 API 模式迁移脚本。桌面会话索引与 `~/.claude/projects` 的会话历史是不同层次，不能把索引复制当作完整数据迁移。

## 构建与测试

需要 macOS 13+、Swift/Xcode 命令行工具。本地验证使用临时目录、假网络和假进程动作，不使用真实账号或钥匙串。

```sh
swift test
./build.sh
```

产物：`build/Claude Switcher.app`，包含 `Contents/Helpers/ClaudeGuard`。构建不会安装 App、注册登录项或启动守卫。

```sh
./build.sh dmg       # 当前架构 DMG，输出到 dist/
./build.sh install   # 明确安装；要求先退出 Claude 和旧切换器，保留原 App 备份
```

安装前请先读 [安装与迁移](docs/安装与迁移.md)，尤其是已安装旧保镖的机器。

## 保护边界

目标国家由用户保存，例如 `SG`。当前支持 Shadowrocket VPN 与 `198.18.*` TUN 识别；“自动识别 TUN”仅检查同类 TUN。国家通过 claude.ai、api.anthropic.com、claude.com 三个域名的无认证 HTTPS trace 并行确认，彼此不一致、超时、错误响应或字段不明确时拒绝启动。

这是**启动门禁和进程急停**，不是防火墙。轮询间隔、网络探测和终止过程存在延迟；从 Finder 直接打开 Claude 也不经过启动门禁。三个主要域名的探测仍不能证明所有子域和每条连接采用同一出口，仍需代理路由正确。

后台急停只针对 Claude 桌面客户端；终端凭据同步不代表任意终端或 IDE 中的 Claude Code 进程也受急停保护。配置与回执只保存必要状态，不记录公网 IP、代理地址、账号或会话内容。

当前阶段还需核对常用 Magpie/3P 模式与守护的进程范围；不能把订阅流程的验证当作 API 兼容验收。见下方存储与迁移分析。

## 文档

- [账号存储、3P 与迁移方案分析](docs/存储与迁移方案分析.md)
- [整合设计与验收边界](docs/整合设计.md)
- [开发与验证](docs/开发与验证.md)
- [安装、旧守卫迁移和停止保护](docs/安装与迁移.md)

Git 只在本地维护，分支为 `codex/network-region-guard`，`upstream` 指向原项目；不推送上游或建立远端仓库。

## License

MIT，保留上游 LICENSE。
