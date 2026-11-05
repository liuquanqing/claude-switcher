# RC2 UI 修订签名交付：build 20261102.2.1

此分支为 `codex/developer-id-signing-rc2-r2`，通过本机 fetch 合入父源码
`f54b1a703c20fc686fb617aa566f92b810bada06`，用于原生更新窗口配色和提示层级修订。
应用、核心与测试源码必须与这个父提交完全一致；签名管线自己的提交另记，不用旧提交的 CI
替代新提交的结果。签名前须确认该精确父提交的云端 CI 完成且成功，或等待父会话补发结果。

语义版本仍为 `1.3.6-rc.2`，数字版本 `1.3.6`，build 递增为 `20261102.2.1`。
Bundle ID 保持 `dev.claudeswitcher.candidate`，`CSReleaseChannel=preview`，不使用 Demo 标记。

旧 RC2（父 `8be140b...`、签名准备 `d037988...`、build `20261102.2.0`）已经被取代，
其 `dist/developer-id/1.3.6-rc.2/`、票据和 `_qa/signing-delivery-rc2.json` 保留原样，
不得安装、发布或当作本次最终包。RC1 的原分支、包、票据与交付记录也保持不变。
新目录为 `dist/developer-id/1.3.6-rc.2-r2/`，新记录为 `_qa/signing-delivery-rc2-r2.json`。

## 执行与验证

先运行 `python3 scripts/test-developer-id-release.py`、`swift test` 和隔离控制器检查，
提交签名管线改动后运行 `python3 scripts/developer-id-release.py prepare`。
准备阶段只调用 `build.sh stage-unsigned`，不接触签名或公证凭据，不构成可安装包。

新父提交 CI 明确通过后，沿用 RC1 已确认的现有个人 Developer ID Application 指纹、
`App/UpdateSigningIdentity.swift` 中的固定 Team 和本机 `claude-switcher-personal-notary` profile。
不新建证书或凭据，不解锁钥匙串、不导出私钥、不改任何真实条目或 ACL。

后续管线命令依次为 `sign`、`submit-app`、`check-app`、`package`、`submit-dmg`、`check-dmg`。
`sign` 需要指定原有 `--identity` 和 `--team-id`；公证命令使用
`--profile claude-switcher-personal-notary`。新源码必须重新完整签名、公证，不能复用旧票据。
`check-*` 若为 `In Progress`，仅按已有编号续查，不重复上传。

签名后逐字比较 RC1 与本次主 GUI 的 designated requirement；只有一致才允许提交公证。
DR 相同不证明真实钥匙串授权继承，不读取或修改真实 ACL。
完整 App 与 DMG 都必须明确 `Accepted`，随后 staple、validate、Gatekeeper 通过。
最终再验证 ZIP 解压后的完整 App、DMG 只读挂载内的 App，确认所有组件的签名、固定 Team、
Hardened Runtime、安全时间戳、预览版本、票据和 GUI DR，并生成最终 SHA256。

不安装、不启动真实 Claude/CLI、不访问账号/会话/代理/守卫/登录项，不推主线、不打 tag、不发 Release。
若系统要求本人认证，停在具体对象上回报，不索要认证秘密，不自行改变凭据。
