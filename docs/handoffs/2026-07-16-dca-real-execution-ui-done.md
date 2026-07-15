# 2026-07-16 DCA 真实成交记录表单 · 完成回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-16-claude-dca-real-execution-ui.md`。

基线：`origin/feat/subscription-sync-integration`（HEAD `0949ba5` = 任务单所述
`44d2d3a` + 任务单文档本身）。分支：`fix/dca-real-execution-ui`，独立工作树
`C:\Users\15892\projects\finwealth-dca-execution`（未动 Codex 集成工作树）。
未修改 `server-rs/**`、`docs/contracts/**`、部署配置或生产数据；未恢复旧的无
body 调用；不下单、不自动确认、无后台 timer。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `e293051` | DcaExecutionInput 契约适配 + 成交表单 + 13 条测试 + 真实联调 + golden |

最终提交为本回执 docs 提交（含 smoke 完成语措辞小修）。远端分支：
`origin/fix/dca-real-execution-ui`。合并、重新打包与生产部署归 Codex。

## 2. 数据层（任务单 §3）

- `DcaExecutionInput`（不可变 VM：holdingAccountId/quantity/totalCost/
  quoteCurrency/executedAt?）。
- `DcaRepository.markExecutedAsProposal(Id reminderId, DcaExecutionInput input)`。
- `LocalServerDcaRepository`：POST
  `/v1/dca/reminders/{id}/mark-executed-as-proposal`，body 按 openapi
  `DcaExecutionInput`；`executedAt` 为空时不发送该键。继续复用
  `DevApiClient.postData()` 幂等键与 401 单飞重放（重放复用同一 key，有测试）。
- `real_local` 保持 `UnsupportedError`；`debug_fixture` 原本假成功
  （空实现），已改为抛 `UnsupportedError`，不再伪造真实成功。

## 3. UI（任务单 §4）

投资页「记录已执行」→ 先 `await ref.read(accountsProvider.future)` 取账户并过滤
`balanceMode ∈ {holdings, mixed}` 且未归档 → 打开 `DcaExecutionDialog`（内容宽
380、高约束 ≤60% 屏内滚动）→ 用户确认才发请求：

1. 持仓账户：只列过滤后账户，显示名称；切换账户时报价币种跟随其
   `defaultCurrency`（仍可改）。
2. 实际数量：**空值**，绝不预填计划金额；hint「如 10 或 0.5」。
3. 实际总成本：默认 `reminder.plannedAmount.amount`，可修改；币种后缀为
   `plannedAmount.currency`（资金账户币种由后端读取，前端不传资金账户）。
4. 报价币种：默认所选持仓账户 `defaultCurrency`，可修改。
5. 成交时间：不展示（省略，服务端取当前时间）。
6. 无可用持仓账户：提示「请先创建证券账户或其他投资账户」，无确认按钮、
   不发请求。
7. 校验复用 `amountError`（必填、>0、≤8 位小数、纯字符串不经 double），
   数量或成本非法时「确认记录」禁用。
8. 提交期间提醒卡片按钮禁用（busy）；成功后失效
   `dueRemindersProvider`/`dcaPlansProvider`/`overviewProvider`/`aiPendingProvider`，
   SnackBar「已生成待确认记录，见 AI 待确认」；409 →「本期已有待确认记录，
   请到 AI 审核处理」，不伪造成功。无常驻解释性段落。

## 4. 测试（任务单 §5 全覆盖，`test/dca_execution_test.dart` 13 条全绿）

1. 映射五字段完全正确（数量 10 ≠ 成本 200.00）+ 幂等键；2. `quantity=10` 时
body 不把 200 写进 quantity、`executedAt` 可省略；3. 401 刷新重放复用同一
Idempotency-Key；4. 点击「记录已执行」只开表单、确认前零 POST；5. 账户选择器
只显示 holdings/mixed（cash/liability/archived 均不出现）；6. 数量空/0/负数/
9 位小数不可提交；7. 总成本空/0/负数/9 位小数不可提交；8. 无持仓账户引导创建
且不发请求；9. busy 期间重复点击不产生第二次调用；10. 成功后四类 provider
全部重算（dueReminders/dcaPlans 页面直接观察、overview/aiPending 隐藏 watcher
计数）且提醒消失；10b. 409 显示「本期已有待确认记录」、无成功文案；
11. 1200×800 与 1440×900 下对话框表面 ≤480 宽、≤75% 屏高、无溢出。

真实联调（`test/local_server_dca_integration_test.dart`，任务单 §5.12）：
真实服务上建资金账户（500.00 CNY）+ 持仓券商账户 → 建计划（planned 200.00、
nextDueDate 过去）→ due 提醒出现 → 提交成交（投入 200、数量 10）→ **确认前**
资金余额 500.00 不变、`/v1/holdings` 无持仓 → AI pending 恰好新增 1 个候选组 →
确认后资金 300.00、持仓 `quantity=10`、`costBasisTotal=200.00`、该提醒从 due
列表消失。

## 5. 门禁实际结果（任务单 §6 全部运行，无未运行项）

- `dart format --output=none --set-exit-if-changed lib test`：通过（0 处需改）。
- `flutter analyze`：No issues found。
- `flutter test`：**134 passed / 23 skipped / 0 failed**（skipped = 19 golden
  预览[仅 PREVIEW_GOLDENS=1] + 4 真实联调[仅 smoke 注入 env]）。
- `pwsh tools/frontend_local_server_smoke.ps1`：**通过**（cargo 构建当前源码
  起服，订阅×2 + 账户 + DCA 共 4 条联调串行全绿）。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：**通过**，
  `Windows self-use package readiness passed`。

## 6. 视觉核验结论

`dca_execution_dialog_dark.png`（真实主题+Noto 字体离屏渲染）已肉眼核验：
数量字段为空并聚焦、成本默认 200.00 CNY、报价币种跟随所选账户（USD）、
「确认记录」在数量为空时禁用、对话框紧凑无巨型弹层。桌面尺寸另有 widget 断言
（测试 11）。真机交互截图沿用上一轮结论：桌面被用户占用时不抢焦点，
建议用户在重新打包后的自用包里顺手目验「记录已执行」流程。

本回执不含 token、密码、认证文件内容或真实账本数据。
