#!/usr/bin/env python3
"""Atomically configure the production Pi sidecar without echoing secrets."""

from __future__ import annotations

import argparse
import base64
import json
import os
import pwd
import secrets
import tempfile
from pathlib import Path
from urllib.parse import urlparse


def decode(payload: dict[str, object], name: str) -> str:
    raw = payload.get(name)
    if not isinstance(raw, str):
        raise ValueError(f"missing {name}")
    try:
        value = base64.b64decode(raw, validate=True).decode("utf-8")
    except (ValueError, UnicodeDecodeError) as error:
        raise ValueError(f"invalid {name}") from error
    if not value or "\x00" in value or "\n" in value or "\r" in value:
        raise ValueError(f"invalid {name}")
    return value


def env_value(value: str) -> str:
    return json.dumps(value, ensure_ascii=False)


def atomic_write(
    path: Path,
    content: str,
    mode: int,
    uid: int,
    gid: int,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temporary_path = Path(temporary)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary_path, mode)
        os.chown(temporary_path, uid, gid)
        os.replace(temporary_path, path)
        directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary_path.unlink(missing_ok=True)


def updated_environment(path: Path, replacements: dict[str, str]) -> str:
    retained: list[str] = []
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            key = line.split("=", 1)[0].strip() if "=" in line else ""
            if key not in replacements:
                retained.append(line)
    while retained and not retained[-1].strip():
        retained.pop()
    if retained:
        retained.append("")
    retained.extend(f"{key}={env_value(value)}" for key, value in replacements.items())
    return "\n".join(retained) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("secrets_file", type=Path)
    parser.add_argument("--server-env", type=Path, default=Path("/etc/finwealth/server.env"))
    parser.add_argument("--agent-env", type=Path, default=Path("/etc/finwealth/agent.env"))
    parser.add_argument("--state-dir", type=Path, default=Path("/var/lib/finwealth-agent"))
    parser.add_argument("--service-user", default="finwealth")
    args = parser.parse_args()
    if os.geteuid() != 0:
        raise SystemExit("run as root")

    try:
        payload = json.loads(args.secrets_file.read_text(encoding="utf-8"))
        if not isinstance(payload, dict):
            raise ValueError("invalid secrets payload")
        api_key = decode(payload, "apiKey")
        base_url = decode(payload, "baseUrl").rstrip("/")
        model_id = decode(payload, "model")
        parsed = urlparse(base_url)
        if parsed.scheme != "https" or not parsed.hostname:
            raise ValueError("model base URL must be public HTTPS")

        account = pwd.getpwnam(args.service_user)
        token = secrets.token_hex(32)
        agent_environment = updated_environment(
            args.agent_env,
            {
                "FINWEALTH_AGENT_ADDR": "127.0.0.1:8792",
                "FINWEALTH_AGENT_INTERNAL_TOKEN": token,
                "FINWEALTH_SERVER_BASE_URL": "http://127.0.0.1:8790",
                "FINWEALTH_AGENT_STATE_DIR": str(args.state_dir),
                "PI_CODING_AGENT_DIR": str(args.state_dir / "pi"),
                "LORE_LLM_API_KEY": api_key,
            },
        )
        server_environment = updated_environment(
            args.server_env,
            {
                "FINWEALTH_AGENT_BASE_URL": "http://127.0.0.1:8792",
                "FINWEALTH_AGENT_INTERNAL_TOKEN": token,
            },
        )
        models = {
            "providers": {
                "lore": {
                    "baseUrl": base_url,
                    "api": "openai-completions",
                    "apiKey": "$LORE_LLM_API_KEY",
                    "authHeader": True,
                    "compat": {
                        "supportsDeveloperRole": False,
                        "supportsReasoningEffort": False,
                    },
                    "models": [
                        {
                            "id": model_id,
                            "name": "LORE",
                            "input": ["text", "image"],
                            "contextWindow": 128000,
                            "maxTokens": 4096,
                        }
                    ],
                }
            }
        }

        args.state_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(args.state_dir, 0o700)
        os.chown(args.state_dir, account.pw_uid, account.pw_gid)
        pi_dir = args.state_dir / "pi"
        pi_dir.mkdir(parents=True, exist_ok=True)
        os.chmod(pi_dir, 0o700)
        os.chown(pi_dir, account.pw_uid, account.pw_gid)
        atomic_write(args.agent_env, agent_environment, 0o600, 0, 0)
        atomic_write(args.server_env, server_environment, 0o600, 0, 0)
        atomic_write(
            pi_dir / "models.json",
            json.dumps(models, ensure_ascii=False, indent=2) + "\n",
            0o600,
            account.pw_uid,
            account.pw_gid,
        )
    finally:
        args.secrets_file.unlink(missing_ok=True)

    print("Finwealth Agent model and internal authentication configured.")


if __name__ == "__main__":
    main()
