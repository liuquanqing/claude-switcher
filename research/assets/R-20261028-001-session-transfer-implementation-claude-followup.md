# 外部审查调用：63789de0-a013-475f-b524-d9d1bcf321dc

> 本文件由知行枢受控 runner 管理。外部模型不能写 canonical synthesis。

<!-- ZHIXING_REVIEW_STATE
{
  "adapter": "claude",
  "artifact_role": "review",
  "attempt": 1,
  "attempt_history": [],
  "block_reason": null,
  "completed_at": "2026-10-28T01:18:53+08:00",
  "created_at": "2026-10-28T01:16:32+08:00",
  "event_count": 812,
  "exit_code": 0,
  "invocation_id": "63789de0-a013-475f-b524-d9d1bcf321dc",
  "last_event": "result:812",
  "model_completion_marker_count": 1,
  "pid": 19120,
  "r_id": "R-20261028-001-session-transfer-implementation",
  "raw_log_ref": "/Users/liuquanqing/Projects/安全 AI/claude-switcher/_qa/claude-review/R-20261028-001-session-transfer-implementation/followup/raw/63789de0-a013-475f-b524-d9d1bcf321dc.attempt-1.jsonl",
  "recovery": "resume invocation 63789de0-a013-475f-b524-d9d1bcf321dc with the same artifact",
  "schema": "zhixing.external-review/v1",
  "source_scope": [
    "source-pack"
  ],
  "sources_observed": [
    "/tmp/transfer-review-63789de0/source-pack/REVIEW_SCOPE.md",
    "/tmp/transfer-review-63789de0/source-pack/",
    "/tmp/transfer-review-63789de0/source-pack/Sources/SwitcherCore/SessionTransferService.swift",
    "/tmp/transfer-review-63789de0/source-pack/App/SessionTransferController.swift",
    "/tmp/transfer-review-63789de0/source-pack/Sources/SwitcherCore/SessionTransferJournal.swift",
    "/tmp/transfer-review-63789de0/source-pack/Sources/SwitcherCore/SessionTransferModels.swift",
    "/tmp/transfer-review-63789de0/source-pack/Sources/SwitcherCore/SessionTransferDisk.swift",
    "/tmp/transfer-review-63789de0/source-pack/scripts/fixtures/controller-check.swift",
    "/tmp/transfer-review-63789de0/source-pack/Tests/SwitcherCoreTests/SessionTransferTests.swift",
    "/tmp/transfer-review-63789de0/source-pack/App"
  ],
  "started_at": "2026-10-28T01:16:32+08:00",
  "status": "complete",
  "updated_at": "2026-10-28T01:18:53+08:00"
}
ZHIXING_REVIEW_STATE -->

## 调用状态

- lifecycle: `complete`
- adapter: `claude`
- R-ID: `R-20261028-001-session-transfer-implementation`
- attempt: `1`
- updated_at: `2026-10-28T01:18:53+08:00`
- raw_log_ref: `/Users/liuquanqing/Projects/安全 AI/claude-switcher/_qa/claude-review/R-20261028-001-session-transfer-implementation/followup/raw/63789de0-a013-475f-b524-d9d1bcf321dc.attempt-1.jsonl`

## 来源范围

- declared: `source-pack`
- observed: `/tmp/transfer-review-63789de0/source-pack/REVIEW_SCOPE.md`
- observed: `/tmp/transfer-review-63789de0/source-pack/`
- observed: `/tmp/transfer-review-63789de0/source-pack/Sources/SwitcherCore/SessionTransferService.swift`
- observed: `/tmp/transfer-review-63789de0/source-pack/App/SessionTransferController.swift`
- observed: `/tmp/transfer-review-63789de0/source-pack/Sources/SwitcherCore/SessionTransferJournal.swift`
- observed: `/tmp/transfer-review-63789de0/source-pack/Sources/SwitcherCore/SessionTransferModels.swift`
- observed: `/tmp/transfer-review-63789de0/source-pack/Sources/SwitcherCore/SessionTransferDisk.swift`
- observed: `/tmp/transfer-review-63789de0/source-pack/scripts/fixtures/controller-check.swift`
- observed: `/tmp/transfer-review-63789de0/source-pack/Tests/SwitcherCoreTests/SessionTransferTests.swift`
- observed: `/tmp/transfer-review-63789de0/source-pack/App`

## 审查正文

**结论:** 我没有发现 P1/P2 的真实可达问题。下面是 3 条 P3。我只做了静态阅读,没有运行任何测试,也没有执行命令。

**已核对且不成问题的部分**
- **自动 rollback 归属:** 未创建的 foreign 文件不会被删。`Journal.swift:91-97` 先校验 `before`,`written` 只在 `io.write` 返回后才插入。独占创建失败不会进入 `eligibleNames`,所以连与计划字节完全相同的 foreign 索引也不会被 rollback 删除。
- **`attemptedUpdates` 的范围:** 它在 `write` 之前插入,只对 update 生效。replace 在写入后失败时仍会按 `after` 哈希回退,没有看到问题。
- **`keepCurrentData` 范围:** `Journal.swift:168-176` 只改 `receipt.state` 和 `message`,没有触碰目标文件、备份和源文件。它会校验 scope 和 marker,并且只接受 `needsRecovery` 状态。
- **恢复与撤销严格性:** 撤销要求 `current == after`。恢复只额外放行 `current == before`。预检失败时整批零写入。
- **setter 与 epoch:** `Controller.swift:163-166` 的 setter 已有 `isWorking` 保护。`copySelected` 的 `defer` 以 `refreshID == intent` 为条件,不会清掉更新一轮扫描的 busy 状态。

**P3-1:`keepCurrentData` 未校验备份就声称备份仍在**
- **位置:** `Sources/SwitcherCore/SessionTransferJournal.swift:168-175`,以及 `App/SessionTransferController.swift:284` 和 `:256`。
- **触发:** 备份文件缺失或被改,`restore` 因 `verifyBackup` 失败而抛错。用户选择"保留现状"后,收据被写成 `.preserved`。界面随后显示"备份仍在"和"保留当前数据和备份",但备份并未验证。
- **最小修复:** `keepCurrentData` 里用 `try? verifyBackup(receipt)` 判断一次,并相应设置 `message`。失败时措辞改为"备份校验未通过,仅结束记录"。控制器不要硬编码"备份仍在",改读 `receipt.message`。

**P3-2:忙时 confirm 会丢弃待确认动作,与声明不符且无测试**
- **位置:** `App/SessionTransferController.swift:229`。
- **触发:** 外部 `refresh()` 使 `isWorking` 为真时点击确认。这行代码调用的是 `cancelConfirmation()`,它会清掉 `pendingPlan`、`pendingRestore` 和 `pendingPreserve`。这与 REVIEW_SCOPE 里"busy confirm 不消耗待确认动作"的说法不一致。真实 alert 的 setter 已先调用 `dismissConfirmation`,所以这个动作会被静默丢弃。
- **验证缺口:** `scripts/fixtures/controller-check.swift` 没有覆盖这条分支。
- **最小修复:** 如果意图是保留待确认动作,把 `cancelConfirmation()` 改为只设置 `errorMessage`,并保持 `confirmation` 可见。如果意图是丢弃,就改正声明。两种情况都补一个忙时 confirm 的 fixture 断言。

**P3-3:`confirmAction` 无条件复位 `isWorking`,可能覆盖更新一轮扫描的 busy 状态**
- **位置:** `App/SessionTransferController.swift:232`。
- **触发:** `confirmAction` 进行期间有外部 `refresh()` 启动。如果 `confirmAction` 走错误分支,不会再调用自己的 `refresh()`,`defer` 会把 `isWorking` 置为 false,而更新那轮扫描仍在跑,setter 提前放行。
- **前提:** 这需要界面层确实会在此时直接调用 `refresh()`。包里没有 UI 调用点,我无法确认这一点。
- **最小修复:** 进入时 `let intent = refreshID`。`defer` 改为 `if refreshID == intent { isWorking = false }`。成功路径由其内部的 `refresh()` 自行复位,所以不受影响。
- **验证缺口:** 现有 `controller-check.swift:173-179` 只在 `await refresh()` 完成后断言,没有观察"更新一轮扫描仍在飞行时 `isWorking` 保持为真"。这条声明的测试覆盖不足。

**测试覆盖与启用前阻塞记录**
- **rollback 归属:** `SessionTransferTests.swift:171` 和 `:339` 都在 `io.write` 内先写入 foreign 文件,再调用 `Disk.write`,所以独占 link 确实会失败。这与声明相符。
- **`keepCurrent` 引擎层:** `:306` 和 `:331` 覆盖了引擎层的行为。
- **`keepCurrent` 控制器层:** `requestKeepCurrent`、`pendingPreserve` 和 `.preserved` 的展示在 controller-check 中没有覆盖。我按你的说明,不把未接 native 的异常按钮当作新的后端缺陷。
- **启用前阻塞记录(保留):** native 的"保留现状"按钮尚未接入,迁移开关启用前必须接上,并补控制器层的 `keepCurrent` 覆盖。

<!-- ZHISHU_RESULT_COMPLETE v1 -->
