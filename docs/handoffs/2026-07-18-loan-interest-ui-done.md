# 2026-07-18 贷款利率 / 应计利息 / 还款计划 UI · 完成回执

执行对象：Claude（前端线）。对应任务单
`docs/handoffs/2026-07-18-claude-loan-interest.md`。

基线：`origin/feat/subscription-sync-integration @ 6941100`（含贷款后端）。
分支：`feat/loan-interest-ui`，独立工作树 `finwealth-loan-interest`。
纯前端 diff：未改 `server-rs/**`、契约、账本格式或部署；`git diff --check`
零输出。

## 1. 提交列表

| commit | 用途 |
| --- | --- |
| `540afdd` | 条款/头寸/还款计划数据层 + LoanRepository 四端点 + loan_interest 类型 + 利率换算 |
| `7ba1052` | 条款表单、账户详情贷款区、记录利息候选、还款计划折叠列表 |
| `fc592bb` | 16 条专项测试 + 真实联调入 smoke + 3 张 golden |
| （最后一笔） | 本回执 |

合并、打包与部署归 Codex；未合集成线、未建 Release。

## 2. 范围落实（任务单逐条）

1. 入口：仅负债账户详情有低强调「贷款条款」入口（未配置时只有这一个按钮）。
2. 条款表单齐 10 字段：贷款类型（助学/房贷/消费/信用卡/其他）、年利率、
   固定/浮动、360/365、起息日、到期日、还款起始日、下次还款日、
   月计划金额（账户币种）、付款账户。
3. 年利率百分比输入：`3.65%` → wire `0.0365`，纯字符串小数点移位
   （`percentToWireRate`/`wireRateToPercent`），编辑态从 wire 回填百分比。
4. 详情展示：剩余债务、应计利息（截至日期）、下次还款日、计划金额、
   预计利息、预计本金——全部来自 `GET /v1/liability-positions`，前端零计算。
5. 「记录利息」→ `POST loan-interest-proposals` 生成待审核候选
   （已加入待确认 + 前往审核）；pending 时重复提交与条款编辑都禁用并提示；
   审核页 approve/reject 刷新链上补了 `liabilityPositionsProvider`
   （账户/负债/概览/流水/AI pending 原有失效保持）。
6. 浮动利率仅一行「利率变化时，在这里更新当前值。」；无 LPR 抓取入口、
   无"已自动同步"表述。
7. 400 显示服务端字段原因（ApiValidationException.userMessage）；409 提示
   数据已变化或已有待确认利息 + 重新加载；网络失败保留表单。
8. `loan_interest` → `MovementType.loanInterest`，流水详情显示「贷款利息」，
   不再落 unknown→adjustment 兜底（映射与 widget 双测试）。
9. 还款计划可折叠、逐期显示日期/付款/本金/利息/期末债务；`hasMore` 时
   「加载更多」按 limit 翻倍继续请求；`balloon` 显示为「到期还款」。

文案边界：无"仅供参考/请自行核对"类常驻解释；`dayCountBasis` 呈现为
「360 天/365 天」选项，说明只在字段旁的点击式 tooltip 内；wire 词、
pending 指针、幂等键不暴露。全部可见字符串通过 defensive_copy_scan 门禁。

## 3. 必测结果（真实 Rust 服务，当前源码构建，临时账本）

`test/local_server_loan_interest_integration_test.dart`（已入 smoke）：

1. 债务 400 CNY、年利率 36.5%、365 基准、2026-01-01 起息：
   `throughDate=2026-01-31` 应计 **12** ✓。
2. 下次还款 2026-02-01、计划 100：预计利息 **12.4**、预计本金 **87.6**
   （与查询截止日的 12 分离，另有映射级断言两值不同）✓。
3. 确认前债务仍 400，确认后 **412**；付款账户余额 1000.00 不变 ✓。
4. 拒绝后 pending 清除且可重新创建（连续两轮验证）；同一
   Idempotency-Key 重放返回同一候选 id（不产生第二条）；新键重复提交 409 ✓。
5. `loan_interest` 映射：确认后的 movement `type == loanInterest`；
   widget 测试断言详情显示「贷款利息」且无「调整」✓。
6. 两期计划：首期 利息 12.4 / 本金 87.6 / 期末 312.4；第二期
   利息 8.7472 / 本金 91.2528 / 期末 221.1472 ✓（真实联调 + 映射测试双份）。
7. 360/1200 宽贷款区无溢出；百分比↔wire 换算回归
   （3.65/36.5/12/0.5/100 双向）✓。

## 4. 门禁实际结果

- `git diff --check`：零输出。
- `dart format --output=none --set-exit-if-changed lib test`：通过。
- `flutter analyze`：No issues found。
- `flutter test`：**203 passed / 42 skipped / 0 failed**
  （skipped = 34 golden 预览 + 8 真实联调）。
- `pwsh tools/frontend_local_server_smoke.ps1`：通过
  （订阅+账户+DCA+投资成交+持仓校准+贷款利息，6 文件 8 用例串行）。
- `pwsh tools/package_release.ps1 -WindowsOnly -CheckReadinessOnly`：
  `Windows self-use package readiness passed`。

## 5. 视觉证据（真实主题 + Noto 字体离屏渲染，逐张肉眼核验）

1. `loan_section_dark.png` / `loan_section_light.png`：贷款区
   400.00/12.00/12.40/87.60 全字段 + 记录利息 + 折叠还款计划入口。
2. `liability_terms_form_dark.png`：条款表单编辑态回填
   （助学贷款、36.5%、固定、365 天、四个日期、100.00 CNY、付款账户），
   360/365 旁只有信息图标无常驻说明。

## 6. 未完成项 / 阻塞

无后端阻塞。围栏外未做：LPR/市场利率自动抓取（任务单明确不做）、
非 monthly 还款频率（契约当前仅 monthly）。

本回执不含 token、密码、认证文件内容或真实账本数据。
