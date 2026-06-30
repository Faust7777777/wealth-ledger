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

Runs a write-capable smoke against a temporary real-local JSON ledger:

```bash
python tools/local_ledger_smoke.py
```

## VPS deployment draft

Private self-use VPS deployment notes and systemd assets:

```text
docs/deploy/VPS_DEPLOYMENT.md
deploy/systemd/finwealth-server.service
deploy/finwealth-server.env.example
tools/install_vps_systemd.sh
```

## Packaging

Create local Windows zip and Android debug APK copies under `dist/`:

```powershell
powershell -ExecutionPolicy Bypass -File tools\package_release.ps1
```

If the builds already exist, package without rebuilding:

```powershell
powershell -ExecutionPolicy Bypass -File tools\package_release.ps1 -SkipBuild
```

GitHub Actions also has a manual `Package` workflow that uploads Windows and
Android artifacts for the current branch.

## Rust server skeleton

```bash
cargo run --manifest-path server-rs/Cargo.toml
```

Default:

```text
http://127.0.0.1:8790
```

## Self-use local run

Fast path for Windows self-use development. This builds and starts the Rust
server with a persistent local ledger, waits for `/v1/health`, starts the
Flutter Windows app against it, and stops the server when Flutter exits:

Check local readiness first:

```powershell
powershell -ExecutionPolicy Bypass -File tools\doctor.ps1
```

Run deeper local checks when needed:

```powershell
powershell -ExecutionPolicy Bypass -File tools\doctor.ps1 -Deep
```

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_self_use_windows.ps1
```

By default the script enables local auth. It prompts for a username/password if
`FINWEALTH_AUTH_USERNAME` / `FINWEALTH_AUTH_PASSWORD_HASH` are not already set.
The password is used only to derive an Argon2 hash for the server process; the
script does not write the password to disk. The app stores login tokens with
Windows DPAPI / Android Keystore.

Smoke-check the script without opening Flutter:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_self_use_windows.ps1 -SmokeOnly
```

Run without auth only for quick local debugging:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_self_use_windows.ps1 -NoAuth
```

Back up the local JSON ledger and auth device state:

```powershell
powershell -ExecutionPolicy Bypass -File tools\backup_local_ledger.ps1
```

Restore from a backup directory:

```powershell
powershell -ExecutionPolicy Bypass -File tools\restore_local_ledger.ps1 -BackupPath backups\<timestamp>
```

Manual two-terminal flow:

Start the Rust server with a persistent local JSON ledger:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_local_server.ps1
```

In a second terminal, start the Windows Flutter app against that server:

```powershell
powershell -ExecutionPolicy Bypass -File tools\run_windows_local.ps1
```

Defaults:

- API: `http://127.0.0.1:8791`
- ledger file: `tmp\ledger.json`
- Flutter data source: `local_server`

## Product boundaries

- No transfer execution.
- No broker order placement.
- No AI direct ledger writes.
- No coupon planning or consumption optimization module.
- DCA "record executed" creates a proposal only; it never places an order.
