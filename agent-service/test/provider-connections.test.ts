import assert from "node:assert/strict";
import { test } from "node:test";
import { selectAgentModel } from "../src/pi-engine.js";
import { ProviderConnections } from "../src/provider-connections.js";

function deferred(): {
  promise: Promise<void>;
  resolve(): void;
  reject(error: Error): void;
} {
  let resolve!: () => void;
  let reject!: (error: Error) => void;
  const promise = new Promise<void>((onResolve, onReject) => {
    resolve = onResolve;
    reject = onReject;
  });
  return { promise, resolve, reject };
}

test("xAI OAuth exposes only the device code and becomes connected", async () => {
  const login = deferred();
  let connected = false;
  let loggedOut = false;
  const providers = new ProviderConnections({
    async checkAuth() {
      return connected ? { type: "oauth" } : undefined;
    },
    async login(_providerId, _type, interaction) {
      interaction.notify({
        type: "device_code",
        verificationUri: "https://auth.x.ai/device",
        userCode: "ABCD-EFGH",
        expiresInSeconds: 300,
      });
      await login.promise;
      connected = true;
      return {};
    },
    async logout() {
      connected = false;
      loggedOut = true;
    },
  });

  assert.deepEqual(await providers.listProviders(), [{
    id: "xai",
    displayName: "Grok",
    authMethods: ["oauth"],
    connectionStatus: "disconnected",
  }]);
  const attempt = await providers.startOAuth("xai");
  assert.equal(attempt.status, "pending");
  assert.equal(attempt.verificationUri, "https://auth.x.ai/device");
  assert.equal(attempt.userCode, "ABCD-EFGH");
  assert.match(attempt.expiresAt ?? "", /^\d{4}-\d{2}-\d{2}T/);
  assert.equal((await providers.listProviders())[0]?.connectionStatus, "connecting");

  login.resolve();
  await login.promise;
  await new Promise((resolve) => setImmediate(resolve));
  assert.equal(providers.getOAuthAttempt(attempt.attemptId).status, "connected");
  assert.equal((await providers.listProviders())[0]?.connectionStatus, "connected");

  await providers.disconnect("xai");
  assert.equal(loggedOut, true);
  assert.equal((await providers.listProviders())[0]?.connectionStatus, "disconnected");
});

test("disconnect aborts an in-flight OAuth login before deleting credentials", async () => {
  let aborted = false;
  let logoutAfterAbort = false;
  const providers = new ProviderConnections({
    async checkAuth() {
      return undefined;
    },
    login(_providerId, _type, interaction) {
      interaction.notify({
        type: "device_code",
        verificationUri: "https://auth.x.ai/device",
        userCode: "CODE",
      });
      return new Promise((_resolve, reject) => {
        interaction.signal.addEventListener("abort", () => {
          aborted = true;
          reject(new Error("aborted"));
        });
      });
    },
    async logout() {
      logoutAfterAbort = aborted;
    },
  });
  const attempt = await providers.startOAuth("xai");
  await assert.rejects(
    providers.startOAuth("xai"),
    /agent_provider_oauth_busy/,
  );
  await providers.disconnect("xai");
  assert.equal(logoutAfterAbort, true);
  assert.equal(providers.getOAuthAttempt(attempt.attemptId).status, "cancelled");
});

test("model selection never falls back to another available provider", () => {
  const available = [
    { provider: "other", id: "available" },
    { provider: "xai", id: "grok-4.5" },
  ];
  assert.deepEqual(
    selectAgentModel(available, undefined, "xai/grok-4.5"),
    available[1],
  );
  assert.throws(
    () => selectAgentModel(available, "xai/not-connected", "other/available"),
    /agent_model_unavailable/,
  );
  assert.throws(
    () => selectAgentModel(available),
    /agent_model_selection_required/,
  );
});
