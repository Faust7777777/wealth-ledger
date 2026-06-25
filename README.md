# finwealth

Personal asset / investment / liability control panel for Android and Windows.

Current development split:

- Flutter frontend skeleton: `lib/`
- Interface and backend contracts: `docs/contracts/`
- Local read-only mock API: `tools/mock_api_server.py`
- Local dev server skeleton: `server/dev_server.py`
- Rust/Axum server skeleton: `server-rs/`

## Contract checks

```bash
python tools/contract_check.py
```

## Local mock API

Returns contract examples only. It is read-only and has no persistence.

```bash
python tools/mock_api_server.py
```

Default:

```text
http://127.0.0.1:8787
```

## Local dev server skeleton

Dependency-free server skeleton for API shape checks. It does not implement real
auth, persistence, AI, quotes, or sync.

```bash
python server/dev_server.py
```

Default:

```text
http://127.0.0.1:8788
```

## Local API smoke checks

Starts the mock API, Python dev server, and Rust server on localhost, verifies
critical contract responses, then shuts them down:

```bash
python tools/server_smoke.py
```

## Rust server skeleton

```bash
cargo run --manifest-path server-rs/Cargo.toml
```

Default:

```text
http://127.0.0.1:8790
```

## Product boundaries

- No transfer execution.
- No broker order placement.
- No AI direct ledger writes.
- No coupon planning or consumption optimization module.
- DCA "record executed" creates a proposal only; it never places an order.
