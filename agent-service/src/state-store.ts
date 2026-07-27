import { mkdir, readFile, rename, writeFile } from "node:fs/promises";
import { dirname, join } from "node:path";
import type { UserState } from "./types.js";

const SAFE_ID = /^[A-Za-z0-9_-]{1,128}$/;

async function renameWithRetry(source: string, destination: string): Promise<void> {
  for (let attempt = 0; ; attempt += 1) {
    try {
      await rename(source, destination);
      return;
    } catch (error) {
      const code = (error as NodeJS.ErrnoException).code;
      if (attempt >= 5 || (code !== "EPERM" && code !== "EBUSY")) throw error;
      await new Promise((resolve) => setTimeout(resolve, 10 * (attempt + 1)));
    }
  }
}

function emptyState(): UserState {
  return {
    schemaVersion: 1,
    conversations: [],
    messages: [],
    events: [],
    attachments: [],
    memories: [],
    idempotency: [],
    nextEventCursor: 1,
  };
}

export class StateStore {
  readonly root: string;
  readonly #queues = new Map<string, Promise<void>>();

  constructor(root: string) {
    this.root = root;
  }

  userRoot(userId: string): string {
    if (!SAFE_ID.test(userId)) throw new Error("invalid_user_id");
    return join(this.root, "users", userId);
  }

  workspace(userId: string): string {
    return join(this.userRoot(userId), "workspace");
  }

  sessionDir(userId: string): string {
    return join(this.userRoot(userId), "sessions");
  }

  async prepareUser(userId: string): Promise<void> {
    await Promise.all([
      mkdir(this.workspace(userId), { recursive: true, mode: 0o700 }),
      mkdir(this.sessionDir(userId), { recursive: true, mode: 0o700 }),
      mkdir(join(this.userRoot(userId), "attachments"), {
        recursive: true,
        mode: 0o700,
      }),
    ]);
  }

  async read(userId: string): Promise<UserState> {
    await this.prepareUser(userId);
    try {
      const parsed = JSON.parse(
        await readFile(this.#statePath(userId), "utf8"),
      ) as UserState;
      if (parsed.schemaVersion !== 1) throw new Error("unsupported_agent_state");
      parsed.idempotency ??= [];
      parsed.attachments ??= [];
      parsed.memories ??= [];
      return parsed;
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return emptyState();
      throw error;
    }
  }

  async update<T>(
    userId: string,
    mutate: (state: UserState) => T | Promise<T>,
  ): Promise<T> {
    let result!: T;
    const previous = this.#queues.get(userId) ?? Promise.resolve();
    const next = previous.then(async () => {
      const state = await this.read(userId);
      result = await mutate(state);
      if (state.events.length > 2_000) {
        state.events = state.events.slice(-2_000);
      }
      if (state.idempotency.length > 1_000) {
        state.idempotency = state.idempotency.slice(-1_000);
      }
      await this.#write(userId, state);
    });
    this.#queues.set(userId, next.catch(() => undefined));
    await next;
    return result;
  }

  #statePath(userId: string): string {
    return join(this.userRoot(userId), "agent-state.json");
  }

  async #write(userId: string, state: UserState): Promise<void> {
    const path = this.#statePath(userId);
    await mkdir(dirname(path), { recursive: true, mode: 0o700 });
    const temporary = `${path}.tmp-${process.pid}`;
    await writeFile(temporary, `${JSON.stringify(state, null, 2)}\n`, {
      encoding: "utf8",
      mode: 0o600,
    });
    await renameWithRetry(temporary, path);
  }
}
