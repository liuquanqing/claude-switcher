# Claude Switcher 1.3.0 RC6

这一版把日常操作整理得更清楚：导入页采用新的操作配色与文字层级，保护状态与纳入操作合并，语言设置使用独立图标。

**[下载 macOS DMG](https://github.com/liuquanqing/claude-switcher/releases/download/v1.3.0-rc.6/ClaudeSwitcher-1.3.0-rc.6-arm64.dmg)** · [SHA256 校验文件](https://github.com/liuquanqing/claude-switcher/releases/download/v1.3.0-rc.6/SHA256SUMS)

Apple Silicon · macOS 13+ · 候选发布

## 本版更新

- **会话导入**：蓝色主操作，清晰区分选中、禁用与待核对状态；统一计数、路径和时间的字号层级。
- **保护状态**：点击“桌面未纳入”进入原确认流程；设置箭头独立展开和收起。
- **语言入口**：底部地球图标提供会话导入页的中文／English 切换，颜色与相邻按钮保持一致。
- **下载方式**：首页只保留 DMG 主入口，ZIP 在本页 Assets 中备用。

账号切换、默认 CLI 登录同步、会话索引备份与恢复机制沿用现有实现。独立网络隔离实验未集成到本版，后台守卫仍采用周期性检测。

## 安装

打开 DMG，把 `Claude Switcher 候选版.app` 拖入“应用程序”。如果 macOS 阻止首次打开，在“系统设置 → 隐私与安全性”中为本应用选择“仍要打开”。

当前包使用 ad-hoc 本地签名，未经过 Apple 公证。完整步骤见 [安装说明](https://github.com/liuquanqing/claude-switcher/blob/v1.3.0-rc.6/docs/INSTALL.md)。

候选版与原版共享账号目录，请保留一个账号管理器进行切换。守卫仅管理已明确纳入的订阅桌面，CLI 同步不强制停止正在运行的任务。

## 验证

发布检查覆盖 Core 测试、106 项控制器隔离检查、release 构建和签名验证。界面交互使用虚构账号及临时会话，包含全选／半选、含更新操作的确认与取消、独立设置入口及演示中的纳入确认。

[验证范围](https://github.com/liuquanqing/claude-switcher/blob/v1.3.0-rc.6/docs/VALIDATION.md) · [界面复核记录](https://github.com/liuquanqing/claude-switcher/blob/v1.3.0-rc.6/docs/prototypes/rc6-ui-review-validation.json)

## 版本与来源

- 版本：`1.3.0-rc.6`
- 内部构建：`20261029.6.8`
- 旧版 `v1.3.0-local.6` 的标签和附件保留。
- 原作者 Luc Succes 的 MIT 版权声明保持不变，感谢 [l2succes/claude-switcher](https://github.com/l2succes/claude-switcher) 提供项目基础。

安装包对应源码提交见 `RELEASE-MANIFEST.json`。本项目由社区维护，与 Anthropic 没有隶属关系。
