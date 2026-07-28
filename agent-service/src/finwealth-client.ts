import { randomUUID } from "node:crypto";
import {
  defineTool,
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type { AgentQuoteCandidate, AgentQuoteWriter } from "./types.js";

const MAX_TOOL_RESPONSE_BYTES = 256 * 1024;

const QUERY_PATHS = {
  overview: "/v1/portfolio/overview",
  accounts: "/v1/accounts",
  movements: "/v1/movements",
  holdings: "/v1/holdings",
  liabilities: "/v1/liability-positions",
  subscriptions: "/v1/subscriptions",
  dca: "/v1/dca/plans",
  pending_review: "/v1/ai/proposals/pending",
  quotes: "/v1/quotes/summary",
} as const;

type QueryName = keyof typeof QUERY_PATHS;

export class FinwealthClient implements AgentQuoteWriter {
  readonly #baseUrl: string;
  readonly #internalToken: string;

  constructor(baseUrl: string, internalToken: string) {
    this.#baseUrl = baseUrl.replace(/\/$/, "");
    this.#internalToken = internalToken;
  }

  async query(name: QueryName, signal?: AbortSignal): Promise<unknown> {
    return this.#request("GET", QUERY_PATHS[name], undefined, undefined, signal);
  }

  async proposeMovement(
    input: Record<string, unknown>,
    signal?: AbortSignal,
  ): Promise<unknown> {
    const draftKey = `agent-draft-${randomUUID()}`;
    const draft = await this.#request(
      "POST",
      "/v1/movements/drafts",
      input,
      draftKey,
      signal,
    ) as { data?: { id?: unknown } };
    const movementId = draft.data?.id;
    if (typeof movementId !== "string" || !movementId) {
      throw new Error("finwealth_invalid_draft_response");
    }
    return this.#request(
      "POST",
      `/v1/movements/${encodeURIComponent(movementId)}/submit-review`,
      undefined,
      `agent-review-${randomUUID()}`,
      signal,
    );
  }

  async refreshStructuredQuotes(signal?: AbortSignal): Promise<unknown> {
    return this.#request(
      "POST",
      "/v1/quotes/refresh",
      {},
      `agent-quotes-${randomUUID()}`,
      signal,
    );
  }

  async applyQuoteCandidate(candidate: AgentQuoteCandidate): Promise<unknown> {
    const item = candidate.kind === "instrument"
      ? {
        instrumentId: candidate.instrumentId,
        price: candidate.price,
        currency: candidate.currency,
        asOf: candidate.asOf,
        source: candidate.source,
        sourceUrl: candidate.sourceUrl,
      }
      : {
        baseCurrency: candidate.baseCurrency,
        quoteCurrency: candidate.quoteCurrency,
        rate: candidate.rate,
        asOf: candidate.asOf,
        source: candidate.source,
        sourceUrl: candidate.sourceUrl,
      };
    const body = {
      mode: "manual",
      requestedAt: candidate.createdAt,
      ...(candidate.kind === "instrument" ? { quotes: [item] } : { fxRates: [item] }),
    };
    const response = await this.#request(
      "POST",
      "/v1/quotes/refresh",
      body,
      `agent-quote-${candidate.id}`,
    );
    const data = response && typeof response === "object"
      ? (response as { data?: unknown }).data
      : undefined;
    const applied = data && typeof data === "object"
      ? candidate.kind === "instrument"
        ? (data as { quotes?: unknown }).quotes
        : (data as { fxRates?: unknown }).fxRates
      : undefined;
    if (!Array.isArray(applied) || applied.length !== 1) {
      throw new Error("agent_quote_apply_failed");
    }
    return response;
  }

  async #request(
    method: "GET" | "POST",
    path: string,
    body?: unknown,
    idempotencyKey?: string,
    signal?: AbortSignal,
  ): Promise<unknown> {
    const response = await fetch(`${this.#baseUrl}${path}`, {
      method,
      headers: {
        "x-finwealth-internal-token": this.#internalToken,
        ...(body === undefined ? {} : { "content-type": "application/json" }),
        ...(idempotencyKey ? { "idempotency-key": idempotencyKey } : {}),
      },
      ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      ...(signal ? { signal } : {}),
    });
    const raw = await response.text();
    if (Buffer.byteLength(raw) > MAX_TOOL_RESPONSE_BYTES) {
      throw new Error("finwealth_response_too_large");
    }
    let value: unknown;
    try {
      value = raw ? JSON.parse(raw) : null;
    } catch {
      throw new Error("finwealth_invalid_response");
    }
    if (!response.ok) {
      const code = errorCode(value) ?? `finwealth_http_${response.status}`;
      throw new Error(code);
    }
    return value;
  }
}

function errorCode(value: unknown): string | undefined {
  if (!value || typeof value !== "object") return undefined;
  const error = (value as { error?: unknown }).error;
  if (!error || typeof error !== "object") return undefined;
  const code = (error as { code?: unknown }).code;
  return typeof code === "string" && /^[a-z0-9_]+$/.test(code) ? code : undefined;
}

function toolText(value: unknown): string {
  return JSON.stringify(value);
}

export function createFinwealthTools(client: FinwealthClient): ToolDefinition[] {
  const query = defineTool({
    name: "finwealth_query",
    label: "查询 Finwealth",
    description:
      "读取 Finwealth 的权威财务数据。需要账户 ID、余额、持仓、订阅、定投、待审核项或报价时使用；不要从聊天上下文猜测财务数据。",
    promptSnippet: "读取 Finwealth 账户、交易、持仓、负债、订阅、定投、待审核项和报价。",
    parameters: Type.Object({
      resource: Type.Union([
        Type.Literal("overview"),
        Type.Literal("accounts"),
        Type.Literal("movements"),
        Type.Literal("holdings"),
        Type.Literal("liabilities"),
        Type.Literal("subscriptions"),
        Type.Literal("dca"),
        Type.Literal("pending_review"),
        Type.Literal("quotes"),
      ], { description: "要读取的财务资源" }),
    }),
    async execute(_id, params, signal) {
      const value = await client.query(params.resource as QueryName, signal);
      return { content: [{ type: "text", text: toolText(value) }], details: {} };
    },
  });

  const proposeMovement = defineTool({
    name: "finwealth_propose_movement",
    label: "创建待审核记录",
    description:
      "创建一条账务草稿并提交到 Finwealth 审核队列。它不会确认记录或改变已确认余额。先用 finwealth_query 获取真实账户和标的 ID。",
    promptSnippet: "把收入、支出、转账、投资或还款整理为待用户审核的账务记录。",
    promptGuidelines: [
      "财务写入只能调用 finwealth_propose_movement；不得调用确认、批准或直接写账接口。",
      "账户、标的或币种不明确时先查询或询问用户，不要虚构 ID。",
    ],
    parameters: Type.Object({
      type: Type.Union([
        Type.Literal("income"),
        Type.Literal("expense"),
        Type.Literal("transfer"),
        Type.Literal("buy"),
        Type.Literal("sell"),
        Type.Literal("dividend"),
        Type.Literal("interest"),
        Type.Literal("fee"),
        Type.Literal("adjustment"),
        Type.Literal("loan_disbursement"),
        Type.Literal("loan_repayment"),
      ]),
      occurredAt: Type.String({ description: "RFC3339 时间" }),
      title: Type.String({ minLength: 1, maxLength: 200 }),
      entries: Type.Array(
        Type.Object({
          accountId: Type.String(),
          instrumentId: Type.Optional(Type.String()),
          amount: Type.String({ description: "非负十进制定点字符串" }),
          currency: Type.String({ description: "大写币种或资产代码" }),
          direction: Type.Union([Type.Literal("in"), Type.Literal("out")]),
          role: Type.Union([
            Type.Literal("source"),
            Type.Literal("destination"),
            Type.Literal("fee"),
            Type.Literal("discount"),
            Type.Literal("pnl"),
            Type.Literal("tax"),
            Type.Literal("adjustment"),
          ]),
        }),
        { minItems: 1, maxItems: 20 },
      ),
      categoryId: Type.Optional(Type.String()),
      counterpartyId: Type.Optional(Type.String()),
    }),
    executionMode: "sequential",
    async execute(_id, params, signal) {
      const value = await client.proposeMovement(
        params as Record<string, unknown>,
        signal,
      );
      return { content: [{ type: "text", text: toolText(value) }], details: {} };
    },
  });

  const refreshQuotes = defineTool({
    name: "finwealth_refresh_quotes",
    label: "刷新结构化报价",
    description:
      "调用 Finwealth 已配置且获准的结构化报价源刷新市场报价和汇率。网页搜索结果不能调用此工具写入。",
    promptSnippet: "从服务器已配置的结构化来源刷新报价和汇率。",
    parameters: Type.Object({}),
    executionMode: "sequential",
    async execute(_id, _params, signal) {
      const value = await client.refreshStructuredQuotes(signal);
      return { content: [{ type: "text", text: toolText(value) }], details: {} };
    },
  });

  return [query, proposeMovement, refreshQuotes];
}
