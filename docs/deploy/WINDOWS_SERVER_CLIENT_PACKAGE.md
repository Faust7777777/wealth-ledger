# Windows server client package

This package is a Finwealth client for an HTTPS VPS. It does not contain a Rust
server or a ledger file. The default universal package asks for the server
origin on first launch; a fixed-origin package can still be built with
`-ApiBase https://api.example.com`.

## Start

1. Keep the zip and its `.sha256` sidecar together.
2. Extract the complete zip into a normal user-writable directory.
3. Run `Start-Finwealth.cmd`.
4. On first launch, enter the HTTPS server origin and pass the health check.
5. Open Settings and log in with the username and password configured on the VPS.

The launcher verifies the client and build metadata before starting. A
fixed-origin package also checks `/v1/health`; a universal package performs the
health check inside the app before saving the origin. Access and refresh tokens
are stored with Windows DPAPI and are not written into this package directory.

Runtime server configuration is stored in `%APPDATA%\Finwealth\server.json` and
contains no credentials. Only an HTTPS origin without a path, query, fragment,
or embedded credentials is accepted. Changing the server clears the old auth
tokens before the new endpoint becomes active.

This remote package must not be confused with the paired Windows self-use
package. The paired package includes a loopback Rust server; this package talks
to a separately deployed VPS server.

## Online updates

The first package containing the Windows updater must be extracted manually.
After that, Settings can check and download a newer Windows stable ZIP from the
same HTTPS origin. The client streams the ZIP into
`%LOCALAPPDATA%\Finwealth\updates`, verifies its exact size and SHA-256, then
starts `Finwealth-Updater.ps1` from that controlled cache and exits.

The helper independently verifies the archive hash, rejects absolute and
traversing ZIP entries, runs the packaged integrity check, waits for the old App
to exit, and replaces the install directory. A failed replacement restores the
old directory. The preceding package is retained beside the install directory
as `.finwealth-previous` until the next successful update, providing one local
rollback copy without accumulating every historical release.

Tokens and the saved server origin remain under `%APPDATA%\Finwealth`; neither
the replacement nor rollback touches them. Keep the extracted package in a
normal user-writable directory rather than `Program Files`, because the updater
does not request administrator privileges.
