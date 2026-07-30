import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, test } from "node:test";
import { AgentService } from "../src/agent-service.js";
import { EventHub } from "../src/event-hub.js";
import {
  FinwealthClient,
  createFinwealthTools,
  normalizeMovementProposalForLedger,
  quoteCandidateInputsFromLookup,
} from "../src/finwealth-client.js";
import { createAgentHttpServer } from "../src/http-server.js";
import { StateStore } from "../src/state-store.js";
import type {
  AgentConversation,
  AgentEngine,
  AgentModelInfo,
  Principal,
  AgentQuoteCandidate,
  AgentQuoteWriter,
  AgentAutomation,
  AgentAutomationResult,
  AgentAutomationRunner,
  RunCallbacks,
} from "../src/types.js";
import { createWorkspaceTools } from "../src/workspace-tools.js";
import { createMemoryTools } from "../src/memory-tools.js";
import {
  createQuoteCandidateTools,
  suggestQuoteCandidate,
} from "../src/quote-candidate-tools.js";
import { prepareFileAttachmentPrompt } from "../src/pi-engine.js";
import { attachmentMatchesMime } from "../src/attachment-formats.js";

const roots: string[] = [];
const owner: Principal = {
  userId: "usr_owner",
  ledgerId: "ledger_default",
  deviceId: "dev_test",
};

test("accepts a JPEG with a small post-EOI metadata trailer", () => {
  // WeChat commonly appends private metadata after the JPEG EOI marker.
  // Decoders accept it; the attachment gate must not call it a MIME mismatch.
  const jpeg = Buffer.from([
    0xff, 0xd8, 0xff, 0xe0, 0x00, 0x04, 0x4a, 0x46,
    0xff, 0xd9,
    0x17, 0x4d, 0xa1, 0x01, 0x00, 0x00, 0x00, 0x00,
    0x42, 0xcd, 0xf2, 0xe4, 0x03, 0xc5, 0xbf, 0x2f,
    0x8d, 0x87, 0x5c, 0x01, 0xeb, 0xfc, 0x4b, 0x5e,
  ]);
  assert.equal(attachmentMatchesMime("image/jpeg", jpeg), true);
  assert.equal(
    attachmentMatchesMime(
      "image/jpeg",
      Buffer.concat([jpeg.subarray(0, 10), Buffer.alloc(4 * 1024 + 1)]),
    ),
    false,
  );
});

test("cash-only movement proposals drop a spurious instrument without rewriting accounting intent", () => {
  const input = {
    type: "expense",
    occurredAt: "2026-07-28T12:30:00+08:00",
    title: "Test Cafe",
    entries: [{
      accountId: "acct_cash",
      instrumentId: "CNY",
      amount: "88.20",
      currency: "CNY",
      direction: "out",
      role: "source",
    }],
  };
  assert.deepEqual(normalizeMovementProposalForLedger(input), {
    ...input,
    entries: [{
      accountId: "acct_cash",
      amount: "88.20",
      currency: "CNY",
      direction: "out",
      role: "source",
    }],
  });
  assert.equal(input.entries[0]?.instrumentId, "CNY");

  const buy = { type: "buy", entries: [{ instrumentId: "inst_btc" }] };
  assert.equal(normalizeMovementProposalForLedger(buy), buy);
});

function storedZip(fileNames: string[]): Buffer {
  const locals: Buffer[] = [];
  const centrals: Buffer[] = [];
  let localOffset = 0;
  for (const fileName of fileNames) {
    const name = Buffer.from(fileName, "utf8");
    const local = Buffer.alloc(30 + name.length);
    local.writeUInt32LE(0x04034b50, 0);
    local.writeUInt16LE(20, 4);
    local.writeUInt16LE(name.length, 26);
    name.copy(local, 30);
    locals.push(local);
    const central = Buffer.alloc(46 + name.length);
    central.writeUInt32LE(0x02014b50, 0);
    central.writeUInt16LE(20, 4);
    central.writeUInt16LE(20, 6);
    central.writeUInt16LE(name.length, 28);
    central.writeUInt32LE(localOffset, 42);
    name.copy(central, 46);
    centrals.push(central);
    localOffset += local.length;
  }
  const centralBytes = Buffer.concat(centrals);
  const eocd = Buffer.alloc(22);
  eocd.writeUInt32LE(0x06054b50, 0);
  eocd.writeUInt16LE(fileNames.length, 8);
  eocd.writeUInt16LE(fileNames.length, 10);
  eocd.writeUInt32LE(centralBytes.length, 12);
  eocd.writeUInt32LE(localOffset, 16);
  return Buffer.concat([...locals, centralBytes, eocd]);
}

class FakeEngine implements AgentEngine {
  readonly models: AgentModelInfo[];
  cancelled: string[] = [];
  lastAttachmentCount = 0;
  failure?: string;
  deleted: string[] = [];

  constructor(models: AgentModelInfo[] = [
    {
      id: "test/vision",
      provider: "test",
      displayName: "Test Vision",
      supportsImages: true,
    },
  ]) {
    this.models = models;
  }

  async listModels(): Promise<AgentModelInfo[]> {
    return this.models;
  }

  async run(
    conversation: AgentConversation,
    text: string,
    _attachments: import("../src/types.js").AgentAttachment[],
    callbacks: RunCallbacks,
  ): Promise<{ text: string; piSessionFile?: string }> {
    this.lastAttachmentCount = _attachments.length;
    if (this.failure) throw new Error(this.failure);
    callbacks.onToolStarted("finwealth_overview");
    callbacks.onToolCompleted("finwealth_overview", false);
    callbacks.onDelta("已处理：");
    callbacks.onDelta(text);
    return {
      text: `已处理：${text}`,
      piSessionFile: join("sessions", `${conversation.id}.jsonl`),
    };
  }

  async cancel(conversationId: string): Promise<boolean> {
    this.cancelled.push(conversationId);
    return true;
  }

  async deleteConversation(conversation: AgentConversation): Promise<void> {
    this.deleted.push(conversation.id);
  }
}

class FakeQuoteWriter implements AgentQuoteWriter {
  applied: AgentQuoteCandidate[] = [];
  failure?: string;

  async applyQuoteCandidate(candidate: AgentQuoteCandidate): Promise<unknown> {
    if (this.failure) throw new Error(this.failure);
    this.applied.push(candidate);
    return { ok: true };
  }
}

class FakeAutomationRunner implements AgentAutomationRunner {
  runs: Array<{ automation: AgentAutomation; scheduledFor: string }> = [];
  failure?: string;
  result: AgentAutomationResult = {
    title: "订阅扣费等待审核",
    body: "新增 2 条待审核记录",
    action: "review",
    notify: true,
  };

  async runAutomation(
    automation: AgentAutomation,
    scheduledFor: string,
  ): Promise<AgentAutomationResult> {
    if (this.failure) throw new Error(this.failure);
    this.runs.push({ automation, scheduledFor });
    return this.result;
  }
}

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true })));
});

test("pre-extracts PDF and XLSX text before the model prompt", async () => {
  const workspace = join(tmpdir(), "finwealth-pdf-prompt-test");
  const calls: string[] = [];
  const events: Array<[string, boolean?]> = [];
  const prompt = await prepareFileAttachmentPrompt(
    workspace,
    [
      {
        id: "att_pdf",
        userId: owner.userId,
        ledgerId: owner.ledgerId,
        fileName: "statement.pdf",
        mimeType: "application/pdf",
        sizeBytes: 123,
        sha256: "0".repeat(64),
        originalPath: join(workspace, "original", "statement.pdf"),
        workingPath: join(workspace, "attachments", "att_pdf", "statement.pdf"),
        createdAt: "2026-07-28T00:00:00Z",
      },
      {
        id: "att_xlsx",
        userId: owner.userId,
        ledgerId: owner.ledgerId,
        fileName: "statement.xlsx",
        mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        sizeBytes: 456,
        sha256: "1".repeat(64),
        originalPath: join(workspace, "original", "statement.xlsx"),
        workingPath: join(workspace, "attachments", "att_xlsx", "statement.xlsx"),
        createdAt: "2026-07-28T00:00:00Z",
      },
    ],
    {
      onToolStarted(name) { events.push([name]); },
      onToolCompleted(name, isError) { events.push([name, isError]); },
    },
    async (_workspace, path) => {
      calls.push(path);
      return "PDF_MARKER_123";
    },
    async (_workspace, path) => {
      calls.push(path);
      return "XLSX_MARKER_456";
    },
  );

  assert.deepEqual(calls, [
    join(workspace, "attachments", "att_pdf", "statement.pdf"),
    join(workspace, "attachments", "att_xlsx", "statement.xlsx"),
  ]);
  assert.deepEqual(events, [
    ["finwealth_read_pdf_text"],
    ["finwealth_read_pdf_text", false],
    ["finwealth_read_xlsx_text"],
    ["finwealth_read_xlsx_text", false],
  ]);
  assert.match(prompt.join("\n"), /<finwealth_pdf_text>/);
  assert.match(prompt.join("\n"), /PDF_MARKER_123/);
  assert.match(prompt.join("\n"), /<finwealth_xlsx_text>/);
  assert.match(prompt.join("\n"), /XLSX_MARKER_456/);
  assert.match(prompt.join("\n"), /不要再解析这些原文件/);
});

async function serviceWith(
  engine: AgentEngine = new FakeEngine(),
  quoteWriter?: AgentQuoteWriter,
  automationRunner?: AgentAutomationRunner,
): Promise<AgentService> {
  const root = await mkdtemp(join(tmpdir(), "finwealth-agent-test-"));
  roots.push(root);
  return new AgentService(
    new StateStore(root),
    new EventHub(),
    engine,
    quoteWriter,
    automationRunner,
  );
}

async function waitForCompleted(
  service: AgentService,
  conversationId: string,
): Promise<void> {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    const messages = await service.listMessages(owner, conversationId);
    const completed = messages.find(
      (message) => message.role === "assistant" && message.status === "completed",
    );
    if (completed?.runId) {
      const events = await service.listEvents(owner, conversationId, 0);
      if (events.some(
        (event) => event.type === "run.completed" && event.data.runId === completed.runId,
      )) return;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.fail("assistant message did not complete");
}

test("creates one persistent owner-scoped primary conversation", async () => {
  const service = await serviceWith();
  const first = await service.listConversations(owner);
  const second = await service.listConversations(owner);

  assert.equal(first.length, 1);
  assert.equal(first[0]?.isPrimary, true);
  assert.equal(first[0]?.title, "财务助手");
  assert.equal(second[0]?.id, first[0]?.id);

  const reloaded = new AgentService(
    new StateStore(service.store.root),
    new EventHub(),
    new FakeEngine(),
  );
  assert.equal((await reloaded.listConversations(owner))[0]?.id, first[0]?.id);
});

test("deletes only archived non-primary conversations and their history", async () => {
  const engine = new FakeEngine();
  const service = await serviceWith(engine);
  const primary = (await service.listConversations(owner))[0];
  assert.ok(primary);
  const old = await service.createConversation(owner, "旧对话");
  const bytes = Buffer.from("old attachment", "utf8");
  const attachment = await service.createAttachment(owner, {
    fileName: "old.txt",
    mimeType: "text/plain",
    bytes,
    sha256: createHash("sha256").update(bytes).digest("hex"),
  });
  const storedAttachment = (await service.store.read(owner.userId)).attachments
    .find((item) => item.id === attachment.id);
  assert.ok(storedAttachment);
  await service.sendMessage(owner, old.id, "旧内容", [attachment.id]);
  await waitForCompleted(service, old.id);

  await assert.rejects(
    service.deleteConversation(owner, primary.id),
    /primary_conversation_cannot_be_deleted/,
  );
  await assert.rejects(
    service.deleteConversation(owner, old.id),
    /conversation_must_be_archived_before_delete/,
  );
  await service.updateConversation(owner, old.id, { status: "archived" });
  const result = await service.deleteConversation(owner, old.id);

  assert.equal(result.conversationId, old.id);
  assert.equal(result.deletedMessageCount, 2);
  assert.equal(result.deletedAttachmentCount, 1);
  assert.deepEqual(engine.deleted, [old.id]);
  assert.equal(
    (await service.listConversations(owner)).some((item) => item.id === old.id),
    false,
  );
  await assert.rejects(
    service.listMessages(owner, old.id),
    /conversation_not_found/,
  );
  await assert.rejects(readFile(storedAttachment.originalPath), /ENOENT/);
  await assert.rejects(readFile(storedAttachment.workingPath), /ENOENT/);
});

test("queues a run, records compact tool events, and persists the Pi session path", async () => {
  const service = await serviceWith();
  const conversation = (await service.listConversations(owner))[0];
  assert.ok(conversation);

  const accepted = await service.sendMessage(owner, conversation.id, "汇总今天消费");
  await waitForCompleted(service, conversation.id);
  for (let attempt = 0; attempt < 100; attempt += 1) {
    if (
      (await service.listEvents(owner, conversation.id, 0)).some(
        (event) => event.type === "run.completed",
      )
    ) {
      break;
    }
    await new Promise((resolve) => setTimeout(resolve, 5));
  }

  const messages = await service.listMessages(owner, conversation.id);
  assert.equal(messages.length, 2);
  assert.equal(messages[0]?.text, "汇总今天消费");
  assert.equal(messages[1]?.text, "已处理：汇总今天消费");
  assert.equal(messages[1]?.runId, accepted.runId);

  const events = await service.listEvents(owner, conversation.id, 0);
  assert.deepEqual(
    events.map((event) => event.type),
    [
      "run.queued",
      "run.started",
      "tool.started",
      "tool.completed",
      "message.delta",
      "message.delta",
      "run.completed",
    ],
  );
  const stored = (await service.listConversations(owner))[0];
  assert.equal(stored?.piSessionFile, join("sessions", `${conversation.id}.jsonl`));
});

test("cancelling a queued run does not abort the active run", async () => {
  let release!: () => void;
  const gate = new Promise<void>((resolve) => { release = resolve; });
  const engine: AgentEngine & { runCalls: number; cancelCalls: number } = {
    runCalls: 0,
    cancelCalls: 0,
    async listModels() {
      return [{
        id: "test/text",
        provider: "test",
        displayName: "Test Text",
        supportsImages: false,
      }];
    },
    async run(_conversation, text, _attachments, callbacks) {
      this.runCalls += 1;
      await gate;
      callbacks.onDelta(text);
      return { text };
    },
    async cancel() {
      this.cancelCalls += 1;
      return true;
    },
  };
  const service = await serviceWith(engine);
  const conversation = (await service.listConversations(owner))[0];
  assert.ok(conversation);
  const active = await service.sendMessage(owner, conversation.id, "first");
  const queued = await service.sendMessage(owner, conversation.id, "second");

  assert.equal(await service.cancelRun(owner, queued.runId), true);
  assert.equal(engine.cancelCalls, 0);
  release();
  await waitForCompleted(service, conversation.id);

  assert.equal(engine.runCalls, 1);
  const messages = await service.listMessages(owner, conversation.id);
  assert.equal(
    messages.find((item) => item.runId === active.runId && item.role === "assistant")?.status,
    "completed",
  );
  const cancelled = messages.find(
    (item) => item.runId === queued.runId && item.role === "assistant",
  );
  assert.equal(cancelled?.status, "failed");
  assert.equal(cancelled?.errorCode, "agent_run_aborted");
  const events = await service.listEvents(owner, conversation.id, 0);
  assert.equal(
    events.some((event) => event.type === "run.started" && event.data.runId === queued.runId),
    false,
  );
});

test("does not expose one principal's conversation to another principal", async () => {
  const service = await serviceWith();
  const conversation = (await service.listConversations(owner))[0];
  assert.ok(conversation);
  const stranger = { ...owner, userId: "usr_other" };

  await assert.rejects(
    service.listMessages(stranger, conversation.id),
    /conversation_not_found/,
  );
});

test("fails before accepting a message when Pi has no configured model", async () => {
  const service = await serviceWith(new FakeEngine([]));
  const conversation = (await service.listConversations(owner))[0];
  assert.ok(conversation);
  await assert.rejects(
    service.sendMessage(owner, conversation.id, "hello"),
    /agent_model_unavailable/,
  );
  assert.deepEqual(await service.listMessages(owner, conversation.id), []);
});

test("HTTP surface requires the Rust gateway token and principal headers", async () => {
  const service = await serviceWith();
  const server = createAgentHttpServer(service, "internal-test-token");
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const base = `http://127.0.0.1:${address.port}`;
  try {
    const unauthorized = await fetch(`${base}/v1/agent/status`);
    assert.equal(unauthorized.status, 401);

    const authorized = await fetch(`${base}/v1/agent/status`, {
      headers: {
        "x-finwealth-internal-token": "internal-test-token",
        "x-finwealth-user-id": owner.userId,
        "x-finwealth-ledger-id": owner.ledgerId,
        "x-finwealth-device-id": owner.deviceId,
      },
    });
    assert.equal(authorized.status, 200);
    const body = (await authorized.json()) as {
      data: { configured: boolean; userId: string };
    };
    assert.equal(body.data.configured, true);
    assert.equal(body.data.userId, owner.userId);
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
});

test("HTTP permanently deletes an archived conversation idempotently", async () => {
  const service = await serviceWith();
  const conversation = await service.createConversation(owner, "待删除");
  await service.updateConversation(owner, conversation.id, { status: "archived" });
  const server = createAgentHttpServer(service, "internal-test-token");
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const url = `http://127.0.0.1:${address.port}/v1/agent/conversations/${conversation.id}`;
  const headers = {
    "x-finwealth-internal-token": "internal-test-token",
    "x-finwealth-user-id": owner.userId,
    "x-finwealth-ledger-id": owner.ledgerId,
    "x-finwealth-device-id": owner.deviceId,
    "idempotency-key": "delete-old-conversation",
  };
  try {
    const deleted = await fetch(url, { method: "DELETE", headers });
    assert.equal(deleted.status, 200);
    assert.equal(
      ((await deleted.json()) as { data: { conversationId: string } }).data
        .conversationId,
      conversation.id,
    );
    const replay = await fetch(url, { method: "DELETE", headers });
    assert.equal(replay.status, 200);
    assert.equal(replay.headers.get("idempotency-replayed"), "true");
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
});

test("persists idempotency results and rejects reuse for a different request", async () => {
  const service = await serviceWith();
  let executions = 0;
  const first = await service.idempotent(
    owner,
    "retry-key",
    "test operation",
    { text: "same" },
    async () => ({ execution: ++executions }),
  );
  const replay = await service.idempotent(
    owner,
    "retry-key",
    "test operation",
    { text: "same" },
    async () => ({ execution: ++executions }),
  );

  assert.deepEqual(first, { value: { execution: 1 }, replayed: false });
  assert.deepEqual(replay, { value: { execution: 1 }, replayed: true });
  assert.equal(executions, 1);
  await assert.rejects(
    service.idempotent(
      owner,
      "retry-key",
      "test operation",
      { text: "different" },
      async () => ({ execution: ++executions }),
    ),
    /idempotency_key_reused/,
  );
});

test("Finwealth client reads data and submits a draft only to review", async () => {
  const requests: Array<{
    method: string | undefined;
    path: string | undefined;
    token: string | undefined;
    key: string | undefined;
    body: unknown;
  }> = [];
  const server = createServer(async (request, response) => {
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(Buffer.from(chunk));
    requests.push({
      method: request.method,
      path: request.url,
      token: typeof request.headers["x-finwealth-internal-token"] === "string"
        ? request.headers["x-finwealth-internal-token"]
        : undefined,
      key: typeof request.headers["idempotency-key"] === "string"
        ? request.headers["idempotency-key"]
        : undefined,
      body: chunks.length ? JSON.parse(Buffer.concat(chunks).toString("utf8")) : undefined,
    });
    let data: unknown = [];
    let status = 200;
    if (request.url === "/v1/movements/drafts") {
      data = { id: "mov_agent_draft" };
      status = 201;
    } else if (request.url === "/v1/movements/mov_agent_draft/submit-review") {
      data = { id: "grp_agent_review", status: "pending" };
    } else if (request.url === "/v1/accounts/acct%2Fokx/holding-snapshot-proposals") {
      data = { id: "grp_holding_snapshot", status: "pending" };
    } else if (request.url === "/v1/accounts/acct%2Fokx/crypto-instruments/ensure") {
      data = {
        accountId: "acct/okx",
        instruments: [
          { id: "inst_btc", symbol: "BTC" },
          { id: "inst_eth", symbol: "ETH" },
          { id: "inst_sol", symbol: "SOL" },
        ],
        createdCount: 3,
        updatedCount: 0,
        reusedCount: 0,
      };
    }
    response.writeHead(status, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: true, data }));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address === "object");
  try {
    const client = new FinwealthClient(
      `http://127.0.0.1:${address.port}`,
      "sidecar-secret",
    );
    await client.query("accounts");
    await client.query("instruments");
    await client.lookupStructuredQuotes({
      currencyPairs: [{ baseCurrency: "USD", quoteCurrency: "CNY" }],
    });
    await client.proposeMovement({
      type: "expense",
      occurredAt: "2026-07-28T00:00:00Z",
      title: "午餐",
      entries: [],
    });
    await client.ensureCryptoInstruments("acct/okx", ["BTC", "ETH", "SOL"]);
    await client.proposeHoldingSnapshot("acct/okx", {
      asOf: "2026-07-29T10:00:00Z",
      positions: [
        { instrumentId: "inst_btc_usdt", targetQuantity: "0.25" },
        { instrumentId: "inst_eth_usdt", targetQuantity: "3.2" },
      ],
      note: "OKX 持仓快照",
    });
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }

  assert.deepEqual(
    requests.map((item) => `${item.method} ${item.path}`),
    [
      "GET /v1/accounts",
      "GET /v1/instruments",
      "POST /v1/quotes/lookup",
      "POST /v1/movements/drafts",
      "POST /v1/movements/mov_agent_draft/submit-review",
      "POST /v1/accounts/acct%2Fokx/crypto-instruments/ensure",
      "POST /v1/accounts/acct%2Fokx/holding-snapshot-proposals",
    ],
  );
  assert.ok(requests.every((item) => item.token === "sidecar-secret"));
  assert.ok(requests.every((item) => !item.path?.includes("confirm")));
  assert.ok(requests.every((item) => !item.path?.includes("approve")));
  const ensure = requests.at(-2);
  assert.match(ensure?.key ?? "", /^agent-crypto-instruments-/);
  assert.deepEqual(ensure?.body, { symbols: ["BTC", "ETH", "SOL"] });
  const snapshot = requests.at(-1);
  assert.match(snapshot?.key ?? "", /^agent-holding-snapshot-/);
  assert.deepEqual(snapshot?.body, {
    asOf: "2026-07-29T10:00:00Z",
    positions: [
      { instrumentId: "inst_btc_usdt", targetQuantity: "0.25" },
      { instrumentId: "inst_eth_usdt", targetQuantity: "3.2" },
    ],
    note: "OKX 持仓快照",
  });
});

test("Finwealth tools expose bounded crypto registration before holding snapshots", () => {
  const client = new FinwealthClient("http://127.0.0.1:1", "sidecar-secret");
  const tools = createFinwealthTools(client);
  assert.deepEqual(
    tools.map((tool) => tool.name),
    [
      "finwealth_query",
      "finwealth_ensure_crypto_instruments",
      "finwealth_propose_movement",
      "finwealth_propose_holding_snapshot",
    ],
  );
  const ensure = tools.find((tool) => tool.name === "finwealth_ensure_crypto_instruments");
  assert.ok(ensure);
  assert.match(ensure.description, /不会创建或改变持仓数量/);
  assert.match(ensure.description, /来源中实际出现/);
});

test("Finwealth client applies an approved quote with a stable candidate idempotency key", async () => {
  let capturedBody: Record<string, unknown> | undefined;
  let capturedKey: string | undefined;
  const server = createServer(async (request, response) => {
    const chunks: Buffer[] = [];
    for await (const chunk of request) chunks.push(Buffer.from(chunk));
    capturedBody = JSON.parse(Buffer.concat(chunks).toString("utf8")) as Record<string, unknown>;
    capturedKey = typeof request.headers["idempotency-key"] === "string"
      ? request.headers["idempotency-key"]
      : undefined;
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({
      ok: true,
      data: { quotes: [{ id: "quote_applied" }], fxRates: [], errors: [] },
    }));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address === "object");
  try {
    const client = new FinwealthClient(
      `http://127.0.0.1:${address.port}`,
      "sidecar-secret",
    );
    await client.applyQuoteCandidate({
      id: "aqc_stable",
      userId: owner.userId,
      ledgerId: owner.ledgerId,
      kind: "instrument",
      instrumentId: "inst_btc",
      price: "118234.25",
      currency: "USDT",
      asOf: "2026-07-28T10:00:00Z",
      source: "Example Exchange",
      sourceUrl: "https://example.test/markets/btc-usdt",
      status: "suggested",
      createdAt: "2026-07-28T10:01:00Z",
      updatedAt: "2026-07-28T10:01:00Z",
    });
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
  assert.equal(capturedKey, "agent-quote-aqc_stable");
  assert.deepEqual(capturedBody, {
    mode: "manual",
    requestedAt: "2026-07-28T10:01:00Z",
    quotes: [{
      instrumentId: "inst_btc",
      price: "118234.25",
      currency: "USDT",
      asOf: "2026-07-28T10:00:00Z",
      source: "Example Exchange",
      sourceUrl: "https://example.test/markets/btc-usdt",
    }],
  });
});

test("Finwealth client maps scheduled quotes, subscription scans and DCA checks", async () => {
  const requests: Array<{ path: string; key?: string }> = [];
  const server = createServer(async (request, response) => {
    for await (const _chunk of request) { /* consume body */ }
    requests.push({
      path: request.url ?? "",
      ...(typeof request.headers["idempotency-key"] === "string"
        ? { key: request.headers["idempotency-key"] }
        : {}),
    });
    const data = request.url === "/v1/quotes/lookup"
      ? {
        quotes: [{
          instrumentId: "inst_btc",
          price: "118234.25",
          currency: "USDT",
          asOf: "2026-07-28T10:00:00Z",
          source: "coingecko",
          sourceUrl: "https://www.coingecko.com/",
        }],
        fxRates: [{
          baseCurrency: "USD",
          quoteCurrency: "CNY",
          rate: "7.21",
          asOf: "2026-07-28T00:00:00Z",
          source: "frankfurter_ecb",
          sourceUrl: "https://frankfurter.app/",
        }],
        errors: [],
      }
      : request.url === "/v1/subscriptions/charge-proposals/due-scan"
      ? { createdCount: 2, blockedCount: 1, remainingEligibleCount: 0 }
      : [{ id: "reminder_due" }];
    response.writeHead(200, { "content-type": "application/json" });
    response.end(JSON.stringify({ ok: true, data }));
  });
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const base: Omit<AgentAutomation, "kind"> = {
    id: "auto_test",
    userId: owner.userId,
    ledgerId: owner.ledgerId,
    deviceId: owner.deviceId,
    intervalHours: 24,
    enabled: true,
    nextRunAt: "2026-07-28T00:00:00Z",
    createdAt: "2026-07-27T00:00:00Z",
    updatedAt: "2026-07-27T00:00:00Z",
  };
  try {
    const client = new FinwealthClient(
      `http://127.0.0.1:${address.port}`,
      "sidecar-secret",
    );
    const quote = await client.runAutomation(
      { ...base, kind: "quote_refresh" },
      "2026-07-28T00:00:00Z",
    );
    const subscription = await client.runAutomation(
      { ...base, kind: "subscription_due_scan" },
      "2026-07-28T00:00:00Z",
    );
    const dca = await client.runAutomation(
      { ...base, kind: "dca_due_check" },
      "2026-07-28T00:00:00Z",
    );
    assert.equal(quote.notify, true);
    assert.equal(quote.quoteCandidateInputs?.length, 2);
    assert.equal(subscription.action, "review");
    assert.equal(subscription.notify, true);
    assert.equal(dca.action, "dca");
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
  assert.deepEqual(requests.map((item) => item.path), [
    "/v1/quotes/lookup",
    "/v1/subscriptions/charge-proposals/due-scan",
    "/v1/dca/reminders/due",
  ]);
  assert.equal(requests[0]?.key, undefined);
  assert.equal(requests[1]?.key, "agent-auto-auto_test-2026-07-28T00:00:00Z");
  assert.equal(requests[2]?.key, undefined);
});

test("structured quote lookup maps provider data into review candidate inputs", () => {
  const inputs = quoteCandidateInputsFromLookup({
    ok: true,
    data: {
      quotes: [{
        instrumentId: "inst_eth",
        price: "3820.15",
        currency: "USDT",
        asOf: "2026-07-29T04:00:00Z",
        source: "coingecko",
        sourceUrl: "https://www.coingecko.com/",
      }],
      fxRates: [{
        baseCurrency: "USD",
        quoteCurrency: "CNY",
        rate: "7.1882",
        asOf: "2026-07-29T00:00:00Z",
        source: "frankfurter_ecb",
        sourceUrl: "https://frankfurter.app/",
      }],
    },
  });
  assert.deepEqual(inputs.map((item) => item.kind), ["instrument", "fx"]);
  assert.equal(inputs[1]?.rate, "7.1882");
});

test("quote tools require deterministic lookup before web fallback", async () => {
  const service = await serviceWith(new FakeEngine());
  const conversation = (await service.listConversations(owner))[0];
  assert.ok(conversation);
  let lookupReturnsRate = true;
  const tools = createQuoteCandidateTools(service.store, conversation, {
    async lookupStructuredQuotes() {
      return lookupReturnsRate
        ? {
          ok: true,
          data: {
            fxRates: [{
              baseCurrency: "USD",
              quoteCurrency: "CNY",
              rate: "7.1882",
              asOf: "2026-07-29T00:00:00Z",
              source: "frankfurter_ecb",
              sourceUrl: "https://frankfurter.app/",
            }],
            quotes: [],
            errors: [],
          },
        }
        : { ok: true, data: { fxRates: [], quotes: [], errors: [{}] } };
    },
  });
  const lookup = tools.find((tool) => tool.name === "finwealth_lookup_quote_candidate");
  const suggest = tools.find((tool) => tool.name === "finwealth_suggest_quote");
  assert.ok(lookup && suggest);
  const webInput = {
    kind: "fx" as const,
    baseCurrency: "USD",
    quoteCurrency: "CNY",
    rate: "7.2",
    asOf: "2026-07-29T05:00:00Z",
    source: "Example FX",
    sourceUrl: "https://example.test/usd-cny",
  };
  await assert.rejects(
    suggest.execute("web-before-lookup", webInput, undefined, undefined, {} as never),
    /structured_quote_lookup_required/,
  );
  await lookup.execute(
    "structured-success",
    { kind: "fx", baseCurrency: "USD", quoteCurrency: "CNY" },
    undefined,
    undefined,
    {} as never,
  );
  assert.equal((await service.listQuoteCandidates(owner)).length, 1);
  await assert.rejects(
    suggest.execute("web-after-success", webInput, undefined, undefined, {} as never),
    /structured_quote_lookup_required/,
  );

  lookupReturnsRate = false;
  await lookup.execute(
    "structured-miss",
    { kind: "fx", baseCurrency: "EUR", quoteCurrency: "CNY" },
    undefined,
    undefined,
    {} as never,
  );
  await suggest.execute(
    "web-after-miss",
    { ...webInput, baseCurrency: "EUR", rate: "8.2" },
    undefined,
    undefined,
    {} as never,
  );
  assert.equal((await service.listQuoteCandidates(owner)).length, 2);
});

test("scheduled quote checks persist suggestions without applying quotes", async () => {
  const writer = new FakeQuoteWriter();
  const runner = new FakeAutomationRunner();
  runner.result = {
    title: "报价建议等待审核",
    body: "新增 1 条报价建议",
    action: "quotes",
    notify: true,
    quoteCandidateInputs: [{
      kind: "fx",
      baseCurrency: "USD",
      quoteCurrency: "CNY",
      rate: "7.1882",
      asOf: "2026-07-29T00:00:00Z",
      source: "frankfurter_ecb",
      sourceUrl: "https://frankfurter.app/",
    }],
  };
  const service = await serviceWith(new FakeEngine(), writer, runner);
  const automation = await service.createAutomation(owner, {
    kind: "quote_refresh",
    intervalHours: 24,
    enabled: true,
    startAt: "2026-07-29T00:00:00Z",
  });
  await service.runAutomationNow(owner, automation.id);
  const candidates = await service.listQuoteCandidates(owner);
  assert.equal(candidates.length, 1);
  assert.equal(candidates[0]?.status, "suggested");
  assert.equal(writer.applied.length, 0);
});

test("archives an image and passes only owned attachment IDs to the model", async () => {
  const engine = new FakeEngine();
  const service = await serviceWith(engine);
  const conversation = (await service.listConversations(owner))[0];
  assert.ok(conversation);
  const server = createAgentHttpServer(service, "internal-test-token");
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const base = `http://127.0.0.1:${address.port}`;
  const principalHeaders = {
    "x-finwealth-internal-token": "internal-test-token",
    "x-finwealth-user-id": owner.userId,
    "x-finwealth-ledger-id": owner.ledgerId,
    "x-finwealth-device-id": owner.deviceId,
  };
  try {
    const imageBytes = Buffer.from(
      "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
      "base64",
    );
    const form = new FormData();
    form.append(
      "file",
      new Blob([imageBytes], { type: "image/png" }),
      "bill.png",
    );
    const uploaded = await fetch(`${base}/v1/agent/attachments`, {
      method: "POST",
      headers: { ...principalHeaders, "idempotency-key": "upload-bill-1" },
      body: form,
    });
    assert.equal(uploaded.status, 201);
    const uploadedBody = await uploaded.json() as { data: { id: string } };

    const metadata = await fetch(
      `${base}/v1/agent/attachments/${uploadedBody.data.id}`,
      { headers: principalHeaders },
    );
    assert.equal(metadata.status, 200);
    const metadataBody = await metadata.json() as {
      data: Record<string, unknown>;
    };
    assert.equal(metadataBody.data.mimeType, "image/png");
    assert.equal(metadataBody.data.fileName, "bill.png");
    assert.equal("originalPath" in metadataBody.data, false);
    assert.equal("workingPath" in metadataBody.data, false);

    const content = await fetch(
      `${base}/v1/agent/attachments/${uploadedBody.data.id}/content`,
      { headers: principalHeaders },
    );
    assert.equal(content.status, 200);
    assert.equal(content.headers.get("content-type"), "image/png");
    assert.equal(content.headers.get("cache-control"), "private, no-store");
    assert.equal(content.headers.get("x-content-type-options"), "nosniff");
    assert.match(content.headers.get("etag") ?? "", /^"sha256-[a-f0-9]{64}"$/);
    assert.deepEqual(Buffer.from(await content.arrayBuffer()), imageBytes);

    const otherLedger = await fetch(
      `${base}/v1/agent/attachments/${uploadedBody.data.id}`,
      {
        headers: {
          ...principalHeaders,
          "x-finwealth-ledger-id": "ledger-other",
        },
      },
    );
    assert.equal(otherLedger.status, 404);

    const sent = await fetch(
      `${base}/v1/agent/conversations/${conversation.id}/messages`,
      {
        method: "POST",
        headers: {
          ...principalHeaders,
          "content-type": "application/json",
          "idempotency-key": "message-with-bill-1",
        },
        body: JSON.stringify({
          text: "整理这张账单",
          attachmentIds: [uploadedBody.data.id],
        }),
      },
    );
    assert.equal(sent.status, 202);
    await waitForCompleted(service, conversation.id);
    assert.equal(engine.lastAttachmentCount, 1);
    assert.equal((await service.store.read(owner.userId)).attachments.length, 1);
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
});

test("archives validated workspace documents and attaches them to an Agent run", async () => {
  const engine = new FakeEngine();
  const service = await serviceWith(engine);
  const conversation = (await service.listConversations(owner))[0];
  assert.ok(conversation);
  const cases = [
    { fileName: "note.txt", mimeType: "text/plain", bytes: Buffer.from("账单备注\n", "utf8") },
    { fileName: "bill.csv", mimeType: "text/csv", bytes: Buffer.from("date,amount\n2026-07-28,12.50\n") },
    { fileName: "bill.pdf", mimeType: "application/pdf", bytes: Buffer.from("%PDF-1.4\n1 0 obj\nendobj\n%%EOF\n") },
    { fileName: "files.zip", mimeType: "application/zip", bytes: storedZip(["bill.csv"]) },
    {
      fileName: "book.xlsx",
      mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      bytes: storedZip(["[Content_Types].xml", "xl/workbook.xml"]),
    },
  ];
  const ids: string[] = [];
  for (const item of cases) {
    const metadata = await service.createAttachment(owner, {
      ...item,
      sha256: createHash("sha256").update(item.bytes).digest("hex"),
    });
    ids.push(metadata.id);
    assert.equal(metadata.mimeType, item.mimeType);
    const content = await service.getAttachmentContent(owner, metadata.id);
    assert.deepEqual(content.bytes, item.bytes);
  }
  await service.sendMessage(owner, conversation.id, "读取这些文件", ids);
  await waitForCompleted(service, conversation.id);
  assert.equal(engine.lastAttachmentCount, cases.length);

  await assert.rejects(
    service.createAttachment(owner, {
      fileName: "fake.xlsx",
      mimeType: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
      bytes: storedZip(["random.txt"]),
      sha256: "0".repeat(64),
    }),
    /attachment_mime_mismatch/,
  );
  await assert.rejects(
    service.createAttachment(owner, {
      fileName: "traversal.zip",
      mimeType: "application/zip",
      bytes: storedZip(["../outside.txt"]),
      sha256: "0".repeat(64),
    }),
    /attachment_mime_mismatch/,
  );
});

test("web quote candidates remain suggested until an idempotent user review applies them", async () => {
  const writer = new FakeQuoteWriter();
  const service = await serviceWith(new FakeEngine(), writer);
  const conversation = (await service.listConversations(owner))[0];
  assert.ok(conversation);
  const candidate = await suggestQuoteCandidate(service.store, conversation, {
    kind: "instrument",
    instrumentId: "inst_btc",
    price: "118234.25",
    currency: "USDT",
    asOf: "2026-07-28T10:00:00Z",
    source: "Example Exchange",
    sourceUrl: "https://example.test/markets/btc-usdt",
  });
  assert.equal(candidate.status, "suggested");
  assert.equal(writer.applied.length, 0);
  const duplicate = await suggestQuoteCandidate(service.store, conversation, {
    kind: "instrument",
    instrumentId: "inst_btc",
    price: "118234.25",
    currency: "USDT",
    asOf: "2026-07-28T10:00:00Z",
    source: "Example Exchange mirror label",
    sourceUrl: "https://example.test/markets/btc-usdt",
  });
  assert.equal(duplicate.id, candidate.id);
  assert.equal((await service.listQuoteCandidates(owner)).length, 1);

  const server = createAgentHttpServer(service, "internal-test-token");
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const base = `http://127.0.0.1:${address.port}`;
  const headers = {
    "x-finwealth-internal-token": "internal-test-token",
    "x-finwealth-user-id": owner.userId,
    "x-finwealth-ledger-id": owner.ledgerId,
    "x-finwealth-device-id": owner.deviceId,
  };
  try {
    const listed = await fetch(`${base}/v1/agent/quote-candidates`, { headers });
    assert.equal(listed.status, 200);
    const listedBody = await listed.json() as { data: AgentQuoteCandidate[] };
    assert.equal(listedBody.data.length, 1);
    assert.equal(listedBody.data[0]?.status, "suggested");

    const crossLedgerReview = await fetch(
      `${base}/v1/agent/quote-candidates/${candidate.id}/review`,
      {
        method: "POST",
        headers: {
          ...headers,
          "x-finwealth-ledger-id": "ledger_other",
          "content-type": "application/json",
          "idempotency-key": "cross-ledger-quote-review",
        },
        body: JSON.stringify({ decision: "apply" }),
      },
    );
    assert.equal(crossLedgerReview.status, 404);
    assert.equal(writer.applied.length, 0);

    const apply = (): Promise<Response> => fetch(
      `${base}/v1/agent/quote-candidates/${candidate.id}/review`,
      {
        method: "POST",
        headers: {
          ...headers,
          "content-type": "application/json",
          "idempotency-key": "apply-web-quote-1",
        },
        body: JSON.stringify({ decision: "apply" }),
      },
    );
    const first = await apply();
    const replay = await apply();
    assert.equal(first.status, 200);
    assert.equal(replay.status, 200);
    assert.equal(replay.headers.get("idempotency-replayed"), "true");
    assert.equal(writer.applied.length, 1);
    assert.equal((await service.listQuoteCandidates(owner))[0]?.status, "applied");

    const otherLedger = await fetch(`${base}/v1/agent/quote-candidates`, {
      headers: { ...headers, "x-finwealth-ledger-id": "ledger_other" },
    });
    const otherBody = await otherLedger.json() as { data: unknown[] };
    assert.deepEqual(otherBody.data, []);
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
});

test("rejecting or failing to apply a quote candidate never changes authoritative quotes", async () => {
  const writer = new FakeQuoteWriter();
  const service = await serviceWith(new FakeEngine(), writer);
  const conversation = (await service.listConversations(owner))[0];
  assert.ok(conversation);
  const rejected = await suggestQuoteCandidate(service.store, conversation, {
    kind: "fx",
    baseCurrency: "USD",
    quoteCurrency: "CNY",
    rate: "7.21",
    asOf: "2026-07-28T10:00:00Z",
    source: "Example Bank",
    sourceUrl: "https://example.test/fx/usd-cny",
  });
  const rejectedResult = await service.reviewQuoteCandidate(
    owner,
    rejected.id,
    "reject",
  );
  assert.equal(rejectedResult.status, "rejected");
  assert.equal(writer.applied.length, 0);

  const failed = await suggestQuoteCandidate(service.store, conversation, {
    kind: "fx",
    baseCurrency: "EUR",
    quoteCurrency: "CNY",
    rate: "8.42",
    asOf: "2026-07-28T10:05:00Z",
    source: "Example Bank",
    sourceUrl: "https://example.test/fx/eur-cny",
  });
  writer.failure = "agent_quote_apply_failed";
  await assert.rejects(
    service.reviewQuoteCandidate(owner, failed.id, "apply"),
    /agent_quote_apply_failed/,
  );
  assert.equal((await service.listQuoteCandidates(owner))[1]?.status, "suggested");
});

test("due automations persist their next run and create account-scoped notifications", async () => {
  const runner = new FakeAutomationRunner();
  const service = await serviceWith(new FakeEngine(), undefined, runner);
  const automation = await service.createAutomation(owner, {
    kind: "subscription_due_scan",
    intervalHours: 24,
    enabled: true,
    startAt: "2026-07-28T08:00:00+08:00",
  });
  await service.runDueAutomations("2026-07-28T00:01:00Z");
  assert.equal(runner.runs.length, 1);
  assert.equal(runner.runs[0]?.scheduledFor, "2026-07-28T08:00:00+08:00");
  const latest = (await service.listAutomations(owner))[0];
  assert.equal(latest?.lastStatus, "success");
  assert.ok(Date.parse(latest?.nextRunAt ?? "") > Date.parse("2026-07-29T00:00:00Z"));
  const notices = await service.listNotifications(owner);
  assert.equal(notices.length, 1);
  assert.equal(notices[0]?.action, "review");
  assert.equal(notices[0]?.readAt, undefined);
  const read = await service.markNotificationRead(owner, notices[0]!.id);
  assert.ok(read.readAt);

  await service.runDueAutomations("2026-07-28T23:59:00Z");
  assert.equal(runner.runs.length, 1);
  const otherLedger = await service.listNotifications({
    ...owner,
    ledgerId: "ledger_other",
  });
  assert.deepEqual(otherLedger, []);
  assert.equal(automation.id, latest?.id);
});

test("failed scheduled automation records a notification and retries in one hour", async () => {
  const runner = new FakeAutomationRunner();
  runner.failure = "quote_provider_unavailable";
  const service = await serviceWith(new FakeEngine(), undefined, runner);
  await service.createAutomation(owner, {
    kind: "quote_refresh",
    intervalHours: 12,
    enabled: true,
    startAt: "2026-07-28T00:00:00Z",
  });
  await service.runDueAutomations("2026-07-28T00:01:00Z");
  const latest = (await service.listAutomations(owner))[0];
  assert.equal(latest?.lastStatus, "failed");
  assert.equal(latest?.lastErrorCode, "quote_provider_unavailable");
  assert.match(latest?.nextRunAt ?? "", /Z$/);
  assert.equal((await service.listNotifications(owner))[0]?.title, "自动任务未完成");
});

test("automation HTTP writes are idempotent and manual runs preserve the schedule", async () => {
  const runner = new FakeAutomationRunner();
  const service = await serviceWith(new FakeEngine(), undefined, runner);
  const server = createAgentHttpServer(service, "internal-test-token");
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve));
  const address = server.address();
  assert.ok(address && typeof address === "object");
  const base = `http://127.0.0.1:${address.port}`;
  const headers = {
    "x-finwealth-internal-token": "internal-test-token",
    "x-finwealth-user-id": owner.userId,
    "x-finwealth-ledger-id": owner.ledgerId,
    "x-finwealth-device-id": owner.deviceId,
    "content-type": "application/json",
  };
  try {
    const create = (): Promise<Response> => fetch(`${base}/v1/agent/automations`, {
      method: "POST",
      headers: { ...headers, "idempotency-key": "create-auto-1" },
      body: JSON.stringify({
        kind: "dca_due_check",
        intervalHours: 24,
        startAt: "2026-08-01T00:00:00Z",
      }),
    });
    const first = await create();
    const replay = await create();
    assert.equal(first.status, 201);
    assert.equal(replay.headers.get("idempotency-replayed"), "true");
    const body = await first.json() as { data: AgentAutomation };
    const run = await fetch(`${base}/v1/agent/automations/${body.data.id}/run`, {
      method: "POST",
      headers: { ...headers, "idempotency-key": "run-auto-1" },
      body: "{}",
    });
    assert.equal(run.status, 200);
    assert.equal(runner.runs.length, 1);
    const listed = await service.listAutomations(owner);
    assert.equal(listed[0]?.nextRunAt, "2026-08-01T00:00:00Z");
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
});

test("financial summary automation completes a read-only report before succeeding", async () => {
  const service = await serviceWith(new FakeEngine());
  const automation = await service.createAutomation(owner, {
    kind: "financial_summary",
    intervalHours: 168,
    enabled: true,
    startAt: "2026-08-01T00:00:00Z",
  });
  await service.runAutomationNow(owner, automation.id);
  const primary = (await service.listConversations(owner)).find((item) => item.isPrimary);
  assert.ok(primary);
  await waitForCompleted(service, primary.id);
  const messages = await service.listMessages(owner, primary.id);
  const request = messages.find((item) => item.role === "user");
  assert.match(request?.text ?? "", /过去一周/);
  assert.match(request?.text ?? "", /不要创建或确认任何账务记录/);
  const notice = (await service.listNotifications(owner))[0];
  assert.equal(notice?.action, "agent");
  assert.equal(notice?.title, "财务总结已生成");
  assert.equal((await service.listAutomations(owner))[0]?.lastStatus, "success");
});

test("startup recovery fails interrupted runs and appends a terminal event", async () => {
  const service = await serviceWith(new FakeEngine());
  const primary = (await service.listConversations(owner)).find((item) => item.isPrimary);
  assert.ok(primary);
  await service.store.update(owner.userId, (state) => {
    state.messages.push({
      id: "msg_interrupted",
      conversationId: primary.id,
      role: "assistant",
      text: "partial",
      status: "streaming",
      runId: "run_interrupted",
      createdAt: "2026-07-28T00:00:00Z",
    });
  });

  assert.equal(await service.recoverInterruptedRuns(), 1);
  const recovered = (await service.listMessages(owner, primary.id)).find(
    (item) => item.id === "msg_interrupted",
  );
  assert.equal(recovered?.status, "failed");
  assert.equal(recovered?.errorCode, "agent_run_interrupted");
  assert.ok(recovered?.completedAt);
  const event = (await service.listEvents(owner, primary.id, 0)).at(-1);
  assert.equal(event?.type, "run.failed");
  assert.equal(event?.data.code, "agent_run_interrupted");
  assert.equal(await service.recoverInterruptedRuns(), 0);
});

test("financial summary model failures fail the automation and remain retryable", async () => {
  const engine = new FakeEngine();
  engine.failure = "agent_model_request_failed";
  const service = await serviceWith(engine);
  const automation = await service.createAutomation(owner, {
    kind: "financial_summary",
    intervalHours: 24,
    enabled: false,
  });

  await assert.rejects(
    service.runAutomationNow(owner, automation.id),
    /agent_model_request_failed/,
  );
  const latest = (await service.listAutomations(owner))[0];
  assert.equal(latest?.lastStatus, "failed");
  assert.equal(latest?.lastErrorCode, "agent_model_request_failed");
  assert.equal((await service.listNotifications(owner))[0]?.title, "自动任务未完成");
});

test("workspace file tools reject paths outside the dedicated workspace", async () => {
  const root = await mkdtemp(join(tmpdir(), "finwealth-workspace-test-"));
  roots.push(root);
  const workspace = join(root, "workspace");
  await import("node:fs/promises").then(({ mkdir }) => mkdir(workspace));
  const outside = join(root, "outside.txt");
  await writeFile(outside, "secret");
  const tools = createWorkspaceTools(workspace);
  const write = tools.find((tool) => tool.name === "write");
  const read = tools.find((tool) => tool.name === "read");
  const pdf = tools.find((tool) => tool.name === "finwealth_read_pdf_text");
  assert.ok(write && read && pdf);

  await write.execute(
    "write-1",
    { path: join(workspace, "note.txt"), content: "inside" },
    undefined,
    undefined,
    {} as never,
  );
  assert.equal(await readFile(join(workspace, "note.txt"), "utf8"), "inside");
  await assert.rejects(
    read.execute(
      "read-escape",
      { path: outside },
      undefined,
      undefined,
      {} as never,
    ),
    /workspace_path_forbidden/,
  );
  await assert.rejects(
    write.execute(
      "write-escape",
      { path: outside, content: "overwrite" },
      undefined,
      undefined,
      {} as never,
    ),
    /workspace_path_forbidden/,
  );
  await assert.rejects(
    pdf.execute(
      "pdf-escape",
      { path: outside },
      undefined,
      undefined,
      {} as never,
    ),
    /workspace_path_forbidden/,
  );
  assert.equal(await readFile(outside, "utf8"), "secret");
});

test("repeated-error memory stays suggested until the user approves it", async () => {
  const service = await serviceWith();
  const conversation = (await service.listConversations(owner))[0];
  assert.ok(conversation);
  const tool = createMemoryTools(service.store, conversation)[0];
  assert.ok(tool);
  await tool.execute(
    "memory-1",
    { content: "日期缺少年份时先询问", reason: "用户连续纠正了两次年份" },
    undefined,
    undefined,
    {} as never,
  );
  const suggested = await service.listMemories(owner);
  assert.equal(suggested.length, 1);
  assert.equal(suggested[0]?.status, "suggested");

  const active = await service.reviewMemory(owner, suggested[0]!.id, "active");
  assert.equal(active.status, "active");
  await assert.rejects(
    service.reviewMemory(owner, suggested[0]!.id, "rejected"),
    /agent_memory_already_reviewed/,
  );
});
