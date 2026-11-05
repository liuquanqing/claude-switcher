# 外部审查调用：53cea2d9-2743-424b-bd91-8ec89bca5455

> 本文件由知行枢受控 runner 管理。外部模型不能写 canonical synthesis。

<!-- ZHIXING_REVIEW_STATE
{
  "adapter": "claude",
  "artifact_role": "review",
  "attempt": 2,
  "attempt_history": [
    {
      "attempt": 1,
      "block_reason": "source_scope_violation:/private/tmp/claude-switcher-review-53cea2d9",
      "ended_at": "2026-10-27T17:27:22+08:00",
      "exit_code": 0,
      "status": "blocked"
    }
  ],
  "block_reason": null,
  "completed_at": "2026-10-27T17:33:00+08:00",
  "created_at": "2026-10-27T17:24:54+08:00",
  "event_count": 2241,
  "exit_code": 0,
  "invocation_id": "53cea2d9-2743-424b-bd91-8ec89bca5455",
  "last_event": "result:2241",
  "model_completion_marker_count": 1,
  "pid": 75251,
  "r_id": "R-20261027-004-local5-review",
  "raw_log_ref": "/Users/liuquanqing/Projects/安全 AI/claude-switcher/_qa/claude-review/R-20261027-004-local5-review/followup/raw/53cea2d9-2743-424b-bd91-8ec89bca5455.attempt-2.jsonl",
  "recovery": "resume invocation 53cea2d9-2743-424b-bd91-8ec89bca5455 with the same artifact",
  "schema": "zhixing.external-review/v1",
  "source_scope": [
    "source-pack"
  ],
  "sources_observed": [
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/REVIEW_SCOPE.md",
    "/private/tmp/claude-switcher-review-53cea2d9",
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/DesktopOnlySwitch.swift",
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/CLILoginController.swift",
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Sources/SwitcherCore/CLITransaction.swift",
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate",
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/main.swift",
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Sources/SwitcherCore/Safety.swift",
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/Protection.swift",
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App",
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/scripts/fixtures/controller-check.swift",
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Tests/SwitcherCoreTests/CLITransactionTests.swift",
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/ProtectionView.swift",
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Sources/SwitcherCore/ProfileTransaction.swift",
    "/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/Views.swift",
    "/tmp/claude-switcher-review-53cea2d9/source-pack/REVIEW_SCOPE.md",
    "/tmp/claude-switcher-review-53cea2d9/source-pack/",
    "/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/DesktopOnlySwitch.swift",
    "/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/CLILoginController.swift",
    "/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Sources/SwitcherCore/CLITransaction.swift",
    "/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/",
    "/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/main.swift",
    "/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/Protection.swift",
    "/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/",
    "/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/scripts/fixtures/controller-check.swift",
    "/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Sources/SwitcherCore/ProfileTransaction.swift",
    "/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Sources/SwitcherCore/Safety.swift",
    "/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Tests/SwitcherCoreTests/CLITransactionTests.swift"
  ],
  "started_at": "2026-10-27T17:31:22+08:00",
  "status": "complete",
  "updated_at": "2026-10-27T17:33:00+08:00"
}
ZHIXING_REVIEW_STATE -->

## 调用状态

- lifecycle: `complete`
- adapter: `claude`
- R-ID: `R-20261027-004-local5-review`
- attempt: `2`
- updated_at: `2026-10-27T17:33:00+08:00`
- raw_log_ref: `/Users/liuquanqing/Projects/安全 AI/claude-switcher/_qa/claude-review/R-20261027-004-local5-review/followup/raw/53cea2d9-2743-424b-bd91-8ec89bca5455.attempt-2.jsonl`

## 来源范围

- declared: `source-pack`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/REVIEW_SCOPE.md`
- observed: `/private/tmp/claude-switcher-review-53cea2d9`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/DesktopOnlySwitch.swift`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/CLILoginController.swift`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Sources/SwitcherCore/CLITransaction.swift`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/main.swift`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Sources/SwitcherCore/Safety.swift`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/Protection.swift`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/scripts/fixtures/controller-check.swift`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Tests/SwitcherCoreTests/CLITransactionTests.swift`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/ProtectionView.swift`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Sources/SwitcherCore/ProfileTransaction.swift`
- observed: `/private/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/Views.swift`
- observed: `/tmp/claude-switcher-review-53cea2d9/source-pack/REVIEW_SCOPE.md`
- observed: `/tmp/claude-switcher-review-53cea2d9/source-pack/`
- observed: `/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/DesktopOnlySwitch.swift`
- observed: `/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/CLILoginController.swift`
- observed: `/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Sources/SwitcherCore/CLITransaction.swift`
- observed: `/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/`
- observed: `/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/main.swift`
- observed: `/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/Protection.swift`
- observed: `/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/App/`
- observed: `/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/scripts/fixtures/controller-check.swift`
- observed: `/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Sources/SwitcherCore/ProfileTransaction.swift`
- observed: `/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Sources/SwitcherCore/Safety.swift`
- observed: `/tmp/claude-switcher-review-53cea2d9/source-pack/candidate/Tests/SwitcherCoreTests/CLITransactionTests.swift`

## 审查正文

# 后端审查：CLI 准备错误分类与仅切桌面备用路径

我只用 Read/Grep/Glob 读了 `/tmp/claude-switcher-review-53cea2d9/source-pack/` 下的文件，没有执行任何命令，也没有声称测试通过或真实运行可用。

## 总体判断

没有发现会直接丢数据或绕过认证边界的严重缺陷。以下几点成立：

- **分类时机正确：** `CLIPreparationFailure` 只包住 `prepare`/`persistOutgoing`（`CLITransaction.swift:238-241`）和 `cliContext`（`CLILoginController.swift:76-78`），都发生在 `quit()` 和 `move()` 之前。`apply` 失败、`revalidate` 失败和未退出都抛普通 `SafetyError`，不会触发备用提示（测试 `CLITransactionTests.swift:212` 覆盖了 apply 失败）。
- **仅切桌面路径没有 CLI 写入：** `DesktopOnlySwitch.swift:13-58` 没有构造 `NativeCLIStorage` 或 `CLITransaction`，没有读写凭据或备份，也不碰 CLI 标记。它只在 `refreshCLI(verify:false)` 里读身份文档元数据。
- **门禁和目录检查基本够用：**
  - 先做桌面 preflight（`:28`），再用 `validate` 检查符号链接、非目录和非空源存档（`:31`）。
  - 退出前后各检查一次订阅模式，退出后复核当前档案，移动前再校验，启动前再做一次 gate（`LaunchGate.run`，`Safety.swift:153-161`）。
- **原事务回滚路径没有发现遗漏：** `apply` 的 catch 会先判断外部改动，再按 `Attempted` 标志逐项还原，最后回读确认。桌面目录的 `activate` 撤销在标记被外部改动时会拒绝覆盖。
- **不误承诺运行任务：** 用户外部改号后的手动同步（`moveTerminal`）靠身份匹配而非标记，状态文案都带“不代表已运行的 CLI 任务”。

下面 4 条是实际缺陷或缺口，均不是阻塞项。

## 主要发现

### 1. 准备阶段部分写备份后仍被归为“CLI 未改变”，并提供备用切换（低-中）

- **位置：** `CLITransaction.swift:127-141`、`:238-241`，`main.swift:371-374`。
- **触发：** `persistOutgoing` 先写离开账号的备份（`:134`），再写目标备份升级（`:138`）。第二次写入失败或回读失败时，第一份备份已经改变。
- **后果：** 这个错误被整体包成 `CLIPreparationFailure`，于是弹出备用提示。这与“CLI 登录/备份保持原样”的承诺不符。活动凭据确实没变，备份内容是同一登录的验证副本，所以不会丢数据，但承诺不精确。
- **测试缺口：** `testBackupFailureCannotQuitOrMoveDesktop`（`:86-93`）用 `denyBackup`，只断言没有 quit/move，没有断言备份是否变化，也没有覆盖“第一份写成功、第二份失败”。
- **最小修复：**
  - 让 `persistOutgoing` 在失败时区分“尚未写入”和“可能已写入备份”。例如给 `CLIPreparationFailure` 加 `backupsTouched` 布尔值。
  - 为 true 时，备用提示和横幅都不要写“备份未改变”。
  - 补一个第二次写入失败的测试。

### 2. 仅切桌面的真实分支没有测试，fixture 的结论和真实路径不同（低-中）

- **位置：** `DesktopOnlySwitch.swift:18-26` 对比 `:27-57`；`controller-check.swift:77-87`。
- **触发：** fixture 里只跑了 demo 分支，其中 `cliStatus = cliProfile == current ? .matched : .different`（`:23`）。真实分支调用 `refreshCLI(verify:false)`，把状态设成 `.unverified`，不会得出 `.different`（`CLILoginController.swift:105`、`:122`）。
- **后果：** 测试通过的“desktop-only choice reports mismatch”是 demo 行为，不能证明真实分支的状态。真实分支的这些行为没有任何测试：
  - gate 失败；
  - `validate` 失败；
  - 目标为 API；
  - 退出后模式变化；
  - 回滚；
  - 不读 CLI 存储。
- **最小修复：**
  - 把 `confirmDesktopOnlySwitch` 的真实分支拆成可注入 `liveDir`/`parkDir`/`quit`/`gate` 的函数。
  - 用临时目录写 3-4 个测试，并断言注入的 CLI 存储零调用。
  - 至少让 demo 分支也设成 `.unverified`，与真实路径一致。

### 3. 仅切桌面在“目录已移动、之后失败”时报错文案不准确（低）

- **位置：** `DesktopOnlySwitch.swift:47-57`。
- **触发：** `switchProfile` 成功后，`LaunchGate.run` 的第二次 gate 失败或 `launchProtectedDesktop` 抛错，会进入同一个 catch。
- **后果：** 横幅写的是“仅切桌面未全部完成：… 请核对当前档案”。用户看不出桌面档案已经切换、Claude 现在未运行。这与 `switchProfile` 自身失败后已还原的情况混在一起。
- **最小修复：** 在 `prepare` 闭包里 `switchProfile` 成功后设一个 `moved = true`，catch 里据此分别写“目录已切换但未打开 Claude，CLI 登录未变”和“未移动目录”。

### 4. `activeProxyMode` 与 `activeCountry` 更新不同步，`hasUnsavedChanges` 可能误报（低）

- **位置：** `Protection.swift:247-248`、`:254`、`:152-153`、`:41-43`。
- **触发：**
  - `preflight` 读到新配置时只更新 `activeCountry`，不更新 `activeProxyMode`；读到无效配置时只清 `activeCountry`。
  - `refreshStatusAsync` 的守卫（`:152`）发现配置在 await 期间变化就直接 return，不更新两者。
  - 结果是保存值的国家和代理模式可能来自不同读取时刻。
- **后果：**
  - 当前非前端、非测试的代码里没有使用 `hasUnsavedChanges`（Grep 只在 `Protection.swift` 里命中），所以暂时不会触发误保存。
  - `enable()` 保存时使用的是表单值（`:191`），不依赖它。
  - 前端接入后可能出现“已保存却提示未保存”，或“磁盘模式已变而界面提示干净”。
- **最小修复：** 抽一个 `applySaved(_ config: SafetyConfig?)`，统一设置 `activeCountry` 和 `activeProxyMode`，`preflight` 和 `refreshStatusAsync` 都改用它。

## 待验证

- **文案是否与代码一致：** demo 的原因文案写“账号目录和 CLI 登录尚未改变”（`main.swift:344`）。真实路径的准备错误文案和横幅需要按发现 1 的修复核对，不能同时说“备份未变”。
- **备用提示的触发范围：** `cliContext` 整体被包成 `CLIPreparationFailure`，临时网络失败、桌面档案身份未确认、CLI 认证配置不支持都会触发。我认为这符合“用户显式选择”的设定，但需要确认前端文案区分“可重试”和“需先处理”。
- **提示残留：** `desktopOnlyOffer` 在 gate 之前就被清空（`DesktopOnlySwitch.swift:15`），gate 失败后用户需要重新发起；offer 只在 `switchTo` 里清除，其他操作后会残留，但执行时有 `source` 复核，不会误切。
- **配置代次保守策略：** 我没有建议降低认证边界。保留 inode/mtime/ctime/content 绑定，需要靠你说明的真实验收确认普通 Claude 配置重写的体验。
- **未执行：** 全部结论来自静态阅读。XCTest、controller 检查、release 构建和真实账号运行都没有由我执行或验证。

<!-- ZHISHU_RESULT_COMPLETE v1 -->
