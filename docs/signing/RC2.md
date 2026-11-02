# 1.3.6-rc.2 签名准备

此文为已被 UI 修订取代的 build `20261102.2.0` 历史记录。
本次 build `20261102.2.1` 的操作范围与独立输出见 [RC2 UI 修订交付](RC2-R2.md)，
不要继续对历史目录执行签名或发布。

本分支 `codex/developer-id-signing-rc2` 通过本机 fetch 精确引入父候选
`8be140b925528e6f93521173d385d787c3442533`，并保留 RC1 的签名管线。
父源码位于另一独立 clone，不切换、修改或构建父目录。
原 RC1 分支、交付记录、最终 ZIP/DMG、完整应用和票据保持原样。

## 本轮允许范围

锁屏期间只做离线合并、构建准备和虚构数据测试。不得访问签名身份、私钥、公证凭据，
不得运行 `codesign` 或解锁钥匙串。需收到用户手动解锁和父会话继续消息后，才能签名。
原生编译器可能产生其默认的本地临时签名；这不代表 Developer ID 分发签名。

`build.sh stage-unsigned` 只编译三组件、生成资源并暂存 bundle，跳过全部 `codesign` 调用，
不会安装、启动 GUI/CLI、注册服务或进行公证。签名管线 `prepare` 只调用这个入口，
然后设置元数据并 strip。准备包是不可安装的中间产物，不能冒充 ad-hoc 分发或公证包。

```sh
python3 scripts/test-developer-id-release.py
python3 scripts/developer-id-release.py prepare
```

准备前先提交源码并保持工作区干净。默认目录是 `dist/developer-id/1.3.6-rc.2/`。
版本固定为 `1.3.6-rc.2`、数字版本 `1.3.6`、build `20261102.2.0`；
`CSReleaseChannel=preview`、`CSReleaseVersion=1.3.6-rc.2`，系统名称为 `Claude Switcher 预览`。
Bundle ID 固定为 `dev.claudeswitcher.candidate`，不使用 Demo 的 `CSPreview*` 字段。
清单记录父候选提交与包含签名管线改动的精确源码提交，两者不混同。

## 解锁后待执行

以下命令当前只供审查，不能在收到解锁后的继续消息前执行：

```sh
python3 scripts/developer-id-release.py sign \
  --identity '<沿用 RC1 的现有个人 Developer ID Application 精确 SHA-1>' \
  --team-id '<App/UpdateSigningIdentity.swift 固定的个人 Team>'
python3 scripts/developer-id-release.py submit-app --profile claude-switcher-personal-notary
python3 scripts/developer-id-release.py check-app --profile claude-switcher-personal-notary
python3 scripts/developer-id-release.py package
python3 scripts/developer-id-release.py submit-dmg --profile claude-switcher-personal-notary
python3 scripts/developer-id-release.py check-dmg --profile claude-switcher-personal-notary
```

不能新建证书或私钥，不解锁钥匙串、不导出私钥；继续使用 RC1 已确认的个人签名身份。
签名前和验证时均核对父源码的公开 Team pin，不能改用其他团队。

签名后将 RC1 与 RC2 GUI 的 `designated => ...` 原文进行比较，并把结果保存到
`evidence/gui-designated-requirement-comparison.json`。原可执行路径不参与比较。
要求 DR 相同才允许提交公证；差异必须停下回报。DR 相同仅证明代码身份要求相同，
不证明真实钥匙串 ACL 已继承，不承诺以后永不出现授权窗口，不读取或修改真实条目/ACL。

仍由内向外签完整三组件及 bundle，再应用公证、加票、验证，最后生成 ZIP 与 DMG。
DMG 也要独立公证及加票。当前这些步骤均为 `NOT_RUN`，没有可安装包。
交付记录使用 `_qa/signing-delivery-rc2.json`，不得覆盖 RC1 的 `_qa/signing-delivery.json`。

不安装、不测试真实 `/usage` 或 `/login`、不读取账号/会话/密钥，不修改代理、登录项、
守卫、LaunchAgent 或真实钥匙串权限；不推主线、不打 tag、不发 Release。
