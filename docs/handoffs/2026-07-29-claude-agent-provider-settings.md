# Claude task: Agent model connections and Grok OAuth

Backend branch: `feat/agent-provider-oauth`

## Product boundary

Build one compact, provider-neutral settings surface similar in structure to a
small Cherry Studio connection list. Only Grok is available now. Do not add GPT,
do not show a fallback model, and do not claim that a failed model will switch
automatically. Future providers must fit the same view model and repository
methods without redesigning the page.

## API

- `GET /v1/agent/providers`
- `POST /v1/agent/providers/{providerId}/oauth/start`
  - requires an `Idempotency-Key`; a 401 replay must reuse it
  - returns HTTP 202 with `attemptId`, `verificationUri`, `userCode`, `expiresAt`
- `GET /v1/agent/provider-oauth/{attemptId}`
  - poll until `connected`, `failed`, or `cancelled`
- `POST /v1/agent/providers/{providerId}/disconnect`
  - requires an `Idempotency-Key`; a 401 replay must reuse it
- `GET /v1/agent/models`
  - after authorization, contains `xai/grok-4.5`
- existing conversation `PATCH` with `modelId` remains the explicit selector

Full shapes are in `docs/contracts/openapi_v1.yaml`. No endpoint returns access
tokens, refresh tokens, cookies, account passwords, or server file paths.

## Required UI

1. Add an Agent settings row named `模型连接`.
2. Render providers from the API, not a hard-coded list of cards. Current result
   is one compact row: `Grok` and its connection state.
3. For disconnected xAI, action is `连接`.
4. Starting OAuth opens a bottom sheet/dialog containing:
   - the authorization URL as an open/copy action;
   - the short user code with a copy action;
   - expiry countdown;
   - cancel/close.
5. Poll the attempt while the sheet is visible. On `connected`, close it, refresh
   providers and models, then allow `xai/grok-4.5` in the existing model picker.
6. For connected xAI, action is `断开连接`, with one concise confirmation.
7. Failure stays on the Grok row with retry. Never display raw upstream errors,
   OAuth scopes, tokens, provider payloads, or implementation explanations.
8. If the selected Grok model becomes unavailable, show reconnect state. Do not
   choose another available model.

## Tests

- disconnected -> start -> device code -> connected;
- 401 refresh replay uses the same idempotency key;
- failed/expired/cancelled attempts remain distinguishable;
- disconnect removes Grok from selectable models;
- unavailable selected Grok never switches to another provider;
- 360px and desktop layouts have no overflow;
- visible copy contains no token fields, raw provider IDs, or fallback wording.

Do not modify `agent-service/**`, `server-rs/**`, contracts, deploy files, or the
OAuth backend. Return a pushed branch and handoff; integration remains Codex's.
