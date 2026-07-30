# VPS deployment draft

Target: a small Linux VPS, including Oracle ARM. The Rust server stays
loopback-only (`127.0.0.1`) and should be exposed through a reverse proxy such as
Caddy or Nginx.

This deployment is the supported private single-user server mode. All online
clients use the same server ledger as their source of truth; offline multi-ledger
merge remains a separate future capability.

## 1. Build and install systemd service

On the VPS:

```bash
git clone --branch feat/subscription-sync-integration --single-branch \
  https://github.com/Faust7777777/wealth-ledger.git
cd wealth-ledger
sudo bash tools/install_vps_systemd.sh
```

## Pi Agent sidecar

The Agent is a separate Node.js 22 service behind the Rust API. The app never
connects to its loopback port directly. Install `bubblewrap`, `poppler-utils`,
`unzip`, and `python3` first; shell commands
run with only the per-user workspace mounted writable, while model credentials
and the rest of the host filesystem remain outside that mount.

Create one random internal token and place the same value in both files:

```text
/etc/finwealth/server.env:
FINWEALTH_AGENT_BASE_URL=http://127.0.0.1:8792
FINWEALTH_AGENT_INTERNAL_TOKEN=<random value>

/etc/finwealth/agent.env:
FINWEALTH_AGENT_INTERNAL_TOKEN=<same random value>
```

Then install and start the sidecar from a reviewed source checkout:

```bash
sudo bash tools/install_vps_agent.sh
```

For non-interactive self-use deployment, `tools/configure_vps_agent.py` accepts
a root-only temporary JSON file whose `apiKey`, `baseUrl`, and `model` fields are
base64-encoded UTF-8. It validates a public HTTPS model endpoint, generates the
shared internal token, atomically updates both environment files, writes the Pi
model configuration with `0600` permissions, and deletes the input file without
printing any value. Start the Agent and restart the Rust gateway only after this
configuration step succeeds.

After the service is configured, run the real-model Linux document smoke as
root with `/etc/finwealth/agent.env` loaded:

```bash
set -a; . /etc/finwealth/agent.env; set +a
python3 tools/agent_vps_document_smoke.py
```

It generates synthetic PDF/XLSX files, uploads them through the authenticated
sidecar surface, and requires the model to recover file-only markers using
`pdftotext` and Python/ZIP inside bubblewrap. PDFs without a usable text layer
are rendered with `pdftoppm` into at most eight bounded JPEG page images and
sent to the selected vision-capable model; no second model or fallback provider
is selected. The smoke does not print model responses or credentials and does
not write the ledger.

Pi provider credentials and model configuration live under
`/var/lib/finwealth-agent/pi/` and must remain owned by `finwealth` with mode
`0700`/`0600`. The service removes the Rust internal token from its process
environment before creating Pi sessions, and tool subprocesses receive a small
environment allow-list rather than the service environment.

Agent state, sessions, images, workspace files, and Pi credentials are not part
of the ledger backup. Back them up separately while the sidecar is stopped:

```bash
sudo bash tools/backup_vps_agent.sh
```

The default output is `/var/backups/finwealth-agent/<UTC timestamp>/`. It is a
root-only checksum-verified archive and contains model credentials; store or
copy it with the same care as `/etc/finwealth/*.env`.

The script:

- builds `server-rs` in release mode;
- installs `/opt/finwealth/finwealth-server`;
- creates system user `finwealth`;
- creates `/var/lib/finwealth` for `ledger.json` and `ledger.auth.json`;
- installs `/etc/systemd/system/finwealth-server.service`;
- creates `/etc/finwealth/server.env` if missing.

If `/etc/finwealth/server.env` still contains `change-me`, the script installs
files but intentionally does not start the service.

### Prebuilt bundle path

The manual Package workflow publishes `finwealth-linux-x86_64-vps-server` and
`finwealth-linux-aarch64-vps-server`.
Use this path when the VPS should not install Rust or when uploading through a
cloud-provider console:

```bash
tar -xzf finwealth-server-*-linux-x86_64-vps.tar.gz
cd finwealth-server-*-linux-x86_64-vps
sha256sum -c SHA256SUMS
sudo bash tools/install_vps_bundle.sh
```

On an ARM64 VPS, use the corresponding `linux-aarch64-vps` archive and directory.

Both architecture bundles contain a statically linked musl release server binary,
systemd unit, environment
example, readiness check, backup and restore scripts, an internal checksum
manifest and source provenance. The installer rejects a mismatched CPU
architecture, preserves an existing ledger and environment file, and follows
the same fail-closed `change-me` and production-config rules as the source
installer.

## 2. Configure auth

Preferred interactive path after installation:

```bash
sudo bash /opt/finwealth/tools/configure_vps_auth.sh your-name api.example.com
```

The password is entered twice without echoing. The script requires at least 12
characters, generates Argon2 locally on the VPS, validates the complete
production configuration through a temporary private EnvironmentFile, then
atomically publishes `/etc/finwealth/server.env` and starts the service. It does
not print or store the plaintext password.

Manual configuration remains available when needed:

Generate an Argon2 password hash on the VPS:

```bash
read -rsp 'Finwealth password: ' FINWEALTH_PASSWORD; echo
printf '%s' "$FINWEALTH_PASSWORD" | /opt/finwealth/finwealth-server --hash-password-stdin
unset FINWEALTH_PASSWORD
```

Edit the env file:

```bash
sudoedit /etc/finwealth/server.env
```

Minimum config:

```env
FINWEALTH_REQUIRE_AUTH=true
FINWEALTH_AUTH_USERNAME=your-name
FINWEALTH_AUTH_PASSWORD_HASH=$argon2id$...
FINWEALTH_RS_ADDR=127.0.0.1:8790
FINWEALTH_ALLOWED_HOSTS=api.example.com
FINWEALTH_QUOTE_PROVIDER=none
FINWEALTH_AI_PROVIDER=none
```

Do not put plaintext passwords in this file. Keep `FINWEALTH_QUOTE_PROVIDER=none`
unless you explicitly accept outbound ticker/FX lookup requests from the VPS; set
it to `yahoo` only after that opt-in. Keep `FINWEALTH_AI_PROVIDER=none` unless
you explicitly accept sending text/image-import content and the minimal account
selection context to an AI provider. To enable Responses-compatible structured
organization, set `FINWEALTH_AI_PROVIDER=openai_responses`,
`FINWEALTH_AI_MODEL`, `FINWEALTH_AI_BASE_URL`, and `FINWEALTH_AI_API_KEY` in
this root-only file. The base URL must use HTTPS, except for loopback testing.

`FINWEALTH_ALLOWED_HOSTS` is required when a reverse proxy preserves the public
Host header. For local-only use, the server always allows `127.0.0.1`,
`localhost`, and loopback IPv6.

Then start:

```bash
sudo systemctl enable --now finwealth-server.service
sudo systemctl status finwealth-server.service --no-pager
```

The installer runs `finwealth-server --check-production-config` through systemd
before starting. It rejects disabled/incomplete auth, a non-loopback bind,
missing public Host allow-list, dev scenario enablement, and unknown quote
provider values.

Health check from the VPS:

```bash
curl http://127.0.0.1:8790/v1/health
```

After configuring the reverse proxy and DNS, run the complete readiness check:

```bash
sudo bash tools/check_vps_readiness.sh --public-base-url https://api.example.com
```

It verifies configuration without printing secrets, ledger/auth semantics,
ownership and permissions, systemd state, loopback-only listening, and both
local and public health endpoints.

## 3. Reverse proxy

Example Caddy config:

```caddyfile
api.example.com {
  reverse_proxy 127.0.0.1:8790
}
```

Server-side firewall/security-list requirements:

- allow inbound `80/tcp` and `443/tcp` to the reverse proxy;
- do not expose `8790/tcp` publicly;
- keep `/etc/finwealth/server.env` mode `0600`;
- back up `/var/lib/finwealth/ledger.json` and `/var/lib/finwealth/ledger.auth.json`.

### Reverse proxy running inside Docker

When Caddy/Nginx runs in a bridge-network container, keep the Rust service on
`127.0.0.1:8790` and expose only a bridge-address relay. For a Docker network
whose host gateway is `172.19.0.1`:

```bash
sudo systemctl enable --now \
  'finwealth-docker-proxy@172.19.0.1:8791.socket'
```

The socket template listens only on the named Docker bridge address and starts
`systemd-socket-proxyd` as the unprivileged `finwealth` user, forwarding to the
loopback Rust service. Point the reverse-proxy container at
`172.19.0.1:8791`. Never bind this relay to `0.0.0.0` or a public interface.

The repository includes `deploy/caddy/finwealth-wuwaidut.com.caddy` as the
reviewed production site block for the current private deployment. It preserves
the existing Cloudflare-only origin rule and forwards the public Host header to
the Rust allow-list. Validate the combined Caddyfile before an atomic reload;
do not replace unrelated site blocks.

### Client update delivery

The installer creates root-owned `/var/lib/finwealth-updates`, adds
`FINWEALTH_CLIENT_UPDATE_DIR` to the server environment when missing, and
installs the atomic publisher plus the narrow shared-Caddy route patch under
`/opt/finwealth/tools`. The Rust service streams published files read-only; it
does not proxy them through the Agent or store them in the ledger.

See `CLIENT_SELF_UPDATE.md` for Android packaging, publication, rollback and
public verification. Applying the client-update Caddy patch affects only
`/v1/client-updates/*` on `wuwaidut.com`; it must not alter the sub2api host or
relay fallback.

Manual backup:

```bash
sudo bash tools/backup_vps_ledger.sh
```

Default output goes to `/var/backups/finwealth/<UTC timestamp>/` with a SHA-256
manifest. The script stops `finwealth-server.service` only when it was active,
copies ledger and auth state into a private staging directory, validates the
copies with the installed Rust binary, writes `manifest.txt` plus safe
`SHA256SUMS`, atomically publishes the backup directory, and restores the
service to its prior active state. Copy the complete directory off the VPS
periodically; individual files are not a complete verified backup.

Restore from a backup directory:

```bash
sudo bash tools/restore_vps_ledger.sh /var/backups/finwealth/<timestamp>
```

The restore script requires and verifies the directory manifest/checksums,
validates both ledger and auth state, stops the service if active, creates a
pre-restore backup, stages replacements in `/var/lib/finwealth`, and validates
the installed files again. A failure after replacement begins rolls both files
back before the service is restarted. If a verified backup says it contains no
auth state, restore removes the current auth file rather than creating a mixed
ledger/auth snapshot. The service is returned to its prior active state
automatically. If the restored files pass validation but the service cannot
return to active state, both pre-restore files are restored and service startup
is retried before the command exits with failure.

`--force` skips only the interactive `RESTORE` prompt; it never bypasses
checksums or semantic validation. Restoring a legacy standalone `ledger.json`
requires explicit `--allow-unverified` and keeps the current auth state. The
emergency environment flags `FINWEALTH_ALLOW_UNVALIDATED_BACKUP=true` and
`FINWEALTH_ALLOW_UNVALIDATED_RESTORE=true` should be used only to preserve or
recover damaged data when the validator is unavailable; such backups record
that validation did not pass.

## 4. Build the Windows server client

Windows:

```powershell
pwsh -NoProfile -File tools\package_remote_windows.ps1 `
  -OutputDir C:\tmp\finwealth-server-client
```

This produces a universal client that asks for the HTTPS API origin on first
launch. Add `-ApiBase https://api.example.com` only when a fixed-origin package
is preferred.

Keep the zip with its `.sha256` sidecar. Extract it and run
`Start-Finwealth.cmd`; the launcher validates package hashes and the public
health endpoint before starting the client. Login is available in Settings and
tokens are protected with Windows DPAPI.

For development without packaging:

```powershell
flutter run -d windows --dart-define=DATA_SOURCE=api_remote --dart-define=API_BASE=https://api.example.com
```

Android:

```powershell
pwsh -NoProfile -File tools\package_remote_android.ps1 `
  -OutputDir C:\tmp\finwealth-android-client
```

The resulting self-use APK is debug-signed and includes SHA-256/provenance
sidecars. On first launch, enter the same HTTPS server origin used by Windows.

Login in Settings with the username/password configured above. The client stores
tokens with Windows DPAPI / Android Keystore.

## Current limitations

- Ledger storage is still JSON, not encrypted SQLite.
- Offline multi-ledger merge is limited to authenticated account/create inbound
  apply. This does not affect online clients sharing the central server ledger.
- No real AI provider is wired.
- Quote/FX calls are best-effort and depend on configured instruments/symbols.
