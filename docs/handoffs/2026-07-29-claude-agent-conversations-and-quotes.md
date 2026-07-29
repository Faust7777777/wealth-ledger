# Claude 前端任务单：Agent 会话管理与报价候选刷新

日期：2026-07-29

基线：从最新 `origin/feat/integration-self-use` 新建独立工作树。只修改 Flutter、Flutter 测试、golden 与前端回执；不要修改 `agent-service/**`、`server-rs/**` 或契约。

## P0.1 默认打开最新活跃会话

- `GET /v1/agent/conversations` 已按 `updatedAt` 降序返回活跃和归档会话。
- Agent 面板首次就绪时，选择列表中第一条 `status=active` 的会话，不再优先 `isPrimary=true`。
- 面板已打开且用户主动切换会话后，列表刷新不得把用户强制切回最新会话。
- 新建、恢复会话后可以主动打开该会话；删除当前会话后打开剩余活跃会话中最新的一条。

## P0.2 已归档会话可见、可恢复、可永久删除

- 会话 sheet 分成“当前/其他会话”和紧凑的“已归档 N”入口；不要把所有归档项常驻堆在聊天区。
- 点“已归档 N”进入同一 bottom sheet 内的可滚动列表，每项支持：
  - 恢复：`PATCH /v1/agent/conversations/{id}`，`status=active`。
  - 永久删除：二次确认后调用 `DELETE /v1/agent/conversations/{id}`，必须带新的 `Idempotency-Key`。
- 删除确认只显示会话标题和“永久删除”；不要展示内部 ID、路径、session 文件或解释性长文案。
- 主会话不显示归档或删除动作。后端也会拒绝主会话删除。
- 后端只允许永久删除已经归档的非主会话；收到 409 时刷新列表并显示简短状态。
- Repository 增加 `deleteConversation(Id)`；不要用 PATCH 伪装删除。

## P0.3 Grok 新建报价候选后立即出现入口

- 当前 `agentQuoteCandidatesProvider` 只在首次读取时请求，导致工具创建候选后手机仍看不到“报价建议 N”。
- `run.completed` 与 `run.failed` 后刷新候选；`finwealth_lookup_quote_candidate` / `finwealth_suggest_quote` 完成后也可提前刷新一次。
- App 从后台恢复到前台且 Agent 面板可见时刷新候选。
- 不要轮询、不要后台 timer、不要在聊天区展开卡片；仍保持一条紧凑入口，点击后显示候选 sheet。

## 必测

1. 返回顺序为“新非主会话、旧主会话”时，首次打开新会话。
2. 列表刷新不打断用户当前主动选择。
3. 归档后“已归档 1”可见，恢复后回到活跃列表并自动打开。
4. 永久删除弹二次确认，只发一次 DELETE，幂等键非空；成功后条目消失。
5. 主会话没有删除入口；409 保留列表并重新加载。
6. 10 条归档会话在 360×640 与 720×1280 下可滚动、无 overflow。
7. 模拟工具完成并收到 `run.completed` 后，无需重启即出现“报价建议 1”。
8. 后台恢复刷新候选，但多次 rebuild 不产生请求风暴。

运行 format、analyze、Flutter 全量测试、两个本地 smoke 和 Android/Windows readiness；更新受影响 golden 并逐张核验。
