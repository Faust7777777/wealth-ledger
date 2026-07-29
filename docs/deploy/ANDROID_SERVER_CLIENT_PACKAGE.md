# Android server client package

The Android server client uses the same HTTPS Rust API as the Windows client.
The universal APK asks for the server origin on first launch, verifies
`/v1/health`, and stores the origin in app-private preferences. Tokens are
encrypted with an Android Keystore AES-GCM key.

Build a private self-use APK:

```powershell
pwsh -NoProfile -File tools\package_remote_android.ps1 `
  -OutputDir C:\tmp\finwealth-android-client
```

The output includes the APK, a SHA-256 sidecar, and a provenance manifest. The
current package is debug-signed for private installation. Keep the same local
Android debug keystore when building upgrades; packages produced with a
different key cannot update an existing installation.

The main Android manifest permits Internet access, rejects cleartext HTTP, and
disables Android system backup. The app accepts only an HTTPS origin without
credentials, path, query, or fragment. Changing the server clears the previous
server's tokens before activating the new endpoint.

This APK does not contain a ledger. All writes go to the configured VPS and use
the same idempotency and atomic-group rules as the Windows client.
