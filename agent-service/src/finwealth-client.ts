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

export interface HoldingSnapshotQuoteContext {
  accountId: string;
  instruments: Array<{
    instrumentId: string;
    quoteCurrency: string;
    targetQuantity: string;
  }>;
}

export interface QuoteLookupDiagnostic {
  targetType: "request" | "instrument" | "fx_pair";
  targetId?: string;
  message: string;
  retryable: boolean;
}

export interface HoldingSnapshotQuoteResult {
  createdCount: number;
  requestedInstrumentCount: number;
  requestedFxCount: number;
  status: "success" | "partial_success" | "failed" | "offline";
  errors: QuoteLookupDiagnostic[];
}

export interface FinwealthToolOptions {
  onHoldingSnapshotProposed?: (
    context: HoldingSnapshotQuoteContext,
    signal?: AbortSignal,
  ) => Promise<HoldingSnapshotQuoteResult>;
}

export class FinwealthRequestError extends Error {
  readonly code: string;
  readonly status: number;
  readonly diagnostics: string[];

  constructor(code: string, status: number, diagnostics: string[]) {
    super(diagnostics.length ? `${code}: ${diagnostics.join("; ")}` : code);
    this.name = "FinwealthRequestError";
    this.code = code;
    this.status = status;
    this.diagnostics = diagnostics;
  }
}

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

  async getAccount(accountId: string, signal?: AbortSignal): Promise<unknown> {
    return this.#request(
      "GET",
      `/v1/accounts/${encodeURIComponent(accountId)}`,
      undefined,
      undefined,
      signal,
    );
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

  async proposeCryptoHoldingSnapshot(
    accountId: string,
    input: Record<string, unknown>,
    signal?: AbortSignal,
    captureResolved?: (context: HoldingSnapshotQuoteContext) => void,
  ): Promise<unknown> {
    const positions = cryptoSnapshotPositions(input.positions);
    const symbols = positions.map((position) => position.symbol);
    const ensured = responseData(
      await this.ensureCryptoInstruments(accountId, symbols, signal),
    );
    if (ensured?.accountId !== accountId) {
      throw new Error("finwealth_invalid_crypto_instrument_response");
    }
    const instruments = Array.isArray(ensured?.instruments)
      ? ensured.instruments
      : [];
    const instrumentIds = new Map<string, { id: string; quoteCurrency: string }>();
    for (const item of instruments) {
      if (!item || typeof item !== "object" || Array.isArray(item)) continue;
      const instrument = item as Record<string, unknown>;
      const symbol = typeof instrument.symbol === "string"
        ? instrument.symbol.trim().toUpperCase()
        : "";
      const id = typeof instrument.id === "string" ? instrument.id.trim() : "";
      const quoteCurrency = typeof instrument.quoteCurrency === "string"
        ? instrument.quoteCurrency.trim().toUpperCase()
        : "";
      if (!symbol || !id || instrument.type !== "crypto" || instrumentIds.has(symbol)) {
        throw new Error("finwealth_invalid_crypto_instrument_response");
      }
      instrumentIds.set(symbol, { id, quoteCurrency });
    }
    const resolvedPositions = positions.map(({ symbol, targetQuantity }) => {
      const instrument = instrumentIds.get(symbol);
      if (!instrument) throw new Error("finwealth_invalid_crypto_instrument_response");
      return { instrumentId: instrument.id, targetQuantity };
    });
    const { positions: _sourcePositions, ...snapshot } = input;
    const response = await this.proposeHoldingSnapshot(
      accountId,
      { ...snapshot, positions: resolvedPositions },
      signal,
    );
    captureResolved?.({
      accountId,
      instruments: positions.map(({ symbol, targetQuantity }) => {
        const instrument = instrumentIds.get(symbol)!;
        return {
          instrumentId: instrument.id,
          quoteCurrency: instrument.quoteCurrency,
          targetQuantity,
        };
      }),
    });
    return response;
  }

  async ensureCryptoInstruments(
    accountId: string,
    symbols: string[],
    signal?: AbortSignal,
  ): Promise<unknown> {
    return this.#request(
      "POST",
      `/v1/accounts/${encodeURIComponent(accountId)}/crypto-instruments/ensure`,
      { symbols },
      `agent-crypto-instruments-${randomUUID()}`,
      signal,
    );
  }

  async proposeInvestmentHoldingSnapshot(
    accountId: string,
    input: Record<string, unknown>,
    signal?: AbortSignal,
    captureResolved?: (context: HoldingSnapshotQuoteContext) => void,
  ): Promise<unknown> {
    const positions = investmentSnapshotPositions(input.positions);
    const sourceInstruments = positions.map((position) => ({
      type: position.type,
      symbol: position.symbol,
      displayName: position.displayName,
      quoteCurrency: position.quoteCurrency,
      market: position.market,
    }));
    const ensured = responseData(
      await this.ensureInvestmentInstruments(accountId, sourceInstruments, signal),
    );
    if (ensured?.accountId !== accountId) {
      throw new Error("finwealth_invalid_investment_instrument_response");
    }
    const instruments = Array.isArray(ensured?.instruments)
      ? ensured.instruments
      : [];
    const instrumentIds = new Map<string, string>();
    for (const item of instruments) {
      if (!item || typeof item !== "object" || Array.isArray(item)) continue;
      const instrument = item as Record<string, unknown>;
      const identity = investmentInstrumentIdentity(instrument);
      const id = typeof instrument.id === "string" ? instrument.id.trim() : "";
      if (!identity || !id || instrumentIds.has(identity)) {
        throw new Error("finwealth_invalid_investment_instrument_response");
      }
      instrumentIds.set(identity, id);
    }
    const resolvedPositions = positions.map((position) => {
      const instrumentId = instrumentIds.get(investmentInstrumentIdentity(position) ?? "");
      if (!instrumentId) {
        throw new Error("finwealth_invalid_investment_instrument_response");
      }
      return { instrumentId, targetQuantity: position.targetQuantity };
    });
    const { positions: _sourcePositions, ...snapshot } = input;
    const response = await this.proposeHoldingSnapshot(
      accountId,
      { ...snapshot, positions: resolvedPositions },
      signal,
    );
    captureResolved?.({
      accountId,
      instruments: positions.map((position) => ({
        instrumentId: instrumentIds.get(investmentInstrumentIdentity(position) ?? "")!,
        quoteCurrency: position.quoteCurrency,
        targetQuantity: position.targetQuantity,
      })),
    });
    return response;
  }

  async ensureInvestmentInstruments(
    accountId: string,
    instruments: Array<Record<string, string>>,
    signal?: AbortSignal,
  ): Promise<unknown> {
    return this.#request(
      "POST",
      `/v1/accounts/${encodeURIComponent(accountId)}/investment-instruments/ensure`,
      { instruments },
      `agent-investment-instruments-${randomUUID()}`,
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
      throw new FinwealthRequestError(code, response.status, errorDiagnostics(value));
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

function cryptoSnapshotPositions(value: unknown): Array<{
  symbol: string;
  targetQuantity: string;
}> {
  if (!Array.isArray(value) || value.length < 1 || value.length > 100) {
    throw new Error("invalid_crypto_snapshot_positions");
  }
  const positions: Array<{ symbol: string; targetQuantity: string }> = [];
  const seen = new Set<string>();
  for (const item of value) {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new Error("invalid_crypto_snapshot_positions");
    }
    const position = item as Record<string, unknown>;
    const symbol = typeof position.symbol === "string"
      ? position.symbol.trim().toUpperCase()
      : "";
    const targetQuantity = typeof position.targetQuantity === "string"
      ? position.targetQuantity.trim()
      : "";
    if (
      !/^[A-Z0-9][A-Z0-9._-]{0,19}$/.test(symbol) ||
      !/^(?:0|[1-9]\d*)(?:\.\d{1,8})?$/.test(targetQuantity) ||
      seen.has(symbol)
    ) {
      throw new Error("invalid_crypto_snapshot_positions");
    }
    seen.add(symbol);
    positions.push({ symbol, targetQuantity });
  }
  return positions;
}

type InvestmentSnapshotPosition = {
  type: "equity" | "fund" | "other";
  symbol: string;
  displayName: string;
  quoteCurrency: string;
  market: string;
  targetQuantity: string;
};

function investmentInstrumentIdentity(
  value: Record<string, unknown>,
): string | undefined {
  const type = typeof value.type === "string" ? value.type : "";
  const symbol = typeof value.symbol === "string" ? value.symbol.trim().toUpperCase() : "";
  const market = typeof value.market === "string" ? value.market.trim().toUpperCase() : "";
  const quoteCurrency = typeof value.quoteCurrency === "string"
    ? value.quoteCurrency.trim().toUpperCase()
    : "";
  if (
    !["equity", "fund", "other"].includes(type) ||
    !/^[A-Z0-9][A-Z0-9._-]{0,31}$/.test(symbol) ||
    !/^[A-Z0-9][A-Z0-9._-]{0,23}$/.test(market) ||
    !/^[A-Z0-9][A-Z0-9._-]{1,11}$/.test(quoteCurrency)
  ) return undefined;
  return `${type}\0${market}\0${symbol}\0${quoteCurrency}`;
}

function investmentSnapshotPositions(value: unknown): InvestmentSnapshotPosition[] {
  if (!Array.isArray(value) || value.length < 1 || value.length > 100) {
    throw new Error("invalid_investment_snapshot_positions");
  }
  const positions: InvestmentSnapshotPosition[] = [];
  const seen = new Set<string>();
  for (const item of value) {
    if (!item || typeof item !== "object" || Array.isArray(item)) {
      throw new Error("invalid_investment_snapshot_positions");
    }
    const position = item as Record<string, unknown>;
    const identity = investmentInstrumentIdentity(position);
    const displayName = typeof position.displayName === "string"
      ? position.displayName.trim()
      : "";
    const targetQuantity = typeof position.targetQuantity === "string"
      ? position.targetQuantity.trim()
      : "";
    if (
      !identity ||
      !displayName ||
      [...displayName].length > 120 ||
      !/^(?:0|[1-9]\d*)(?:\.\d{1,8})?$/.test(targetQuantity) ||
      seen.has(identity)
    ) {
      throw new Error("invalid_investment_snapshot_positions");
    }
    seen.add(identity);
    positions.push({
      type: position.type as InvestmentSnapshotPosition["type"],
      symbol: String(position.symbol).trim().toUpperCase(),
      displayName,
      quoteCurrency: String(position.quoteCurrency).trim().toUpperCase(),
      market: String(position.market).trim().toUpperCase(),
      targetQuantity,
    });
  }
  return positions;
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

export function quoteLookupDiagnosticsFromLookup(value: unknown): {
  status: HoldingSnapshotQuoteResult["status"];
  errors: QuoteLookupDiagnostic[];
} {
  const data = responseData(value);
  const rawStatus = data?.status;
  const status = rawStatus === "success" || rawStatus === "partial_success" ||
      rawStatus === "failed" || rawStatus === "offline"
    ? rawStatus
    : "failed";
  const errors: QuoteLookupDiagnostic[] = [];
  for (const item of Array.isArray(data?.errors) ? data.errors : []) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const error = item as Record<string, unknown>;
    const targetType = error.targetType;
    const message = safeDiagnostic(error.message);
    if (
      !message ||
      (targetType !== "request" && targetType !== "instrument" && targetType !== "fx_pair")
    ) continue;
    const targetId = safeDiagnostic(error.targetId);
    errors.push({
      targetType,
      ...(targetId ? { targetId: [...targetId].slice(0, 128).join("") } : {}),
      message,
      retryable: error.retryable === true,
    });
    if (errors.length === 100) break;
  }
  return { status, errors };
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

function errorDiagnostics(value: unknown): string[] {
  if (!value || typeof value !== "object" || Array.isArray(value)) return [];
  const error = (value as { error?: unknown }).error;
  if (!error || typeof error !== "object" || Array.isArray(error)) return [];
  const record = error as Record<string, unknown>;
  const details = record.details;
  const errors = details && typeof details === "object" && !Array.isArray(details)
    ? (details as { errors?: unknown }).errors
    : undefined;
  const diagnostics = Array.isArray(errors)
    ? errors.map(safeDiagnostic).filter((item): item is string => Boolean(item))
    : [];
  if (diagnostics.length) return [...new Set(diagnostics)].slice(0, 10);
  const message = safeDiagnostic(record.message);
  return message ? [message] : [];
}

function safeDiagnostic(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const normalized = value.replace(/[\u0000-\u001f\u007f]+/g, " ").trim();
  if (!normalized) return undefined;
  return [...normalized].slice(0, 300).join("");
}

function toolText(value: unknown): string {
  return JSON.stringify(value);
}

async function snapshotToolResult(
  value: unknown,
  context: HoldingSnapshotQuoteContext | undefined,
  options: FinwealthToolOptions,
  signal?: AbortSignal,
): Promise<unknown> {
  if (!context || !options.onHoldingSnapshotProposed) return value;
  let quoteCandidateCreatedCount = 0;
  let quoteLookupCompleted = false;
  let quoteLookupStatus: HoldingSnapshotQuoteResult["status"] = "failed";
  let quoteLookupErrors: QuoteLookupDiagnostic[] = [];
  let quoteLookupRequestedInstrumentCount = 0;
  let quoteLookupRequestedFxCount = 0;
  try {
    const result = await options.onHoldingSnapshotProposed(context, signal);
    quoteCandidateCreatedCount = result.createdCount;
    quoteLookupStatus = result.status;
    quoteLookupErrors = result.errors;
    quoteLookupRequestedInstrumentCount = result.requestedInstrumentCount;
    quoteLookupRequestedFxCount = result.requestedFxCount;
    quoteLookupCompleted = true;
  } catch {
    // The holding snapshot is already persisted. Quote lookup is ancillary and
    // must never make the model retry a successful snapshot proposal.
  }
  if (!value || typeof value !== "object" || Array.isArray(value)) return value;
  const envelope = value as Record<string, unknown>;
  const data = envelope.data;
  if (!data || typeof data !== "object" || Array.isArray(data)) return value;
  return {
    ...envelope,
    data: {
      ...data,
      quoteCandidateCreatedCount,
      quoteLookupCompleted,
      quoteLookupStatus,
      quoteLookupErrors,
      quoteLookupRequestedInstrumentCount,
      quoteLookupRequestedFxCount,
    },
  };
}

export function createFinwealthTools(
  client: FinwealthClient,
  options: FinwealthToolOptions = {},
): ToolDefinition[] {
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
      "把同一交易所或钱包账户的多项加密资产数量整理成一个待审核持仓快照。只提交来源中的资产代码和数量；工具会由服务端登记或复用标的并替换为真实 instrumentId。快照成功后会从结构化来源生成独立的待审核报价候选；它不会确认持仓、修改余额或写入报价。",
    promptSnippet: "把交易所、钱包文件或截图中的多资产数量整理为一个待审核持仓快照。",
    promptGuidelines: [
      "先用 finwealth_query 读取 accounts 和 holdings，确认目标账户；positions 只填写来源中实际出现的 symbol 和当前总数量。",
      "不要提交 instrumentId，也不要根据 symbol 自造 ID；工具内部会调用服务端登记或复用标的，并使用服务端返回的真实 ID。",
      "同一份快照的全部资产必须一次提交；不要为每个资产分别创建账务记录。",
      "targetQuantity 是当前总数量，不是本期增量；不得为负数。文件中不明确、无法可靠识别或不属于目标账户的资产应先询问用户。",
      "快照成功后工具会自动查询相关标的报价与折算汇率；不要为同一批标的重复调用报价工具。",
      "该工具只生成待审核组；不得随后调用确认、批准或报价采用接口。",
    ],
    parameters: Type.Object({
      accountId: Type.String({ minLength: 1 }),
      asOf: Type.Optional(Type.String({ description: "带时区的 RFC3339 时间" })),
      positions: Type.Array(
        Type.Object({
          symbol: Type.String({
            minLength: 1,
            maxLength: 20,
            pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$",
          }),
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
      let context: HoldingSnapshotQuoteContext | undefined;
      const value = await client.proposeCryptoHoldingSnapshot(
        accountId,
        input,
        signal,
        (resolved) => context = resolved,
      );
      const output = await snapshotToolResult(value, context, options, signal);
      return { content: [{ type: "text", text: toolText(output) }], details: {} };
    },
  });

  const proposeInvestmentHoldingSnapshot = defineTool({
    name: "finwealth_propose_investment_holding_snapshot",
    label: "创建投资持仓快照审核",
    description:
      "把券商、基金平台或其他非加密投资来源中的当前数量整理成一个待审核持仓快照。只提交来源中明确出现的类型、代码、名称、市场、计价币和数量；Rust 会严格匹配或登记并返回真实 instrumentId。快照成功后会从结构化来源生成独立的待审核报价候选；它不会确认持仓、修改余额或写入报价。",
    promptSnippet: "把券商或基金来源中的非加密投资数量整理为一个待审核持仓快照。",
    promptGuidelines: [
      "先查询 accounts、instruments 和 holdings，确认目标账户与已有标的。",
      "positions 只能填写来源中明确出现的 type、symbol、displayName、market、quoteCurrency 和当前总数量；缺少市场或计价币时先询问用户。",
      "市场使用来源可验证的规范代码；美股使用 NASDAQ/NYSE/AMEX/ARCA，沪市使用 SSE，深市使用 SZSE，港股使用 HKEX 且计价币为 HKD。不要根据证券代码猜市场。",
      "不得提交或编造 instrumentId；工具内部由 Rust 严格匹配或生成 ID，并验证完整映射。",
      "equity 用于股票，fund 用于基金或 ETF，other 只用于来源明确但现有类型没有覆盖的投资品；加密资产必须使用加密持仓快照工具。",
      "同一份快照的全部资产必须一次提交；targetQuantity 是当前总数量，不是本期增量，且不得为负数。",
      "快照成功后工具会自动查询相关标的报价与折算汇率；不要为同一批标的重复调用报价工具。",
      "该工具只生成待审核组；不得随后调用确认、批准或报价采用接口。",
    ],
    parameters: Type.Object({
      accountId: Type.String({ minLength: 1 }),
      asOf: Type.Optional(Type.String({ description: "带时区的 RFC3339 时间" })),
      positions: Type.Array(
        Type.Object({
          type: Type.Union([
            Type.Literal("equity"),
            Type.Literal("fund"),
            Type.Literal("other"),
          ]),
          symbol: Type.String({
            minLength: 1,
            maxLength: 32,
            pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$",
          }),
          displayName: Type.String({ minLength: 1, maxLength: 120 }),
          market: Type.String({
            minLength: 1,
            maxLength: 24,
            pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,23}$",
          }),
          quoteCurrency: Type.String({
            minLength: 2,
            maxLength: 12,
            pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{1,11}$",
          }),
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
      let context: HoldingSnapshotQuoteContext | undefined;
      const value = await client.proposeInvestmentHoldingSnapshot(
        accountId,
        input,
        signal,
        (resolved) => context = resolved,
      );
      const output = await snapshotToolResult(value, context, options, signal);
      return { content: [{ type: "text", text: toolText(output) }], details: {} };
    },
  });

  const ensureCryptoInstruments = defineTool({
    name: "finwealth_ensure_crypto_instruments",
    label: "登记加密资产标的",
    description:
      "为一个持仓账户登记或复用来源中实际出现的加密资产标的元数据，并返回真实 instrumentId。它不会创建或改变持仓数量、余额、报价和账务记录。仅在查询 instruments 后确认所需标的缺失时使用。",
    promptSnippet: "在创建交易所或钱包持仓快照前，补齐来源中加密资产的真实标的 ID。",
    promptGuidelines: [
      "调用前先用 finwealth_query 查询 accounts 和 instruments；已有标的必须直接复用。",
      "symbols 只能来自用户消息、附件或查询结果中实际出现的加密资产代码；不得猜测、补全或登记股票、基金和法币。",
      "工具返回后使用其中的真实 instrumentId 创建待审核持仓快照；不得把 symbol 当作 ID。",
      "登记元数据不代表用户持有该资产，也不得据此生成非零数量。",
      "新标的没有报价时仍保留原始数量；如需估值，另行生成待审核报价候选，不得自动采用。",
    ],
    parameters: Type.Object({
      accountId: Type.String({ minLength: 1 }),
      symbols: Type.Array(
        Type.String({
          minLength: 1,
          maxLength: 20,
          pattern: "^[A-Za-z0-9][A-Za-z0-9._-]{0,19}$",
        }),
        { minItems: 1, maxItems: 100 },
      ),
    }),
    executionMode: "sequential",
    async execute(_id, params, signal) {
      const value = await client.ensureCryptoInstruments(
        params.accountId,
        params.symbols,
        signal,
      );
      return { content: [{ type: "text", text: toolText(value) }], details: {} };
    },
  });

  return [
    query,
    ensureCryptoInstruments,
    proposeMovement,
    proposeHoldingSnapshot,
    proposeInvestmentHoldingSnapshot,
  ];
}
