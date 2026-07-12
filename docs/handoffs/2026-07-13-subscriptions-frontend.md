# 2026-07-13 订阅管理前端接线给 Claude

范围：Flutter 只消费后端契约，不修改 Rust、本地账本格式或同步语义。

## 能力与入口

- `GET /v1/ledger/bootstrap` 的 `capabilities.canManageSubscriptions` 控制写入口。
- `GET /v1/subscriptions` 返回全部订阅。
- `GET /v1/subscriptions/upcoming?days=30` 返回截止窗口内到期项，包含已逾期未处理项；`days` 范围 1–365。
- `GET /v1/subscriptions/{id}` 读取详情。
- `POST /v1/subscriptions` 创建；`PATCH /v1/subscriptions/{id}` 编辑。
- `POST /v1/subscriptions/{id}/cancel` 取消未来扣费。
- `POST /v1/subscriptions/{id}/charge-proposal` 生成待确认支出。

所有非 auth 写请求必须发送 `Idempotency-Key`，401 refresh 重放必须复用同一个 key。前端提交 `cc0251a` 已实现该门禁，接线时继续复用现有 `DevApiClient` 写请求路径。

## 页面最小闭环

1. 列表显示名称、服务商、原币金额、周期、下次扣费日和状态。
2. 创建/编辑支持原币金额、付款账户、开始日期、周期、持续时长或结束日期、自动续订和提前提醒天数。
3. `duration` 与 `endDate` 在 UI 中互斥；金额必须大于 0，周期/时长必须是正整数。
4. 月度订阅显示自然月锚点语义，例如 1 月 31 日下一期为 2 月末，再下一期恢复 31 日。
5. “记录本期扣费”只生成 AI 审核区的 `pending_review` 候选，不立即扣余额。
6. 候选确认后刷新订阅与账户；拒绝后仍保留本期到期状态，可再次生成。
7. 有待确认候选时禁用重复生成和取消，并引导用户先去审核。
8. `paused`、`cancelled`、`expired` 不显示未来扣费动作；取消保留历史记录。

## 建议 Repository / ViewModel

在领域命名中增加 `SubscriptionRepository`，至少暴露：

```dart
listSubscriptions()
listUpcomingSubscriptions({int days = 30})
getSubscription(String id)
createSubscription(CreateSubscriptionInput input)
updateSubscription(String id, UpdateSubscriptionInput input)
cancelSubscription(String id)
createChargeProposal(String id)
```

日期字段保持 `YYYY-MM-DD` 的本地日历语义，不要在客户端转成 UTC 瞬间后再截断。金额继续使用十进制字符串，不使用 `double`。

## 前端验收

- USD 订阅可绑定 USD 账户并按原币展示。
- 1 月 31 日月订阅跨 2 月后恢复 31 日锚点。
- 重复点击扣费只产生一个候选；409 显示可恢复提示。
- 确认前余额不变，确认后余额与下次扣费日同时刷新。
- 拒绝后可重新生成；待确认时取消会收到 409。
- dev/mock 模式明确标注非持久化；真实闭环只以 `local_server` 为准。
