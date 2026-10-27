# 外部审查调用：f9e14d1d-be79-4fef-8736-0d2cf59ed42c

> 本文件由知行枢受控 runner 管理。外部模型不能写 canonical synthesis。

<!-- ZHIXING_REVIEW_STATE
{
  "adapter": "claude",
  "artifact_role": "review",
  "attempt": 2,
  "attempt_history": [
    {
      "attempt": 1,
      "block_reason": "process_exit_nonzero",
      "ended_at": "2026-10-27T12:00:34+08:00",
      "exit_code": 1,
      "status": "blocked"
    }
  ],
  "block_reason": null,
  "completed_at": "2026-10-27T13:22:18+08:00",
  "created_at": "2026-10-27T12:00:33+08:00",
  "event_count": 2259,
  "exit_code": 0,
  "invocation_id": "f9e14d1d-be79-4fef-8736-0d2cf59ed42c",
  "last_event": "result:2259",
  "model_completion_marker_count": 1,
  "pid": 78857,
  "r_id": "R-20261027-003-improvement-review",
  "raw_log_ref": "/Users/liuquanqing/Projects/安全 AI/claude-switcher/_qa/claude-review/R-20261027-003-improvement-review/raw/f9e14d1d-be79-4fef-8736-0d2cf59ed42c.attempt-2.jsonl",
  "recovery": "resume invocation f9e14d1d-be79-4fef-8736-0d2cf59ed42c with the same artifact",
  "schema": "zhixing.external-review/v1",
  "source_scope": [
    "source-pack"
  ],
  "sources_observed": [
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/REVIEW_SCOPE.md",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/MANIFEST.json",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/App/main.swift",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/App/Protection.swift",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/Sources/SwitcherCore/Safety.swift",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/Sources/SwitcherCore/ProfileTransaction.swift",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/Sources/SwitcherCore/GuardService.swift",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/Sources/ClaudeGuard/GuardMain.swift",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/Sources/SwitcherCore/NetworkProbe.swift",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/reference/ccswitcher-v2.1.0/KeychainService.swift",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/reference/ccswitcher-v2.1.0/CredentialAnchor.swift",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/reference/ccswitcher-v2.1.0/ClaudeService.swift",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/docs/CLI登录保存方案调研.md",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/docs/开发与验证.md",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/docs/存储与迁移方案分析.md",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/migration/execution-summary.md",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/migration/run-after-quit.sh",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/migration/reset-index-example.sh",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/migration/sync-desktop-sessions.py",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/migration/planning-fixtures.json",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/Sources/SwitcherCore/ThreadRepository.swift",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/App",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/App/Views.swift",
    "/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate"
  ],
  "started_at": "2026-10-27T13:17:05+08:00",
  "status": "complete",
  "updated_at": "2026-10-27T13:22:18+08:00"
}
ZHIXING_REVIEW_STATE -->

## 调用状态

- lifecycle: `complete`
- adapter: `claude`
- R-ID: `R-20261027-003-improvement-review`
- attempt: `2`
- updated_at: `2026-10-27T13:22:18+08:00`
- raw_log_ref: `/Users/liuquanqing/Projects/安全 AI/claude-switcher/_qa/claude-review/R-20261027-003-improvement-review/raw/f9e14d1d-be79-4fef-8736-0d2cf59ed42c.attempt-2.jsonl`

## 来源范围

- declared: `source-pack`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/REVIEW_SCOPE.md`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/MANIFEST.json`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/App/main.swift`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/App/Protection.swift`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/Sources/SwitcherCore/Safety.swift`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/Sources/SwitcherCore/ProfileTransaction.swift`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/Sources/SwitcherCore/GuardService.swift`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/Sources/ClaudeGuard/GuardMain.swift`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/Sources/SwitcherCore/NetworkProbe.swift`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/reference/ccswitcher-v2.1.0/KeychainService.swift`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/reference/ccswitcher-v2.1.0/CredentialAnchor.swift`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/reference/ccswitcher-v2.1.0/ClaudeService.swift`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/docs/CLI登录保存方案调研.md`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/docs/开发与验证.md`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/docs/存储与迁移方案分析.md`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/migration/execution-summary.md`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/migration/run-after-quit.sh`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/migration/reset-index-example.sh`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/migration/sync-desktop-sessions.py`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/migration/planning-fixtures.json`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/Sources/SwitcherCore/ThreadRepository.swift`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/App`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate/App/Views.swift`
- observed: `/private/tmp/claude-switcher-review-f9e14d1d/source-pack/candidate`

## 审查正文

## 总体判断

只做了静态源码阅读。没有运行测试或脚本，没有登录，没有读真实钥匙串，也没有确认本机当前账号。文档里写的“39 项通过”和演示 PASS 只能说明隔离逻辑和假数据界面没问题，不能当作真实验收。

- **守护与桌面目录切换：建议保留，正式部署前还有一个已知阻塞。**
  - 失败或未知时都拒绝，这部分代码是对的：配置无效时守卫会关闭 Claude（`GuardMain.swift:16-23`）；任一域名国家未知或互相不一致都会拦截（`Safety.swift:46-50,105-113`）；探测期间配置变了就不写回执（`GuardMain.swift:32`）。
  - “守卫在线”（`guardOnline`）和“允许打开”（`lastDecision`）是分开存的（`Protection.swift:85-90,160-166`）。
  - 目录切换失败会回滚，也会拒绝符号链接（`ProfileTransaction.swift:25-62`）。
  - 已知阻塞是 1P/3P 进程范围还没定（见发现 4）。
- **CLI 登录：保存基础值得保留，但借鉴 CCSwitcher 要挑着来。**
  - 应保留：原生 Keychain 更新、每个档案一条备份、读取失败就停止、备份写失败就中止。这几点比 reference 更稳。reference 备份失败后仍继续切换（`ClaudeService.swift:430-436`），写活动凭据是先删再加，还把 token 放在命令参数里（`KeychainService.swift:137-150`）。
  - 现实缺口有三个：核验时机太晚、身份锚点太弱、恢复后没有确认。
- **迁移脚本：只能当思路参考，不能原样产品化。** 发现了一个真实可达的错写组织缺陷（见发现 1），父任务的虚构复现也印证了它。这份复现只证明“计划确实会偏”，不说明迁移是安全的。

## 主要发现

### 1. 迁移：清空目标组织后，导入可能写进另一个组织；DRY 预演也不等于实际执行计划

- **严重程度：** 高（对迁移而言；产品入口已禁用）。
- **已知或新发现：** 新发现。父任务的虚构计划复现印证了这一点（`planning-fixtures.json:5-9,17-21`）。文档只笼统提到“未指定组织时偏向条目最多的目录”（`存储与迁移方案分析.md:70`），没有指出它和重置脚本组合后会出错。
- **怎样触发：**
  1. 目标账号下有两个以上组织目录。
  2. `reset-index-example.sh:23-26` 先把目标组织里的索引移走，只留下 1 条 `KEEP`。
  3. 随后第 29 行调用 sync，但没有传 `--dst-org` / `--src-org`。
  4. `resolve()` 按条目数从多到少挑组织（`sync-desktop-sessions.py:46-49`），这时会选中另一个组织。
- **DRY 为什么不可信：**
  - DRY 在清空之前运行（第 16-18 行）。那时目标组织还有很多条目，所以挑中的组织是对的，计划里多是“dst ahead / same”。
  - 实际执行在清空之后，挑中的组织和计划都会变，几乎全部变成新增。
  - `grep -v '\[new'` 又恰好把新增项隐藏了。结果是 DRY 显示的组织与操作，和实际执行的都对不上。
- **影响：** 目标组织的侧栏只剩 1 条，导入的索引落到另一个组织。原文不会丢，备份目录还在，可以手动恢复。
- **最小修正：**
  - 包装脚本已经知道目标账号和组织的 UUID，直接显式传 `--dst-org` 和 `--src-org`。
  - sync 在执行前断言 `dst_dir == 期望路径`。
  - DRY 要模拟“移出后”的目标状态再出计划，并且不要过滤掉 `[new]`。
- **复杂性：** 低。
- **待验证：** 用户那次 rc=0 的真实运行，收据里的 `dest` 是否等于脚本里的 `DST`。

### 2. CLI 归属核验放在桌面目录切换之后，几种常见情况都会让切换停在一半

- **严重程度：** 高（阻止正式部署）。
- **已知或新发现：** 新发现。文档把“部分完成要如实报告”当成已接受的行为（`整合设计.md:50`），但没意识到这几种失败本来可以提前发现。
- **代码位置：**
  - `main.swift:371-380`：先退出 Claude、移动目录，然后才执行 `switchCLI`。
  - `switchCLI` 的读钥匙串、联网核对邮箱、邮箱比对都在 `main.swift:411-426`。
- **现实触发：**
  - 终端 CLI 的 access token 已过期（例如很久没用 CLI）。`/profile` 返回 401，提示却是误导性的 “Session expired — switch to it to re-auth”（`main.swift:157`）。
  - 外部工具（如 CCSwitcher）刚切过号。
  - 正在运行的旧 CLI 把自己的旧 token 写回了钥匙串。
  - 离开的档案没有桌面快照邮箱。
  - 用户拒绝了钥匙串授权弹窗。
- **影响：** 桌面目录已经换了，终端没换，Claude 也没有重新打开（第 380 行）。每次切换都可能卡在这个状态。
- **最小修正：** 把 `switchCLI` 拆成两步。只读的“归属核验和目标备份分类”放进 `LaunchGate` 的第一次检查之后、`quitClaude` 之前；真正的写入仍留在 `prepare` 里。token 已过期时，在本地就明确报错，不要再去联网。
- **复杂性：** 低。不需要锁或状态机。

### 3. CLI 身份锚点太弱：只比邮箱、只信标记文件、存档的身份块没有配对核验

- **严重程度：** 中高。
- **已知或新发现：** 部分已知，部分新发现。
  - 已知：UI 依赖 `.cli-current`，身份块没有和 token 配对（`CLI登录保存方案调研.md:45`）。
  - 新发现：同一邮箱属于多个组织时会存错；外部改号后应用内没有恢复路径。
- **代码位置：**
  - `refreshCLI` 只要 `.cli-current` 存在就采信（`main.swift:393-395`）。
  - 归属比对只用快照里的邮箱（`main.swift:420-426`，`Safety.swift:161-169`）。
  - 存档时 `oauthAccount` 直接取活动文件，没有核对（`main.swift:429`）。
  - 终端状态条只要标记文件里的档案名等于当前档案，就显示“已与桌面同步”（`Views.swift:160-161`）。
- **现实触发：**
  1. 个人 Max 账号和 Team 席位用同一个邮箱。邮箱比对会通过，Team 的 token 可能被存成 Personal。
  2. 运行中的旧 CLI 写回了旧账号的 token 和身份块。下一次切换会拒绝，这本身是对的；但“同步到”按钮走的是同一条路径，会一直失败，应用里没有办法恢复。
- **影响：** 可能长期存错账号；界面显示“已同步”，可下方显示的邮箱其实不一致。
- **最小修正：**
  - 在 `Snapshot` 里保存 `/profile` 返回的 `account.uuid` 和 `organization.uuid`，比对时用“UUID + 组织”。
  - 存档前核对身份块与 `/profile` 的结果一致，不一致就拒绝或用响应结果重建。
  - 状态条改成三态：已确认、不一致、未知。依据 `cliEmail` 与档案邮箱是否一致，而不只是标记文件。
  - CCSwitcher 那套 token 指纹锚点（`CredentialAnchor.swift:92-146`）先不要整套引入。只有真机验收确实观察到旧 CLI 回写的问题，再考虑加一个按档案保存的 SHA256 指纹。
- **复杂性：** 低到中。

### 4. 守卫的进程与路由范围：1P 和 3P 用的是同一个 bundle ID，启用后会误杀 3P/Magpie 会话

- **严重程度：** 高（部署阻塞）。
- **已知或新发现：** 已知阻塞（`存储与迁移方案分析.md:96-98`，`README.md:53,57`）。这里补充具体的失败方式。
- **原因：** 急停只按 `com.anthropic.claudefordesktop` 查找进程（`GuardMain.swift:53-60`），探测只看三个 Claude 域名（`NetworkProbe.swift:18-20`）。而文档写明 `Claude-3p` 也是同一个官方桌面应用（`存储与迁移方案分析.md:33`）。
- **现实触发与影响：**
  - 用户在 3P/Magpie 模式下使用，并且关掉了代理或换了出口。守卫约 10 秒内会先请求退出，约 2 秒后强制结束 Claude，进行中的工作会被打断。
  - 反过来，终端或 IDE 里的 Claude Code、走 API 上游的请求完全不在保护范围内。
  - 另外，三个域名里任何一个临时超时，就会被判为国家未知，触发强制关闭（`Safety.swift:46-50`）。这是有意的失败即拒绝，但误杀频率需要真机评估。
- **最小修正：**
  - 正式启用前，先决定 3P 模式是否豁免。如果豁免，就只读识别当前模式，并在 UI 上明确写出“3P 不受保护”或“3P 也会被急停”。
  - 若想减少误杀，可以改成连续两次失败才强制关闭。代价是最多多暴露约 10 秒，这需要用户自己取舍。
  - 启动门禁仍然应在一次失败时就拒绝。
- **复杂性：** 中（主要是策略决定，不是代码量）。

### 5. CLI 恢复侧：不检查目标备份是否可用，写后不确认，也不提示 API 遮蔽

- **严重程度：** 中。
- **已知或新发现：** 已知但未实现（`CLI登录保存方案调研.md:51-59`）。钥匙串条目的访问权限风险是新发现，有待验证。
- **代码位置：**
  - `main.swift:432-441` 只校验 JSON 的形状。空 token、过期备份都会照写，写完就返回成功（第 457 行）。
  - 第 547-550 行的注释说“Everything goes through /usr/bin/security”，和实际的原生 API 实现不符。
  - 活动条目不存在时（例如之前执行过 `claude /logout`），`SecItemAdd`（第 578-580 行）会由本 App 新建这个条目。CLI 之后再用 `security` 读取它时，可能会弹窗或失败。
- **现实触发：**
  - 目标档案的备份是空的，或 refresh token 已被吊销。
  - 设置了 `ANTHROPIC_API_KEY` 或 `apiKeyHelper`，或 `~/.claude/settings.json` 的 env 里配了 3P 路由。这时 CLI 根本不用 OAuth，界面却显示“已同步”。
- **最小修正：**
  - 借鉴 reference 的 `hasUsableCredentials`（`KeychainService.swift:26-34`），在写入前拒绝空凭据。
  - 写入后在本地回读钥匙串和 `oauthAccount`，确认和刚写入的一致。界面文案改成“已恢复保存的登录，未确认 CLI 实际生效”。
  - 只读检查 `settings.json` 的 env、`apiKeyHelper` 和 `primaryApiKey`，有就提示“可能被 API 遮蔽”。
  - 不要照搬三样东西：未经网络门禁的 `claude auth status`（它会联网并可能写入）、后台刷新 refresh token、先删后加的写法。
  - 修正第 550 行的注释。
- **复杂性：** 低。

### 6. 迁移脚本中其他不能原样产品化的点

- **严重程度：** 中（个人一次性使用可以接受，产品化不行）。
- **已知或新发现：** 部分已知（`存储与迁移方案分析.md:69-74`），以下几点是新发现。
- **具体问题：**
  - **退出检测：** `run-after-quit.sh:6-7` 写死了 `/Applications/Claude.app` 路径。App 装在别处时会被当成“已退出”，立刻开始执行，运行中的 App 会回写覆盖结果。脚本既不阻止用户中途重新打开，也不负责重新启动。
  - **失败不会自动还原：** 重置脚本先移走目标索引（第 23-26 行），之后 sync 才做组织解析等前置检查。sync 一旦失败，`set -e` 会让脚本退出，目标组织只剩 `KEEP`，只能照提示手动 `mv` 回去。
  - **轮数覆盖不看延续链：** 只要源会话轮数更多就覆盖，不检查是否同一条链（`sync-desktop-sessions.py:106`）。父任务复现 2 印证了这一点。
  - **坏的目标索引无备份覆盖：** 读不了的目标索引会被当成“不存在”（第 54-57 行），随后按新增处理，不经备份就被覆盖。
  - **写入与收据：** `copy2` 不是原子写入；收据最后才写（第 127-136 行），中途崩溃就没有收据。
  - **原文存在性检查不全：** 只查当前的 `cliSessionId`（第 66-67 行），延续链的前序原文和 3P 自定义配置目录都没覆盖。
  - **删除标记：** 删除标记用 `cliSessionId` 匹配（第 58、100 行），它是否就是这个键要待验证。
  - **备份与收据：** 重置脚本对目标组织做了全量备份（第 22 行），这一点值得保留。
- **最小修正（产品化时）：**
  - 沿用候选 `ThreadRepository` 的现有做法：显式选择目标组织（`ThreadRepository.swift:68-93`）、同名但身份不同就拒绝、剥离和账号绑定的字段（第 98-119 行）。
  - 再补上延续链判定、先写收据或日志、失败时自动还原。
- **复杂性：** 中。

### 7. 生产菜单栏弹层没有高度上限，长内容时底部按钮可能够不着

- **严重程度：** 低到中。
- **已知或新发现：** 新发现。文档承认生产弹层没有验收（`开发与验证.md:98`）。
- **原因：** 演示窗口外面包了带视口上限的 `ScrollView`（`Views.swift:487-500`），生产弹层却直接用 `Panel` 并跟随内容尺寸（`main.swift:619-623`，`Views.swift:405-475`）。
- **现实触发：** 超过 3 个账号时，账号网格固定高 386pt（`Views.swift:425`）。再加上展开的保护设置和多行横幅（第 411-417 行），在 13 寸屏幕上总高度可能超过可视区域。
- **影响：** 底部的刷新、退出界面按钮可能被截掉，键盘和辅助功能也无法到达。
- **最小修正：** 生产弹层同样包一层 `ScrollView`，最大高度取屏幕可视高度减去边距。不改视觉设计。
- **复杂性：** 低。

### 8. 守卫的几处小问题

- **严重程度：** 低。
- **已知或新发现：** 新发现。
- **具体问题：**
  - 启动门禁只要回执新鲜就放行，不看回执里的 `terminationFailed` 等决策（`Safety.swift:132-137`）。上一轮急停失败了，前台检查只要通过照样能打开。
  - `refreshStatus` 每 5 秒在主线程同步执行一次 `launchctl print`（`Protection.swift:62-64,82`，`GuardService.swift:19-21`），可能让界面卡顿。
- **最小修正：**
  - 回执里 `termination == "failed"` 时拒绝打开。
  - `registered` 的查询移到后台执行。
- **复杂性：** 低。不需要锁或重试。

## 建议与待验证

**保留 / 小修 / 重构**
- **保留：**
  - 目录轮换和回滚（`ProfileTransaction`）。
  - 失败即拒绝的守卫决策，以及回执的新鲜度设计。
  - 原生 Keychain、每个档案一条备份、读或写失败就停止。
  - 演示截图必须带 `--demo` 才能运行的限制。
- **小修：** 发现 2、3、5、7、8。都是局部改动，不需要新的状态机。
- **重构：** 只针对迁移。产品化应以 `ThreadRepository` 为基础重写计划、DRY 和执行逻辑，而不是把脚本搬进来。

**阻止正式部署的**
- 发现 4：1P/3P 范围要先做决定并在 UI 上写明。
- 发现 2：CLI 核验要挪到移动目录之前。
- 发现 3：同一邮箱多组织的 UUID 比对。如果用户确实有这种账号，就是阻塞项。
- 真实 A/B 切换、断网急停、守卫启停验收目前都是 NOT_RUN，也是正式部署的前提。

**仅是禁用中迁移原型的后续要求**
- 发现 1 和发现 6。产品入口保持禁用，不受影响。

**待验证**
1. 用户那次真实迁移的收据里，`dest` 是否就是预期的目标组织；目标组织侧栏是否只剩 1 条。
2. 当前 CLI（2.1.310）的 access token 有效期多长；过期后 `/profile` 是否返回 401。这决定发现 2 会多频繁地触发。
3. 钥匙串条目由本 App 用 `SecItemAdd` 新建后，CLI 通过 `security` 或其他方式读取时，会不会弹窗或失败（包括 SSH 等无图形界面的场景）。
4. 运行中的旧 CLI 在切换后会不会回写钥匙串和 `~/.claude.json`，多久写一次。
5. 3P 模式下桌面进程和 1P 是否无法区分；用户实际使用 Magpie 时，在当前出口策略下会不会被误杀。
6. sync 使用的 `deleted_*` 标记，是否确实以 `cliSessionId` 为键。
7. ad-hoc 签名每次重新构建后，钥匙串授权弹窗会不会反复出现。

<!-- ZHISHU_RESULT_COMPLETE v1 -->
