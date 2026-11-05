# 1.3.6-rc.3 签名交付

精确父提交 `32d0b6891c396b8f46995bd52522abfbd59b7bb9`，父目录只读；签名 clone
通过本机 fetch 合入新分支 `codex/developer-id-signing-rc3`。运行源码 `App/`、`Sources/`
逐文件保持与父提交一致，不替父分支修改、提交、推送或构建。

版本 `1.3.6-rc.3`，数字版本 `1.3.6`，build `20261103.3.0`，渠道 `preview`；
Bundle ID 继续 `dev.claudeswitcher.candidate`，公开 Team 从真实的
`App/UpdateSigningIdentity.swift` 读取，不能写入虚构占位符。

本轮父会话允许先构建和签名；云端 CI 与发布门禁由父会话处理。
本地结果、公证结果、父 CI、安装与发布分别记录，不能互相替代。
没有安装、标签或 Release 授权。既有签名身份与本机公证 profile 沿用，不创建或导出证书私钥，
不改任何真实条目或 ACL；遇到本人认证时停下报告具体对象，不索要认证秘密。

管线先 `prepare`（只调用 `build.sh stage-unsigned`），然后 `sign`、`submit-app`、
`check-app`、`package`、`submit-dmg`、`check-dmg`。只有明确 Accepted 才加票与验证。
使用现有个人 Developer ID 给 GUI、两个助手和整个 bundle 签名，所有 Mach-O 均启用
Hardened Runtime、安全时间戳。最后 ZIP 和 DMG 内完整应用都需验签、验票及 Gatekeeper。

公开包顶层名称为 `Claude Switcher Preview.app`，显示名仍 `Claude Switcher 预览`。
默认目录 `dist/developer-id/1.3.6-rc.3-r2/`，独立记录 `_qa/signing-delivery-rc3.json`。
命名调整前的 `dist/developer-id/1.3.6-rc.3/` 仅为未签名准备证据，不能用于交付。
DR 基线是 RC2 build `20261102.2.1` 的已公证 bundle，位于
`dist/developer-id/1.3.6-rc.2-r2/Claude Switcher 签名预览.app`。
签名后逐字比较 GUI designated requirement 并记录。相同不代表真实钥匙串授权已继承，
真实继承始终单列 `NOT_PROVEN`，不能通过改 ACL 消除提示。

旧 RC1、各 RC2、已发布标签、包、票据和原交付记录全部保留不可变；不得把旧票据用于新代码。
不安装、不停止守卫，不操作真实 Claude/CLI、登录、会话、网络、代理、守卫或登录项，不发布。
