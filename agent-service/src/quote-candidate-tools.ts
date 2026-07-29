import { randomUUID } from "node:crypto";
import { defineTool, type ToolDefinition } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { FinwealthClient } from "./finwealth-client.js";
import { quoteCandidateInputsFromLookup } from "./finwealth-client.js";
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
  owner: Pick<AgentConversation, "userId" | "ledgerId">,
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
    userId: owner.userId,
    ledgerId: owner.ledgerId,
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
  return store.update(owner.userId, (state) => {
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

function candidateTargetKey(input: Record<string, unknown>): string {
  if (input.kind === "instrument") {
    return `instrument:${String(input.instrumentId ?? "").trim()}`;
  }
  return `fx:${String(input.baseCurrency ?? "").trim().toUpperCase()}/${
    String(input.quoteCurrency ?? "").trim().toUpperCase()
  }`;
}

function lookupRequest(input: Record<string, unknown>): Record<string, unknown> {
  if (input.kind === "instrument") {
    return { instruments: [String(input.instrumentId ?? "").trim()] };
  }
  return {
    currencyPairs: [{
      baseCurrency: String(input.baseCurrency ?? "").trim().toUpperCase(),
      quoteCurrency: String(input.quoteCurrency ?? "").trim().toUpperCase(),
    }],
  };
}

export function createQuoteCandidateTools(
  store: StateStore,
  conversation: AgentConversation,
  client: Pick<FinwealthClient, "lookupStructuredQuotes">,
): ToolDefinition[] {
  const fallbackEligible = new Set<string>();
  const targetParameters = Type.Union([
    Type.Object({
      kind: Type.Literal("instrument"),
      instrumentId: Type.String({ minLength: 1, maxLength: 128 }),
    }),
    Type.Object({
      kind: Type.Literal("fx"),
      baseCurrency: Type.String({ minLength: 2, maxLength: 12 }),
      quoteCurrency: Type.String({ minLength: 2, maxLength: 12 }),
    }),
  ]);
  const lookup = defineTool({
    name: "finwealth_lookup_quote_candidate",
    label: "查询结构化报价",
    description:
      "从 Finwealth 配置的确定性行情源查询一个标的或汇率，并保存为待审核候选。它不会改变估值；只有明确查不到后才能改用网页来源。",
    promptSnippet: "优先从结构化来源查询报价或汇率并生成待审核候选。",
    promptGuidelines: [
      "任何报价请求都先调用本工具；不要先搜索网页。",
      "成功只表示生成待审核候选，不表示报价已经写入或估值已经更新。",
      "工具明确返回 fallbackAllowed=true 后，才可搜索网页并调用 finwealth_suggest_quote。",
    ],
    parameters: targetParameters,
    executionMode: "sequential",
    async execute(_id, params, signal) {
      const input = params as Record<string, unknown>;
      const key = candidateTargetKey(input);
      try {
        const response = await client.lookupStructuredQuotes(
          lookupRequest(input),
          signal,
        );
        const inputs = quoteCandidateInputsFromLookup(response);
        const candidates = [];
        for (const candidateInput of inputs) {
          candidates.push(
            await suggestQuoteCandidate(store, conversation, candidateInput),
          );
        }
        if (candidates.length === 0) fallbackEligible.add(key);
        else fallbackEligible.delete(key);
        return {
          content: [{
            type: "text",
            text: JSON.stringify({
              ok: true,
              data: {
                createdCount: candidates.length,
                candidateIds: candidates.map((candidate) => candidate.id),
                approvalRequired: candidates.length > 0,
                fallbackAllowed: candidates.length === 0,
              },
            }),
          }],
          details: {},
        };
      } catch {
        fallbackEligible.add(key);
        return {
          content: [{
            type: "text",
            text: JSON.stringify({
              ok: true,
              data: {
                createdCount: 0,
                approvalRequired: false,
                fallbackAllowed: true,
              },
            }),
          }],
          details: {},
        };
      }
    },
  });
  const suggest = defineTool({
    name: "finwealth_suggest_quote",
    label: "建议报价",
    description:
      "把网页中找到的单个标的报价或汇率保存为待用户审核的候选。它不会改变估值；必须提供网页来源、报价时间和定点十进制数值。",
    promptSnippet: "把有明确来源和时间的网页报价整理成待审核候选。",
    promptGuidelines: [
      "先用 finwealth_query 获取真实 instrumentId、计价单位和缺失报价，不要虚构内部 ID。",
      "同一目标必须先调用 finwealth_lookup_quote_candidate；仅当它明确允许 fallback 后才能提交网页候选。",
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
      const input = params as Record<string, unknown>;
      if (!fallbackEligible.has(candidateTargetKey(input))) {
        throw new Error("structured_quote_lookup_required");
      }
      const candidate = await suggestQuoteCandidate(
        store,
        conversation,
        input,
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
  });
  return [lookup, suggest];
}
