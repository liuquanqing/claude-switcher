# RC5 本机升级用签名交付

精确父提交 `10e9e33fa3b49be0d0b224495b566300b8b34911`，签名分支
`codex/developer-id-signing-rc5`。只通过本机 Git fetch 合入提交，父 checkout 保持只读。
App/Sources（以及原有测试）与父提交一致，仅版本/签名管线元数据独立调整。
版本 `1.3.6-rc.5`，数字版本 `1.3.6`，build `20261104.5.0`，渠道 `preview`。

公开内层名称 `Claude Switcher Preview.app`，显示名 `Claude Switcher 预览`，
Bundle ID `dev.claudeswitcher.candidate`。不带 `CSPreview*` Demo 标记。
沿用原 Developer ID Application、真实公开 Team pin、本机 notary profile；不创建或导出私钥、
不更改真实 Keychain ACL。GUI DR 与 RC4 build `20261103.4.1` 的已交付完整 App 比较。
DR 相同不能代替真实 ACL 继承验收，后者单列 `NOT_PROVEN`。

输出 `dist/developer-id/1.3.6-rc.5/`，交付 `_qa/signing-delivery-rc5.json`。
完整签名 GUI、两个内嵌 helper、整个 bundle，开启 Hardened Runtime 和安全时间戳。
App、DMG 各单次提交公证，同一 ID 查询；Accepted 后加票、验证票据及 Gatekeeper。
精确读取 manifest 的最终 zipName，核对哈希后在全新目录解包、独立验证普通票据文件，
不能以 app-submission.zip 或在线 Gatekeeper 结果冒充最终 ZIP 票据通过。
DMG 只读挂载验证后卸载，最终产物不可混入旧 helper 或旧票据。

父侧报告的 360 控制器和 13 虚构 AppKit 检查不等于真实外部点击验收；
签名聊天按自己的结果记录本地回归，真实点击仍为 `NOT_RUN`。
此轮无需云端 CI 或发布。安装及 Preview 重启由父侧处理；签名聊天不安装、不启动真实应用，
不操作守卫、LaunchAgent、账号、真实会话、网络/代理或 ACL，不推送、不创建发布 tag。
旧 RC1/RC2/RC3/RC4 的包、票据、交付记录、分支和既有标签全部保持不变。
