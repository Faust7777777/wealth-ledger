# Finwealth self-hosted client updates

Finwealth serves update manifests and versioned APK/ZIP files through the existing Rust service and `wuwaidut.com`. No update file is stored in the ledger, Agent workspace, Caddy container, or Git repository.

## Server layout

```text
/var/lib/finwealth-updates/
  android/stable/
    latest.json
    releases/
      finwealth-...apk
      finwealth-...apk.sha256
```

The directory is root-owned and mode `0755`; artifacts are mode `0644`. The systemd service has read-only access. `FINWEALTH_CLIENT_UPDATE_DIR` points the Rust server at this root.

Public endpoints:

```text
https://wuwaidut.com/v1/client-updates/android/stable/latest
https://wuwaidut.com/v1/client-updates/android/stable/assets/<versioned.apk>
```

They intentionally work without bearer auth so an expired or not-yet-authenticated App can update. They contain no account data or credentials.

## Build an Android update

Before building, increase the build number after `+` in `pubspec.yaml`; Android compares this `versionCode`, not the visible version name. A published channel rejects equal or lower values.

```powershell
pwsh -NoProfile -File tools\package_remote_android.ps1 -OutputDir dist
```

The command emits the APK, SHA-256 sidecar, and `.manifest.json`. The provenance manifest now includes `versionName`, `versionCode`, `apkSizeBytes`, clean source commit and APK hash.

## Publish on the VPS

Copy only the APK and matching provenance manifest to a temporary VPS directory. Then, as root:

```bash
/opt/finwealth/tools/publish_client_update.py \
  /tmp/finwealth-update/finwealth-1.1.0+2-android-server-client-debug.apk \
  /tmp/finwealth-update/finwealth-1.1.0+2-android-server-client-debug.apk.manifest.json \
  --channel stable \
  --minimum-version-code 1 \
  --note '加入应用内更新'
```

The publisher verifies clean provenance, exact filename, size and SHA-256; stages the immutable APK and sidecar; rejects overwrite/downgrade; and atomically replaces `latest.json` last. It never reads the APK contents as configuration and never writes the ledger.

Do not use `--mandatory` for ordinary releases. It only changes client presentation and does not bypass Android installation confirmation.

## Shared Caddy route

The repository template includes `/v1/client-updates/*` in the existing root-domain `@finwealth` matcher. On the current shared Caddy deployment, apply the narrow atomic patch:

```bash
sudo python3 /opt/finwealth/tools/patch_vps_caddy_client_update_route.py
```

The script validates the candidate inside the running Caddy container, backs up the host Caddyfile, restarts the container so its single-file bind mount refreshes, confirms the route is loaded, and restores the backup on failure. It does not change `sub2api.wuwaidut.com`, `/v1/models`, Cloudflare Access, or the relay container upstream.

## Verify

```bash
curl -fsS https://wuwaidut.com/v1/client-updates/android/stable/latest
curl -fsSI https://wuwaidut.com/v1/client-updates/android/stable/assets/<versioned.apk>
sudo bash /opt/finwealth/tools/check_vps_readiness.sh \
  --public-base-url https://wuwaidut.com
```

Expected asset headers include the APK content type, exact `Content-Length`, SHA-256 `ETag`, `nosniff`, and immutable cache policy.

## Rollback

Publishing is fail-safe: until the final atomic manifest rename, clients continue seeing the previous release. Android does not accept a lower `versionCode`. To roll back application behavior, rebuild the previous source with a new, higher build number and publish it as another release. Never overwrite an existing versioned artifact.

Old versioned files are retained so a client that fetched the preceding manifest can finish its download while a newer release is being published.
