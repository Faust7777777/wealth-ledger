# Windows server client package

This package is a Finwealth client compiled for one HTTPS server origin. It does
not contain a Rust server or a ledger file.

## Start

1. Keep the zip and its `.sha256` sidecar together.
2. Extract the complete zip into a normal user-writable directory.
3. Run `Start-Finwealth.cmd`.
4. Open Settings and log in with the username and password configured on the VPS.

The launcher verifies the client and build metadata before starting. It also
checks the configured server's public `/v1/health` endpoint. The access and
refresh tokens are stored with Windows DPAPI and are not written into this
package directory.

The server address is fixed at build time and recorded in
`finwealth.build-config.json` and `package-manifest.json`. Rebuild the package
when moving to another domain. Only an HTTPS origin without a path, query,
fragment, or embedded credentials is accepted by the packaging tool.

This remote package must not be confused with the paired Windows self-use
package. The paired package includes a loopback Rust server; this package talks
to a separately deployed VPS server.
