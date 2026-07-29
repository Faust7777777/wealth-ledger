# Windows self-update delivery — 2026-07-29

## Delivery

- Implementation branch: `feat/windows-self-update` at `57bf076`.
- Online release branch: `release/windows-1.2.0-5` at `a71b325`.
- Install baseline: Windows `1.2.0+4`, source commit `57bf076`.
- Stable online update: Windows `1.2.0+5`, source commit `c74fea3`.
- The `+4` ZIP, SHA-256 sidecar, and provenance manifest are on the user's Desktop.

## Update behavior

- The app reads the installed Windows build number from `finwealth.build-config.json`.
- Update checks use the public, unauthenticated Windows stable endpoint and do not affect the ledger session.
- ZIP downloads stream to `%LOCALAPPDATA%\Finwealth\updates` and must match both declared size and SHA-256.
- A separate PowerShell helper rechecks the archive, blocks ZIP path traversal, runs packaged integrity verification, waits for the old process to exit, replaces the program directory, restores on failure, retains one `.finwealth-previous`, and relaunches the app.
- Tokens and the configured server origin remain under `%APPDATA%\Finwealth`; program replacement does not overwrite them.

## Verification

- Flutter format and analyze passed.
- Flutter full suite passed: 355 passed, 73 skipped, 0 failed.
- Contract check, publisher smoke, ledger smoke, Agent smoke, and Windows package readiness passed.
- The updater helper passed real directory replacement and ZIP traversal rejection smokes.
- A real packaged `1.2.0+4 -> 1.2.0+5` replacement passed in an isolated directory: the installed build became `+5`, `.finwealth-previous` retained `+4`, and both packages passed integrity verification.
- The public `+5` ZIP was downloaded in full from `wuwaidut.com`: 18,853,396 bytes, SHA-256 `4432c7f330db0a9671820a5f87e343c0683a4521e965aa71563521c1c6868d74`.

## Published assets

- VPS stable manifest: `/v1/client-updates/windows/stable/latest`, `versionCode=5`, `minimumVersionCode=4`.
- GitHub `windows-v1.2.0+4`: prerelease with ZIP, SHA sidecar, and provenance manifest.
- GitHub `windows-v1.2.0+5`: non-latest archive with the same three assets.
- Repository-wide GitHub Latest remains Android `1.1.0+3`.
- Desktop `+4` ZIP SHA-256: `1cf24d586eb5763861206d596917de7369689d6337e8fcbf441c18c1f3884eec`.

## Related compatibility correction

Android stable `+3` was republished under a wire filename without `+`, while retaining identical APK bytes and SHA-256. Publisher commit `a71b325` now maps Android build-name `+` to `-build`, preserving compatibility with previously installed Android parsers.

No password, token, API key, private key, ledger content, or model endpoint is included in this handoff.
