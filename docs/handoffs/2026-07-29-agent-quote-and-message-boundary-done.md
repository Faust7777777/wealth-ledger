# Agent FX lookup and message-boundary fix — 2026-07-29

## Delivery

- Branch: `fix/agent-quote-and-message-boundary`.
- Frontend assignment: `3f782c8`, `docs/handoffs/2026-07-29-claude-agent-chat-ui.md`.
- Backend implementation: `9010822`.
- Production Pi sidecar has been atomically deployed from the tested `9010822` build; the previous `dist` remains on the VPS as `dist.before-9010822` for rollback.

## Reproduced production bad case

The latest affected conversation was inspected only through structural metadata, without printing message bodies or other conversations.

- `finwealth_refresh_quotes` completed at the transport level but returned the configured provider-disabled business result.
- The model then ran two generic `bash` calls; both exited without a tool error but produced no quote candidate.
- The final assistant message contained 11 literal `\\n` sequences and zero actual newline characters.
- The preceding correctly formatted assistant message contained seven actual newlines.
- No suggested quote candidate was created.

## Backend correction

### Deterministic public FX candidate

- Added `finwealth_lookup_fx_candidate` as a dedicated Pi tool.
- It accepts a three-letter base and quote currency, reads the fixed public JSON source `https://open.er-api.com/v6/latest/USD`, validates response status, base, source timestamp, and positive rates, derives a cross rate with at most eight decimal places, and creates exactly one `suggested` candidate through the existing quote-candidate store.
- It never applies the candidate, changes balances, or changes authoritative valuation before user review.
- It fails closed as `agent_public_fx_unavailable` when the response, timestamp, or requested rates are absent.
- Tool guidance now directs legal-tender FX requests to this tool instead of probing `finwealth_refresh_quotes` or composing arbitrary shell commands.
- The existing server quote provider remains disabled; this correction does not silently opt the Rust service into background outbound pricing.

### Assistant text boundary

- Added `normalizeAssistantText` at completed-message persistence and history projection.
- A response is normalized only when it has no real newline and at least two JSON-style layout newline escapes.
- Existing real multiline text, isolated escape-like text, Windows paths, and Markdown inline/fenced code are protected.
- Historical affected messages are repaired on read without rewriting conversation state. The production bad case now projects 11 actual newlines and zero literal `\\n` sequences.

## Verification

- TypeScript check passed.
- Agent service: 30 passed, 0 failed.
- Agent service production build passed.
- Rust-to-Pi local sidecar smoke passed.
- VPS atomic deployment health probe passed; two earlier attempts failed before acceptance and rolled back automatically (first probe was too early; second staging directory was not traversable by the service user). The accepted deployment waits for the authenticated sidecar endpoint and publishes world-readable code directories with no writable service secrets.
- Real production model smoke passed: `lore/gpt-5.4` called `finwealth_lookup_fx_candidate` exactly once, created one positive USD/CNY suggested candidate with source and timestamp, and left the authoritative quote summary unchanged.
- The smoke used an isolated temporary user and removed its state afterward.

## Frontend follow-up

Claude should implement `docs/handoffs/2026-07-29-claude-agent-chat-ui.md`: adopt the Apache-2.0 Flutter chat renderer, render assistant output as an unfilled Markdown reading surface, keep user bubbles compact, and retain Finwealth SSE/replay/business-card behavior.

No password, token, API key, private key, model endpoint, message body, ledger content, or production quote value is included in this handoff.
