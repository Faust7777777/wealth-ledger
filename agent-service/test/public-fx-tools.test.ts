import assert from "node:assert/strict";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import {
  lookupPublicFxCandidate,
  PUBLIC_FX_SOURCE_URL,
} from "../src/public-fx-tools.js";
import { StateStore } from "../src/state-store.js";
import type { AgentConversation } from "../src/types.js";

function conversation(): AgentConversation {
  return {
    id: "conv_fx",
    userId: "usr_owner",
    ledgerId: "ledger_default",
    title: "FX",
    isPrimary: false,
    status: "active",
    createdAt: "2026-07-29T00:00:00Z",
    updatedAt: "2026-07-29T00:00:00Z",
  };
}

test("public FX lookup creates a review-only USD/CNY candidate with source time", async () => {
  const root = await mkdtemp(join(tmpdir(), "finwealth-public-fx-"));
  try {
    const requested: string[] = [];
    const fetchFx: typeof fetch = async (input) => {
      requested.push(String(input));
      return new Response(JSON.stringify({
        result: "success",
        time_last_update_unix: 1_785_283_351,
        base_code: "USD",
        rates: { USD: 1, CNY: 6.77847 },
      }), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    };
    const store = new StateStore(root);
    const candidate = await lookupPublicFxCandidate(
      store,
      conversation(),
      { baseCurrency: "USD", quoteCurrency: "CNY" },
      fetchFx,
    );
    assert.deepEqual(requested, [PUBLIC_FX_SOURCE_URL]);
    assert.equal(candidate.kind, "fx");
    assert.equal(candidate.baseCurrency, "USD");
    assert.equal(candidate.quoteCurrency, "CNY");
    assert.equal(candidate.rate, "6.77847");
    assert.equal(candidate.asOf, "2026-07-29T00:02:31.000Z");
    assert.equal(candidate.source, "ExchangeRate-API");
    assert.equal(candidate.sourceUrl, PUBLIC_FX_SOURCE_URL);
    assert.equal(candidate.status, "suggested");
    assert.equal((await store.read("usr_owner")).quoteCandidates.length, 1);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});

test("public FX lookup fails closed when the provider omits a requested rate", async () => {
  const root = await mkdtemp(join(tmpdir(), "finwealth-public-fx-missing-"));
  try {
    const store = new StateStore(root);
    await assert.rejects(
      lookupPublicFxCandidate(
        store,
        conversation(),
        { baseCurrency: "USD", quoteCurrency: "CNY" },
        async () => new Response(JSON.stringify({
          result: "success",
          time_last_update_unix: 1_785_283_351,
          base_code: "USD",
          rates: { USD: 1 },
        })),
      ),
      /agent_public_fx_unavailable/,
    );
    assert.equal((await store.read("usr_owner")).quoteCandidates.length, 0);
  } finally {
    await rm(root, { recursive: true, force: true });
  }
});
