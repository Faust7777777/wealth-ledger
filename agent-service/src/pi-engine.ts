import { mkdir, readFile } from "node:fs/promises";
import {
  ModelRuntime,
  SessionManager,
  createAgentSession,
  type AgentSession,
} from "@earendil-works/pi-coding-agent";
import { createFinwealthTools, FinwealthClient } from "./finwealth-client.js";
import type {
  AgentConversation,
  AgentAttachment,
  AgentEngine,
  AgentModelInfo,
  RunCallbacks,
} from "./types.js";
import { StateStore } from "./state-store.js";
import { createWorkspaceTools } from "./workspace-tools.js";
import { createMemoryTools } from "./memory-tools.js";
import { createQuoteCandidateTools } from "./quote-candidate-tools.js";

interface CachedSession {
  session: AgentSession;
  sessionFile?: string;
  modelId: string;
}

export class PiAgentEngine implements AgentEngine {
  readonly #store: StateStore;
  readonly #agentDir: string;
  readonly #models: ModelRuntime;
  readonly #finwealth: FinwealthClient;
  readonly #sessions = new Map<string, CachedSession>();

  private constructor(
    store: StateStore,
    agentDir: string,
    models: ModelRuntime,
    finwealth: FinwealthClient,
  ) {
    this.#store = store;
    this.#agentDir = agentDir;
    this.#models = models;
    this.#finwealth = finwealth;
  }

  static async create(
    store: StateStore,
    agentDir: string,
    finwealth: FinwealthClient,
  ): Promise<PiAgentEngine> {
    await mkdir(agentDir, { recursive: true, mode: 0o700 });
    const models = await ModelRuntime.create({
      authPath: `${agentDir}/auth.json`,
      modelsPath: `${agentDir}/models.json`,
    });
    return new PiAgentEngine(store, agentDir, models, finwealth);
  }

  async listModels(): Promise<AgentModelInfo[]> {
    const models = await this.#models.getAvailable();
    return models.map((model) => ({
      id: `${model.provider}/${model.id}`,
      provider: model.provider,
      displayName: model.name,
      supportsImages: model.input.includes("image"),
    }));
  }

  async run(
    conversation: AgentConversation,
    text: string,
    attachments: AgentAttachment[],
    callbacks: RunCallbacks,
  ): Promise<{ text: string; piSessionFile?: string }> {
    const cached = await this.#session(conversation);
    let output = "";
    const unsubscribe = cached.session.subscribe((event) => {
      if (
        event.type === "message_update" &&
        event.assistantMessageEvent.type === "text_delta"
      ) {
        output += event.assistantMessageEvent.delta;
        callbacks.onDelta(event.assistantMessageEvent.delta);
      } else if (event.type === "tool_execution_start") {
        callbacks.onToolStarted(event.toolName);
      } else if (event.type === "tool_execution_end") {
        callbacks.onToolCompleted(event.toolName, event.isError);
      }
    });
    try {
      const images = await Promise.all(
        attachments.map(async (attachment) => ({
          type: "image" as const,
          data: (await readFile(attachment.originalPath)).toString("base64"),
          mimeType: attachment.mimeType,
        })),
      );
      const state = await this.#store.read(conversation.userId);
      const activeMemories = state.memories
        .filter((item) => item.ledgerId === conversation.ledgerId && item.status === "active")
        .map((item) => item.content);
      const prompt = activeMemories.length
        ? `<finwealth_user_memory>${JSON.stringify(activeMemories)}</finwealth_user_memory>\n\n${text}`
        : text;
      await cached.session.prompt(prompt, images.length ? { images } : undefined);
      if (cached.session.sessionFile) {
        cached.sessionFile = cached.session.sessionFile;
      }
      return {
        text: output,
        ...(cached.sessionFile ? { piSessionFile: cached.sessionFile } : {}),
      };
    } finally {
      unsubscribe();
    }
  }

  async cancel(conversationId: string): Promise<boolean> {
    const cached = this.#sessions.get(conversationId);
    if (!cached) return false;
    await cached.session.abort();
    return true;
  }

  async #session(conversation: AgentConversation): Promise<CachedSession> {
    const existing = this.#sessions.get(conversation.id);
    if (
      existing &&
      (!conversation.selectedModelId || existing.modelId === conversation.selectedModelId)
    ) {
      return existing;
    }
    if (existing) {
      existing.session.dispose();
      this.#sessions.delete(conversation.id);
    }

    const available = await this.#models.getAvailable();
    const selected = conversation.selectedModelId
      ? available.find(
          (model) =>
            `${model.provider}/${model.id}` === conversation.selectedModelId,
        )
      : available[0];
    if (!selected) throw new Error("agent_model_unavailable");

    const cwd = this.#store.workspace(conversation.userId);
    const sessionDir = this.#store.sessionDir(conversation.userId);
    await this.#store.prepareUser(conversation.userId);
    const sessionManager = conversation.piSessionFile
      ? SessionManager.open(conversation.piSessionFile, sessionDir, cwd)
      : SessionManager.create(cwd, sessionDir);
    const { session } = await createAgentSession({
      cwd,
      agentDir: this.#agentDir,
      model: selected,
      modelRuntime: this.#models,
      sessionManager,
      noTools: "builtin",
      customTools: [
        ...createWorkspaceTools(cwd),
        ...createFinwealthTools(this.#finwealth),
        ...createMemoryTools(this.#store, conversation),
        ...createQuoteCandidateTools(this.#store, conversation),
      ],
    });
    const cached: CachedSession = {
      session,
      modelId: `${selected.provider}/${selected.id}`,
      ...(session.sessionFile ? { sessionFile: session.sessionFile } : {}),
    };
    this.#sessions.set(conversation.id, cached);
    return cached;
  }
}
