import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, rm, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import { EventHub } from "./event-hub.js";
import { StateStore } from "./state-store.js";
import { ATTACHMENT_EXTENSIONS, attachmentMatchesMime } from "./attachment-formats.js";
import type {
  AgentConversation,
  AgentEngine,
  AgentEvent,
  AgentAttachment,
  AgentMemory,
  AgentMessage,
  Principal,
  AgentQuoteCandidate,
  AgentQuoteWriter,
  AgentAutomation,
  AgentAutomationKind,
  AgentAutomationRunner,
  AgentNotification,
} from "./types.js";

function now(): string {
  return new Date().toISOString();
}

function validTimestamp(value: string): boolean {
  return /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value) &&
    !Number.isNaN(Date.parse(value));
}

function cleanTitle(value: string): string {
  const compact = value.replace(/\s+/g, " ").trim();
  return compact.length > 32 ? `${compact.slice(0, 32)}…` : compact;
}

export class AgentService {
  readonly store: StateStore;
  readonly events: EventHub;
  readonly engine: AgentEngine;
  readonly #quoteWriter: AgentQuoteWriter | undefined;
  readonly #automationRunner: AgentAutomationRunner | undefined;
  readonly #automationRuns = new Set<string>();
  readonly #runQueues = new Map<string, Promise<void>>();
  readonly #idempotencyQueues = new Map<string, Promise<unknown>>();

  constructor(
    store: StateStore,
    events: EventHub,
    engine: AgentEngine,
    quoteWriter?: AgentQuoteWriter,
    automationRunner?: AgentAutomationRunner,
  ) {
    this.store = store;
    this.events = events;
    this.engine = engine;
    this.#quoteWriter = quoteWriter;
    this.#automationRunner = automationRunner;
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

  async listAutomations(principal: Principal): Promise<AgentAutomation[]> {
    const state = await this.store.read(principal.userId);
    return state.automations.filter((item) => item.ledgerId === principal.ledgerId);
  }

  async createAutomation(
    principal: Principal,
    input: { kind: AgentAutomationKind; intervalHours: number; enabled: boolean; startAt?: string },
  ): Promise<AgentAutomation> {
    if (!Number.isInteger(input.intervalHours) || input.intervalHours < 1 || input.intervalHours > 720) {
      throw new Error("invalid_agent_automation_interval");
    }
    const timestamp = now();
    const startAt = input.startAt ?? new Date(Date.parse(timestamp) + input.intervalHours * 3_600_000).toISOString();
    if (!validTimestamp(startAt)) throw new Error("invalid_agent_automation_start");
    return this.store.update(principal.userId, (state) => {
      if (state.automations.some(
        (item) => item.ledgerId === principal.ledgerId && item.kind === input.kind,
      )) throw new Error("agent_automation_already_exists");
      const automation: AgentAutomation = {
        id: `auto_${randomUUID()}`,
        userId: principal.userId,
        ledgerId: principal.ledgerId,
        deviceId: principal.deviceId,
        kind: input.kind,
        intervalHours: input.intervalHours,
        enabled: input.enabled,
        nextRunAt: startAt,
        createdAt: timestamp,
        updatedAt: timestamp,
      };
      state.automations.push(automation);
      return { ...automation };
    });
  }

  async updateAutomation(
    principal: Principal,
    automationId: string,
    patch: { intervalHours?: number; enabled?: boolean; nextRunAt?: string },
  ): Promise<AgentAutomation> {
    if (patch.intervalHours !== undefined && (
      !Number.isInteger(patch.intervalHours) || patch.intervalHours < 1 || patch.intervalHours > 720
    )) throw new Error("invalid_agent_automation_interval");
    if (patch.nextRunAt !== undefined && !validTimestamp(patch.nextRunAt)) {
      throw new Error("invalid_agent_automation_start");
    }
    return this.store.update(principal.userId, (state) => {
      const item = state.automations.find(
        (value) => value.id === automationId && value.ledgerId === principal.ledgerId,
      );
      if (!item) throw new Error("agent_automation_not_found");
      if (patch.intervalHours !== undefined) item.intervalHours = patch.intervalHours;
      if (patch.enabled !== undefined) item.enabled = patch.enabled;
      if (patch.nextRunAt !== undefined) item.nextRunAt = patch.nextRunAt;
      item.updatedAt = now();
      return { ...item };
    });
  }

  async listNotifications(principal: Principal): Promise<AgentNotification[]> {
    const state = await this.store.read(principal.userId);
    return state.notifications
      .filter((item) => item.ledgerId === principal.ledgerId)
      .sort((left, right) => right.createdAt.localeCompare(left.createdAt));
  }

  async markNotificationRead(
    principal: Principal,
    notificationId: string,
  ): Promise<AgentNotification> {
    return this.store.update(principal.userId, (state) => {
      const item = state.notifications.find(
        (value) => value.id === notificationId && value.ledgerId === principal.ledgerId,
      );
      if (!item) throw new Error("agent_notification_not_found");
      item.readAt ??= now();
      return { ...item };
    });
  }

  async runAutomationNow(principal: Principal, automationId: string): Promise<AgentAutomation> {
    const state = await this.store.read(principal.userId);
    const item = state.automations.find(
      (value) => value.id === automationId && value.ledgerId === principal.ledgerId,
    );
    if (!item) throw new Error("agent_automation_not_found");
    await this.#executeAutomation(item, now(), false);
    const latest = await this.listAutomations(principal);
    return latest.find((value) => value.id === automationId)!;
  }

  async runDueAutomations(at = now()): Promise<void> {
    for (const userId of await this.store.listUserIds()) {
      const state = await this.store.read(userId);
      for (const item of state.automations) {
        if (item.enabled && item.nextRunAt <= at) {
          await this.#executeAutomation(item, item.nextRunAt, true).catch(() => undefined);
        }
      }
    }
  }

  async #executeAutomation(
    automation: AgentAutomation,
    scheduledFor: string,
    advanceSchedule: boolean,
  ): Promise<void> {
    if (this.#automationRuns.has(automation.id)) throw new Error("agent_automation_busy");
    this.#automationRuns.add(automation.id);
    try {
      const result = automation.kind === "financial_summary"
        ? await this.#startFinancialSummary(automation, scheduledFor)
        : this.#automationRunner
        ? await this.#automationRunner.runAutomation(automation, scheduledFor)
        : (() => { throw new Error("agent_automation_unavailable"); })();
      await this.store.update(automation.userId, (state) => {
        const current = state.automations.find((item) => item.id === automation.id);
        if (!current) return;
        const timestamp = now();
        current.lastRunAt = timestamp;
        current.lastStatus = "success";
        delete current.lastErrorCode;
        current.updatedAt = timestamp;
        if (advanceSchedule) {
          current.nextRunAt = new Date(
            Math.max(Date.parse(scheduledFor), Date.parse(timestamp)) +
              current.intervalHours * 3_600_000,
          ).toISOString();
        }
        if (result.notify) {
          state.notifications.push({
            id: `notice_${randomUUID()}`,
            userId: current.userId,
            ledgerId: current.ledgerId,
            kind: current.kind,
            title: result.title,
            body: result.body,
            ...(result.action ? { action: result.action } : {}),
            createdAt: timestamp,
          });
        }
      });
    } catch (error) {
      const code = error instanceof Error && /^[a-z0-9_]+$/.test(error.message)
        ? error.message
        : "agent_automation_failed";
      await this.store.update(automation.userId, (state) => {
        const current = state.automations.find((item) => item.id === automation.id);
        if (!current) return;
        const timestamp = now();
        current.lastRunAt = timestamp;
        current.lastStatus = "failed";
        current.lastErrorCode = code;
        current.updatedAt = timestamp;
        if (advanceSchedule) {
          current.nextRunAt = new Date(Date.parse(timestamp) + 3_600_000).toISOString();
        }
        state.notifications.push({
          id: `notice_${randomUUID()}`,
          userId: current.userId,
          ledgerId: current.ledgerId,
          kind: current.kind,
          title: "自动任务未完成",
          body: "任务将在稍后重试",
          createdAt: timestamp,
        });
      });
      throw error;
    } finally {
      this.#automationRuns.delete(automation.id);
    }
  }

  async #startFinancialSummary(
    automation: AgentAutomation,
    scheduledFor: string,
  ): Promise<{
    title: string;
    body: string;
    action: "agent";
    notify: true;
  }> {
    const principal: Principal = {
      userId: automation.userId,
      ledgerId: automation.ledgerId,
      deviceId: automation.deviceId,
    };
    const conversations = await this.listConversations(principal);
    const primary = conversations.find((item) => item.isPrimary);
    if (!primary) throw new Error("agent_primary_conversation_not_found");
    const hours = automation.intervalHours;
    const period = hours <= 24 ? "过去一天" : hours <= 168 ? "过去一周" : "过去一个月";
    await this.sendMessage(
      principal,
      primary.id,
      `请生成${period}的财务总结。读取权威账本数据，概括消费分类与变化、订阅支出、投资仓位和盈亏，并给出简短可执行建议。报告截止时间：${scheduledFor}。不要创建或确认任何账务记录。`,
    );
    return {
      title: "财务总结正在生成",
      body: `${period}的报告已加入主会话`,
      action: "agent",
      notify: true,
    };
  }

  async createAttachment(
    principal: Principal,
    file: { fileName: string; mimeType: string; bytes: Buffer; sha256: string },
  ): Promise<Omit<AgentAttachment, "originalPath" | "workingPath">> {
    const extension = ATTACHMENT_EXTENSIONS[file.mimeType];
    if (!extension) throw new Error("unsupported_attachment_type");
    if (file.bytes.length === 0 || file.bytes.length > 15 * 1024 * 1024) {
      throw new Error("invalid_attachment_size");
    }
    if (!attachmentMatchesMime(file.mimeType, file.bytes)) {
      throw new Error("attachment_mime_mismatch");
    }
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

  async getAttachment(
    principal: Principal,
    attachmentId: string,
  ): Promise<Omit<AgentAttachment, "originalPath" | "workingPath">> {
    const state = await this.store.read(principal.userId);
    const attachment = state.attachments.find(
      (item) => item.id === attachmentId && item.ledgerId === principal.ledgerId,
    );
    if (!attachment) throw new Error("attachment_not_found");
    const { originalPath: _original, workingPath: _working, ...safe } = attachment;
    return safe;
  }

  async getAttachmentContent(
    principal: Principal,
    attachmentId: string,
  ): Promise<{ metadata: Omit<AgentAttachment, "originalPath" | "workingPath">; bytes: Buffer }> {
    const state = await this.store.read(principal.userId);
    const attachment = state.attachments.find(
      (item) => item.id === attachmentId && item.ledgerId === principal.ledgerId,
    );
    if (!attachment) throw new Error("attachment_not_found");
    const { originalPath, workingPath: _working, ...metadata } = attachment;
    return { metadata, bytes: await readFile(originalPath) };
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

  async listQuoteCandidates(principal: Principal): Promise<AgentQuoteCandidate[]> {
    const state = await this.store.read(principal.userId);
    return state.quoteCandidates.filter(
      (item) => item.ledgerId === principal.ledgerId,
    );
  }

  async reviewQuoteCandidate(
    principal: Principal,
    candidateId: string,
    decision: "apply" | "reject",
  ): Promise<AgentQuoteCandidate> {
    const state = await this.store.read(principal.userId);
    const candidate = state.quoteCandidates.find(
      (item) => item.id === candidateId && item.ledgerId === principal.ledgerId,
    );
    if (!candidate) throw new Error("agent_quote_candidate_not_found");
    if (candidate.status !== "suggested") {
      throw new Error("agent_quote_candidate_already_reviewed");
    }
    if (decision === "apply") {
      if (!this.#quoteWriter) throw new Error("agent_quote_apply_unavailable");
      await this.#quoteWriter.applyQuoteCandidate(candidate);
    }
    return this.store.update(principal.userId, (latest) => {
      const current = latest.quoteCandidates.find(
        (item) => item.id === candidateId && item.ledgerId === principal.ledgerId,
      );
      if (!current) throw new Error("agent_quote_candidate_not_found");
      if (current.status !== "suggested") {
        throw new Error("agent_quote_candidate_already_reviewed");
      }
      const timestamp = now();
      current.status = decision === "apply" ? "applied" : "rejected";
      current.updatedAt = timestamp;
      if (decision === "apply") current.appliedAt = timestamp;
      return { ...current };
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
