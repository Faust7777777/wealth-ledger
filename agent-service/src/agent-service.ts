import { createHash, randomUUID } from "node:crypto";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { EventHub } from "./event-hub.js";
import { StateStore } from "./state-store.js";
import type {
  AgentConversation,
  AgentEngine,
  AgentEvent,
  AgentAttachment,
  AgentMemory,
  AgentMessage,
  Principal,
} from "./types.js";

function now(): string {
  return new Date().toISOString();
}

function cleanTitle(value: string): string {
  const compact = value.replace(/\s+/g, " ").trim();
  return compact.length > 32 ? `${compact.slice(0, 32)}…` : compact;
}

export class AgentService {
  readonly store: StateStore;
  readonly events: EventHub;
  readonly engine: AgentEngine;
  readonly #runQueues = new Map<string, Promise<void>>();
  readonly #idempotencyQueues = new Map<string, Promise<unknown>>();

  constructor(store: StateStore, events: EventHub, engine: AgentEngine) {
    this.store = store;
    this.events = events;
    this.engine = engine;
  }

  async status(principal: Principal): Promise<Record<string, unknown>> {
    const models = await this.engine.listModels();
    const conversations = await this.listConversations(principal);
    return {
      service: "finwealth-agent",
      configured: models.length > 0,
      userId: principal.userId,
      ledgerId: principal.ledgerId,
      modelCount: models.length,
      primaryConversationId: conversations.find((item) => item.isPrimary)?.id,
    };
  }

  async idempotent<T>(
    principal: Principal,
    key: string,
    operation: string,
    request: unknown,
    action: () => Promise<T>,
  ): Promise<{ value: T; replayed: boolean }> {
    const normalizedKey = key.trim();
    if (!normalizedKey || Buffer.byteLength(normalizedKey) > 128) {
      throw new Error("invalid_idempotency_key");
    }
    const requestHash = createHash("sha256")
      .update(JSON.stringify(request))
      .digest("hex");
    const scope = `${principal.userId}\u0000${normalizedKey}`;

    const existing = await this.#storedIdempotency(
      principal.userId,
      normalizedKey,
      operation,
      requestHash,
    );
    if (existing.found) return { value: existing.value as T, replayed: true };

    const pending = this.#idempotencyQueues.get(scope);
    if (pending) {
      await pending;
      const replay = await this.#storedIdempotency(
        principal.userId,
        normalizedKey,
        operation,
        requestHash,
      );
      if (!replay.found) throw new Error("idempotency_result_missing");
      return { value: replay.value as T, replayed: true };
    }

    const execution = action().then(async (value) => {
      await this.store.update(principal.userId, (state) => {
        state.idempotency.push({
          key: normalizedKey,
          operation,
          requestHash,
          response: value,
          createdAt: now(),
        });
      });
      return value;
    });
    this.#idempotencyQueues.set(scope, execution);
    try {
      return { value: await execution, replayed: false };
    } finally {
      if (this.#idempotencyQueues.get(scope) === execution) {
        this.#idempotencyQueues.delete(scope);
      }
    }
  }

  async listModels(): Promise<unknown[]> {
    return this.engine.listModels();
  }

  async createAttachment(
    principal: Principal,
    file: { fileName: string; mimeType: string; bytes: Buffer; sha256: string },
  ): Promise<Omit<AgentAttachment, "originalPath" | "workingPath">> {
    const extensions: Record<string, string> = {
      "image/png": ".png",
      "image/jpeg": ".jpg",
      "image/webp": ".webp",
    };
    const extension = extensions[file.mimeType];
    if (!extension) throw new Error("unsupported_attachment_type");
    if (file.bytes.length === 0 || file.bytes.length > 15 * 1024 * 1024) {
      throw new Error("invalid_attachment_size");
    }
    const matchesMime =
      (file.mimeType === "image/png" &&
        file.bytes.length >= 24 &&
        file.bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])) &&
        file.bytes.subarray(12, 16).toString("ascii") === "IHDR") ||
      (file.mimeType === "image/jpeg" &&
        file.bytes.length >= 4 &&
        file.bytes[0] === 0xff && file.bytes[1] === 0xd8 &&
        file.bytes.at(-2) === 0xff && file.bytes.at(-1) === 0xd9) ||
      (file.mimeType === "image/webp" &&
        file.bytes.length >= 12 &&
        file.bytes.subarray(0, 4).toString("ascii") === "RIFF" &&
        file.bytes.subarray(8, 12).toString("ascii") === "WEBP");
    if (!matchesMime) throw new Error("attachment_mime_mismatch");
    await this.store.prepareUser(principal.userId);
    const id = `att_${randomUUID()}`;
    const root = this.store.userRoot(principal.userId);
    const originalPath = join(root, "attachments", id, `original${extension}`);
    const workingPath = join(
      this.store.workspace(principal.userId),
      "attachments",
      `${id}${extension}`,
    );
    await Promise.all([
      mkdir(dirname(originalPath), { recursive: true, mode: 0o700 }),
      mkdir(dirname(workingPath), { recursive: true, mode: 0o700 }),
    ]);
    try {
      await writeFile(originalPath, file.bytes, { mode: 0o600, flag: "wx" });
      await writeFile(workingPath, file.bytes, { mode: 0o600, flag: "wx" });
    } catch (error) {
      await Promise.all([
        rm(originalPath, { force: true }),
        rm(workingPath, { force: true }),
      ]);
      throw error;
    }
    const attachment: AgentAttachment = {
      id,
      userId: principal.userId,
      ledgerId: principal.ledgerId,
      fileName: file.fileName.slice(0, 255),
      mimeType: file.mimeType,
      sizeBytes: file.bytes.length,
      sha256: file.sha256,
      originalPath,
      workingPath,
      createdAt: now(),
    };
    try {
      await this.store.update(principal.userId, (state) => {
        state.attachments.push(attachment);
      });
    } catch (error) {
      await Promise.all([
        rm(originalPath, { force: true }),
        rm(workingPath, { force: true }),
      ]);
      throw error;
    }
    const { originalPath: _original, workingPath: _working, ...safe } = attachment;
    return safe;
  }

  async listMemories(principal: Principal): Promise<AgentMemory[]> {
    const state = await this.store.read(principal.userId);
    return state.memories.filter((item) => item.ledgerId === principal.ledgerId);
  }

  async reviewMemory(
    principal: Principal,
    memoryId: string,
    decision: "active" | "rejected",
  ): Promise<AgentMemory> {
    return this.store.update(principal.userId, (state) => {
      const memory = state.memories.find(
        (item) => item.id === memoryId && item.ledgerId === principal.ledgerId,
      );
      if (!memory) throw new Error("agent_memory_not_found");
      if (memory.status !== "suggested") throw new Error("agent_memory_already_reviewed");
      memory.status = decision;
      memory.updatedAt = now();
      return { ...memory };
    });
  }

  async listConversations(principal: Principal): Promise<AgentConversation[]> {
    await this.#ensurePrimary(principal);
    const state = await this.store.read(principal.userId);
    return state.conversations
      .filter(
        (item) =>
          item.userId === principal.userId && item.ledgerId === principal.ledgerId,
      )
      .sort((left, right) => right.updatedAt.localeCompare(left.updatedAt));
  }

  async createConversation(
    principal: Principal,
    title?: string,
  ): Promise<AgentConversation> {
    const timestamp = now();
    const conversation: AgentConversation = {
      id: `conv_${randomUUID()}`,
      userId: principal.userId,
      ledgerId: principal.ledgerId,
      title: cleanTitle(title ?? "新会话") || "新会话",
      isPrimary: false,
      status: "active",
      createdAt: timestamp,
      updatedAt: timestamp,
    };
    await this.store.update(principal.userId, (state) => {
      state.conversations.push(conversation);
    });
    return conversation;
  }

  async updateConversation(
    principal: Principal,
    conversationId: string,
    patch: { title?: string; status?: "active" | "archived"; modelId?: string },
  ): Promise<AgentConversation> {
    if (patch.modelId) {
      const models = await this.engine.listModels();
      if (!models.some((model) => model.id === patch.modelId)) {
        throw new Error("agent_model_not_allowed");
      }
    }
    return this.store.update(principal.userId, (state) => {
      const conversation = this.#ownedConversation(
        state.conversations,
        principal,
        conversationId,
      );
      if (patch.title !== undefined) {
        const title = cleanTitle(patch.title);
        if (!title) throw new Error("invalid_conversation_title");
        conversation.title = title;
      }
      if (patch.status !== undefined) {
        if (conversation.isPrimary && patch.status === "archived") {
          throw new Error("primary_conversation_cannot_be_archived");
        }
        conversation.status = patch.status;
      }
      if (patch.modelId !== undefined) conversation.selectedModelId = patch.modelId;
      conversation.updatedAt = now();
      return { ...conversation };
    });
  }

  async listMessages(
    principal: Principal,
    conversationId: string,
  ): Promise<AgentMessage[]> {
    const state = await this.store.read(principal.userId);
    this.#ownedConversation(state.conversations, principal, conversationId);
    return state.messages.filter((item) => item.conversationId === conversationId);
  }

  async sendMessage(
    principal: Principal,
    conversationId: string,
    text: string,
    attachmentIds: string[] = [],
  ): Promise<{ runId: string; userMessageId: string; assistantMessageId: string }> {
    const normalized = text.trim();
    if (!normalized || normalized.length > 100_000) {
      throw new Error("invalid_agent_message");
    }
    if ((await this.engine.listModels()).length === 0) {
      throw new Error("agent_model_unavailable");
    }
    if (attachmentIds.length > 8 || new Set(attachmentIds).size !== attachmentIds.length) {
      throw new Error("invalid_agent_attachments");
    }
    const attachmentState = await this.store.read(principal.userId);
    const attachments = attachmentIds.map((id) => {
      const attachment = attachmentState.attachments.find(
        (item) => item.id === id && item.ledgerId === principal.ledgerId,
      );
      if (!attachment) throw new Error("attachment_not_found");
      return attachment;
    });

    const timestamp = now();
    const runId = `run_${randomUUID()}`;
    const userMessage: AgentMessage = {
      id: `msg_${randomUUID()}`,
      conversationId,
      role: "user",
      text: normalized,
      status: "completed",
      runId,
      createdAt: timestamp,
      completedAt: timestamp,
      ...(attachmentIds.length ? { attachmentIds } : {}),
    };
    const assistantMessage: AgentMessage = {
      id: `msg_${randomUUID()}`,
      conversationId,
      role: "assistant",
      text: "",
      status: "queued",
      runId,
      createdAt: timestamp,
    };
    const conversation = await this.store.update(principal.userId, (state) => {
      const owned = this.#ownedConversation(
        state.conversations,
        principal,
        conversationId,
      );
      if (owned.status !== "active") throw new Error("conversation_archived");
      state.messages.push(userMessage, assistantMessage);
      owned.updatedAt = timestamp;
      if (!owned.isPrimary && owned.title === "新会话") {
        owned.title = cleanTitle(normalized);
      }
      return { ...owned };
    });
    await this.#appendEvent(principal.userId, conversationId, "run.queued", {
      runId,
      userMessageId: userMessage.id,
      assistantMessageId: assistantMessage.id,
    });

    const previous = this.#runQueues.get(conversationId) ?? Promise.resolve();
    const queued = previous.then(() =>
      this.#executeRun(
        principal,
        conversation,
        runId,
        assistantMessage.id,
        normalized,
        attachments,
      ),
    );
    this.#runQueues.set(
      conversationId,
      queued.finally(() => {
        if (this.#runQueues.get(conversationId) === queued) {
          this.#runQueues.delete(conversationId);
        }
      }),
    );
    void queued.catch(() => undefined);
    return {
      runId,
      userMessageId: userMessage.id,
      assistantMessageId: assistantMessage.id,
    };
  }

  async cancelRun(principal: Principal, runId: string): Promise<boolean> {
    const state = await this.store.read(principal.userId);
    const message = state.messages.find(
      (item) => item.runId === runId && item.role === "assistant",
    );
    if (!message) throw new Error("agent_run_not_found");
    this.#ownedConversation(
      state.conversations,
      principal,
      message.conversationId,
    );
    return this.engine.cancel(message.conversationId);
  }

  async listEvents(
    principal: Principal,
    conversationId: string,
    after: number,
  ): Promise<AgentEvent[]> {
    const state = await this.store.read(principal.userId);
    this.#ownedConversation(state.conversations, principal, conversationId);
    return state.events.filter(
      (event) =>
        event.conversationId === conversationId && event.cursor > after,
    );
  }

  async #ensurePrimary(principal: Principal): Promise<void> {
    await this.store.update(principal.userId, (state) => {
      if (
        state.conversations.some(
          (item) =>
            item.userId === principal.userId &&
            item.ledgerId === principal.ledgerId &&
            item.isPrimary,
        )
      ) {
        return;
      }
      const timestamp = now();
      state.conversations.push({
        id: `conv_${randomUUID()}`,
        userId: principal.userId,
        ledgerId: principal.ledgerId,
        title: "财务助手",
        isPrimary: true,
        status: "active",
        createdAt: timestamp,
        updatedAt: timestamp,
      });
    });
  }

  async #executeRun(
    principal: Principal,
    conversation: AgentConversation,
    runId: string,
    assistantMessageId: string,
    text: string,
    attachments: AgentAttachment[],
  ): Promise<void> {
    await this.#setMessageStatus(principal.userId, assistantMessageId, "streaming");
    await this.#appendEvent(principal.userId, conversation.id, "run.started", {
      runId,
      assistantMessageId,
    });
    let eventQueue = Promise.resolve();
    const enqueue = (type: string, data: Record<string, unknown>): void => {
      eventQueue = eventQueue.then(() =>
        this.#appendEvent(principal.userId, conversation.id, type, data).then(
          () => undefined,
        ),
      );
    };
    try {
      const result = await this.engine.run(conversation, text, attachments, {
        onDelta: (delta) => enqueue("message.delta", { assistantMessageId, delta }),
        onToolStarted: (name) => enqueue("tool.started", { runId, name }),
        onToolCompleted: (name, isError) =>
          enqueue("tool.completed", { runId, name, isError }),
      });
      await eventQueue;
      const completedAt = now();
      await this.store.update(principal.userId, (state) => {
        const message = state.messages.find(
          (item) => item.id === assistantMessageId,
        );
        if (!message) throw new Error("agent_message_not_found");
        message.text = result.text;
        message.status = "completed";
        message.completedAt = completedAt;
        const storedConversation = state.conversations.find(
          (item) => item.id === conversation.id,
        );
        if (storedConversation) {
          storedConversation.updatedAt = completedAt;
          if (result.piSessionFile) {
            storedConversation.piSessionFile = result.piSessionFile;
          }
        }
      });
      await this.#appendEvent(principal.userId, conversation.id, "run.completed", {
        runId,
        assistantMessageId,
      });
    } catch (error) {
      await eventQueue;
      const code =
        error instanceof Error && /^[a-z0-9_]+$/.test(error.message)
          ? error.message
          : "agent_run_failed";
      await this.store.update(principal.userId, (state) => {
        const message = state.messages.find(
          (item) => item.id === assistantMessageId,
        );
        if (!message) return;
        message.status = "failed";
        message.errorCode = code;
        message.completedAt = now();
      });
      await this.#appendEvent(principal.userId, conversation.id, "run.failed", {
        runId,
        assistantMessageId,
        code,
      });
    }
  }

  async #setMessageStatus(
    userId: string,
    messageId: string,
    status: AgentMessage["status"],
  ): Promise<void> {
    await this.store.update(userId, (state) => {
      const message = state.messages.find((item) => item.id === messageId);
      if (!message) throw new Error("agent_message_not_found");
      message.status = status;
    });
  }

  async #appendEvent(
    userId: string,
    conversationId: string,
    type: string,
    data: Record<string, unknown>,
  ): Promise<AgentEvent> {
    const event = await this.store.update(userId, (state) => {
      const next: AgentEvent = {
        cursor: state.nextEventCursor++,
        conversationId,
        type,
        data,
        createdAt: now(),
      };
      state.events.push(next);
      return next;
    });
    this.events.publish(event);
    return event;
  }

  #ownedConversation(
    conversations: AgentConversation[],
    principal: Principal,
    conversationId: string,
  ): AgentConversation {
    const conversation = conversations.find(
      (item) =>
        item.id === conversationId &&
        item.userId === principal.userId &&
        item.ledgerId === principal.ledgerId,
    );
    if (!conversation) throw new Error("conversation_not_found");
    return conversation;
  }

  async #storedIdempotency(
    userId: string,
    key: string,
    operation: string,
    requestHash: string,
  ): Promise<{ found: boolean; value?: unknown }> {
    const state = await this.store.read(userId);
    const record = state.idempotency.find((item) => item.key === key);
    if (!record) return { found: false };
    if (record.operation !== operation || record.requestHash !== requestHash) {
      throw new Error("idempotency_key_reused");
    }
    return { found: true, value: record.response };
  }
}
