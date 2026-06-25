# finwealth-server

Rust/Axum server skeleton for Finwealth.

This is not the production service yet. It exists to prove the HTTP API shape
and product boundaries before real storage, auth, AI, quotes, or sync are added.

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

## Boundaries

- localhost only
- no persistence
- no real auth
- no real AI
- no real quotes
- no real sync
- no transfer execution
- no broker order endpoints
- no AI direct ledger writes
- no coupon planning

## Internal boundary

Routes now use `AppState { ledger: DevLedgerCore }` as the backend seam.
`DevLedgerCore` is deterministic and in-memory; it owns the empty/degraded dev
dataset selection. HTTP handlers should stay thin: parse path/query, call the
ledger facade, then wrap the result in the shared response envelope.

When real local storage is added, replace the dev core/store behind this facade
instead of letting route handlers talk directly to SQLite, sync, quotes, or AI.

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

The Rust dev server also accepts two temporary compatibility aliases for early
frontend integration:

```text
GET /v1/holdings?scenario=degraded          # canonical: /v1/portfolio/holdings
GET /v1/movements/recent?scenario=degraded  # canonical: /v1/movements
```

## Dev proposal write paths

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
`confirmedMovementIds` list in this dev server. This is intentional until the
real local ledger store exists.

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
- DCA mark-executed returns `pending_review` proposal and states no order/no transfer
- dev-only AI/DCA proposal write paths do not write confirmed ledger
- forbidden product-boundary endpoints return 403
- AI proposal contains old → new diff
