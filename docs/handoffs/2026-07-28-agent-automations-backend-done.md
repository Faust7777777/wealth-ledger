# Pi Agent 自动任务与通知后端回执

日期：2026-07-28

功能提交：`142951b feat(agent): schedule reminders and in-app notifications`

周期总结：`ebe1be9 feat(agent): schedule periodic financial summaries`

## 已实现

1. 持久化自动任务：`quote_refresh`、`subscription_due_scan`、`dca_due_check`、`financial_summary`。每账本每类最多一个，可配置 1–720 小时间隔、首次时间和启用状态。
2. Node sidecar 每分钟检查到期任务，启动后也会补一次检查；服务重启后从账号状态恢复，不依赖内存 timer 保存计划。
3. 结构化报价任务调用现有 provider，不采用网页候选；正常刷新不制造通知，存在 provider 错误时才提醒。
4. 订阅任务调用现有 bounded due-scan，只生成待审核扣费候选，不扣余额、不推进日期；有新增、阻塞或剩余项时通知。
5. DCA 任务只读取到期提醒，不下单、不自动标记完成。
6. 财务总结任务在主会话排队一个只读报告请求；按日/周/月概括消费、订阅、投资与建议，不创建或确认账务记录。
7. 失败任务记录错误状态，生成简短通知并在一小时后重试；停机期间不会逐个补跑历史周期。
8. 支持立即运行且不改变下次计划。所有 POST/PATCH 均持久化幂等；计划和通知按账号/账本隔离。
9. App 内通知支持 newest-first 查询与幂等已读；最多保留 2000 条。

## API

- `GET/POST /v1/agent/automations`
- `PATCH /v1/agent/automations/{automationId}`
- `POST /v1/agent/automations/{automationId}/run`
- `GET /v1/agent/notifications`
- `POST /v1/agent/notifications/{notificationId}/read`

## 验证

- Node TypeScript check/build：通过；19 passed / 0 failed。
- OpenAPI/contract check：通过，93 paths / 168 schemas。
- 覆盖持久化下次运行、无重复补跑、失败重试、手动运行不改计划、HTTP 幂等、跨账本通知隔离，以及三个 Rust 接口的请求映射。

## 尚未实现

- Flutter 自动任务设置和通知入口。
- 系统级 Android/Windows push；当前是 App 内通知。
- 真实模型生成周期报告的端到端验证仍待模型配置；状态机和主会话排队已实现。
