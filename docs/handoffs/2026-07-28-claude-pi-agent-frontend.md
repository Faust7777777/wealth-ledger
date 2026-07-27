# Claude 前端任务单：Pi Agent 控制中枢

日期：2026-07-28

## 基线与边界

- 后端分支已推送为 `origin/feat/pi-agent-control-center`（附件/SSE 契约至少包含 `b4a8745`）；先 `git fetch origin`，再以该远端分支最新 HEAD 新建独立工作树。
- Claude 只修改 Flutter `lib/**`、Flutter `test/**`、必要的前端 smoke 和完成回执。
- 不修改 `server-rs/**`、`agent-service/**`、`docs/contracts/**`、`deploy/**`、账本版本或生产配置。
- 这不是 Telegram 集成，也不做 Telegram 式消息映射；只是 App 内原生 Agent 界面。
- App 只访问现有 Rust 公网 origin 下的 `/v1/agent/**`，不得直连 sidecar 的 `8792` 端口。

## 已提供的后端接口

- `GET /v1/agent/status`
- `GET /v1/agent/models`
- `POST /v1/agent/attachments`（multipart `file`，PNG/JPEG/WEBP，15 MiB）
- `GET /v1/agent/attachments/{attachmentId}`（安全元数据，不含服务端路径）
- `GET /v1/agent/attachments/{attachmentId}/content`（原图，用于消息历史与 App 重启后恢复预览）
- `GET /v1/agent/memories`
- `POST /v1/agent/memories/{memoryId}/review`
- `GET/POST /v1/agent/conversations`
- `PATCH /v1/agent/conversations/{conversationId}`
- `GET/POST /v1/agent/conversations/{conversationId}/messages`
- `GET /v1/agent/conversations/{conversationId}/events`（SSE，可用 `after` 或 `Last-Event-ID` 续接）
- `POST /v1/agent/runs/{runId}/cancel`

所有 POST/PATCH 都必须带 `Idempotency-Key`。401 的刷新重放必须复用同一个 key；不得因重试重复发送消息、重复上传或重复审批记忆。完整 wire schema 以 `docs/contracts/openapi_v1.yaml` 为准。

## P0：全局 Agent 入口与会话

1. 在 App 全局提供低强调悬浮入口；Windows 打开右侧栏，Android 打开全屏页。
2. 默认进入后端标记 `isPrimary=true` 的主会话；支持新建、重命名、归档和切换会话。
3. 显示服务端允许的模型并可按会话切换；不显示或编辑 API key、provider 配置路径、环境变量。
4. 消息发送后立即显示 queued 状态，完整消费 `run.queued`、`run.started`、`message.delta`、`tool.started`、`tool.completed`、`run.completed`、`run.failed`。每种事件的正式字段见 OpenAPI。
5. 网络重连从最后 cursor 续接；页面重开先拉消息快照再接 SSE，不能重复拼接 delta。
6. busy 时允许排队发送，但同一次点击只能产生一个请求；提供停止当前运行。

## P0：图片账单

1. 输入区支持选择 PNG/JPEG/WEBP；先上传附件，拿到 `attachment.id` 后再随消息发送 `attachmentIds`。
2. 默认界面只显示缩略图、文件名、移除/重选；不显示 Base64、MIME、哈希、内部路径和上传实现说明。
   已发送或历史消息的缩略图从附件 content 接口恢复，不要求把图片字节持久化在 Flutter 本地。
3. 用户可用自然语言要求整理微信或支付宝账单。后端会把图片原生交给视觉模型；最终账务变更只会出现在现有 AI Review 待审核列表。
4. Agent 返回待审核记录后，提供低强调“前往审核”，并刷新 AI pending；不得在 Agent 页面直接确认账本。

## P1：记忆审批

1. Agent 只能创建 `suggested` 记忆。界面用小卡片或设置页入口展示建议内容与原因。
2. 用户可批准为 `active` 或拒绝为 `rejected`；批准前不得在 UI 中表现为已生效。
3. 不制作商户到账户的映射编辑器。本轮记忆是通用纠错偏好，不是账单映射。
4. 不显示“AI 可能犯错”“不会直接写账”“仅供参考”等常驻防御性文案。

## 状态与错误

- `configured=false`：输入区不可发送，提供简短的“服务器尚未配置模型”；不要伪造回复。
- 401：走现有 token refresh，并复用原 idempotency key。
- 403：简短显示账号无对应能力。
- 409：会话/记忆状态已变化，刷新当前数据。
- 413/400 附件错误：保留已选图片并允许重试。
- 503：保留草稿与附件引用，提供重试。
- 不展示 sidecar、loopback、Pi session path、内部 token、bubblewrap、原始 tool payload 或隐藏 reasoning。
- 已知 tool 名映射为简短中文活动行，例如“正在读取账户…”；未知 tool 统一显示“正在处理…”，不得直接显示内部 tool 名。

## 回归与验收

1. 360、1200、1440 宽无 overflow；Windows 右栏不遮挡主要导航，Android 返回键行为正确。
2. 明暗主题覆盖：空会话、流式回复、tool 事件、图片待发送、无模型、断线重连、记忆建议。
3. Repository mapping 覆盖全部接口、SSE 断线续接、401 同 key 重放、重复点击防抖。
4. fixture/MockClient 不得伪造生产写入成功；可新增前端专用 Agent smoke，复用 `tools/agent_local_smoke.ps1` 的 Rust + Node 启动方式，但不修改后端 smoke。真实 smoke 至少验证 Rust 代理可达、会话持久化、附件上传与回读、无模型时 503 fail-closed。
5. 跑现有 format/analyze/test/真实 Rust smoke/readiness 门禁并新增完成回执。
