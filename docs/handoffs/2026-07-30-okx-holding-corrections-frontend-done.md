# OKX 多资产持仓修正 · 前端回执

执行对象：Claude（前端线）。对应修正单
`docs/handoffs/2026-07-29-claude-okx-holding-corrections.md`，
后端回执 `docs/handoffs/2026-07-29-okx-holding-valuation-backend-done.md`。

基线：`origin/feat/integration-self-use @ 77457e8`（含后端 `95016d4`）。
分支：`fix/okx-holding-corrections`（独立工作树 `finwealth-okx-fix`）。
边界核对：对 `server-rs/**`、`agent-service/**`、`docs/contracts/**`、
部署与发布脚本的改动为空。`git diff --check` 零输出。

## 1. P0.1 账户合计使用正确币种

- `HoldingVm` 增加 `accountMarketValue` 并接上 HTTP 映射；
  `marketValue` 保持账本本位币语义（组合/净资产），两者不再互相顶替。
- 新增 `holdingAccountValue(holding)`：账户口径只认 `accountMarketValue`，
  `unpriceable` / `anomaly` 视为无值。`accountHoldingsTotal` 只累加它，
  **不再把 CNY 的 marketValue 与账户折算单位混算**。
- 账户详情行内的折算价值同样切到账户口径，与合计同源。
- `AccountHoldingsTotal.hasAmount`（`pricedCount > 0`）为假时，合计显示 `—`；
  只有至少一项成功计价才显示部分合计，未计入项仍走低强调入口。

## 2. P0.2 刷新失败不再显示内部英文

新增 `lib/features/quote_refresh_messages.dart`（纯函数，可独立测试）：

| 情况 | 文案 |
| --- | --- |
| instrument 缺 provider symbol | `无法识别该资产` |
| instrument 其他报价失败 | `暂时没有可用报价` |
| fx_pair 失败 | `暂时无法换算为 {目标币种}` |
| request / 其他 | `刷新失败，请重试` |

- 目标币种从接口的 `targetId`（`BASE/QUOTE`）解析，**没有硬编码 CNY**；
  形状异常时退化成「暂时无法完成换算」。
- `QuoteRefreshResultVm` 增加结构化 `errorDetails`（targetType / targetId /
  message / retryable）。首页与估值面板的 Snackbar 一律走
  `quoteRefreshResultText`；异常路径用固定文案，**不拼接异常原文**。
- 服务端英文只出现在估值面板新增的低强调「详情」里（默认收起）。

## 3. P0.3 审核后精确刷新账户详情

- 新增纯函数 `holdingGroupAccountIds(group)`：优先
  `holdingAdjustment.accountId`，缺失时退回 movement entry 的 `accountId`。
- 审核页在接受/拒绝后，除既有全局 provider 外，按该集合精确失效
  `accountByIdProvider(accountId)` 与 `holdingsByAccountProvider(accountId)`。
- 回归用例让账户详情与审核页**同屏挂载**，确认后断言详情里的数量从
  `0.25` 原地变成 `0.4`，且 `AccountDetailPage` 从未卸载。

## 4. P0.4 账户表单术语与默认值

- `defaultCurrency` 标签改为**账户折算单位**；`supportedCurrencies` 改为
  **交易计价单位**，旁边一个 `help_outline` 帮助入口，说明只在弹窗里，
  正文没有解释段落。
- 新增 `defaultConversionUnitFor(type)`：exchange / wallet → `USDT`，其余 `CNY`。
  新建时按类型给默认值，切换类型会跟随；用户手动选过之后不再跟随。
- **编辑既有账户不静默改折算单位**：`_currency` 初始化为服务端值，
  切换类型时对 `existing != null` 直接跳过默认值覆盖，必须用户明确保存。

## 5. P1 标的缺失流程

「添加资产」的标的选择器在没有匹配时给出「登记 {代码}」：

- 调 `POST /v1/instruments`（既有确定性接口），前端只传符号、显示名、
  计价单位（取账户折算单位）与 `crypto` 类型，**instrumentId 由服务端分配**；
- 成功后用返回的真实 id 建行并刷新标的列表；
- 失败只给「登记未成功，请重试」，**不建行、不假装成功**。

若后端后续提供专用的 crypto 标的登记接口，只需替换
`_InstrumentPicker._register` 里的一处调用。

## 6. 测试

新增 `test/okx_holding_corrections_test.dart`（16 条，全绿）：

| 修正单必测 | 用例 |
| --- | --- |
| 1 accountMarketValue=USDT 时只显示 USDT 合计 | `只累加 accountMarketValue…`、`账户详情只显示 USDT 合计…` |
| 2 全部不可计价合计为 `—` | `全部不可计价：合计为 — 而不是 0`、`界面显示 —，且没有 0 合计` |
| 3 部分可计价 | `一项可计价、一项缺报价：部分合计 + 1 项入口` |
| 4 接口返回内部英文 | `估值面板刷新失败：界面与 Snackbar 都没有英文实现细节`、`刷新抛异常：不拼接异常原文` |
| 5 快照确认时详情保持挂载 | `账户详情保持挂载：确认后数量原地更新` |
| 6 360 宽无 overflow | `360 宽：多资产列表 + 估值弹层 + 错误态` |

另有映射与纯函数用例（错误文案矩阵含 `ETH/USDT` 证明币种不硬编码、
wire→VM 结构化字段、账户推导优先级、折算单位默认值矩阵、编辑不静默改）。

`test/holding_snapshot_test.dart` 增加 2 条：登记资产成功（断言 id 来自服务端、
不由前端生成）与登记失败（不建行）。既有用例里 BTC 的 fixture 补上
`accountMarketValue`——这是账户口径切换后的必要适配，不是放松断言。

## 7. 门禁实际结果

- `dart format --output=none --set-exit-if-changed lib test integration_test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：**436 passed / 92 skipped / 0 failed**。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：通过。
- `pwsh tools/package_remote_android.ps1 -CheckReadinessOnly`：
  `Android server client readiness passed (endpoint mode: runtime)`。
- `git diff --check`：零输出。
- 视觉预览：`PREVIEW_GOLDENS=1 ... --update-goldens` 81 条通过。
  `account_multi_asset_narrow_{light,dark}` 等已按账户口径重生成并核验：
  合计为 `1,302.10 USDT`（= 1250 + 52.10），ETH 不可计价时是「1 项待补报价」+
  「暂无估值」，数量仍完整可见。

### 两项门禁被本机环境阻断（非本次改动）

- `pwsh tools/frontend_local_server_smoke.ps1`：前 8 个联调用例通过
  （含多资产持仓快照），最后两个失败：
  `local_server_loan_interest_integration_test` 与
  `local_server_ai_text_integration_test`，报
  `SocketException: Write failed (errno = 10053)`（连接被本机软件中止）。
- `pwsh tools/frontend_agent_smoke.ps1`：Rust 服务与 agent 都已启动并监听，
  但脚本的 `Invoke-RestMethod` 就绪探测 100 次全部失败 →
  `Agent proxy did not become ready.`

判为环境问题的依据：

1. 同样两个联调用例在 `finwealth-holding-snapshot` 工作树里同样失败，
   而那份代码今天早些时候跑通过同一个 smoke；agent smoke 在
   `finwealth-agent-conv` 工作树也同样失败。三个工作树表现一致。
2. 用 `curl --noproxy '*'` 直接打同一个本机服务，
   `/v1/health`、`/v1/liability-positions`、`/v1/ai/proposals/pending`
   都返回 200，服务端 stderr 为空、进程未退出。
3. 本机现在开着系统代理 `127.0.0.1:7890`（`HTTP_PROXY` / `HTTPS_PROXY`
   也已设为该地址），清掉子进程的这些环境变量后现象不变，
   说明是网络栈层面的回环拦截。

需要在关闭代理/TUN 后重跑这两条命令确认。前端代码侧未改动任何网络配置。

## 8. 说明

- 账户详情顶部的账户总值仍是服务端 `account.value`（账本本位币，
  当前生产是 CNY），持仓合计是账户折算单位并明确标注「合计（USDT）」。
  修正单只要求持仓合计换口径，这里保持契约语义，两个数字各自带单位。
- 「N 项待补报价」与「N 项未计入合计」的分工沿用上一批：
  全部因缺报价被排除时用前者；存在有价值但币种不一致的项时用后者。

本回执不含 token、密码、认证文件内容或真实账本数据。
