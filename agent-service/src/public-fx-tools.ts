import { defineTool, type ToolDefinition } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import { suggestQuoteCandidate } from "./quote-candidate-tools.js";
import { StateStore } from "./state-store.js";
import type { AgentConversation, AgentQuoteCandidate } from "./types.js";

export const PUBLIC_FX_SOURCE_URL = "https://open.er-api.com/v6/latest/USD";
const CURRENCY = /^[A-Z]{3}$/;

interface PublicFxInput {
  baseCurrency: string;
  quoteCurrency: string;
}

interface PublicFxPayload {
  result?: unknown;
  time_last_update_unix?: unknown;
  base_code?: unknown;
  rates?: unknown;
}

function decimal(value: number): string {
  return value.toFixed(8).replace(/0+$/, "").replace(/\.$/, "");
}

function currency(value: string): string {
  const normalized = value.trim().toUpperCase();
  if (!CURRENCY.test(normalized)) throw new Error("invalid_agent_fx_pair");
  return normalized;
}

export async function lookupPublicFxCandidate(
  store: StateStore,
  conversation: AgentConversation,
  input: PublicFxInput,
  fetchFx: typeof fetch = fetch,
  signal?: AbortSignal,
): Promise<AgentQuoteCandidate> {
  const baseCurrency = currency(input.baseCurrency);
  const quoteCurrency = currency(input.quoteCurrency);
  if (baseCurrency === quoteCurrency) throw new Error("invalid_agent_fx_pair");
  const timeout = AbortSignal.timeout(15_000);
  const requestSignal = signal ? AbortSignal.any([signal, timeout]) : timeout;
  let response: Response;
  try {
    response = await fetchFx(PUBLIC_FX_SOURCE_URL, {
      headers: { accept: "application/json" },
      signal: requestSignal,
    });
  } catch {
    throw new Error("agent_public_fx_unavailable");
  }
  if (!response.ok) throw new Error("agent_public_fx_unavailable");
  let payload: PublicFxPayload;
  try {
    payload = await response.json() as PublicFxPayload;
  } catch {
    throw new Error("agent_public_fx_unavailable");
  }
  const rates = payload.rates;
  const updated = payload.time_last_update_unix;
  if (
    payload.result !== "success" ||
    payload.base_code !== "USD" ||
    !rates || typeof rates !== "object" || Array.isArray(rates) ||
    typeof updated !== "number" || !Number.isSafeInteger(updated) || updated <= 0
  ) {
    throw new Error("agent_public_fx_unavailable");
  }
  const values = rates as Record<string, unknown>;
  const baseRate = baseCurrency === "USD" ? 1 : values[baseCurrency];
  const quoteRate = quoteCurrency === "USD" ? 1 : values[quoteCurrency];
  if (
    typeof baseRate !== "number" || !Number.isFinite(baseRate) || baseRate <= 0 ||
    typeof quoteRate !== "number" || !Number.isFinite(quoteRate) || quoteRate <= 0
  ) {
    throw new Error("agent_public_fx_unavailable");
  }
  const rate = decimal(quoteRate / baseRate);
  if (!rate || rate === "0") throw new Error("agent_public_fx_unavailable");
  const asOf = new Date(updated * 1_000);
  if (Number.isNaN(asOf.getTime())) throw new Error("agent_public_fx_unavailable");
  return suggestQuoteCandidate(store, conversation, {
    kind: "fx",
    baseCurrency,
    quoteCurrency,
    rate,
    asOf: asOf.toISOString(),
    source: "ExchangeRate-API",
    sourceUrl: PUBLIC_FX_SOURCE_URL,
  });
}

export function createPublicFxTools(
  store: StateStore,
  conversation: AgentConversation,
): ToolDefinition[] {
  return [defineTool({
    name: "finwealth_lookup_fx_candidate",
    label: "查询汇率建议",
    description:
      "从无需密钥的公网日汇率源查询一个币种对，并直接创建待用户审核的汇率候选；不会改余额或自动采用。Finwealth 结构化报价源未配置时优先使用此工具，不要改用通用 bash 猜测网页接口。",
    promptSnippet: "查询公网 FX 汇率并创建待审核候选。",
    promptGuidelines: [
      "用户要求查询或更新法币汇率时，调用此工具；成功后明确告诉用户候选仍需审核。",
      "不要先调用 finwealth_refresh_quotes 探测配置，也不要要求用户提供网页链接或手工汇率。",
      "币种使用三个大写 ISO 代码；此工具只创建 suggested 候选，不会自动应用。",
    ],
    parameters: Type.Object({
      baseCurrency: Type.String({ minLength: 3, maxLength: 3 }),
      quoteCurrency: Type.String({ minLength: 3, maxLength: 3 }),
    }),
    executionMode: "sequential",
    async execute(_id, params, signal) {
      const candidate = await lookupPublicFxCandidate(
        store,
        conversation,
        params as PublicFxInput,
        fetch,
        signal,
      );
      return {
        content: [{
          type: "text",
          text: JSON.stringify({
            ok: true,
            data: {
              id: candidate.id,
              kind: candidate.kind,
              baseCurrency: candidate.baseCurrency,
              quoteCurrency: candidate.quoteCurrency,
              rate: candidate.rate,
              asOf: candidate.asOf,
              source: candidate.source,
              sourceUrl: candidate.sourceUrl,
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
