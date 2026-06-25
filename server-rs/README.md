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
- DCA mark-executed returns `pending_review` proposal and states no order/no transfer
- forbidden product-boundary endpoints return 403
- AI proposal contains old → new diff
