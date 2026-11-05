# 云端CI验证

## 云端 CI（2026-10-29 更新）

[云端运行记录](https://github.com/liuquanqing/claude-switcher/actions/runs/40747931686) 已通过，验证提交 `d63f77a3807981371315a58dc4556894faa75829`，执行机为标准 `macos-15-intel`。

- Core：176项通过。
- 控制器隔离检查：106项通过。
- release构建及ad-hoc签名验证：通过。

先前失败来自macOS ARM执行机容量不足，以及执行机未预装`rg`。现已切换到标准Intel执行机，并用Bash内建枚举源码，保留全部检查项。本机也已在无`rg`的PATH中复跑106项检查。

应用、Core、测试用例及发布构建源码与本版标签一致；仅CI、控制器测试脚本和验证说明更新。已发布安装包及SHA256不变。本次未操作真实登录、会话或守卫。Intel云端构建不等于Intel原生界面验收，预编译安装包仍仅提供arm64。

机器可读回执见 `prototypes/local6-cloud-ci-validation.json`。失败与成功的完整日志仅保留于本地 `_qa/cloud-ci/`。
