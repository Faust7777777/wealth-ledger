import { randomUUID } from "node:crypto";
import { defineTool, type ToolDefinition } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { AgentConversation } from "./types.js";
import { StateStore } from "./state-store.js";

export function createMemoryTools(
  store: StateStore,
  conversation: AgentConversation,
): ToolDefinition[] {
  return [defineTool({
    name: "finwealth_suggest_memory",
    label: "建议记忆",
    description:
      "在同类理解错误反复发生并被用户纠正后，建议一条可复用偏好。只创建待用户确认的建议，不会立即影响后续会话。",
    promptSnippet: "把反复出现的用户纠正整理成待确认的通用记忆。",
    promptGuidelines: [
      "不要学习商户到账户映射；不要记录密码、令牌、完整账单或其他秘密。",
      "只有同类错误反复发生时才建议记忆，且保持为简短通用规则。",
    ],
    parameters: Type.Object({
      content: Type.String({ minLength: 1, maxLength: 500 }),
      reason: Type.String({ minLength: 1, maxLength: 500 }),
    }),
    executionMode: "sequential",
    async execute(_id, params) {
      const timestamp = new Date().toISOString();
      const memory = {
        id: `mem_${randomUUID()}`,
        userId: conversation.userId,
        ledgerId: conversation.ledgerId,
        content: params.content.trim(),
        reason: params.reason.trim(),
        status: "suggested" as const,
        createdAt: timestamp,
        updatedAt: timestamp,
      };
      if (!memory.content || !memory.reason) throw new Error("invalid_agent_memory");
      await store.update(conversation.userId, (state) => {
        state.memories.push(memory);
      });
      return {
        content: [{
          type: "text",
          text: JSON.stringify({
            ok: true,
            data: { id: memory.id, status: memory.status, approvalRequired: true },
          }),
        }],
        details: {},
      };
    },
  })];
}
