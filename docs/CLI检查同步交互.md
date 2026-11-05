# CLI 检查 / 同步交互（终端条）

状态：前端已改，**未构建、未做原生 QA**（由 Codex 负责）。

## 原则
- 后台刷新/检查平时不覆盖 CLI 登录，也不停止 CLI 任务；手动“同步”需确认。软件内用户主动切换桌面账号时，仍按原有流程联动备份/恢复 CLI 登录，不受本条限制。
- 同步改的是默认全局登录：不关闭任何 CLI 任务，已运行任务何时采用新登录由 CLI 自己决定。
- 检查（只读）与同步（写入）分开：先检查，再按结果决定是否同步。
- 只管默认订阅登录（钥匙串或默认位置凭据文件）；不代表已运行的 CLI 任务已切换；不改 API provider / env；自定义目录仍未适配。

## 交互
| 状态 | 状态文案 | 入口 |
|---|---|---|
| unverified | 登录待核验 | 强调色“核验登录” |
| matched | 已与桌面一致 / 订阅登录已核验(API 桌面) | 弱化“重新检查” |
| different | 与桌面不同 | “重新检查” + “同步到 X” |
| needsLogin / otherAuthentication / unsupportedStorage | 原文案 | 弱化“重新检查” |

- 检查入口在所有状态可见，调用 `store.verifyDefaultCLI()`（无登录写入）。
- “同步到 X”仅在 `cliStatus == .different` 且 `protection.desktopScope == .subscription` 时出现；API/未知桌面不出现，订阅 CLI 仍可检查但不与 API 桌面比较。
- 点“同步”时固定目标名 X（`syncTarget`）并弹确认：先备份当前 CLI 登录，再恢复 X 的已保存登录并回读；不关闭 CLI 任务，运行中任务何时采用新登录由 CLI 决定；不改 API 设置。
- 确认时重新校验：`canSync`（仍为 different 且订阅桌面）、未 busy/refreshing、`store.current == X`。通过才调用 `store.moveTerminal(to: X)`；否则不写入，提示“状态已变化，未同步，请重新检查”。无全局锁/状态机。
- 检查/同步在 `store.busy != nil || store.refreshing` 时禁用。
- 后端已处理：默认文件凭据有效后可核验/备份/同步；不同存储账号冲突失败关闭；目标无 CLI 备份时手动同步不清空现有登录；API/未知模式拒绝同步。
- 目标账号没有已保存登录、文件与钥匙串冲突、读取拒绝、身份不完整：由后端报错并停止，前端不显示“已同步”；状态绿勾只来自后端 `.matched`，不据邮箱或本地 CLI 报告推断。

## 改动
- `App/Views.swift` `TerminalStrip`：常驻检查按钮、`canSync`/`controlsLocked`/`checkHelp`、同步确认框；更新 different 与 unsupportedStorage 说明（不再写“仅钥匙串”）。

## 布局（500pt 固定宽修正）
- 旧版把标题、状态、详情、说明、检查、同步挤在一行，终端区仅约 270pt，标题被挤成四行、同步被截断。
- 现在 `TerminalStrip` 分两层：上层为图标 + 「终端 OAuth」（不换行、不压缩）+ 状态 + 说明 ⓘ，下面一行详情（单行，中间截断）；下层独立动作行：“重新检查”（unverified 时为强调色“核验登录”）+ different 且订阅桌面时的“同步到 X”（长名称在按钮内中间截断，检查按钮 `fixedSize` 优先保留）。
- 正常状态只显示重新检查；不一致显示检查 + 同步，并排可见。字号不变。
- 同步确认框与“状态已变化”提示挂在条的容器上，而非同步按钮上，刷新使按钮消失时提示不会丢。
- `ProtectionView`：终端条与保护摘要（154pt）仍左右并排；分隔线由固定 36pt 改为随高度填充（上下各留 10pt）。保护摘要内容未改。

## 给 Codex 的事项
- 请 QA 500pt 宽下：正常/不一致/unverified/长账号名与长邮箱/保护设置展开时，标题单行、两个按钮都完整可见，条整体高度与分隔线对齐是否可接受。
- 请 QA：各状态按钮显示、API/未知桌面无同步、busy 禁用、确认框取消不写入、确认框打开后切换/刷新导致 `store.current` 变化时不同步并提示、目标无保存登录时报错且原 CLI 不变、窄窗口下按钮不挤压文字。

## Codex接线与验收（2026-10-28）

最终release构建及签名通过，176项核心测试、97项控制器检查通过。原生只用Store(demo:true)与虚构账号：500pt窗口不一致状态的标题/检查/同步均可读；重新检查保持Business，取消同步保持Business，确认后回显Personal一致，正常状态仍可重新检查；API桌面检查后无同步入口。同步确认目标变更的分支经代码审查，未注入真实账号变化或冒称已做原生瞬态验收。busy禁用亦不冒称捕获过原生瞬态。

[不一致状态](prototypes/local6-cli-sync-mismatch.png) · [虚构同步后](prototypes/local6-cli-sync-matched.png)。这些图片中的保护状态为演示预设，不表示新守卫已交接。
