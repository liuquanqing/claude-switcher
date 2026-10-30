# macOS 发布、签名与公证

核对日期：2026-10-30。当前正式包为 `v1.3.1`，使用 ad-hoc 签名，尚未公证。本文是 Developer ID 分发准备说明，不表示现有附件已重新签名或通过 Apple 公证。

## 版本命名

本次正式发布统一使用 `1.3.1`：

| 位置 | 名称 |
| --- | --- |
| Release 标题 | Claude Switcher 1.3.1 |
| Git 标签 | `v1.3.1` |
| DMG | `ClaudeSwitcher-1.3.1-arm64.dmg` |
| ZIP | `ClaudeSwitcher-1.3.1-arm64.zip` |

新标签必须绑定新包的实际构建源码，校验文件与构建清单同时生成。保留已发布的 `v1.3.0`、`v1.3.0-local.6` 与 `v1.3.0-rc.6`；不改名旧附件或移动旧标签。正式版本号不代表已通过 Apple 公证；独立实验分支不会自动进入安装包。Apple bundle 的版本字段与对外发布标识在构建阶段分别校验。

## 两种安装体验

| 分发方式 | 用户首次打开 |
| --- | --- |
| 当前 ad-hoc 包 | 系统可能阻止打开；用户信任来源并核对文件后，在“隐私与安全性”中仅为本应用选择“仍要打开” |
| Developer ID 签名并公证的包 | Gatekeeper 可以验证开发者及公证票据，通常不再需要未知开发者例外；仍可能显示正常的首次打开确认 |

公证不会代替用户授予钥匙串、后台项目或其他实际需要的系统权限，也不能保证每台受管理 Mac 都允许安装。

## 公证前需要什么

- 有效的 Apple Developer Program 会员资格。Apple 公布的标准年费为 99 USD，地区价格以注册页面为准；是否购买由账号持有人决定。
- 带对应私钥的 **Developer ID Application** 证书，用于应用、helper 和 DMG。Apple Development、ad-hoc 及 Mac App Store 分发证书不能替代它。
- Apple 公证服务的认证凭据，通过本机钥匙串配置或受保护的 CI secret 提供，不放进源码、普通日志、Release 附件或聊天。
- `codesign`、`notarytool` 和 `stapler`。本机已具备工具，但只读检查返回 `0 valid identities found`；这不代表账号持有人一定没有开发者会员。

直接分发 DMG 无需上架 Mac App Store，也不需要为此申请 Developer ID Installer；后者用于 PKG。

## 可自动化的发布顺序

1. 冻结发布源码与版本，完成现有核心测试和控制器检查。
2. 构建临时发布副本，完成图标、Info.plist、二进制 strip 等所有修改。
3. 由内到外签名：`ClaudeGuard`、`ClaudeSessionTransfer`，再签应用 bundle。采用 Developer ID Application、Hardened Runtime 和安全时间戳。签名后不再修改内容。
4. 验证每个签名。此项目是原生 Swift 应用，先保持最小权限；不照抄其他运行时的 JIT、禁用库校验或调试权限。
5. 打包临时提交 ZIP，通过 `notarytool` 提交 Apple。只有结果明确为 `Accepted` 才继续；被拒绝时读取日志并修复，不降级成“已公证”。
6. 对应用执行 staple 与 validate，再从带票据的应用生成分发 ZIP 和 DMG。
7. 签名 DMG，并公证、staple、validate DMG。分别通过 `codesign` 和 Gatekeeper 评估。
8. 完成所有签名与票据附加后，重新生成最终 SHA256 和清单。用隔离的干净 macOS 环境验证下载、挂载、拖入应用程序和首次启动。
9. 仅在全部步骤通过后发布。现有已安装应用及运行中的 helper 不参与此流程。

CI 可以使用临时钥匙串，凭据由 GitHub Secrets 提供，任务结束后清理临时材料。先完成一次受控的本地签名和公证，再启用上传自动化；当前仓库尚未配置这条认证流程。

## 当前采用的路径

现有包继续采用用户逐应用授权，操作见 [INSTALL.md](INSTALL.md)。不关闭 Gatekeeper、不降低系统保护，不提供批量移除隔离属性的一键脚本。若具备可用 Developer ID，再执行以上流程发布新版本；若继续使用用户逐应用授权，正式版也必须如实标明未公证，不能仅凭版本后缀改变签名状态。

CC Switch 的公开发布流程也执行 Developer ID 签名、应用和 DMG 公证、staple 及 Gatekeeper 验证；我们可以借鉴顺序，原生 Swift 项目不需要引入它的 Tauri 构建链或运行时权限。

## 一手资料

- [Apple：Developer ID 证书](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [Apple：公证 macOS 软件](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Apple：开发者计划注册与费用](https://developer.apple.com/programs/enroll/)
- [Apple：安全打开 Mac 应用及“仍要打开”](https://support.apple.com/102445)
- [CC Switch：发布工作流](https://github.com/farion1231/cc-switch/blob/main/.github/workflows/release.yml)
- [SemVer：预发布版本格式](https://semver.org/#spec-item-9)
