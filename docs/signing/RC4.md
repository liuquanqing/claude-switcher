# RC4 独立签名交付

精确父提交 `302a3f72636f4f491a7ea5bebe76631574319920`，签名分支
`codex/developer-id-signing-rc4`。通过本机 fetch 导入父提交，不修改父 checkout，
`App/`、`Sources/` 运行源码逐文件与父提交一致。

版本 `1.3.6-rc.4`、数字版本 `1.3.6`、build `20261103.4.0`、渠道 `preview`。
公开内层名称 `Claude Switcher Preview.app`，显示名 `Claude Switcher 预览`，
Bundle ID `dev.claudeswitcher.candidate`。公开 Team 只从原有真实源码 pin 读取，
沿用已有 Developer ID Application 与本机公证 profile，不创建或导出私钥，不改真实 ACL。

默认输出 `dist/developer-id/1.3.6-rc.4/`，独立交付记录 `_qa/signing-delivery-rc4.json`。
DR 基线为已发布 RC3 的原签名 bundle：
`dist/developer-id/1.3.6-rc.3-r2/Claude Switcher Preview.app`。
DR 一致只证明签名身份要求一致，真实 Keychain ACL 继承仍记为 `NOT_PROVEN`。

管线依次 prepare、sign、submit-app、check-app、package、submit-dmg、check-dmg。
所有嵌套 Mach-O 和完整应用使用既有个人 Developer ID，启用 Hardened Runtime 与安全时间戳。
App 和 DMG 各只提交一次，仅按已有编号查询；只有明确 Accepted 才 staple、validate 与 Gatekeeper。

最终验包必须从最终 manifest 的精确 `zipName` 取文件，先核对最终 SHA256，
再在全新目录用 `/usr/bin/ditto -x -k` 解包并独立运行 `stapler validate` 和 codesign。
不能用 `*.zip` 或 `next(glob(...))` 选择归档，送审 `app-submission.zip` 不等于最终发行 ZIP。
须确认 `Contents/CodeResources` 在解包后及验签前后存在，且与源加票应用一致；不打印票据内容。
DMG 另做只读挂载验证，结束后卸载；Gatekeeper 在线通过不能代替加票验证。

父侧拥有云端 CI、独立验包、发布和本机安装门禁；此签名聊天只交可审查产物。
不安装、不发布、不创建 tag，不访问真实账号、会话、代理、网络设置、守卫、LaunchAgent 或登录项。
旧 RC1/RC2/RC3 产物、原交付记录、既有分支和标签引用全部保留不变。
