import type { AgentEvent } from "./types.js";

type Listener = (event: AgentEvent) => void;

export class EventHub {
  readonly #listeners = new Map<string, Set<Listener>>();

  publish(event: AgentEvent): void {
    for (const listener of this.#listeners.get(event.conversationId) ?? []) {
      listener(event);
    }
  }

  subscribe(conversationId: string, listener: Listener): () => void {
    const listeners = this.#listeners.get(conversationId) ?? new Set();
    listeners.add(listener);
    this.#listeners.set(conversationId, listeners);
    return () => {
      listeners.delete(listener);
      if (listeners.size === 0) this.#listeners.delete(conversationId);
    };
  }
}
