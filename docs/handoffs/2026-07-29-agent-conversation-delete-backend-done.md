# Agent 会话永久删除后端回执

日期：2026-07-29

## 已交付

- 新增 `DELETE /v1/agent/conversations/{conversationId}`，要求 `Idempotency-Key`。
- 只允许删除已归档的非主会话；主会话、活跃会话和仍有运行的会话均拒绝删除。
- 删除会话记录、消息、SSE 事件、相关幂等缓存和 Pi session。
- 会话附件只有在未被其他消息引用时才删除元数据与原始/工作区文件。
- 接口保持用户与账本隔离；同一删除请求重放返回原结果，不会因目标已消失变成 404。

## 验证

- TypeScript build/check：通过。
- Node：29 passed / 0 failed，覆盖主会话拒绝、活跃会话拒绝、消息与附件清理、HTTP DELETE 及幂等重放。
- OpenAPI/contract check：通过。
- 前端任务见 `2026-07-29-claude-agent-conversations-and-quotes.md`。
