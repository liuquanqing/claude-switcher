# Claude Code 独立目录联动

桌面档案和 Claude Code 的账号目录各自保留。点桌面卡片切换时只切桌面。打开终端时，依次核验已关联目录、默认目录、已有独立目录；有与当前桌面账号和组织一致的登录就复用。

没有可复用登录时，只检查旧 CLI 备份是否存在。找到备份会提供「恢复旧备份」入口，即使默认 CLI 已退出也可使用。确认后才核验凭据，已有默认登录先核验和备份；无可用备份时可在独立目录走官方登录。恢复不会启动或关闭桌面版、启动终端或自动换掉运行中的终端账号。

正式版 1.3.5 把 CLI 恢复作为桌面换号事务的一部分；本版沿用其备份回读和身份核验，用于单独确认的恢复操作。各目录的设置和历史保持原样。

Preview 单独写入自己的额度和账号核验缓存，原版共享缓存仅用于兼容读取。旧缓存缺少账号及组织身份时，显式打开终端会先核对当前桌面账号。

## 查询和续期

- CLI 登录状态和桌面订阅额度各自处理。额度刷新参见 [用量刷新与重置时间](../../USAGE-REFRESH.md)。
- 缓存文件格式是兼容读取，不是官方承诺的第三方接口。需要主动查询时，在原生 CLI 内执行 `/usage`；需要检查默认登录时，现有核验使用官方 `claude auth status`。刷新额度不代为核验或恢复登录。
- 续期和重新登录交由原生 CLI。刷新额度不会启动旧备份恢复；只有用户确认恢复后，既有备份事务才核验旧凭据并在必要时尝试官方 CLI 续期。
- 官方状态行的 `rate_limits` 是可选后续集成，需要绑定目录与账号，并保留用户已有状态行配置。本版没有自动安装状态行。

## 对比依据

- [Claude Code 多账号登录](https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts)：官方建议给不同订阅账号使用各自目录。 [CLI 参考](https://code.claude.com/docs/en/cli-reference) 和 [用量命令](https://code.claude.com/docs/en/commands) 描述原生命令。
- [CC Switch v4.0.21](https://github.com/farion1231/cc-switch/blob/main/docs/release-notes/v4.0.21-en.md) 同时提供独立目录终端及切卡片搬动默认登录；后者被其文档明确区分为官方文档未覆盖的操作。[v4.0.25](https://github.com/farion1231/cc-switch/releases/tag/v4.0.25) 进一步修复了「打开终端」混入路由设置的问题。
- [官方状态行输入](https://code.claude.com/docs/en/statusline) 定义会话可用的限额字段，不能拿来当做未运行账号的后台额度 API。
