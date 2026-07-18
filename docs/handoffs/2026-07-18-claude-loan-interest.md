# Claude 前端后续：贷款利率、应计利息与下一期还款

日期：2026-07-18  
基线：等待 Codex 推送贷款后端提交后，从最新 `origin/feat/subscription-sync-integration` 派生。

## 后端接口

```text
GET   /v1/liability-positions?throughDate=YYYY-MM-DD
GET   /v1/accounts/{accountId}/repayment-schedule?limit=24
PATCH /v1/accounts/{accountId}/liability-terms
POST  /v1/accounts/{accountId}/loan-interest-proposals
```

`liability-positions` 是计算结果的权威来源，返回当前未偿金额、指定日期的应计利息，以及下一期合同计划金额的预计利息与本金拆分。前端不得自行计算。

## 前端范围

1. 仅在贷款/负债账户详情提供低强调「贷款条款」入口。
2. 条款表单包括贷款类型、年利率、固定/浮动、360/365、起息日、到期日、还款起始日、下次还款日、月计划金额和付款账户。
3. 年利率按百分比输入；例如 `3.65%` wire 发送 `0.0365`。
4. 详情展示剩余债务、截至日期、应计利息、下次还款日、计划金额、预计本金和预计利息。
5. 「记录利息」创建待审核候选；pending 时禁用重复提交与条款编辑。确认/拒绝后刷新账户、负债、概览、流水、AI pending 和 liability positions。
6. 浮动利率是用户维护当前利率，不做 LPR 自动抓取入口，不显示成已自动同步。
7. 400 展示字段原因；409 提示数据已变化或已有待确认利息；网络失败保留表单。
8. 新增 wire movement type `loan_interest` → `MovementType.loanInterest`，流水与审核标题显示「贷款利息」；不得继续落入当前 unknown→adjustment 兜底。
9. 账户详情增加可折叠的还款计划列表，逐期显示日期、付款、本金、利息和期末债务；按 `hasMore` 继续请求更大 limit，`balloon` 只显示为「到期还款」。

## 文案边界

- 不增加“仅供参考”“系统不会猜测”“请自行核对”“这只是资产统计”等常驻解释。
- 不把 `dayCountBasis`、wire 小数、pending pointer、幂等键等工程词直接显示给用户。
- 360/365 可使用简短选项名；需要解释时放在字段旁的小型信息入口内，不占常驻正文。

## 必测

1. 当前债务 400 CNY、年利率 36.5%、365、2026-01-01 至 2026-01-31：应计 12 CNY。
2. 下次还款日 2026-02-01、计划 100 CNY：预计利息 12.4、预计本金 87.6；不得误用查询截止日的 12。
3. 确认前债务仍为 400，确认后为 412；付款账户不变。
4. 拒绝后 pending 清除且可重新创建；重复幂等请求不产生第二条候选。
5. `loan_interest` 映射、流水详情和审核卡片不得显示成「调整」。
6. 两期计划应为：首期利息 12.4/本金 87.6/期末 312.4；第二期利息 8.7472/本金 91.2528/期末 221.1472。
7. 360/1200 宽度无溢出；百分比与 wire 小数映射有回归测试。

只改 Flutter 与前端测试，不改 Rust、OpenAPI、账本格式或部署。
