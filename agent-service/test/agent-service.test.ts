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
  normalizeMovementProposalForLedger,
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
import { suggestQuoteCandidate } from "../src/quote-candidate-tools.js";

const roots: string[] = [];
const owner: Principal = {
  userId: "usr_owner",
  ledgerId: "ledger_default",
  deviceId: "dev_test",
};

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

async function serviceWith(
  engine = new FakeEngine(),
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
    if (messages.some((message) => message.role === "assistant" && message.status === "completed")) {
      return;
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
  }> = [];
  const server = createServer(async (request, response) => {
    requests.push({
      method: request.method,
      path: request.url,
      token: typeof request.headers["x-finwealth-internal-token"] === "string"
        ? request.headers["x-finwealth-internal-token"]
        : undefined,
    });
    let data: unknown = [];
    let status = 200;
    if (request.url === "/v1/movements/drafts") {
      for await (const _chunk of request) { /* consume request */ }
      data = { id: "mov_agent_draft" };
      status = 201;
    } else if (request.url === "/v1/movements/mov_agent_draft/submit-review") {
      data = { id: "grp_agent_review", status: "pending" };
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
    await client.refreshStructuredQuotes();
    await client.proposeMovement({
      type: "expense",
      occurredAt: "2026-07-28T00:00:00Z",
      title: "午餐",
      entries: [],
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
      "POST /v1/quotes/refresh",
      "POST /v1/movements/drafts",
      "POST /v1/movements/mov_agent_draft/submit-review",
    ],
  );
  assert.ok(requests.every((item) => item.token === "sidecar-secret"));
  assert.ok(requests.every((item) => !item.path?.includes("confirm")));
  assert.ok(requests.every((item) => !item.path?.includes("approve")));
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
    const data = request.url === "/v1/quotes/refresh"
      ? { quotes: [{}], fxRates: [{}], errors: [] }
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
    assert.equal(quote.notify, false);
    assert.equal(subscription.action, "review");
    assert.equal(subscription.notify, true);
    assert.equal(dca.action, "dca");
  } finally {
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
  assert.deepEqual(requests.map((item) => item.path), [
    "/v1/quotes/refresh",
    "/v1/subscriptions/charge-proposals/due-scan",
    "/v1/dca/reminders/due",
  ]);
  assert.equal(requests[0]?.key, "agent-auto-auto_test-2026-07-28T00:00:00Z");
  assert.equal(requests[1]?.key, "agent-auto-auto_test-2026-07-28T00:00:00Z");
  assert.equal(requests[2]?.key, undefined);
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
    startAt: "2026-07-28T00:00:00Z",
  });
  await service.runDueAutomations("2026-07-28T00:01:00Z");
  assert.equal(runner.runs.length, 1);
  assert.equal(runner.runs[0]?.scheduledFor, "2026-07-28T00:00:00Z");
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

test("financial summary automation queues a read-only report in the primary conversation", async () => {
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
  assert.equal(notice?.title, "财务总结正在生成");
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
  assert.ok(write && read);

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
