# finwealth-server

Rust/Axum server for Finwealth development and private self-use.

With `--ledger-path` it is a real write-capable implementation backed by a
validated, synced and atomically replaced JSON ledger. It includes persistent local auth,
idempotent write handling, portfolio derivation, proposal confirmation, and a
local sync log. Without `--ledger-path` it remains a deterministic in-memory dev
server. It is not a multi-tenant production service: AI is not model-backed and
there is no complete multi-device sync coordinator.

## Run

```bash
cargo run --manifest-path server-rs/Cargo.toml
```

Default:

```text
http://127.0.0.1:8790
```

Override:

```powershell
$env:FINWEALTH_RS_ADDR='127.0.0.1:8790'
cargo run --manifest-path server-rs/Cargo.toml
```

Equivalent CLI override:

```powershell
cargo run --manifest-path server-rs/Cargo.toml -- --port 8791
cargo run --manifest-path server-rs/Cargo.toml -- --addr 127.0.0.1:8791
```

Enable the real-local JSON ledger seam:

```powershell
cargo run --manifest-path server-rs/Cargo.toml -- --port 8791 --ledger-path .\tmp\ledger.json
```

## Boundaries

- localhost only
- no persistence in the default deterministic dev mode
- `--ledger-path` enables real-local JSON persistence for accounts,
  instruments/holdings, movements, DCA plans/reminders, subscriptions, AI
  proposals, snapshots, categories/counterparties, quote/FX cache, sync log,
  idempotency records, and derived portfolio read models
- persistent configurable local auth for login/refresh/devices; dev-compatible
  tokens are used only when auth env vars are absent
- no model-backed AI; import routes create reviewable proposals only
- outbound quote/FX/historical-price fetches are disabled by default; set
  `FINWEALTH_QUOTE_PROVIDER=yahoo` to opt in when symbols are configured
- validated local sync log/outbox and HTTP push/pull/ack shapes, but no remote
  coordinator or background transport
- no transfer execution
- no broker order endpoints
- no AI direct ledger writes
- no coupon planning

## Internal boundary

`DevLedgerCore` owns deterministic empty/degraded data when no ledger path is
mounted. With `--ledger-path`, handlers route writes through `local_ledger`,
which validates the full document and serializes mutation plus idempotency
record into one file replacement. HTTP handlers should remain thin and must not
bypass that module for persistent writes. The JSON store is the current
self-use implementation, not a debug fixture or a future database abstraction.

## Dev scenarios

Default routes keep the empty-ledger shape. Add `?scenario=degraded` to the
first-batch read routes when the Flutter frontend needs a consistent demo state
for local HTTP integration:

```text
GET /v1/portfolio/overview?scenario=degraded
GET /v1/accounts?scenario=degraded
GET /v1/accounts/acct_us_broker?scenario=degraded
GET /v1/accounts/acct_us_broker/holdings?scenario=degraded
GET /v1/accounts/anomalies?scenario=degraded
GET /v1/portfolio/holdings?scenario=degraded
GET /v1/portfolio/allocation?scenario=degraded
GET /v1/movements?scenario=degraded
GET /v1/movements/mov_luckin_001?scenario=degraded
GET /v1/dca/plans?scenario=degraded
GET /v1/dca/reminders/due?scenario=degraded
GET /v1/ai/proposals/pending?scenario=degraded
GET /v1/ai/proposals/proposal_ai_001?scenario=degraded
GET /v1/snapshots/latest?scenario=degraded
GET /v1/snapshots?scenario=degraded
GET /v1/quotes/summary?scenario=degraded
```

This data is virtual dev data only. It is not a fixture seed and must not be
synced or persisted.

## Local auth

For self-hosted use, prefer an Argon2 password hash:

```powershell
"your-password" | cargo run --manifest-path server-rs/Cargo.toml -- --hash-password-stdin
$env:FINWEALTH_AUTH_USERNAME="your-name"
$env:FINWEALTH_AUTH_PASSWORD_HASH="<printed-argon2-hash>"
$env:FINWEALTH_REQUIRE_AUTH="true"
```

Temporary local development can use `FINWEALTH_AUTH_PASSWORD`, but do not use it
for deployment. Tokens are random opaque strings; the server stores only token
hashes. With `--ledger-path .\tmp\ledger.json`, auth device state defaults to
`.\tmp\ledger.auth.json`, so refresh-token "instant login" survives server
restart. Set `FINWEALTH_AUTH_STATE_PATH` to override this location. If auth env
vars are absent, `/v1/auth/login` remains dev-compatible and returns `dev_*`
tokens for existing smoke tests.

`FINWEALTH_REQUIRE_AUTH=true` protects non-public routes with `Authorization:
Bearer <accessToken>`. It is off by default so existing local Flutter integration
continues to work until the client stores and sends tokens.

## Real-local ledger bootstrap

The first real-local storage seam is a validated JSON ledger file plus an
optional sibling auth-state file. This is a bootstrap format for local self-use
development: it is not the debug fixture, it has a local sync log but no remote
coordinator, and it is not encrypted yet. Future SQLite/encryption work should sit
behind the same ledger boundary instead of changing route handlers.

```powershell
cargo run --manifest-path server-rs/Cargo.toml -- --init-ledger .\tmp\ledger.json
cargo run --manifest-path server-rs/Cargo.toml -- --validate-ledger .\tmp\ledger.json
cargo run --manifest-path server-rs/Cargo.toml -- --validate-auth-state .\tmp\ledger.auth.json
cargo run --manifest-path server-rs/Cargo.toml -- --check-ledger-paths .\tmp\ledger.json .\tmp\ledger.fixture.json
```

Persisted files for the default path pair are:

```text
tmp\ledger.json       # business ledger, sync log, idempotency records
tmp\ledger.auth.json  # optional device state and token hashes; no plaintext tokens
tmp\ledger.json.lock  # permanent process-lease sidecar; never infer ownership from existence
```

The sibling auth state backs login/refresh/logout and device list/revoke routes;
it is not part of portfolio or movement derivation.

## Exclusive local-ledger lease

`--ledger-path` mode is single-process by design. Before initializing or reading
the ledger and before opening its sibling auth state, the server acquires an
exclusive OS file lock on a permanent sidecar formed by appending `.lock` to the
normalized ledger path. The `LedgerLease` guard is retained by `AppState` for
the entire server lifetime, so one lease protects both ledger and auth writes.

Acquisition waits for at most three seconds by default. A second server for the
same ledger then fails closed with a `ledger is already in use` error; it does
not continue in a degraded mode or initialize replacement state. Process exit
or a crash releases the lock through the operating system, but the sidecar file
itself is deliberately never deleted. Its presence therefore does not mean a
process currently owns the ledger.

This boundary does not provide active-active service, multiple writers, or
shared-filesystem clustering. The implementation uses Rust standard-library
file locking and requires Rust 1.89 or newer.

Running the server with `--ledger-path` makes the first self-use write paths use
the JSON ledger when no `?scenario=` query is present:

- accounts: list/create/detail/update/archive
- movements: draft → submit review → confirm/reject, detail, list
- DCA: create plan, list due reminders, skip/snooze, record executed as a
  confirmable proposal
- subscriptions: `GET/POST /v1/subscriptions`,
  `GET /v1/subscriptions/upcoming`,
  `GET/PATCH /v1/subscriptions/{subscription_id}`,
  `POST /v1/subscriptions/{subscription_id}/cancel`, and
  `POST /v1/subscriptions/{subscription_id}/charge-proposal`, plus the bounded
  `POST /v1/subscriptions/charge-proposals/due-scan`; plans never charge an
  external payment provider, and only confirmed proposals affect balances
- AI proposal review: text/image/CSV import proposals, edit, approve/reject
- snapshots: latest/list/manual baseline
- instruments and cached market data: instrument create/update plus quote/FX
  reads and explicit quote refresh when a provider is configured
- taxonomy: categories, counterparties, counterparty merge proposal
- portfolio read models: overview, allocation, holdings, quote summary
- sync outbox: pull/ack plus idempotent remote log relay; no entity merge yet
- crash-safe file boundary: temp contents are synced before rename; a valid temp
  is promoted only when the primary is missing, while an invalid temp blocks
  empty-ledger initialization and remains available for recovery

With a real ledger mounted, `?scenario=` is rejected by default so virtual data
cannot be mixed with real state. `FINWEALTH_ALLOW_LEDGER_SCENARIO=true` is an
explicit dev-only diagnostic override.

The validator rejects debug fixture markers and basic invalid money shapes so a
real-local file cannot silently become demo data.

All real-local ledger mutation routes require `Idempotency-Key` (1–128 visible
ASCII characters). The server stores only SHA-256 key/request hashes plus the
original successful response inside `ledger.json`; the domain mutation and
idempotency record are committed by the same atomic file replacement. Retrying
the same request replays the saved response with `Idempotency-Replayed: true`.
Reusing a key for a different request returns `409 idempotency_key_reused`.
Records expire after 30 days and are capped at 5000 entries.

DCA "record executed" in real-local mode may persist a pending proposal/draft so
the review flow survives refresh/restart. It still does not place orders,
execute transfers, or affect the confirmed/effective ledger until the user
confirms the atomic group.

Subscription due-scan is also a real-local-only, explicit command endpoint. It
is not a background timer: a client or scheduler must call it with a local
calendar date and an idempotency key. Without `--ledger-path` it returns `501`
instead of pretending that candidates were persisted. For example:

```powershell
$headers = @{ 'Idempotency-Key' = 'subscription-scan-2026-07-13' }
$body = @{ throughDate = '2026-07-13'; limit = 100 } | ConvertTo-Json
Invoke-RestMethod -Method Post `
  -Uri 'http://127.0.0.1:8791/v1/subscriptions/charge-proposals/due-scan' `
  -Headers $headers -ContentType 'application/json' -Body $body
```

The scan creates `pending_review` charge candidates only. It does not deduct an
account balance, advance `lastChargeDate`/`nextChargeDate`, call a payment
provider, or auto-confirm anything. Each candidate remains visible in AI review
until the user confirms or rejects its atomic group.

## Ledger schema compatibility and migrations

The persisted schema remains `ledgerVersion: 1`. The migration registry is an
intentionally empty, validated skeleton in this slice; starting the server and
ordinary API reads do not migrate or rewrite `ledger.json`.

The v1 read-compatibility layer is deliberately narrow. In memory it may add a
missing `subscriptions` array, `syncChanges` array, or version-1
`idempotencyState`. It may add `syncState.nextChangeSequence = 1` only when the
`syncState` object already exists. A missing `syncState`, `syncState.cursor`, or
`syncState.pendingChangeIds` fails validation instead of guessing sync progress
or rebuilding the outbox. These compatibility defaults do not bump
`ledgerVersion` or append migration history.

Initialization and `.tmp` recovery happen only during explicit initialization
or server startup. Once running, request-time reads and write transactions
require the primary ledger to still exist; if it disappears they fail closed
instead of silently creating a new empty ledger.

A future real schema upgrade must use an explicit backup-and-migrate command:
first create and validate a complete ledger/auth snapshot, then apply one
unambiguous contiguous registry path, validate the result, and atomically
replace the live ledger. No such upgrade command is exposed by this slice.

The Rust dev server also accepts two temporary compatibility aliases for early
frontend integration:

```text
GET /v1/holdings?scenario=degraded          # canonical: /v1/portfolio/holdings
GET /v1/movements/recent?scenario=degraded  # canonical: /v1/movements
```

## Dev proposal write paths without `--ledger-path`

The following POST routes validate frontend flow shape but do not persist state
and do not write the confirmed ledger:

```text
POST /v1/dca/reminders/{reminder_id}/mark-executed-as-proposal
POST /v1/ai/proposals/from-text
POST /v1/ai/proposals/from-image
POST /v1/ai/proposals/from-csv
POST /v1/ai/atomic-groups/{atomic_group_id}/approve
POST /v1/ai/atomic-groups/{atomic_group_id}/reject
POST /v1/ai/atomic-groups/{atomic_group_id}/edit
POST /v1/atomic-groups/{atomic_group_id}/confirm
POST /v1/atomic-groups/{atomic_group_id}/reject
```

Approve/confirm responses include `ledgerWrite: false` and an empty
`confirmedMovementIds` list when no ledger path is mounted. This is intentional
because deterministic dev mode has no durable confirmed ledger.

Within a running dev-server process, proposal create / approve / reject / edit
state is tracked in memory so the frontend can verify review flows. Restarting
the server clears this state.

## Real-local ledger smoke

This runs the write-capable local ledger flow against a temporary file and
removes it afterwards:

```powershell
python tools\local_ledger_smoke.py
```

It verifies persistent account-create replay, account update, manual movement
confirmation, DCA record-executed confirmation, and a real-local subscription
due-scan over multiple foreign-currency plans. The subscription checks cover
same-key replay, different-body conflict, unchanged balance/schedule before
confirmation, AI-review discovery, confirmed deduction/date advancement, and
the invariant that the projected candidate is not duplicated in `aiProposals`.
The smoke also covers CSV/image proposal creation, AI approval, snapshot
creation, derived overview/allocation values, forbidden broker endpoints, and
on-disk persistence.

## Checks

```bash
cargo fmt --manifest-path server-rs/Cargo.toml --check
cargo check --manifest-path server-rs/Cargo.toml
cargo test --manifest-path server-rs/Cargo.toml
cargo clippy --manifest-path server-rs/Cargo.toml -- -D warnings
```

Current route regression tests cover:

- localhost-only bind guard
- contract examples parse
- `GET /v1/health`
- degraded portfolio overview pending summary
- empty-list defaults for first-batch read routes
- degraded account / holding / movement / DCA / AI / snapshot / quote routes
- subscription scheduling, pending-charge conflict, rejection/retry,
  confirmation date advancement, cancellation, and foreign-currency charging
- DCA mark-executed returns `pending_review` proposal and states no order/no transfer
- dev-only AI/DCA proposal write paths do not write confirmed ledger
- forbidden product-boundary endpoints return 403
- AI proposal contains old → new diff
