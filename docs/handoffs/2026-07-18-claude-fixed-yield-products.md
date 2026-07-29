# Claude 前端后续：固定收益产品利率与计息

日期：2026-07-18  
基线：等待 Codex 推送固定收益后端提交后，从最新 `origin/feat/subscription-sync-integration` 派生。

## 后端接口

```text
GET   /v1/yield-positions?throughDate=YYYY-MM-DD
PATCH /v1/holdings/{holdingId}/yield-terms
POST  /v1/holdings/{holdingId}/interest-proposals
```

条款字段：本金与币种、年利率、固定/浮动、单利/复利、360/365、复利周期、起息日、到期日、收款账户。

## 前端范围

1. 在持仓详情提供低强调「收益条款」入口；没有条款时可配置，有条款时展示并编辑。
2. 年利率按百分比输入，例如用户输入 `3.65%`，wire 发送 `0.0365`；不得混淆百分数和小数。
3. 单利固定发送 `compoundingFrequency=none`；复利必须选择月、季或年。
4. 展示本金、年利率、起息日、到期日、截至日期、应计利息和状态。
5. 「记录利息」提交 throughDate，成功只显示 `已加入待确认`；pending 时禁用重复提交和条款编辑。
6. 确认/拒绝后失效 yield positions、holding、账户、概览、流水和 AI pending。
7. 400 显示字段原因，409 显示数据已变化或已有待确认利息；网络失败保留表单。

## 文案边界

- 不增加“只是估算”“不会自动入账”“后端计算”等常驻解释。
- 页面只显示条款、计算结果、状态和真实失败原因。
- 不使用“投资建议”等防御性文案。

## 必测

1. 10000 CNY、3.65%、365、2026-01-01 至 2026-01-31：应计 30 CNY。
2. 月复利结果高于同名义利率单利，前端只展示服务端结果，不自行计算。
3. proposal 确认前收款余额不变，确认后增加；本金 holding quantity 不变。
4. duplicate pending 返回 409。
5. 360/1200 宽度无溢出；百分比与 wire 小数映射有回归测试。

只改 Flutter 与前端测试，不改 Rust、OpenAPI、账本格式或部署。
