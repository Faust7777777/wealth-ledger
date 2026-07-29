import { randomUUID } from "node:crypto";
import { defineTool, type ToolDefinition } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { StateStore } from "./state-store.js";
import type { AgentConversation, AgentQuoteCandidate } from "./types.js";

const POSITIVE_DECIMAL = /^(?:0|[1-9][0-9]*)(?:\.[0-9]{1,8})?$/;
const CURRENCY = /^[A-Z0-9]{2,12}$/;
const RFC3339 = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/;

function validPositiveDecimal(value: string): boolean {
  return POSITIVE_DECIMAL.test(value) && !/^0(?:\.0+)?$/.test(value);
}

function cleanText(value: string, max: number): string {
  return value.replace(/\s+/g, " ").trim().slice(0, max);
}

function validSourceUrl(value: string): boolean {
  if (value.length > 2_048) return false;
  try {
    const parsed = new URL(value);
    return (
      (parsed.protocol === "https:" || parsed.protocol === "http:") &&
      !parsed.username && !parsed.password
    );
  } catch {
    return false;
  }
}

export async function suggestQuoteCandidate(
  store: StateStore,
  conversation: AgentConversation,
  input: Record<string, unknown>,
): Promise<AgentQuoteCandidate> {
  const kind = input.kind;
  const asOf = typeof input.asOf === "string" ? input.asOf.trim() : "";
  const source = typeof input.source === "string" ? cleanText(input.source, 120) : "";
  const sourceUrl = typeof input.sourceUrl === "string" ? input.sourceUrl.trim() : "";
  if (
    (kind !== "instrument" && kind !== "fx") ||
    !RFC3339.test(asOf) || Number.isNaN(Date.parse(asOf)) ||
    !source || !validSourceUrl(sourceUrl)
  ) {
    throw new Error("invalid_agent_quote_candidate");
  }
  const timestamp = new Date().toISOString();
  const shared = {
    id: `aqc_${randomUUID()}`,
    userId: conversation.userId,
    ledgerId: conversation.ledgerId,
    asOf,
    source,
    sourceUrl,
    status: "suggested" as const,
    createdAt: timestamp,
    updatedAt: timestamp,
  };
  let candidate: AgentQuoteCandidate;
  if (kind === "instrument") {
    const instrumentId = typeof input.instrumentId === "string"
      ? input.instrumentId.trim()
      : "";
    const price = typeof input.price === "string" ? input.price.trim() : "";
    const currency = typeof input.currency === "string" ? input.currency.trim() : "";
    if (!instrumentId || !validPositiveDecimal(price) || !CURRENCY.test(currency)) {
      throw new Error("invalid_agent_quote_candidate");
    }
    candidate = { ...shared, kind, instrumentId, price, currency };
  } else {
    const baseCurrency = typeof input.baseCurrency === "string"
      ? input.baseCurrency.trim()
      : "";
    const quoteCurrency = typeof input.quoteCurrency === "string"
      ? input.quoteCurrency.trim()
      : "";
    const rate = typeof input.rate === "string" ? input.rate.trim() : "";
    if (
      !CURRENCY.test(baseCurrency) || !CURRENCY.test(quoteCurrency) ||
      baseCurrency === quoteCurrency || !validPositiveDecimal(rate)
    ) {
      throw new Error("invalid_agent_quote_candidate");
    }
    candidate = { ...shared, kind, baseCurrency, quoteCurrency, rate };
  }
  return store.update(conversation.userId, (state) => {
    const existing = state.quoteCandidates.find((item) =>
      item.ledgerId === candidate.ledgerId &&
      item.status === "suggested" &&
      item.kind === candidate.kind &&
      item.instrumentId === candidate.instrumentId &&
      item.price === candidate.price &&
      item.currency === candidate.currency &&
      item.baseCurrency === candidate.baseCurrency &&
      item.quoteCurrency === candidate.quoteCurrency &&
      item.rate === candidate.rate &&
      item.asOf === candidate.asOf &&
      item.sourceUrl === candidate.sourceUrl
    );
    if (existing) return { ...existing };
    state.quoteCandidates.push(candidate);
    return { ...candidate };
  });
}

export function createQuoteCandidateTools(
  store: StateStore,
  conversation: AgentConversation,
): ToolDefinition[] {
  return [defineTool({
    name: "finwealth_suggest_quote",
    label: "建议报价",
    description:
      "把网页中找到的单个标的报价或汇率保存为待用户审核的候选。它不会改变估值；必须提供网页来源、报价时间和定点十进制数值。",
    promptSnippet: "把有明确来源和时间的网页报价整理成待审核候选。",
    promptGuidelines: [
      "先用 finwealth_query 获取真实 instrumentId、计价单位和缺失报价，不要虚构内部 ID。",
      "网页结果只能调用 finwealth_suggest_quote，不能直接调用结构化报价刷新或声称已经更新估值。",
      "每个候选只包含一个报价或一个汇率；来源 URL 必须是实际读取的 http/https 页面。",
    ],
    parameters: Type.Union([
      Type.Object({
        kind: Type.Literal("instrument"),
        instrumentId: Type.String({ minLength: 1, maxLength: 128 }),
        price: Type.String({ pattern: "^(?:0|[1-9][0-9]*)(?:\\.[0-9]{1,8})?$" }),
        currency: Type.String({ minLength: 2, maxLength: 12 }),
        asOf: Type.String({ description: "RFC3339 报价时间" }),
        source: Type.String({ minLength: 1, maxLength: 120 }),
        sourceUrl: Type.String({ minLength: 8, maxLength: 2048 }),
      }),
      Type.Object({
        kind: Type.Literal("fx"),
        baseCurrency: Type.String({ minLength: 2, maxLength: 12 }),
        quoteCurrency: Type.String({ minLength: 2, maxLength: 12 }),
        rate: Type.String({ pattern: "^(?:0|[1-9][0-9]*)(?:\\.[0-9]{1,8})?$" }),
        asOf: Type.String({ description: "RFC3339 报价时间" }),
        source: Type.String({ minLength: 1, maxLength: 120 }),
        sourceUrl: Type.String({ minLength: 8, maxLength: 2048 }),
      }),
    ]),
    executionMode: "sequential",
    async execute(_id, params) {
      const candidate = await suggestQuoteCandidate(
        store,
        conversation,
        params as Record<string, unknown>,
      );
      return {
        content: [{
          type: "text",
          text: JSON.stringify({
            ok: true,
            data: {
              id: candidate.id,
              status: candidate.status,
              approvalRequired: true,
            },
          }),
        }],
        details: {},
      };
    },
  })];
}
