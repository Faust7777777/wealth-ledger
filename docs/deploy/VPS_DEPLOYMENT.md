# VPS deployment draft

Target: a small Linux VPS, including Oracle ARM. The Rust server stays
loopback-only (`127.0.0.1`) and should be exposed through a reverse proxy such as
Caddy or Nginx.

This is enough for private self-use testing. It is not yet a hardened production
sync service.

## 1. Build and install systemd service

On the VPS:

```bash
git clone https://github.com/Faust7777777/wealth-ledger.git
cd wealth-ledger
sudo bash tools/install_vps_systemd.sh
```

The script:

- builds `server-rs` in release mode;
- installs `/opt/finwealth/finwealth-server`;
- creates system user `finwealth`;
- creates `/var/lib/finwealth` for `ledger.json` and `ledger.auth.json`;
- installs `/etc/systemd/system/finwealth-server.service`;
- creates `/etc/finwealth/server.env` if missing.

If `/etc/finwealth/server.env` still contains `change-me`, the script installs
files but intentionally does not start the service.

## 2. Configure auth

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
FINWEALTH_QUOTE_PROVIDER=yahoo
```

Do not put plaintext passwords in this file.

Then start:

```bash
sudo systemctl enable --now finwealth-server.service
sudo systemctl status finwealth-server.service --no-pager
```

Health check from the VPS:

```bash
curl http://127.0.0.1:8790/v1/health
```

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

## 4. Run Flutter against the VPS

Windows:

```powershell
flutter run -d windows --dart-define=DATA_SOURCE=local_server --dart-define=API_BASE=https://api.example.com
```

Android:

```powershell
flutter run -d <device-id> --dart-define=DATA_SOURCE=local_server --dart-define=API_BASE=https://api.example.com
```

Login in Settings with the username/password configured above. The client stores
tokens with Windows DPAPI / Android Keystore.

## Current limitations

- Ledger storage is still JSON, not encrypted SQLite.
- Sync merge endpoints are bootstrap-only and do not merge remote changes yet.
- No real AI provider is wired.
- Quote/FX calls are best-effort and depend on configured instruments/symbols.
