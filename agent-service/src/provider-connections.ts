import { randomUUID } from "node:crypto";
import type {
  AgentProviderInfo,
  AgentProviderManager,
  AgentProviderOAuthAttempt,
} from "./types.js";

interface ProviderAuthRuntime {
  checkAuth(providerId: string): Promise<{ type: string } | undefined>;
  login(
    providerId: string,
    type: "oauth",
    interaction: {
      signal: AbortSignal;
      prompt(prompt: unknown): Promise<string>;
      notify(event: unknown): void;
    },
  ): Promise<unknown>;
  logout(providerId: string): Promise<void>;
}

interface ProviderDefinition {
  id: string;
  displayName: string;
  authMethods: Array<"oauth" | "api_key">;
}

interface StoredAttempt {
  public: AgentProviderOAuthAttempt;
  controller: AbortController;
  task: Promise<void>;
  ready: Promise<AgentProviderOAuthAttempt>;
}

const CURRENT_PROVIDERS: ProviderDefinition[] = [
  { id: "xai", displayName: "Grok", authMethods: ["oauth"] },
];

function copyAttempt(value: AgentProviderOAuthAttempt): AgentProviderOAuthAttempt {
  return { ...value };
}

export class ProviderConnections implements AgentProviderManager {
  readonly #runtime: ProviderAuthRuntime;
  readonly #definitions: ProviderDefinition[];
  readonly #attempts = new Map<string, StoredAttempt>();
  readonly #activeByProvider = new Map<string, string>();

  constructor(
    runtime: ProviderAuthRuntime,
    definitions: ProviderDefinition[] = CURRENT_PROVIDERS,
  ) {
    this.#runtime = runtime;
    this.#definitions = definitions;
  }

  async listProviders(): Promise<AgentProviderInfo[]> {
    return Promise.all(this.#definitions.map(async (definition) => {
      const attemptId = this.#activeByProvider.get(definition.id);
      const attempt = attemptId ? this.#attempts.get(attemptId) : undefined;
      const connected = (await this.#runtime.checkAuth(definition.id)) !== undefined;
      return {
        ...definition,
        connectionStatus: connected
          ? "connected" as const
          : attempt?.public.status === "pending"
            ? "connecting" as const
            : "disconnected" as const,
      };
    }));
  }

  async startOAuth(providerId: string): Promise<AgentProviderOAuthAttempt> {
    const definition = this.#definition(providerId);
    if (!definition.authMethods.includes("oauth")) {
      throw new Error("agent_provider_oauth_not_supported");
    }
    if (this.#activeByProvider.has(providerId)) {
      throw new Error("agent_provider_oauth_busy");
    }

    const attemptId = `oauth_${randomUUID()}`;
    const controller = new AbortController();
    let resolveReady!: (value: AgentProviderOAuthAttempt) => void;
    let rejectReady!: (reason: Error) => void;
    const ready = new Promise<AgentProviderOAuthAttempt>((resolve, reject) => {
      resolveReady = resolve;
      rejectReady = reject;
    });
    const stored: StoredAttempt = {
      public: {
        attemptId,
        providerId,
        status: "pending" as const,
      },
      controller,
      ready,
      task: Promise.resolve(),
    };
    this.#attempts.set(attemptId, stored);
    this.#activeByProvider.set(providerId, attemptId);

    let notified = false;
    stored.task = this.#runtime.login(providerId, "oauth", {
      signal: controller.signal,
      prompt: async () => {
        throw new Error("agent_provider_oauth_prompt_unsupported");
      },
      notify: (event) => {
        if (!event || typeof event !== "object") return;
        const value = event as Record<string, unknown>;
        if (
          value.type !== "device_code" ||
          typeof value.userCode !== "string" ||
          typeof value.verificationUri !== "string"
        ) return;
        const expiresInSeconds = typeof value.expiresInSeconds === "number" &&
            Number.isFinite(value.expiresInSeconds) && value.expiresInSeconds > 0
          ? value.expiresInSeconds
          : 600;
        stored.public = {
          attemptId,
          providerId,
          status: "pending",
          verificationUri: value.verificationUri,
          userCode: value.userCode,
          expiresAt: new Date(Date.now() + expiresInSeconds * 1000).toISOString(),
        };
        if (!notified) {
          notified = true;
          resolveReady(copyAttempt(stored.public));
        }
      },
    }).then(() => {
      stored.public = { attemptId, providerId, status: "connected" };
      if (!notified) {
        notified = true;
        resolveReady(copyAttempt(stored.public));
      }
    }).catch(() => {
      const cancelled = controller.signal.aborted;
      stored.public = {
        attemptId,
        providerId,
        status: cancelled ? "cancelled" : "failed",
        ...(!cancelled ? { errorCode: "agent_provider_oauth_failed" } : {}),
      };
      if (!notified) {
        notified = true;
        rejectReady(new Error(
          cancelled ? "agent_provider_oauth_cancelled" : "agent_provider_oauth_failed",
        ));
      }
    }).finally(() => {
      if (this.#activeByProvider.get(providerId) === attemptId) {
        this.#activeByProvider.delete(providerId);
      }
    });

    return ready;
  }

  getOAuthAttempt(attemptId: string): AgentProviderOAuthAttempt {
    const attempt = this.#attempts.get(attemptId);
    if (!attempt) throw new Error("agent_provider_oauth_attempt_not_found");
    return copyAttempt(attempt.public);
  }

  async disconnect(providerId: string): Promise<void> {
    this.#definition(providerId);
    const attemptId = this.#activeByProvider.get(providerId);
    const attempt = attemptId ? this.#attempts.get(attemptId) : undefined;
    if (attempt) {
      attempt.controller.abort();
      await attempt.task;
    }
    await this.#runtime.logout(providerId);
  }

  #definition(providerId: string): ProviderDefinition {
    const definition = this.#definitions.find((item) => item.id === providerId);
    if (!definition) throw new Error("agent_provider_not_found");
    return definition;
  }
}
