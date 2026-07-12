# Windows self-use package

The Windows self-use zip is a paired client/server artifact. It is built with:

```text
DATA_SOURCE=local_server
API_BASE=http://127.0.0.1:8791
```

It also contains the matching release `finwealth-server.exe`. Do not launch
`finwealth.exe` directly; double-click `Start-Finwealth.cmd` so the private
loopback server and client have the same lifecycle.

The package command refuses to emit this zip unless the Flutter client contains
tested `Idempotency-Key` handling. Each logical non-auth write must keep one key
across the client's automatic 401 refresh/replay; generating a new key inside
the retry attempt defeats server-side replay protection. Until that frontend
gate passes, no artifact should be described as a writable self-use package.

## First launch

1. Extract the complete zip to a normal user-writable folder.
2. Double-click `Start-Finwealth.cmd`.
3. Choose a local username and password when prompted. The password is sent
   only to the bundled server process to derive an Argon2 hash; plaintext is
   not written to disk.
4. Use the same credentials on the app's login screen.

The launcher keeps user state outside the extracted application directory:

```text
%LOCALAPPDATA%\Finwealth\ledger.json
%LOCALAPPDATA%\Finwealth\ledger.auth.json
%LOCALAPPDATA%\Finwealth\launcher.config.json
```

`launcher.config.json` contains the username and Argon2 password hash, not the
plaintext password. The server binds only to `127.0.0.1:8791`, requires auth,
keeps outbound quote access disabled by default, and is stopped when the app
exits. Server logs are stored in the same `%LOCALAPPDATA%\Finwealth` directory
and must not contain tokens or complete financial values.

To reset local credentials while retaining recoverable copies of the old auth
files:

```powershell
.\Start-Finwealth.ps1 -ResetAuth
```

Back up both `ledger.json` and `ledger.auth.json` before moving machines or
resetting Windows. The repository's `backup_local_ledger.ps1` remains the
validated developer-side backup tool.

## Integrity metadata

`package-manifest.json` records the package mode, API base, bundled server path,
and server SHA-256. `finwealth.build-config.json` records the Flutter compile-
time data source. The launcher validates both files and the server checksum
before starting. These checks detect accidental corruption or mixed build
outputs; they are not a publisher signature and do not establish provenance.

## Android is intentionally separate

This zip does not solve Android storage. The project still needs an explicit
decision between embedding the Rust core through FFI and connecting Android to
an authenticated desktop/VPS server. Until then, Android packaging is available
only as an explicitly named read-only preview and must not be presented as a
writable release.
