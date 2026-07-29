#!/usr/bin/env python3

import json
import tempfile
import unittest
from pathlib import Path

from prepare_vps_xai_oauth import (
    remove_legacy_lore_provider,
    update_agent_environment,
)


class PrepareVpsXaiOauthTest(unittest.TestCase):
    def test_removes_only_legacy_secret_and_sets_explicit_model(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "agent.env"
            path.write_text(
                'FINWEALTH_AGENT_ADDR="127.0.0.1:8792"\n'
                'LORE_LLM_API_KEY="not-a-real-secret"\n'
                'FUTURE_PROVIDER_SETTING="preserved"\n'
                'FINWEALTH_AGENT_DEFAULT_MODEL_ID="lore/old"\n',
                encoding="utf-8",
            )
            updated = update_agent_environment(path, "xai/grok-4.5")
            self.assertNotIn("LORE_LLM_API_KEY", updated)
            self.assertNotIn("lore/old", updated)
            self.assertIn('FUTURE_PROVIDER_SETTING="preserved"', updated)
            self.assertIn(
                'FINWEALTH_AGENT_DEFAULT_MODEL_ID="xai/grok-4.5"',
                updated,
            )

    def test_removes_lore_but_preserves_future_custom_providers(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "models.json"
            path.write_text(
                json.dumps({
                    "providers": {
                        "lore": {"baseUrl": "https://legacy.invalid"},
                        "future": {"baseUrl": "https://future.invalid"},
                    },
                }),
                encoding="utf-8",
            )
            updated = json.loads(remove_legacy_lore_provider(path))
            self.assertNotIn("lore", updated["providers"])
            self.assertIn("future", updated["providers"])


if __name__ == "__main__":
    unittest.main()
