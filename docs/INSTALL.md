# 安装与卸载

Claude Switcher 常驻菜单栏，安装后不会自动接管 Claude。完成账号设置，或主动开启保护后，才会参与相应的切换与检查流程。

适用版本：`v1.3.0-local.6`（预发布）。

## 系统要求

- Apple Silicon（arm64）Mac，macOS 13 或更高。
- 预编译包没有 Intel 版。universal 构建也没有在真机上验收过，Intel 用户请自行从源码构建，并自行承担风险。

## 1. 下载并校验

推荐直接[下载 macOS DMG](https://github.com/liuquanqing/claude-switcher/releases/download/v1.3.0-local.6/ClaudeSwitcher-1.3.0-local.6-arm64.dmg)，打开后将应用拖入“应用程序”。也可以在[当前版本的 Release 页面](https://github.com/liuquanqing/claude-switcher/releases/tag/v1.3.0-local.6)下载：

- `.dmg` 或 `.zip`（二选一）
- `SHA256SUMS`

把它们放进同一个文件夹，在终端里进入这个文件夹，然后运行：

```bash
shasum -a 256 <下载的文件名>
cat SHA256SUMS
```

把第一条命令输出的哈希值和 `SHA256SUMS` 里同名文件的那一行对比，完全一致才继续。不一致时，请删除文件并重新下载。

## 2. 拖进“应用程序”

打开 DMG（或解压 ZIP），把 **`Claude Switcher 候选版.app`** 拖进 **应用程序（/Applications）** 文件夹。

- 候选版的 Bundle ID 是 `dev.claudeswitcher.candidate`，名称也和原版不同，所以默认不会覆盖已经装好的原版 Claude Switcher。
- **不要直接在磁盘映像或下载/临时目录里运行。** 独立守卫会记录 App 内 helper 的路径。磁盘映像推出后或临时目录被清理后，这个路径就会失效。
- **候选版和原版共享同一个账号目录。** 两者可以并存，但不要同时用两个管理器切号，也不要在两个管理器里同时开启保护。

## 3. 首次打开

当前包使用 ad-hoc 本地签名，尚无 Developer ID 签名和 Apple 公证。macOS 可能提示“无法验证开发者”或“Apple 无法检查此应用”。

确认下载来自本仓库并完成哈希校验后：

1. 将应用放入“应用程序”，双击尝试打开一次。
2. 若被系统阻止，打开 **系统设置 → 隐私与安全性**。
3. 在安全性区域找到 **Claude Switcher 候选版** 的提示，点 **仍要打开（Open Anyway）**。
4. 按系统提示验证身份并确认打开。授权仅针对这个应用；系统版本或组织管理策略可能影响按钮是否可用。

部分系统版本也可用 Control 点按应用 →“打开”，但不应把这一方式当成所有 macOS 版本都有效的唯一入口。

[Apple 的首次打开说明](https://support.apple.com/102445)。请保留 Gatekeeper，不对整个下载目录或“应用程序”批量移除隔离属性。如果提示文件损坏或恶意软件，请先停止打开并重新核对来源与校验值。

签名、公证的准备要求与下一版 `1.3.0-rc.6` 的命名见 [macOS 分发说明](MACOS-DISTRIBUTION.md)。现有下载包的签名状态未因此改变。

## 4. 开启保护（可选）

在设置中填写目标出口国家（两位国家代码，例如 `SG`），选择代理检测方式（Shadowrocket 或自动/TUN），然后启用保护。启用后：

- 会在 `~/Library/LaunchAgents/` 下注册用户级任务 `dev.claudeswitcher.guard`，大约每 10 秒复查一次。
- 守卫只管理通过本工具打开的 Claude Desktop，或者你明确确认过的订阅模式桌面。API 模式和无法确认模式的桌面不会被自动纳入。
- 关闭菜单栏面板或界面**不会**停止守卫。

网络检查只是本程序对几个 Claude 域名的观察结果。它不是防火墙，也不能证明每条连接都走同一个出口。

## 5. 卸载

1. 先在 App 设置里**关闭保护**，确认后台守卫已经卸载。
2. 如果界面无法操作，可以在终端运行（路径按你的实际安装位置填写）：

   ```bash
   "/Applications/Claude Switcher 候选版.app/Contents/MacOS/ClaudeSwitcher" --stop-protection
   ```

   源码仓库里的 `scripts/stop-protection.sh` 做的是同一件事，它接受 App 路径作为参数。
3. 退出 App，把它移到废纸篓。

关闭保护只会停用本工具的后台任务，**不会删除**已保存的账号或会话数据。

## 与原版共存或迁移

- 安装候选版之前，建议先退出原版 Claude Switcher 和 Claude Desktop。
- 如果原版也开着保护或守卫，先在原版里关掉，避免两套守卫同时管理同一个桌面。
- 本工具检测到旧版系统级守卫时会拒绝启用保护，请先停用旧服务。
