import assert from "node:assert/strict";
import { mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { createServer } from "node:http";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, test } from "node:test";
import { AgentService } from "../src/agent-service.js";
import { EventHub } from "../src/event-hub.js";
import { FinwealthClient } from "../src/finwealth-client.js";
import { createAgentHttpServer } from "../src/http-server.js";
import { StateStore } from "../src/state-store.js";
import type {
  AgentConversation,
  AgentEngine,
  AgentModelInfo,
  Principal,
  RunCallbacks,
} from "../src/types.js";
import { createWorkspaceTools } from "../src/workspace-tools.js";
import { createMemoryTools } from "../src/memory-tools.js";

const roots: string[] = [];
const owner: Principal = {
  userId: "usr_owner",
  ledgerId: "ledger_default",
  deviceId: "dev_test",
};

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

afterEach(async () => {
  await Promise.all(roots.splice(0).map((root) => rm(root, { recursive: true })));
});

async function serviceWith(engine = new FakeEngine()): Promise<AgentService> {
  const root = await mkdtemp(join(tmpdir(), "finwealth-agent-test-"));
  roots.push(root);
  return new AgentService(new StateStore(root), new EventHub(), engine);
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
    const form = new FormData();
    form.append(
      "file",
      new Blob([
        Buffer.from(
          "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=",
          "base64",
        ),
      ], { type: "image/png" }),
      "bill.png",
    );
    const uploaded = await fetch(`${base}/v1/agent/attachments`, {
      method: "POST",
      headers: { ...principalHeaders, "idempotency-key": "upload-bill-1" },
      body: form,
    });
    assert.equal(uploaded.status, 201);
    const uploadedBody = await uploaded.json() as { data: { id: string } };

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
