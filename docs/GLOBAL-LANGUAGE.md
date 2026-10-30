# 应用全局语言

## 数据流与偏好

- `Store.appLanguage` 是界面唯一语言来源，支持 `zh` 与 `en`。`PanelViewport` 在父层向主面板注入 SwiftUI 环境，直接渲染的快照入口单独注入；不使用 `.id` 重建视图。
- 复制会话控制器订阅同一个 `Store.appLanguage`。原生菜单、演示窗口和复制会话窗口标题通过语言变更回调更新。
- 正式版使用 `applicationLanguage`。`Store.loadApplicationLanguage(from:)` 接受调用方提供的 `UserDefaults`：新键存在时优先；新键缺失时读取并迁移 `importInterfaceLanguage`，随后移除旧键。
- Demo 仅从预览配置读取初始语言，切换时只改内存，不读写 `UserDefaults`。
- setter 忽略非法值。语言不参与身份核验、守卫、退出、网络判定或会话存储。

## 翻译覆盖

- 首页、账号卡、用量、缓存、重置时间、日期和相对时间。
- CLI 状态、检查说明、同步确认和常用核验消息。
- 保护状态、设置、网络检查、帮助、纳入与停止确认。
- 复制会话、空间选择、确认恢复、备份、撤销以及复制指令中的应用说明。
- 功能统一命名为“复制会话 / Copy sessions”，主操作为“开始 / Start”；完成摘要使用真实目标名称及本次新增、更新数量。
- 应用菜单、编辑菜单、按钮、工具提示和无障碍名称。

`AppLocalization` 管理主应用文案，`SessionTransferLocalization` 管理复制与恢复文案，两者读取同一语言。索引共享范围说明仅在备份预览中按需展示。

## 英文排版

- 主面板保持 500pt，复制会话窗口及其内容保持 680pt 最小宽度。
- CLI 与右侧 164pt 保护列使用紧凑英文状态；仅保护列详情和底部状态允许局部缩放。
- 底部工具按钮、退出和复制操作保持自然尺寸，状态区域优先弹性压缩。
- 不移动添加账号入口，不改变整体布局，不全局缩小字号。

## 原始诊断与数据例外

- 自定义账号名、邮箱、路径、会话标题、聊天原文、命令参数、请求指纹和 receiptID 不做翻译。
- 应用消息仅按已知全文或锚定模板处理。比如复合错误只翻译 `打开 Claude 失败：` 前缀，拼接的系统错误原文保持不变。
- 未匹配的 CLI/系统错误和罕见底层诊断保留原文，避免把用户数据或原始诊断误作可翻译界面字符串。
- 复制指令只本地化已知说明模板；命令、路径和动态数据不变，请求文件与会话存储内容不受语言影响。

## 验证记录

界面与文案由 Kimi CLI 完成，Codex 负责独立审查、隔离测试与原生交互复核。本轮保留了主线 `c70d903` 的“复制会话 / Copy sessions”命名、真实目标及新增/更新分类摘要。当前为本地开发版，未替换正在使用的正式应用，也未发布新安装包。

- 176 项 Core 测试、147 项控制器隔离检查通过，release 构建与 ad-hoc 签名验证通过。
- 中英文应用文案各 266 个键、复制文案各 79 个键；键集合、重复键及插值参数检查通过。
- 用随机命名的独立 `UserDefaults` suite 验证默认值、旧偏好迁移、新键优先、重新读取和无效值；不构造真实账号的 Store。
- 语言切换保留未保存的保护设置和复制页搜索，不改变账号、CLI 观察或守卫判断。全部 12 种安全判断的英文展示均已检查，允许/拦截语义保持不变。
- 原生演示验证中英双向切换、已有复制窗口同步、搜索保留、全选与半选、确认/取消、新增 1 项加更新 1 项、真实目标摘要、备份范围预览、撤销和返回。复制与撤销仅操作临时虚构会话。
- 复制指令的本地化额外验证了命令、引号路径、指纹、实际 receipt 参数和用户名称保持原样。
- 复核了 500pt 主面板及 680pt 复制窗口的英文排版，保护设置、模拟结果与帮助完整可见。临时演示程序已退出。
- 未安装开发版、改真实登录/会话、操作真实守卫或进行网络故障注入。

[验证摘要](prototypes/global-language/validation.json) · [中文主面板](prototypes/global-language/chinese-main.png) · [英文主面板](prototypes/global-language/english-main.png) · [中文复制页](prototypes/global-language/chinese-copy.png) · [英文复制页](prototypes/global-language/english-copy.png) · [英文保护设置](prototypes/global-language/english-protection.png) · [语言菜单](prototypes/global-language/language-menu.png)
