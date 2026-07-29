#!/usr/bin/env python3
"""Prepare production for xAI OAuth without handling or printing credentials."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path

from configure_vps_agent import atomic_write, env_value, environment_without


def update_agent_environment(path: Path, default_model_id: str) -> str:
    retained = environment_without(
        path,
        {"LORE_LLM_API_KEY", "FINWEALTH_AGENT_DEFAULT_MODEL_ID"},
    )
    while retained and not retained[-1].strip():
        retained.pop()
    if retained:
        retained.append("")
    retained.append(
        f"FINWEALTH_AGENT_DEFAULT_MODEL_ID={env_value(default_model_id)}"
    )
    return "\n".join(retained) + "\n"


def remove_legacy_lore_provider(path: Path) -> str:
    if path.exists():
        value = json.loads(path.read_text(encoding="utf-8"))
        if not isinstance(value, dict):
            raise ValueError("invalid Pi models configuration")
    else:
        value = {}
    providers = value.get("providers")
    if providers is None:
        providers = {}
        value["providers"] = providers
    if not isinstance(providers, dict):
        raise ValueError("invalid Pi provider configuration")
    providers.pop("lore", None)
    return json.dumps(value, ensure_ascii=False, indent=2) + "\n"


def main() -> None:
    import pwd

    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--agent-env",
        type=Path,
        default=Path("/etc/finwealth/agent.env"),
    )
    parser.add_argument(
        "--state-dir",
        type=Path,
        default=Path("/var/lib/finwealth-agent"),
    )
    parser.add_argument("--service-user", default="finwealth")
    parser.add_argument("--default-model", default="xai/grok-4.5")
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit("run as root")
    if args.default_model != "xai/grok-4.5":
        raise SystemExit("unsupported production default model")

    account = pwd.getpwnam(args.service_user)
    pi_dir = args.state_dir / "pi"
    pi_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(pi_dir, 0o700)
    os.chown(pi_dir, account.pw_uid, account.pw_gid)
    atomic_write(
        args.agent_env,
        update_agent_environment(args.agent_env, args.default_model),
        0o600,
        0,
        0,
    )
    atomic_write(
        pi_dir / "models.json",
        remove_legacy_lore_provider(pi_dir / "models.json"),
        0o600,
        account.pw_uid,
        account.pw_gid,
    )
    print("Finwealth Agent prepared for xAI OAuth with an explicit Grok model.")


if __name__ == "__main__":
    main()
