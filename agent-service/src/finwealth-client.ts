import { randomUUID } from "node:crypto";
import {
  defineTool,
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";
import type {
  AgentAutomation,
  AgentAutomationResult,
  AgentAutomationRunner,
  AgentQuoteCandidate,
  AgentQuoteWriter,
} from "./types.js";

const MAX_TOOL_RESPONSE_BYTES = 256 * 1024;

const QUERY_PATHS = {
  overview: "/v1/portfolio/overview",
  accounts: "/v1/accounts",
  instruments: "/v1/instruments",
  movements: "/v1/movements",
  holdings: "/v1/holdings",
  liabilities: "/v1/liability-positions",
  subscriptions: "/v1/subscriptions",
  dca: "/v1/dca/plans",
  pending_review: "/v1/ai/proposals/pending",
  quotes: "/v1/quotes/summary",
} as const;

type QueryName = keyof typeof QUERY_PATHS;

const CASH_ONLY_MOVEMENT_TYPES = new Set([
  "expense",
  "fee",
  "income",
  "dividend",
  "interest",
]);

export function normalizeMovementProposalForLedger(
  input: Record<string, unknown>,
): Record<string, unknown> {
  if (!CASH_ONLY_MOVEMENT_TYPES.has(String(input.type)) || !Array.isArray(input.entries)) {
    return input;
  }
  return {
    ...input,
    entries: input.entries.map((entry) => {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) return entry;
      const { instrumentId: _ignored, ...cashEntry } = entry as Record<string, unknown>;
      return cashEntry;
    }),
  };
}

export class FinwealthClient implements AgentQuoteWriter, AgentAutomationRunner {
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

  async proposeHoldingSnapshot(
    accountId: string,
    input: Record<string, unknown>,
    signal?: AbortSignal,
  ): Promise<unknown> {
    return this.#request(
      "POST",
      `/v1/accounts/${encodeURIComponent(accountId)}/holding-snapshot-proposals`,
      input,
      `agent-holding-snapshot-${randomUUID()}`,
      signal,
    );
  }

  async lookupStructuredQuotes(
    input: Record<string, unknown>,
    signal?: AbortSignal,
  ): Promise<unknown> {
    return this.#request(
      "POST",
      "/v1/quotes/lookup",
      input,
      undefined,
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

  async runAutomation(
    automation: AgentAutomation,
    scheduledFor: string,
  ): Promise<AgentAutomationResult> {
    const key = `agent-auto-${automation.id}-${scheduledFor}`;
    if (automation.kind === "quote_refresh") {
      const response = await this.lookupStructuredQuotes({});
      const data = responseData(response);
      const quoteCandidateInputs = quoteCandidateInputsFromLookup(response);
      const errors = Array.isArray(data?.errors) ? data.errors.length : 0;
      return {
        title: quoteCandidateInputs.length ? "报价建议等待审核" : "报价检查完成",
        body: `新增 ${quoteCandidateInputs.length} 条报价建议${errors ? `，${errors} 项未找到` : ""}`,
        action: "quotes",
        notify: quoteCandidateInputs.length > 0 || errors > 0,
        quoteCandidateInputs,
      };
    }
    if (automation.kind === "subscription_due_scan") {
      const response = await this.#request(
        "POST",
        "/v1/subscriptions/charge-proposals/due-scan",
        { throughDate: scheduledFor.slice(0, 10), limit: 100 },
        key,
      );
      const data = responseData(response);
      const created = numberField(data, "createdCount");
      const blocked = numberField(data, "blockedCount");
      const remaining = numberField(data, "remainingEligibleCount");
      return {
        title: created ? "订阅扣费等待审核" : "订阅到期扫描完成",
        body: `新增 ${created} 条待审核记录${blocked ? `，${blocked} 项需处理` : ""}${remaining ? `，还有 ${remaining} 项待扫描` : ""}`,
        action: "review",
        notify: created > 0 || blocked > 0 || remaining > 0,
      };
    }
    if (automation.kind !== "dca_due_check") {
      throw new Error("unsupported_agent_automation");
    }
    const response = await this.#request("GET", "/v1/dca/reminders/due");
    const data = responseDataValue(response);
    const due = Array.isArray(data) ? data.length : 0;
    return {
      title: due ? "定投计划到期" : "定投检查完成",
      body: due ? `${due} 个定投计划等待处理` : "当前没有到期定投计划",
      action: "dca",
      notify: due > 0,
    };
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

function responseDataValue(value: unknown): unknown {
  return value && typeof value === "object" ? (value as { data?: unknown }).data : undefined;
}

function responseData(value: unknown): Record<string, unknown> | undefined {
  const data = responseDataValue(value);
  return data && typeof data === "object" && !Array.isArray(data)
    ? data as Record<string, unknown>
    : undefined;
}

/// Convert the read-only structured lookup response into the same candidate
/// input shape used by web fallback. Validation still happens when persisted.
export function quoteCandidateInputsFromLookup(
  value: unknown,
): Record<string, unknown>[] {
  const data = responseData(value);
  if (!data) return [];
  const candidates: Record<string, unknown>[] = [];
  for (const item of Array.isArray(data.quotes) ? data.quotes : []) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const quote = item as Record<string, unknown>;
    candidates.push({
      kind: "instrument",
      instrumentId: quote.instrumentId,
      price: quote.price,
      currency: quote.currency,
      asOf: quote.asOf,
      source: quote.source,
      sourceUrl: quote.sourceUrl,
    });
  }
  for (const item of Array.isArray(data.fxRates) ? data.fxRates : []) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const rate = item as Record<string, unknown>;
    candidates.push({
      kind: "fx",
      baseCurrency: rate.baseCurrency,
      quoteCurrency: rate.quoteCurrency,
      rate: rate.rate,
      asOf: rate.asOf,
      source: rate.source,
      sourceUrl: rate.sourceUrl,
    });
  }
  return candidates;
}

function numberField(value: Record<string, unknown> | undefined, field: string): number {
  const item = value?.[field];
  return typeof item === "number" && Number.isSafeInteger(item) && item >= 0 ? item : 0;
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
      "读取 Finwealth 的权威财务数据。需要账户 ID、标的 ID、余额、持仓、订阅、定投、待审核项或报价时使用；不要从聊天上下文猜测财务数据。",
    promptSnippet: "读取 Finwealth 账户、标的、交易、持仓、负债、订阅、定投、待审核项和报价。",
    parameters: Type.Object({
      resource: Type.Union([
        Type.Literal("overview"),
        Type.Literal("accounts"),
        Type.Literal("instruments"),
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
      "expense/fee 必须且只能有一条非负现金分录，direction=out、role=source；income/dividend/interest 同理使用一条 direction=in、role=source 的现金分录。",
      "occurredAt 必须是带时区的 RFC3339 时间；amount 必须是非负十进制定点字符串，支出方向由 direction=out 表达，不要写负数。",
      "纯现金分录必须省略 instrumentId；只有 buy/sell 等持仓数量腿才可填写真实的 instrumentId。",
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
        normalizeMovementProposalForLedger(params as Record<string, unknown>),
        signal,
      );
      return { content: [{ type: "text", text: toolText(value) }], details: {} };
    },
  });

  const proposeHoldingSnapshot = defineTool({
    name: "finwealth_propose_holding_snapshot",
    label: "创建持仓快照审核",
    description:
      "把同一交易所或钱包账户的多项资产数量整理成一个待审核持仓快照。它只创建一个整体审核组，不会确认持仓、修改余额或写入报价。必须先查询真实账户和标的 ID。",
    promptSnippet: "把交易所、钱包文件或截图中的多资产数量整理为一个待审核持仓快照。",
    promptGuidelines: [
      "先用 finwealth_query 分别读取 accounts 和 holdings，并确认每个资产对应的真实 instrumentId；不要把 BTC、ETH、USDT 代码当作 ID。",
      "同一份快照的全部资产必须一次提交；不要为每个资产分别创建账务记录。",
      "targetQuantity 是当前总数量，不是本期增量；不得为负数。文件中不明确、无法可靠识别或不属于目标账户的资产应先询问用户。",
      "该工具只生成待审核组；不得随后调用确认、批准或报价采用接口。",
    ],
    parameters: Type.Object({
      accountId: Type.String({ minLength: 1 }),
      asOf: Type.Optional(Type.String({ description: "带时区的 RFC3339 时间" })),
      positions: Type.Array(
        Type.Object({
          instrumentId: Type.String({ minLength: 1 }),
          targetQuantity: Type.String({ description: "非负十进制定点字符串" }),
        }),
        { minItems: 1, maxItems: 100 },
      ),
      note: Type.Optional(Type.String({ maxLength: 500 })),
    }),
    executionMode: "sequential",
    async execute(_id, params, signal) {
      const { accountId, ...input } = params as {
        accountId: string;
        [key: string]: unknown;
      };
      const value = await client.proposeHoldingSnapshot(accountId, input, signal);
      return { content: [{ type: "text", text: toolText(value) }], details: {} };
    },
  });

  return [query, proposeMovement, proposeHoldingSnapshot];
}
