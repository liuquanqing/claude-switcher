# CCSwitcher 的 CLI 登录保存与权限比较

R-ID：R-20261027-002-cli-login-storage。日期：2026-10-27。

状态：子任务调查线索经主会话独立源码复核后的本地设计结论；不是登录迁移、真机验收或正式 BP 接受。本轮没有读取真实令牌、调用认证状态命令、修改钥匙串、重启或切换实际账号。用户报告已用原版完成一次切换，属于用户使用反馈，不替代我们的验证。

## local.5 实现进展（后续更新）

以下调研正文保留 local.3/local.4 当时事实，不能当作 local.5 当前实现说明。local.5 已补默认 CLI 身份/组织配对、备份分类、写前核验、回读和失败恢复；保留原生 Keychain 更新及每档案独立备份。最新功能与验收状态见 [离线对比说明](功能对比说明.html) 与 [开发记录](开发与验证.md)。

正常从本软件切号联动同步默认 CLI；用户在外部改号后，经过核验确认不一致才提供同步补救。准备阶段无法确认时，允许用户明确选择仅切桌面，CLI 保持原样；不会自动降级或伪称同步成功。没有可用登录的目标仍需用户在官方 CLI 登录，不能从桌面生成凭据。已运行 CLI 任务不受托管，shell 环境和项目级配置不在全局核验能力内。


## 结论

保留当前的保存基础，补齐识别和验证，不整体照搬 CCSwitcher。它的优势主要是 CLI 登录生命周期处理较完整，不能归结为“权限更科学”。我们的原生钥匙串更新、每账号独立条目、读取失败就停止，这些做法值得保留；但现状还不能称为完整验收、无需改进。

本次只比较用户指定的 [XueshiQiao/CCSwitcher](https://github.com/XueshiQiao/CCSwitcher)，不是另一个 CC Switch。

## 版本与证据范围

- 对方源码固定到 `v2.1.0`：`efff246d4e3a12ff064eae1431b9e9126bd0302c`，与本机应用的版本号一致；这不等于已做二进制与源码的可重复构建鉴定。
- 本地维护版基线：`a7adb33` / `v1.3.0-local.3`。当前钥匙串和 CLI 代码在 `App/main.swift`，身份匹配逻辑在 `Sources/SwitcherCore/Safety.swift`。
- 只运行 `claude --version` 确认命令行版本为 `2.1.310`。没有运行 `claude auth status`：对方源码把它用于刷新，不能把它当作绝对无写入副作用的调查命令。
- 签名元数据只读检查显示，已安装 CCSwitcher 使用 Developer ID 与 hardened runtime。本地维护版构建脚本使用 ad-hoc 签名；没有实际比较授权弹窗次数。

## 权限和保存机制

| 比较项 | CCSwitcher v2.1.0 源码 | 当前维护版 | 判断 |
|---|---|---|---|
| OAuth 登录授权 | 新账号调用官方 `claude auth login` | 恢复各账号已有 CLI 登录，没有集成新账号 OAuth 流程 | 对方添加账号体验更完整；不能据此说申请了更大的系统权限 |
| 自有凭据备份 | 自有 Keychain 的一条 `all-accounts` JSON，包含各账号 token 和身份块 | 自有 Keychain 中每个档案一条，只保存该账号的 OAuth 与身份块 | 都使用钥匙串；无需改成整库单条 |
| 活动 CLI 凭据写入 | 调用 `security` 子进程，先删再加 | 原生 `SecItemUpdate`，确认不存在才 `SecItemAdd` | 保留现写法，可避免先删除再创建的失败窗口，也不把 token 放进命令参数 |
| 自有备份读取失败 | 区分不存在、拒绝/锁定、解码失败，不把失败当空库 | 区分 `errSecItemNotFound` 与其他错误并抛出 | 基础原则相同；对方用户提示分类值得借鉴 |
| 定制钥匙串访问控制 | 所查备份代码未设置自定义 ACL、AccessControl、Accessible、Synchronizable | 当前也未设置这些定制属性 | 没有证据表明对方用了更强的访问控制策略；不能推断系统默认授权无效 |
| 应用签名 | 发布流程有 Developer ID 签名和公证步骤 | 当前仅本地 ad-hoc 签名 | 签名身份可能影响授权体验，但本轮未验证因果关系；这是发布问题，不是改为调用 `security` 的理由 |

注意：README 前半仍写 `~/.ccswitcher/backups.json`，实际 v2.1.0 已迁到自有 Keychain；不能只凭 README 比较保存介质。其活动条目读取通过子进程将多种失败折成 nil，自有备份读取的错误分类则更严格，两者不能混为一谈。

对方保存并恢复完整的 CLI 钥匙串 JSON；当前设计只交换 `claudeAiOauth`，其余字段沿用读入的活动记录。这更符合本项目不接管其他认证配置的范围，但依然不是跨进程隔离，也不能保证另一个运行进程随后不会覆盖。

两款工具的功能范围也不同。本项目还读取 `Claude Safe Storage` 来解密桌面配置中的用量访问材料；所查 CCSwitcher CLI 保存代码不做这件事。因此，即使授权提示数量不同，也不能直接推断 CLI 保存方案更好或当前多申请了无关权限。该桌面读取与 CLI 登录备份是两条路径。

来源：[KeychainService](https://github.com/XueshiQiao/CCSwitcher/blob/efff246d4e3a12ff064eae1431b9e9126bd0302c/CCSwitcher/Services/KeychainService.swift#L137)、[自有备份读取](https://github.com/XueshiQiao/CCSwitcher/blob/efff246d4e3a12ff064eae1431b9e9126bd0302c/CCSwitcher/Services/KeychainService.swift#L281)、[发布签名流程](https://github.com/XueshiQiao/CCSwitcher/blob/efff246d4e3a12ff064eae1431b9e9126bd0302c/.github/workflows/build.yml#L97)、[官方 CLI 登录调用](https://github.com/XueshiQiao/CCSwitcher/blob/efff246d4e3a12ff064eae1431b9e9126bd0302c/CCSwitcher/Services/ClaudeService.swift#L735)。

## 真正值得借鉴的部分

### 1. 不把身份文件和“上次选中的账号”当作全部事实

CCSwitcher 用账号 ID 和 token 指纹记录自己确认过的配对，识别运行中的 CLI 回写旧身份块的情况。它也明确说明，token 轮换与身份同时变化时仍有歧义，因此这个指纹不是完整隔离或真实性证明。

当前 `refreshCLI()` 优先相信 `.cli-current`，UI 主要据此判断是否与桌面一致。切出前虽会在线核对 token 对应邮箱，能阻止一些错存，但不能保证 UI 一直准确，也没有核对待备份的身份块是否与已确认 token 配对。用户刚在外部工具切过账号，就是需要处理的现实输入。建议先补齐真实身份、不一致与未知三态；是否再采用指纹锚点，应按需要评估，不能直接堆入整套状态机。

来源：[CredentialAnchor](https://github.com/XueshiQiao/CCSwitcher/blob/efff246d4e3a12ff064eae1431b9e9126bd0302c/CCSwitcher/Services/CredentialAnchor.swift#L27)；本地 `App/main.swift` 的 `refreshCLI()`、`switchCLI()`。

### 2. 写之前识别坏备份，写之后再确认

对方拒绝明显没有 OAuth secret 的目标备份；切后检查官方 CLI 状态，失败时尝试还原。当前只做目标 JSON 形状校验，尚无相应的切后身份确认。

建议增加目标凭据有效形状/空值分类和恢复后的验证。缺少目标终端登录应显示“需要登录”，不能把“已恢复保存材料”直接宣称为“终端实际已用该账号”。网络超时或验证未知也不能冒充确认成功。

来源：[目标备份校验与切后确认](https://github.com/XueshiQiao/CCSwitcher/blob/efff246d4e3a12ff064eae1431b9e9126bd0302c/CCSwitcher/Services/ClaudeService.swift#L398)。

### 3. 区分“保存的订阅登录”和“CLI 实际生效的认证来源”

对方处理了环境变量、API 等来源遮蔽订阅身份的情况：本地材料匹配时，只说明保存恢复成功，并另外警告 CLI 实际可能不会使用这个登录。当前维护版未做这层检测。

这值得借鉴，尤其要避免在 API 接管时显示“终端已与桌面同步”并让人误以为请求一定使用订阅。当前调查没有读取用户环境或配置，不能据此断言本机已经出现遮蔽。

来源：[遮蔽处理](https://github.com/XueshiQiao/CCSwitcher/blob/efff246d4e3a12ff064eae1431b9e9126bd0302c/CCSwitcher/Services/ClaudeService.swift#L497)、[官方认证优先级](https://code.claude.com/docs/en/authentication#authentication-precedence)。

## 不应照搬的部分

- 不为减少弹窗，改成把 token 通过 `security` 参数传递或先删除活动条目。
- 不把两次钥匙串/文件写入称为完整原子事务。对方源码也分步骤写入、验证与回滚；源备份失败仍可能继续，某些回滚结果只记日志。
- 不顺带增加非活跃账号的后台直接 OAuth 刷新。对方 v2.1.0 有这项实现，不是所有刷新都委托官方 CLI；它会维护 refresh token 轮换，明显扩大本项目范围。
- 不承诺正在运行的 CLI 在下一次请求必然无缝换号。README 这样描述，但本轮没有验证当前 2.1.310 的运行会话行为；历史 issue 也不能代替当前实测。

来源：[切换失败路径](https://github.com/XueshiQiao/CCSwitcher/blob/efff246d4e3a12ff064eae1431b9e9126bd0302c/CCSwitcher/Services/ClaudeService.swift#L425)、[非活跃备份刷新](https://github.com/XueshiQiao/CCSwitcher/blob/efff246d4e3a12ff064eae1431b9e9126bd0302c/CCSwitcher/Services/ClaudeService.swift#L297)。

## 官方多目录方案是后续选项，不是本轮替换决定

当前官方文档推荐用 `CLAUDE_CONFIG_DIR` 保持多个 CLI 登录，并说明 macOS 钥匙串也按目录区分；也描述了钥匙串写入失败时的文件回退。较早的公开问题曾报告隔离失效，不能用那些旧报告否定当前文档，也不能仅凭文档宣称已在本机验证成功。

如果以后需要不同账号同时运行 CLI，可以单独验证该方案。但它也分开设置、历史、插件等内容，不是只换登录；当前需求是桌面与终端跟随同一订阅账号，不据此立即换架构。现有维护版与对方所查默认路径代码都不能自动代表支持所有自定义目录/回退存储。

来源：[官方多账号与凭据说明](https://code.claude.com/docs/en/authentication#log-in-with-multiple-accounts)。

## 建议的后续顺序

1. 保留当前 Keychain 保存结构、原生更新及失败停止行为。
2. 补“外部改号后的真实识别、目标备份分类、切后确认、API 遮蔽提示”，先用虚构材料和隔离存储测试。
3. 真实登录切换、过期刷新、拒绝授权、同时运行旧 CLI、外部工具切号后再切回等验收，在允许中断工作的独立窗口执行；当前均为 NOT_RUN。
4. 稳定签名发布、完整新账号浏览器登录、并行 CLI 配置目录和后台刷新另行评估，不捆绑进这次 UI 或守护收口。

CCSwitcher 与本项目的备份库彼此独立，不会自动同步。用户当前已在原版中切换账号，后续交接要重新确认实际归属与登录新鲜度；本轮不从原版导入、覆盖或强制切回。两个管理器若持有同一份旧 refresh token，不能依据“非活跃账号只有本工具持有”的假设直接开启后台刷新。

本轮只形成研究结论，未实现上述 CLI 改进。当前 CLI 登录基础可以保留；“真实身份与恢复验证还需补齐”比“现方案已经完美”更准确。

## 后续独立审查

Claude CLI 已对冻结的 local.4 源码完成只读审查，Runner 完整性与来源校验通过，主会话另做逐项回核。结论支持保留原生 Keychain 和每档案独立备份，优先补齐切换前核验、身份/备份配对及恢复后确认，详见 [独立审查](../research/R-20261027-003-improvement-review.md)。这些升级尚未实施，不能把外审完成当成部署或真实切换验收通过。

用户明确补充原版曾实测切换成功、当前仍在使用原版，并已完成 CLI 登录。该经验与新版验收分别记录；本轮没有操作真实账号回切，也未检查旧账号的具体凭据备份。
