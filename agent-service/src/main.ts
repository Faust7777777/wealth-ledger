import { resolve } from "node:path";
import { AgentService } from "./agent-service.js";
import { EventHub } from "./event-hub.js";
import { FinwealthClient } from "./finwealth-client.js";
import { createAgentHttpServer } from "./http-server.js";
import { PiAgentEngine } from "./pi-engine.js";
import { StateStore } from "./state-store.js";

function required(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`${name} is required`);
  return value;
}

function parseAddress(value: string): { host: string; port: number } {
  const match = value.match(/^(127\.0\.0\.1|\[::1\]):([0-9]{1,5})$/);
  if (!match?.[1] || !match[2]) {
    throw new Error("FINWEALTH_AGENT_ADDR must be a loopback host and port");
  }
  const port = Number.parseInt(match[2], 10);
  if (port < 1 || port > 65_535) throw new Error("invalid Agent port");
  return { host: match[1] === "[::1]" ? "::1" : match[1], port };
}

const stateRoot = resolve(
  process.env.FINWEALTH_AGENT_STATE_DIR ?? ".finwealth-agent",
);
const agentDir = resolve(process.env.PI_CODING_AGENT_DIR ?? `${stateRoot}/pi`);
const internalToken = required("FINWEALTH_AGENT_INTERNAL_TOKEN");
const serverBaseUrl = required("FINWEALTH_SERVER_BASE_URL");
delete process.env.FINWEALTH_AGENT_INTERNAL_TOKEN;
const address = parseAddress(
  process.env.FINWEALTH_AGENT_ADDR ?? "127.0.0.1:8792",
);
const store = new StateStore(stateRoot);
const finwealth = new FinwealthClient(serverBaseUrl, internalToken);
const engine = await PiAgentEngine.create(
  store,
  agentDir,
  finwealth,
);
const service = new AgentService(store, new EventHub(), engine, finwealth);
const server = createAgentHttpServer(service, internalToken);

server.listen(address.port, address.host, () => {
  process.stdout.write(
    `finwealth-agent listening on ${address.host}:${address.port}\n`,
  );
});
