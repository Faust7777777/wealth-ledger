# Claude 前端后续：AI 文本整理真实 provider

日期：2026-07-18
基线：等待 Codex 推送 AI provider 提交后，从最新 `origin/feat/subscription-sync-integration` 派生。

## 后端行为

接口不变：

```text
POST /v1/ai/proposals/from-text
GET  /v1/ai/proposals/pending
POST /v1/ai/atomic-groups/{atomicGroupId}/approve
POST /v1/ai/atomic-groups/{atomicGroupId}/reject
POST /v1/ai/atomic-groups/{atomicGroupId}/edit
```

- provider 默认关闭；此时纯文本返回不可确认的「待补全」候选。
- provider 显式开启后，明确的单账户收入/支出文本可以直接生成结构化候选。
- 无论 provider 是否成功，确认前都不改变余额；approve 仍走现有服务端校验。
- 当前 AI 范围只有单账户 `income|expense`。转账、投资、贷款、订阅继续走专用表单和接口。

## 前端范围

1. 增加简洁的文本输入入口和提交 busy 状态；成功后直接进入现有 AI Review。
2. 有结构化 movement 时展示标题、账户、金额、币种和时间，提供确认、编辑、拒绝。
3. 无结构化 movement 时只显示「待补全」和编辑入口，不显示工程原因、provider 名、schema、prompt 或环境变量。
4. 503 错误只显示简短失败状态和重试按钮；不要把 `openai_responses`、上游状态码或配置字段常驻展示。
5. `source.modelName` 仅用于诊断详情，不放在候选主卡片。
6. 删除/禁止以下常驻文案：
   - “AI 不会直接写账”
   - “本地模式不会猜金额”
   - “这只是候选/仅供参考”
   - “请自行核对”

## 刷新范围

创建、确认、编辑或拒绝后刷新：

- AI pending 与首页 pending count
- movements/recent
- 涉及账户
- overview

## 必测

1. 「午餐 18 元」且只有一个 CNY 现金账户：生成 expense 18 CNY 候选。
2. 确认前余额不变，approve 后才减少 18。
3. 金额或账户不明确：显示待补全，不能直接 approve。
4. 503 保留原文本并允许重试。
5. 相同幂等键重放同一 proposal，不重复生成或重复调用 provider。
6. defensive copy scan 覆盖上面列出的禁用短语。

只改 Flutter 与前端测试，不改 Rust、OpenAPI、部署脚本或 provider 配置。
