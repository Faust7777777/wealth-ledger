# 2026-07-27 固定收益条款与计息 · 完成回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-18-claude-fixed-yield-products.md`（清单 §2）。

基线：`origin/feat/subscription-sync-integration @ 0c55498`。
分支：`feat/fixed-yield-ui`，独立工作树 `finwealth-fixed-yield`。
纯前端 diff：`git diff 0c55498..HEAD -- server-rs docs/contracts deploy
tools/contract_check.py` 零输出；`git diff --check` 零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `17e3deb` | 收益条款接入、持仓详情收益区、pending 门控与错误处理 |
| `7f4f89c` | 21 条专项测试 + 真实 Rust 联调 + smoke 增列 |
| `1f9aed0` | 收益区与条款表单 golden 预览 |
| （最后一笔） | 本回执 |

合并、打包与部署归 Codex；未合集成线、未建 Release。

## 2. 逐项完成情况

1. **三个接口全部接入**（新增 `YieldRepository`）：
   `GET /v1/yield-positions?throughDate=`、
   `PATCH /v1/holdings/{holdingId}/yield-terms`、
   `POST /v1/holdings/{holdingId}/interest-proposals`；
   `HoldingVm` 增补 `yieldTerms`；新增 `yieldRepositoryProvider` 与
   `yieldPositionsProvider`；`real_local` / DEMO 只读，写路径直接报不支持。
2. **持仓详情低强调入口**：账户详情每行持仓下方是 `YieldSection`——
   未配置时只有一枚低强调「收益条款」按钮；已配置时展示条款与应计，
   右上角「编辑」进同一表单（新路由 `/holding/:id/yield-terms`）。
3. **年利率按百分比输入**：`3.65` → wire `0.0365`，换算直接复用贷款条款
   那一份 `percentToWireRate`/`wireRateToPercent`（纯字符串小数点移位，
   全程不经 `double`），不新造第二套规则；往返一致有回归测试。
4. **条款字段齐全**：固定/浮动、单利/复利、360/365、月/季/年复利周期、
   起息日、到期日、收款账户、本金与币种。单利强制发
   `compoundingFrequency=none`；切到复利时自动给出可用默认周期，
   且复利不允许 `none`（校验有独立单测）。
5. **只展示服务端结果**：本金、年利率、起息/到期日、截至日期、应计利息、
   状态（到期显示「收益条款 · 已到期」）全部取自 `/v1/yield-positions`；
   前端不做任何收益计算。
6. **「记录利息」只生成待确认**：成功只显示「已加入待确认」+ 前往审核；
   pending 时「记录利息」与「编辑」「保存条款」三处一并禁用，并显示
   已有待确认利息（含截至日期）与前往审核入口。
7. **刷新范围**：提交/保存后失效 `yieldPositionsProvider`、`holdingsProvider`、
   `accountsProvider`、`overviewProvider`、`recentMovementsProvider`、
   `aiPendingProvider`。
8. **错误处理**：400 显示服务端字段原因（`ApiValidationException.userMessage`）；
   409 提示数据已变化并给「重新加载」动作；网络失败保留表单不返回、不清空。

文案边界：未新增「只是估算」「不会自动入账」「后端计算」「投资建议」等
解释性文案；`defensive_copy_scan_test` 全绿。

## 3. 必测结果

真实联调（`test/local_server_yield_integration_test.dart`，已入 smoke）：

1. **必测 1**：10000 CNY、3.65%、365、`2026-01-01 → 2026-01-31` →
   `accrualDays=30`、`accruedInterest=30 CNY`，本金原样 10000。
2. **必测 2**：同名义利率下，月复利在 `2026-12-31` 的应计严格高于单利
   （断言 `compareDecimal(compound, simple) > 0`），前端只展示服务端数字。
3. **必测 3**：提交 proposal 后收款余额保持 `100.00`、本金 holding 数量
   保持 `10000`；`approve` 后收款余额变 `130.00`，holding 数量仍为 `10000`，
   `lastAccruedThrough` 推进到 `2026-01-31`。
4. **必测 4**：已有待确认利息时重复提交返回 409；同一状态下 PATCH 条款
   同样返回 409（与前端的 pending 门控一致）。
5. **必测 5**：360 与 1200 宽度下收益区与条款表单均无 overflow；
   百分比 ↔ wire 小数映射有往返回归测试
   （`3.65↔0.0365`、`0.5↔0.005`、`12↔0.12`、`100↔1`、`2.875↔0.02875`）。

组件/单测（`test/yield_terms_test.dart`，21 条全绿）：利率换算与周期约束、
条款 wire 载荷、头寸读模型映射、低强调入口、服务端应计展示、复利周期展示、
pending 三处门控与前往审核、记录利息成功/409、条款 400/断网、双宽度无溢出。

## 4. 门禁实际结果

- `git diff --check`：零输出。
- `dart format --output=none --set-exit-if-changed lib test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：**230 passed / 46 skipped / 0 failed**
  （skipped = 36 golden 预览 + 10 真实联调）。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过
  （8 文件 10 用例串行，含新增收益联调）。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：
  `Windows self-use package readiness passed`。

## 5. 视觉证据（真实主题 + Noto 字体离屏渲染，逐张肉眼核验）

1. `yield_section_dark.png` / `yield_section_light.png`：本金 ¥10,000.00、
   `3.65% · 单利 · 365 天`、起息日、到期日、`应计利息（截至 2026-01-31）¥30.00`
   与「记录利息」；标题右侧只有低强调「编辑」。
2. `yield_terms_form_dark.png`：本金（后缀 CNY）、年利率（后缀 %）、
   固定/浮动、单利/复利、360/365、起息日、到期日、收款账户与「保存条款」，
   无常驻解释文案。

## 6. 未完成项 / Codex 集成注意事项

- 无后端阻塞。
- 本批与已收编的贷款利息批共用
  `lib/features/liability_terms_validation.dart` 的利率换算函数
  （`yield_terms_validation.dart` 通过 `export ... show` 复用），
  合并时请勿把这两处换算实现拆成两份。
- 新路由 `/holding/:id/yield-terms`；`YieldSection` 挂在账户详情的
  每行持仓下方（当前没有独立的持仓详情页）。
- 联调测试在临时账本里新建两个账户、两个标的与两笔持仓，并推进
  `lastAccruedThrough`；排在 smoke 末尾，不影响先跑的联调文件。

本回执不含 token、密码、认证文件内容或真实账本数据。
