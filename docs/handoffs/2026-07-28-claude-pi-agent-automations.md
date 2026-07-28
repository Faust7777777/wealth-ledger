# Claude 前端任务：Agent 自动任务与通知

日期：2026-07-28

## 基线

报价多候选紧凑修正与非图片附件 UI 已由 Codex 合入 `origin/feat/pi-agent-control-center`（合并提交 `08ffe67`）。请从该远端分支最新 HEAD 新建或 rebase 前端工作树，再完成本任务；不要回到旧的 `3e34dbc` 基线。后端自动任务提交为 `142951b`，周期总结补充为 `ebe1be9`，真实模型与附件联调修复也已在最新集成线。

## 后端接口

- `GET/POST /v1/agent/automations`
- `PATCH /v1/agent/automations/{automationId}`
- `POST /v1/agent/automations/{automationId}/run`
- `GET /v1/agent/notifications`
- `POST /v1/agent/notifications/{notificationId}/read`

完整字段以 OpenAPI 为准；所有 POST/PATCH 继续使用既有 Idempotency-Key 与 401 同 key 重放。

## UI 要求

1. Agent 面板只放一个低强调通知入口和未读数，不常驻展示任务实现说明。
2. 通知列表 newest-first，显示标题、正文、时间；根据 `action` 前往审核、报价或 DCA，打开后幂等标记已读。
3. Agent 设置中提供四行任务：结构化报价刷新、订阅到期扫描、定投到期检查、周期财务总结。每行只展示开关、频率、下次时间、上次结果和“立即运行”。
4. 频率用易懂预设加自定义小时，范围 1–720；首次运行时间用日期+时间选择器。不要暴露 cron、sidecar、timer、内部错误码。
5. 失败只显示“上次未完成”和重试时间；立即运行 busy 时按钮禁用，同一次点击只能发一个请求。
6. 财务总结通知的 `action=agent` 打开主会话。不要把排队状态写成报告已完成。
7. 不提供“自动采用网页报价”“自动确认订阅扣费”“自动执行定投”的开关，后端也不支持这些行为。
8. fixture 不伪造权威写入成功。真实 smoke 验证创建/关闭/重开计划后仍存在、立即运行不改变 nextRunAt、跨重启到期任务生成 App 内通知。
9. 360/1200/1440 与明暗主题覆盖无任务、四任务、未读通知、失败任务；不要加入防御性常驻文案。
