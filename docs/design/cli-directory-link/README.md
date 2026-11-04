# Claude Code 独立目录联动

桌面档案和 Claude Code 的账号目录各自保留。点桌面卡片切换时只切桌面；需要对应的 Claude Code 时，复制当前档案的启动命令，并在终端运行。它使用官方的 `CLAUDE_CONFIG_DIR`，仍运行普通 `claude`，第一次在那个目录使用官方登录并选择对应账号。终端已有的 API 环境变量仍由终端管理；专用命令只指定配置目录。目录内的历史和设置独立。原来用普通 `claude` 的终端和默认目录没有迁移；切换器不重写 shell 设置或自动打开终端。旧的「同步默认 CLI」仍是明确确认的兼容操作，它可能改写默认登录。

## 查询和续期

- 启动、唤醒、后台观察和底栏刷新只读取本地状态以及 Claude Code 已写入的额度缓存。缓存缺失、无法匹配账号或比已有数据旧时保留旧数据与原采样时间。
- 缓存文件格式是兼容读取，不是官方承诺的第三方接口。需要主动查询时，在原生 CLI 内执行 `/usage`；需要检查默认登录时，现有核验使用官方 `claude auth status`。刷新额度不代为核验或恢复登录。
- 续期和重新登录交由原生 CLI。切换器不再因为检查额度而读 CLI 钥匙串、启动恢复助手或直接请求订阅额度端点。独立目录入口不收集、复制或续期该目录的登录；现版保留的旧同步操作与此独立。
- 官方状态行的 `rate_limits` 是可选后续集成，需要绑定目录与账号，并保留用户已有状态行配置。本版没有自动安装状态行。

## 对比依据

- [Claude Code 多账号登录](https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts)：官方建议给不同订阅账号使用各自目录。 [CLI 参考](https://code.claude.com/docs/en/cli-reference) 和 [用量命令](https://code.claude.com/docs/en/commands) 描述原生命令。
- [CC Switch v4.0.21](https://github.com/farion1231/cc-switch/blob/main/docs/release-notes/v4.0.21-en.md) 同时提供独立目录终端及切卡片搬动默认登录；后者被其文档明确区分为官方文档未覆盖的操作。[v4.0.25](https://github.com/farion1231/cc-switch/releases/tag/v4.0.25) 进一步修复了「打开终端」混入路由设置的问题。
- [官方状态行输入](https://code.claude.com/docs/en/statusline) 定义会话可用的限额字段，不能拿来当做未运行账号的后台额度 API。
