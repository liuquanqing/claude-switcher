# 外部审查调用：a96c30c6-6e51-4ac0-84a5-27be75f1eac1

> 本文件由知行枢受控 runner 管理。外部模型不能写 canonical synthesis。

<!-- ZHIXING_REVIEW_STATE
{
  "adapter": "claude",
  "artifact_role": "review",
  "attempt": 1,
  "attempt_history": [],
  "block_reason": null,
  "completed_at": "2026-10-28T00:51:33+08:00",
  "created_at": "2026-10-28T00:49:54+08:00",
  "event_count": 1058,
  "exit_code": 0,
  "invocation_id": "a96c30c6-6e51-4ac0-84a5-27be75f1eac1",
  "last_event": "result:1058",
  "model_completion_marker_count": 1,
  "pid": 36437,
  "r_id": "R-20261028-001-session-transfer-implementation",
  "raw_log_ref": "/Users/liuquanqing/Projects/安全 AI/claude-switcher/_qa/claude-review/R-20261028-001-session-transfer-implementation/raw/a96c30c6-6e51-4ac0-84a5-27be75f1eac1.attempt-1.jsonl",
  "recovery": "resume invocation a96c30c6-6e51-4ac0-84a5-27be75f1eac1 with the same artifact",
  "schema": "zhixing.external-review/v1",
  "source_scope": [
    "source-pack"
  ],
  "sources_observed": [
    "/tmp/transfer-implementation-review-a96c30c6/source-pack/REVIEW_SCOPE.md",
    "/tmp/transfer-implementation-review-a96c30c6/source-pack/",
    "/tmp/transfer-implementation-review-a96c30c6/source-pack/Sources/SwitcherCore/SessionTransferService.swift",
    "/tmp/transfer-implementation-review-a96c30c6/source-pack/Sources/SwitcherCore/SessionTransferDisk.swift",
    "/tmp/transfer-implementation-review-a96c30c6/source-pack/Sources/SwitcherCore/SessionTransferJournal.swift",
    "/tmp/transfer-implementation-review-a96c30c6/source-pack/App/SessionTransferController.swift",
    "/tmp/transfer-implementation-review-a96c30c6/source-pack/Sources/SwitcherCore/SessionTransferModels.swift",
    "/tmp/transfer-implementation-review-a96c30c6/source-pack/App/SessionTransferView.swift",
    "/tmp/transfer-implementation-review-a96c30c6/source-pack/App/SessionTransferDemo.swift",
    "/tmp/transfer-implementation-review-a96c30c6/source-pack/Tests/SwitcherCoreTests/SessionTransferTests.swift",
    "/tmp/transfer-implementation-review-a96c30c6/source-pack/Sources/SwitcherCore/ProfileTransaction.swift",
    "/tmp/transfer-implementation-review-a96c30c6/source-pack/scripts/fixtures/controller-check.swift"
  ],
  "started_at": "2026-10-28T00:49:54+08:00",
  "status": "complete",
  "updated_at": "2026-10-28T00:51:33+08:00"
}
ZHIXING_REVIEW_STATE -->

## 调用状态

- lifecycle: `complete`
- adapter: `claude`
- R-ID: `R-20261028-001-session-transfer-implementation`
- attempt: `1`
- updated_at: `2026-10-28T00:51:33+08:00`
- raw_log_ref: `/Users/liuquanqing/Projects/安全 AI/claude-switcher/_qa/claude-review/R-20261028-001-session-transfer-implementation/raw/a96c30c6-6e51-4ac0-84a5-27be75f1eac1.attempt-1.jsonl`

## 来源范围

- declared: `source-pack`
- observed: `/tmp/transfer-implementation-review-a96c30c6/source-pack/REVIEW_SCOPE.md`
- observed: `/tmp/transfer-implementation-review-a96c30c6/source-pack/`
- observed: `/tmp/transfer-implementation-review-a96c30c6/source-pack/Sources/SwitcherCore/SessionTransferService.swift`
- observed: `/tmp/transfer-implementation-review-a96c30c6/source-pack/Sources/SwitcherCore/SessionTransferDisk.swift`
- observed: `/tmp/transfer-implementation-review-a96c30c6/source-pack/Sources/SwitcherCore/SessionTransferJournal.swift`
- observed: `/tmp/transfer-implementation-review-a96c30c6/source-pack/App/SessionTransferController.swift`
- observed: `/tmp/transfer-implementation-review-a96c30c6/source-pack/Sources/SwitcherCore/SessionTransferModels.swift`
- observed: `/tmp/transfer-implementation-review-a96c30c6/source-pack/App/SessionTransferView.swift`
- observed: `/tmp/transfer-implementation-review-a96c30c6/source-pack/App/SessionTransferDemo.swift`
- observed: `/tmp/transfer-implementation-review-a96c30c6/source-pack/Tests/SwitcherCoreTests/SessionTransferTests.swift`
- observed: `/tmp/transfer-implementation-review-a96c30c6/source-pack/Sources/SwitcherCore/ProfileTransaction.swift`
- observed: `/tmp/transfer-implementation-review-a96c30c6/source-pack/scripts/fixtures/controller-check.swift`

## 审查正文

# 审查结论（只读静态审查）

我没有运行任何测试或命令。下面的结论都来自读源码。它们不代表 38 项核心测试或 43 项 controller 检查已执行，也不代表真实 Claude 索引格式兼容。

共 2 条主要发现，另有 1 条低优先级建议。

## 主要发现

### 1. P1：目标索引被外部改动后，回滚和恢复会卡死，目标空间被永久阻断

**触发**：复制进行中，目标里某个待写索引被 CLI 或桌面端改动或新建。

这个改动可能出现在第 k 项的写入前校验（`SessionTransferJournal.swift:92`）。也可能出现在 `.create` 的排他 link 报 EEXIST 时（`SessionTransferDisk.swift:80`）。

**经过**：
- 回滚遇到第 k 项时，当前内容既不是 before 也不是 after，所以走到 `Journal.swift:127` 抛错。
- `Journal.swift:130` 吞掉这个错误并设 `complete=false`，于是收据变成 `recoveryRequired`（`Journal.swift:102`）。
- 此时第 k 项根本没被本次复制写过。保留外部数据本来是对的，但这一项被当成了"恢复失败"。
- 之后"手动恢复"会再次失败。`Journal.swift:144-146` 的预检要求每项都等于 before 或 after，外部改动让它永远抛错。
- 该收据状态是 `needsRecovery`，`existingReceiptsAllowCopy`（`Journal.swift:57-60`）会一直拒绝同一目标的新复制。controller 的 `recoveryBlocksTarget`（`SessionTransferController.swift:127-131`）也会禁用复制按钮。
- 用户没有任何应用内出口。

测试 `testForeignTargetDuringCreateIsPreservedAndRecoveryRequired`（`SessionTransferTests.swift:171-179`）把"数据保住"和"进入 recoveryRequired"都断言为期望行为，所以现有测试不会报这个问题。

**影响**：不会丢数据，但同一目标空间的所有后续复制都会被阻断，没有应用内的解除办法。

**最小修复**：只改非撤销的 rollback 和恢复路径。当前内容既不等于 before 也不等于 after 时，视为"外部已接管，保留，不动"，不计入失败，也不让预检抛错。收据照常结束为 `restored`，`message` 里记一句"某某条目已被外部更改，已保留"。

撤销（`undo`）仍保持整批预检、遇冲突就整批停止，这个设计应保留。不需要加锁，也不需要进度计数器。

### 2. P2：异步生成计划期间改了来源、目标或"更新"开关，仍会按旧计划提交

**触发**：用户点"复制"后，`worker.plan` 还没返回（目录扫描慢时可见），就切换目标空间、来源或更新开关。

**经过**：
- `setSource`、`setTarget`、`setSourceSpace`、`setTargetSpace`、`setUpdates` 只用 `!writing` 守卫（`SessionTransferController.swift:157-166`）。`isWorking` 在计划阶段已为 true，但没被检查。
- 它们会清空选择，并清掉 `confirmation` 和 `pendingPlan`。
- `copySelected` 在 `:213` 恢复后，没有校验这期间界面状态是否变过。
  - 纯新增、无需确认时，`:217` 直接 `execute` 旧计划，会写到界面上已不再显示的目标空间。
  - 含更新时，`:215-216` 在已清空的界面上弹出过期确认，确认后执行旧计划。
- `:211` 的 `defer { isWorking = false }` 还会提前结束新触发的 refresh 的忙碌状态，导致 `picked` 在扫描中可被改动。

**影响**：不是误绑定，因为计划自带 source、target，并经 `revalidate` 签名校验，不会写错内容。但这会违背"用户看到什么就提交什么"。这是新增复制的直接写入，属于对未展示目标的一次误提交。

**最小修复**：在 `copySelected` 开头记下 `let epoch = refreshID`，每次 `setXxx`、`queueRefresh` 本来就会更新它。`await worker.plan` 返回后，如果 `refreshID != epoch` 就直接丢弃计划。同时让这五个 setter 在 `isWorking` 时也直接返回。不需要新增常驻状态。

### 3. P3（低，可选）：确认回调在忙碌时被静默丢弃，pending 状态不随 dismiss 清理

- `confirmAction` 在 `isWorking` 时直接 `return`（`SessionTransferController.swift:221`）。Alert 此时已被关闭，用户点了"确认"却没有任何反馈。
- `dismissConfirmation`（`:242`）只清 `confirmation`，保留 `pendingPlan` 和 `pendingRestore`。目前只有 Alert 按钮能调用 `confirmAction`，所以没有现实触发路径。
- 建议：`confirmAction` 因忙碌返回时设一条 `statusMessage`。Alert 的确认按钮闭包里先取走 pending 再调用，避免依赖 SwiftUI 回调顺序。这一条不阻塞上线。

## 确认无问题、可保留的部分

- **备份与收据顺序**：备份先写，再回读校验、`revalidate`、保存收据，最后才第一次写目标（`Journal.swift:71-83` 到 `:87`）。收据落盘后才写目标，符合要求。
- **源与原文只读**：`SessionTransferService` 全程没有对源索引或 JSONL 的写操作。
- **新建排他**：用同目录暂存文件加 `linkItem`，不会覆盖他人先建的索引。
- **sameCLI 更新白名单**：只更新 `completedTurns` 和 `lastActivityAt`（`SessionTransferService.swift:144-145`）。`priorCliSessionIds` 或 fixtureProof 不能授权覆盖。目标有多个相关会话、分叉或同名不同身份时都 blocked。目标读不出的索引不会被当作"不存在"。
- **namespace 与 marker**：每次写之前，以及回滚时，都重新验证 scope 和 marker。恢复时按收据里的原目标 scope 解析，不信旧的活动路径。
- **收据路径**：UUID 目录、文件名为 `local_*.json`、`afterFile` 和 `beforeFile` 固定为 `after-i.json` 和 `before-i.json`，路径不能逃出 namespace。
- **活动目标门禁**：`idle` 经 `requireIdle` 已实接 `execute` 和 `restore`，每个写之前都会检查。探针出错时会抛错而不是放行。
- **Demo 与测试环境**：`SessionTransferDemo` 和 `testEnvironment` 使用临时目录，探针固定为 false，不碰真实路径。
- **撤销遇外部更改**：整批停止、保留当前数据，这个设计应保留。
- **不需要新增机制**：我没有发现需要全局锁、数据库或常驻状态的问题。

## 测试缺口

1. 缺"外部改动后，非撤销恢复能把收据正常收尾，并解除目标阻断"的用例。需要改掉第 171 行那条断言的预期。
2. 缺"外部改动后目标仍不能复制"的负向用例，与第 1 条对应。
3. controller 检查缺"`worker.plan` 在飞时切换目标、来源或更新开关，旧计划必须丢弃"的用例。可用延迟的注入 worker 来做。
4. 缺"`confirmAction` 在 `isWorking` 时被丢弃"的状态提示用例。
5. 这次未发现缺陷，但我也没看到测试覆盖：非当前 profile 在 `activeEndpointIDs` 之外时不会被探针门禁。这是设计意图，建议加一条断言固定下来。

<!-- ZHISHU_RESULT_COMPLETE v1 -->
