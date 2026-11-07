# 外部审查调用：2824a459-03c2-4224-b595-c3a558bc71ea

> 本文件由知行枢受控 runner 管理。外部模型不能写 canonical synthesis。

<!-- ZHIXING_REVIEW_STATE
{
  "adapter": "claude",
  "artifact_role": "review",
  "attempt": 1,
  "attempt_history": [],
  "block_reason": null,
  "completed_at": "2026-10-27T17:06:33+08:00",
  "created_at": "2026-10-27T17:02:43+08:00",
  "event_count": 1734,
  "exit_code": 0,
  "invocation_id": "2824a459-03c2-4224-b595-c3a558bc71ea",
  "last_event": "result:1734",
  "model_completion_marker_count": 1,
  "pid": 2297,
  "r_id": "R-20261027-004-local5-review",
  "raw_log_ref": "/Users/liuquanqing/Projects/安全 AI/claude-switcher/_qa/claude-review/R-20261027-004-local5-review/raw/2824a459-03c2-4224-b595-c3a558bc71ea.attempt-1.jsonl",
  "recovery": "resume invocation 2824a459-03c2-4224-b595-c3a558bc71ea with the same artifact",
  "schema": "zhixing.external-review/v1",
  "source_scope": [
    "source-pack"
  ],
  "sources_observed": [
    "/private/tmp/claude-switcher-review-2824a459/source-pack/REVIEW_SCOPE.md",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/MANIFEST.json",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/CLITransaction.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/ProfileTransaction.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/ClaudeGuard/GuardMain.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/CLILoginController.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/NativeCLIStorage.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/AuthenticationConfiguration.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/CLIModels.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/ManagedDesktop.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/DesktopLifecycle.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/Protection.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/Safety.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/GuardService.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/ProtectionView.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/PanelPresentation.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/APIConfiguration.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/APIManagement.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/GuardWorker.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Tests/SwitcherCoreTests/CLITransactionTests.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/main.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/Views.swift",
    "/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/NetworkProbe.swift"
  ],
  "started_at": "2026-10-27T17:02:43+08:00",
  "status": "complete",
  "updated_at": "2026-10-27T17:06:33+08:00"
}
ZHIXING_REVIEW_STATE -->

## 调用状态

- lifecycle: `complete`
- adapter: `claude`
- R-ID: `R-20261027-004-local5-review`
- attempt: `1`
- updated_at: `2026-10-27T17:06:33+08:00`
- raw_log_ref: `/Users/liuquanqing/Projects/安全 AI/claude-switcher/_qa/claude-review/R-20261027-004-local5-review/raw/2824a459-03c2-4224-b595-c3a558bc71ea.attempt-1.jsonl`

## 来源范围

- declared: `source-pack`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/REVIEW_SCOPE.md`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/MANIFEST.json`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/CLITransaction.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/ProfileTransaction.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/ClaudeGuard/GuardMain.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/CLILoginController.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/NativeCLIStorage.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/AuthenticationConfiguration.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/CLIModels.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/ManagedDesktop.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/DesktopLifecycle.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/Protection.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/Safety.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/GuardService.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/ProtectionView.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/PanelPresentation.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/APIConfiguration.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/APIManagement.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/GuardWorker.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Tests/SwitcherCoreTests/CLITransactionTests.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/main.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/App/Views.swift`
- observed: `/private/tmp/claude-switcher-review-2824a459/source-pack/candidate/Sources/SwitcherCore/NetworkProbe.swift`

## 审查正文

我已读完所有重点源码,现在汇总结论。我只用了 Read 和 Grep,范围限于 source-pack/,没有运行任何命令,也没有碰真实账号。

## 总体判断

CLITransaction 的主体设计可以保留。prepare 先读后核验,persist 先落源备份并读回,再退出桌面,再 revalidate,最后 move/apply。源备份失败、读取被拒和 marker 读失败都会在退出或移动桌面之前停止。apply 逐字段还原,外部改过就不覆盖,这些在代码里都能对上。

我没找到 ProfileTransaction undo 的具体数据丢失路径:
- 只在 marker 仍为 target 时撤销。
- 只删除自己新建且为空的目录。
- 非空数据保留。

守卫的授权条件是 PID、启动时间、bundleID 和配置代次,API 和未知模式会撤销归属。我没发现真实的误杀路径。

主要问题有两个:
- CLI 备份状态会卡死桌面切换。
- 受管桌面的"代次"设计过于脆弱。

其余是文案和 UI 的交互风险。

## 主要发现

**1. [高,部署前需决策] CLI 备份状态卡死桌面切换,应用内没有补救入口**
- **触发:**
  - 目标档案的旧版备份没有验证戳,且访问令牌已过期,走到 `verify` 末尾 `CLITransaction.swift:63` 抛错。旧版备份靠 access token 到期就会满足这个条件,而这类备份无法被本应用补盖验证戳(要盖章需要未过期的令牌)。
  - 或者档案槽里是另一账号/组织的备份(`CLITransaction.swift:83-87`、`:44-46`)。
- **影响:** `CLILinkedSwitch.run` 在 prepare 阶段就失败,所以不只 CLI,桌面账号也切不过去或切不出来。没有数据丢失,但用户只能手动处理钥匙串。
- **最小修正:**
  - 目标侧"过期且无凭证"时,允许桌面继续切换。`desired` 取空,按 `.needsLogin` 处理,不动目标备份,界面提示 CLI 需重新登录。这依赖源备份已经先落盘,而代码是这样做的。
  - 源侧"槽位属于他人"时,改成不覆盖并提示,同样不要阻断桌面切换。
- **复杂度:** 中。需要改 prepare 分支,并补两个测试。
- **说明:** 范围文件说"拒绝"是有意的,所以我只质疑它与桌面切换的耦合,不质疑拒绝本身。

**2. [中,建议部署前修] 受管桌面"代次"绑定了文件元数据,配置被触碰后保护会无声失效**
- **触发:**
  - `DesktopModeInspector.evidence` 的 revision 混入了 inode、mtime、ctime(`AuthenticationConfiguration.swift:112-120`)。
  - 桌面自己或用户编辑 `claude_desktop_config.json` 时,即使内容不变也会触发。
  - 启动后写入同理:`launchProtectedDesktop` 在启动后才取 revision(`ManagedDesktop.swift:34`)。
- **影响:**
  - `session.authorizes` 失败后,守卫的 `application()` 返回 nil,断网时不再关闭该桌面(`GuardMain.swift:63-70`)。
  - 界面最多 5 秒后降为"当前桌面未保护",没有主动提示。
  - 这是偏向放行的失效,不是误杀。
- **最小修正:** revision 只哈希与授权有关的规范化内容,即每个根目录的 `deploymentMode` 和文件是否存在。稳定读取的 stat 三重检查保留,但不进入 revision。
- **复杂度:** 低。
- **待验证:** 真实 Claude 桌面是否会自行改写该文件,这一点我无法确认,见 NOT_RUN。

**3. [中,文案] "API 遮蔽"检测只覆盖 App 进程环境和 home 下的设置文件**
- **位置:** `CLILoginController.swift:5-8`,`AuthenticationConfiguration.swift:18-23`、`:45-60`。
- **触发:**
  - 用户在 `.zshrc` 里导出 `ANTHROPIC_API_KEY`、`CLAUDE_CONFIG_DIR` 或 Bedrock 开关。
  - 或某个项目目录里有自己的 `.claude/settings.json`。
  - 菜单栏 App 的环境里没有这些,`cwd` 也固定为 home。
- **影响:** 界面可能显示默认登录"已核验/一致",实际终端走 API。这不会造成数据损害。
- **最小修正:** 不要去读 shell。在 `cliStatusDetail` 和相关 tooltip 里明确写"未检测 shell 环境变量与项目级设置"。
- **复杂度:** 低。
- **保留项:** `refreshCLI` 里"不代表各个正在运行的终端"的限定已经有了,代码行为本身可保留。

**4. [中,交互] 关键限定语只出现在 `.help` 悬浮提示里,而且主文案被截断**
- **位置:**
  - `Views.swift:231-232`:`detail` 是 `lineLimit(1)` 加中间截断,完整 `detailHelp` 只在悬浮时可见。
  - `ProtectionView.swift:392`、`:447`、`:450` 的范围说明同样如此。
  - `Views.swift:246` 的"不改 API key"说明也是。
- **影响:** 键盘和 VoiceOver 用户读不到"默认保存登录、非各会话"这类限定,窄宽度下关键词会被截掉。
- **最小修正:** 让 `detail` 允许 2 行,并给该行加 `.accessibilityHint(detailHelp)`。也可以把内容并入已有的"了解检查"浮层。
- **复杂度:** 低。

**5. [中,NOT_RUN] 嵌套浮层和确认对话框放在 `NSPopover(.transient)` 里,交互没有验证**
- **位置:** `main.swift:505`,`ProtectionView.swift:478`、`:545`、`:554`、`:561`。
- **风险:**
  - 点击子浮层或"第三方体检"链接时,瞬态父弹层可能被关掉。
  - `confirmationDialog` 在 NSPopover 的窗口里可能弹不出来。
- **影响:** 弹不出来时,"停止保护"和"保护当前桌面"会变成无反应。这是偏安全的失败,不会误操作。
- **最小修正:** 先做真机验收。若有问题,用内联确认行代替对话框。
- **复杂度:** 低到中。

**6. [低] 采用已有桌面时,确认框没有说明进程信息,用户无法判断它是否真是订阅模式**
- **位置:** `ManagedDesktop.swift:12-22`,`ProtectionView.swift:554`。
- **触发:** 进程是通过原工具以 API 方式启动的,之后配置被改回 1p 而进程未重启。`currentSubscriptionDesktopRecord` 只能证明配置层是订阅,不能证明运行中的进程是订阅。
- **影响:** 用户点了确认后,断网时守卫会关闭这个 API 进程。这需要用户明确确认,属于残余风险。
- **最小修正:** 对话框附上进程启动时间和配置最近修改时间,并提示"若此进程由 API 工具启动,请取消"。
- **复杂度:** 低。
- **说明:** 自动误杀的路径我没有找到。守卫失败时关闭受管进程的行为(`GuardMain.swift:22-23`)属于 fail-closed,可保留。

**7. [低] 切换失败或部分失败后,CLI 状态不会立刻刷新**
- **位置:** `main.swift:360`(`switchTo` 的 catch 只调用 `reloadList()`),`CLILoginController.swift:164`。
- **触发:**
  - 桌面目录已撤销,但 CLI 还原未确认,走 `CLITransaction.swift:182`、`:216`、`:220`。
  - 或者 apply 回读失败。
- **影响:** `cliStatus` 保持旧值(例如"一致"),要等 300 秒的定时刷新。错误横幅会提示"停止操作",所以风险有限。
- **最小修正:** 两处 catch 里调用 `await refreshCLI(verify: false)`。该调用只读元数据,不碰 Keychain。
- **复杂度:** 低。

## 建议与待验证

**部署前建议**
- 先决定发现 1 的处理方式。我倾向于让桌面切换不被 CLI 备份问题阻断。
- 修发现 2、4、7,改动都很小。
- 发现 3 和 6 只改文案。

**可保留**
- CLITransaction 的顺序和还原逻辑。
- ProfileTransaction undo。
- 守卫的授权条件和 API/未知模式撤销归属。
- APIConfiguration 的固定 ID 和固定文件名读取。
  - 冲突和未知会降级。
  - 不读取任意路径,也不显示秘密。
  - `openAPIManager` 在打开前复核配置(`APIManagement.swift:12-14`)。
  - 打开原工具与退出接管是分开的,界面文案也这么说。
- 钥匙串"未找到"和"读取失败"的区分(`main.swift:452-455`)。

**测试盲区**(只从源码看,没有运行)
- `MemoryCLI` 是内存实现,没有覆盖:
  - 真实钥匙串 ACL 弹窗阻塞。
  - `SecItemUpdate` 对 CLI 创建的条目的行为。
  - 运行中的 CLI 并发改写 `~/.claude.json`。apply 是整文件读改写,窗口很小,靠 revalidate 和回读兜底。
- 没有看到 ProfileTransaction undo 与 CLI apply 失败联动的端到端测试。
- 没有看到 revision 在文件被触碰后失效的测试,也没有 "legacy 过期备份阻断桌面切换" 的测试。

**明确 NOT_RUN 的真实验收**
- 真实 Claude 桌面是否改写 `claude_desktop_config.json`(发现 2)。
- 首次访问 Claude Code 钥匙串条目时,同步 `SecItem*` 调用在主线程的阻塞表现。`CLICredentialIO` 是 `@MainActor`,弹窗期间菜单栏面板会冻结。
- NSPopover 内浮层和对话框的实际行为(发现 5)。
- 运行中的旧 CLI 刷新令牌后,备份里的 refresh token 是否失效。这是范围文件已声明的边界。

<!-- ZHISHU_RESULT_COMPLETE v1 -->
