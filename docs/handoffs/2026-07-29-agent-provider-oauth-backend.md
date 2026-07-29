# Agent provider/OAuth backend

Branch: `feat/agent-provider-oauth`

## Delivered

- Provider-neutral connection API with an initial xAI-only registry.
- Pi-native xAI OAuth device-code login for SuperGrok/X Premium accounts.
- OAuth credentials remain in Pi `auth.json` with `0600` permissions and are
  refreshed by `ModelRuntime`; API responses expose only URL, user code and
  attempt state.
- Disconnect aborts an in-flight login before deleting the stored credential.
- Explicit model resolution: conversation model, otherwise the configured
  `FINWEALTH_AGENT_DEFAULT_MODEL_ID`. Missing or unavailable selection fails;
  the runtime never chooses the first available model or another provider.
- Production migration helper removes the legacy Lore custom provider and key,
  then selects `xai/grok-4.5`. It preserves unrelated environment entries and
  custom providers for later expansion.
- OpenAPI and deployment documentation updated.

## Verification

- TypeScript check and Agent tests, including device-code state, cancellation
  ordering, credential-free HTTP responses, and no-fallback selection.
- Contract checker parses and validates the new paths and schemas.

## Production sequence

1. Deploy the new sidecar build.
2. Run `sudo python3 tools/prepare_vps_xai_oauth.py`.
3. Restart `finwealth-agent`.
4. Start xAI OAuth through the authenticated API and complete browser approval.
5. Run real text, image, finance-tool and USD/CNY smoke with `xai/grok-4.5`.
6. Verify the old Lore provider and key are absent without printing either
   credential.

OAuth cannot be completed unattended because the account owner must approve the
device code in their browser.
