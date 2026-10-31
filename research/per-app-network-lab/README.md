# Claude 专属网络阻断：2026-11-01 续验

用户已确认本轮范围：先阻断 Claude 桌面与 Claude Code 的网络，保留其他软件联网；已在普通终端运行的 Claude Code 也不能漏掉。确认网络阻断后再通知，关闭桌面由用户选择。保留任务进程不等于允许其继续联网。

本目录是隔离研究，**不属于 1.3.3 的已发布能力，不安装或激活系统扩展，不改个人网络和守卫，不接触真实账号或会话**。产品接入继续 HOLD。

## 从目标推导的边界

1. 必须覆盖目标进程的新流和已有流，包括主动推送、IPv4/IPv6、TCP/UDP；DNS 与系统代发连接需单独证明归属。启动入口、默认登录相同与否，都不能证明流量已受控。
2. 网络阻断不等待用户响应。状态必须区分“阻断已确认”与“无法确认阻断”；关闭提示不能放行。“关闭桌面”是阻断后的可选操作，其退出确认不影响阻断。
3. 代理断开不得直连回退；错误国家、未知或过期证据均不放行；恢复需要新的有效核验。国家变化仍有探测发现时延，不能声称零延迟感知。
4. 只看同一个用户、进程名、域名或本地代理端口，都不能据此证明按应用可靠隔离。不要把 Terminal、所有 Node/Python、所有访问 Claude 域名的软件都纳入。
5. 同一个 Claude/CLI 可执行文件也可能承载 API 会话，本轮“断掉所有 Claude 的网”不承诺自动豁免这些连接。生产接入前必须展示真实覆盖范围。
6. 本轮优先验证应用级阻断，不能在选择性失败时静默退化为整机断网。

## 候选职责

```text
已保存的目标国家 + Claude 域名结果 + 隧道/路径上下文
                    ↓ 新鲜且绑定上下文的许可
独立网络执行层：识别实际流来源，约束新流，撤销已有流
                    ↓ 先执行并取得可信结果
界面/系统通知：网络已阻断；重新检查并恢复；可选关闭桌面
```

正常运行的界面不是阻断前提。需要验证执行器自身暂停/崩溃、重启、启动尚未就绪时的系统行为；不能因有多个守护进程就宣称失效关闭。

macOS 正式候选优先考虑系统内容过滤扩展。`AuditTokenBridge.swift` 仅证明 SDK 接口可编译：用流的 app/process audit token 取得代码身份，使用 `update(...drop..., .any)` 撤销旧 socket flow。macOS 不提供同名的 `sourceAppIdentifier` 属性；系统代发连接的 app 与 process token 可以不同。编译不证明在扩展沙箱里能成功取得全部身份，更不证明暂停、崩溃或旧流撤销已通过。

遇到未识别的流有实质矛盾：默认 allow 可能漏掉目标，默认 drop 可能干扰其他应用。因此策略模型保留 unresolved，**上线门不能通过**。实际的 helper、旧 npm CLI、CLI 调用的工具、系统代发 DNS 与代理外层流，均需真实归属实验，不能靠字符串猜测。

## 本轮实验与证据层级

| 项目 | 实际执行 | 能证明什么 | 不能证明什么 |
|---|---|---|---|
| 54 项虚构策略检查 | 普通 Swift 程序，内存虚构身份和时间 | 目标默认拒绝、过期/JP/未知/上下文变化拒绝；无关身份不受这些条件影响；未知不冒充通过 | OS 流归属、真实断网、旧连接撤销 |
| AuditTokenBridge | arm64/macOS 13 目标仅编译，不启动 | 当前 SDK 支持所选审计令牌和双向撤销 API | 扩展签名/安装/激活/运行及失败语义 |
| PF 同用户负对照 | 一次性 GitHub macOS runner，环回 IPv4/IPv6 TCP/UDP，虚构客户端 | 核实只按用户写规则是否误伤同用户的无关软件；不同用户和恢复为正向对照 | 真实 Claude、代理/TUN、正式应用过滤后端 |

PF 实验硬校验 GitHub hosted 环境及专用显式开关，限定环回目标和两个实验端口，不在个人 Mac 执行。通过表示正确复现边界，**不等于选择性保护通过**。工作流会保存每次服务端收到的唯一测试标记及清理结果；异常/清理失败使实验失败。

## 下一门

- 获得完整云端同用户负对照回执，绑定精确提交；不把预期误伤计入保护能力。
- 在真正可部署、获系统批准的隔离内容过滤环境，验证实际 flow 身份、CLI/桌面 helpers、系统代发，以及同一目标的无关应用对照。现有开发会员/签名与独立扩展测试环境未确认，不访问个人证书或在个人 Mac 代测。
- 在该执行层内验证既有流双向撤销、执行器 SIGSTOP/SIGKILL、控制失联、许可过期、隧道断开/恢复；每阶段同时发无关应用的控制流，客户端进程应保持存活。
- 这些证据齐全后才讨论原生应用接入与提示交互。现有守卫保持不变。

来源：
- [Apple 内容过滤提供器](https://developer.apple.com/documentation/networkextension/content-filter-providers)
- [Apple 审计令牌](https://developer.apple.com/documentation/networkextension/nefilterflow/sourceappaudittoken)
- [Apple 更新已有流判定](https://developer.apple.com/documentation/networkextension/nefilterdataprovider/update(_:using:for:))
- [Apple TN3134 部署条件](https://developer.apple.com/documentation/technotes/tn3134-network-extension-provider-deployment)
- 本仓库原 `research/network-lab/stock_core_pf_probe.py`：已复现 PF 执行器退出后的许可残留；没有转成生产能力。

当前最近产品交付为 1.3.3；该分支基于独立网络研究提交 c963508，仅用于研究。产品运行态本轮不验收；方案与原生窗口修复分别存放，不改产品 App/Sources/build。
