# Developer ID 独立签名预览

本管线基于 `21a7eba19e4a61003edc6abdb51fed3fa8ace2f5`，只在独立 clone
`claude-switcher-signing`、分支 `codex/developer-id-signing` 工作。
目标是 `1.3.6-rc.1`，并非正式发布；不推主线、不打标签、不替换已发布附件。

## 身份与凭据

只使用个人团队 **quanqing liu** 的 **Developer ID Application**。Xcode 已登录，
开发者网站显示新版协议于 2026-11-02 接受；不要再要求登录或接受其他协议。
本次只读检查尚无有效签名身份。创建证书和本机私钥要取得操作时确认。
不使用公司团队、Apple Development、Mac App Distribution 或 Developer ID Installer。

证书私钥仅留本机钥匙串，不导出给其他设备，不设置“允许所有应用”，不改真实
Claude 钥匙串条目的权限。公证认证优先使用本机 `notarytool` profile；不写入仓库、
日志、`_qa` 或 CI secrets。不创建 App Store Connect API 密钥作为默认捷径。

若本机尚无公证 profile，由用户自己在 Apple 账号页面创建 App 专用密码，并在自己的
终端完成以下交互式命令。不要把密码发给代理或写成命令行参数。此步骤不使用 `--sync`，
凭据仅存本机指定钥匙串；需本人系统认证时由本人完成。

```sh
xcrun notarytool store-credentials claude-switcher-personal-notary \
  --keychain "$HOME/Library/Keychains/login.keychain-db"
```

按提示填写个人 Apple ID、个人 Team ID 与 App 专用密码，并完成工具的在线验证。
此文档没有实际创建任何凭据。账号开通、证书可用和公证认证可用是三个独立状态。

## 分阶段执行

先完成本地提交，保证工作区干净。脚本只接受此 clone 的 `dist/` 输出目录；已有输出不覆盖。
默认输出为 `dist/developer-id/1.3.6-rc.1/`。它不会启动应用、CLI、守卫或注册后台服务。

```sh
python3 scripts/developer-id-release.py prepare
security find-identity -v -p codesigning
python3 scripts/developer-id-release.py sign \
  --identity '<Developer ID Application 的精确 SHA-1>' --team-id '<个人 Team ID>'
python3 scripts/developer-id-release.py submit-app --profile claude-switcher-personal-notary
python3 scripts/developer-id-release.py check-app --profile claude-switcher-personal-notary
python3 scripts/developer-id-release.py package
python3 scripts/developer-id-release.py submit-dmg --profile claude-switcher-personal-notary
python3 scripts/developer-id-release.py check-dmg --profile claude-switcher-personal-notary
```

`prepare` 构建完整三组件，制作独立 `Claude Switcher 签名预览.app`，完成版本设置与 strip。
对外标识 `1.3.6-rc.1`；Apple 数字版本字段为 `1.3.6` / `20261102.1.0`。
Bundle ID 继续使用 `dev.claudeswitcher.candidate`，不添加预览偏好键。
此时签名是 `NOT_RUN`，预览不能作为可安装交付。

`sign` 先签两个助手与主 Mach-O，再签外层 bundle，不使用 `--deep` 代替逐组件签名。
每个 Mach-O 都启用 Hardened Runtime、安全时间戳，不添加 JIT、调试或禁用库验证权限。
逐项检查 Developer ID、Team ID、时间戳与 runtime；再执行完整 bundle 校验。
不支持偷偷加入额外可执行组件：若 Mach-O 清单变化，先审核并调整管线。

提交为异步，每次返回的 submission ID 写入清单。`check-*` 只查询已有 ID；
`In Progress` 时稍后再次查询，不能重复提交。被拒绝时保存 Apple 日志并停止。
若上传被中断且还没有保存 ID，先人工用 `notarytool history` 对照提交记录及提交归档散列，
不要重跑上传或删除证据。只有明确 `Accepted` 才 staple、validate 和 Gatekeeper 评估。

应用加票后才创建最终 ZIP 和 DMG；保留票据的资源分叉与扩展属性，不再 strip 或重签应用。
DMG 独立签名、公证及加票。最终清单和 SHA256 在 DMG 也全部通过后才生成。
现有 `scripts/package-release.sh` 是 ad-hoc 管线，会 strip 并重签；**不能用于处理本预览包**。

`RELEASE-MANIFEST.json`、`evidence/` 保存精确源码、身份、逐组件验证、公证 ID 和日志。
只有 `phase=ready-for-review` 才可交父会话评审。未执行的安装、真实账号验证仍为 `NOT_RUN`。
首次 ad-hoc 到 Developer ID 迁移可能需要一次钥匙串授权，公证不能代替系统权限。

## 安装交接边界

本机原版 `/Applications/Claude Switcher.app` 为另一 Bundle ID 的 1.2，必须保留。
本机候选版和 MBP16 的旧包内部都有正在使用的守卫路径，不能替换、搬移或删掉。
本管线只交付完整独立 bundle，由父会话决定新路径；旧包、旧助手和旧守卫保持原状。
不重启、不重新注册守卫，也不自行决定双守卫迁移。不把旧 ad-hoc helper 复制进已签名包。
MBP16 运行客户端不需要签名私钥。新的预览包不能直接走此前“只替换 GUI 后重签”的安装方法。

## Apple 一手依据

- [Developer ID 证书及所需角色](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
- [公证常见错误、时间戳与 Hardened Runtime](https://developer.apple.com/documentation/security/resolving-common-notarization-issues)
