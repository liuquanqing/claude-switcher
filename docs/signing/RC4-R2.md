# RC4 单列表整改后的独立签名交付

仅使用父提交 `d33dda383c677ff58c8fc641a2dd26795f40568e`，版本 `1.3.6-rc.4`、
build `20261103.4.1`，签名分支 `codex/developer-id-signing-rc4-r2`。
通过本机 fetch 导入精确 Git 提交，不复制父工作区未跟踪文件，也不修改父 checkout。
App/Sources 必须与这个提交逐文件一致。父侧继续负责最终 CI、独立验包和发布/安装。

旧 build `20261103.4.0` 的 `UI_REVIEW_HOLD`、已有提交 ID、App 与记录全部保持不可变。
不复用旧票据。新目录 `dist/developer-id/1.3.6-rc.4-r2/`，新记录
`_qa/signing-delivery-rc4-r2.json`；旧 RC1/RC2/RC3、旧 RC4 以及原分支/标签均不改。

内层名称 `Claude Switcher Preview.app`，显示名 `Claude Switcher 预览`，
Bundle ID `dev.claudeswitcher.candidate`，渠道 `preview`。真实公开 Team 从既有
UpdateSigningIdentity.swift 读取，沿用已有个人 Developer ID Application 与本机 notary profile。
不新建、导出密钥，不改真实 ACL。GUI DR 仍与已发布 RC3 build `20261103.3.0` 比较，
真实钥匙串继承单列 `NOT_PROVEN`。

按 prepare、sign、submit-app、check-app、package、submit-dmg、check-dmg 执行。
App 与 DMG 各只提交一次，按同一 ID 续查；Accepted 后才加票和 Gatekeeper。
最终 ZIP 必须按 manifest 的精确 zipName 选择，不用通配符误选 app-submission.zip。
全新目录解包后单独 stapler validate，核对普通票据文件 Contents/CodeResources 在验签前后
存在且不变；不输出票据内容。DMG 只读挂载验证并卸载，不启动应用。

此签名会话不安装、不发布、不打标签，不触碰真实登录、会话、代理、守卫或 LaunchAgent。
