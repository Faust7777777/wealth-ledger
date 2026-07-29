# Finwealth Agent service

This Node.js 22 sidecar embeds `@earendil-works/pi-coding-agent`. It is not a
public API: the Rust server authenticates App devices, injects the account
principal, and proxies `/v1/agent/**` to this loopback service.

Required environment:

- `FINWEALTH_AGENT_INTERNAL_TOKEN`: shared only with the Rust process;
- `FINWEALTH_SERVER_BASE_URL`: loopback Rust origin, for custom finance tools;
- `FINWEALTH_AGENT_ADDR`: loopback address, default `127.0.0.1:8792`;
- `FINWEALTH_AGENT_STATE_DIR`: conversations, sessions, attachments and workspaces;
- `PI_CODING_AGENT_DIR`: Pi `auth.json` and `models.json` directory.

The token is removed from `process.env` before any Pi session is created.
Finance writes expose only draft plus submit-for-review; there is no confirm or
approve tool. Built-in filesystem tools are replaced with path-checked workspace
tools. Shell is available only on Linux through `bubblewrap`, with the dedicated
workspace mounted and a small environment allow-list.

Development checks:

```bash
npm ci
npm run check
npm test
npm run build
npm audit --omit=dev --audit-level=high
```
