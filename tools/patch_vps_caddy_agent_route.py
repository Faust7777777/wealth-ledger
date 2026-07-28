#!/usr/bin/env python3
"""Atomically add the Finwealth Agent path to an existing shared Caddyfile."""

from __future__ import annotations

import argparse
import os
import shutil
import stat
import subprocess
import tempfile
from datetime import datetime, timezone
from pathlib import Path


ROUTE = "/v1/agent/*"


def run_caddy(container: str, command: str) -> None:
    subprocess.run(
        ["docker", "exec", container, "caddy", command, "--config", "/etc/caddy/Caddyfile"],
        check=True,
        stdout=subprocess.DEVNULL,
    )


def write_atomic(path: Path, content: str, mode: int, uid: int, gid: int) -> None:
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        newline="",
        dir=path.parent,
        prefix=f".{path.name}.",
        delete=False,
    ) as handle:
        temporary = Path(handle.name)
        handle.write(content)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(temporary, mode)
    os.chown(temporary, uid, gid)
    os.replace(temporary, path)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--caddyfile",
        type=Path,
        default=Path("/home/opc/sub2api-deploy/Caddyfile"),
    )
    parser.add_argument("--container", default="sub2api-caddy")
    args = parser.parse_args()

    path = args.caddyfile.resolve()
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or path.is_symlink():
        raise RuntimeError("Caddyfile must be a regular non-symlink file")
    original = path.read_text(encoding="utf-8")
    if original.count("wuwaidut.com {") != 1 or original.count("@finwealth {") != 1:
        raise RuntimeError("shared Caddyfile does not have one expected Finwealth matcher")
    start = original.index("@finwealth {")
    end = original.find("\n\t}", start)
    if end < 0:
        raise RuntimeError("Finwealth matcher block is incomplete")
    block = original[start:end]
    if "/v1/health" not in block or "path /v1/accounts" not in block:
        raise RuntimeError("Finwealth matcher is missing its expected anchor paths")
    if ROUTE in block:
        run_caddy(args.container, "validate")
        print("OK: shared Caddyfile already routes the Finwealth Agent API.")
        return

    updated_block = block.replace(
        "path /v1/accounts",
        f"path /v1/accounts {ROUTE}",
        1,
    )
    updated = original[:start] + updated_block + original[end:]
    timestamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = path.with_name(f"{path.name}.before-finwealth-agent-{timestamp}")
    shutil.copy2(path, backup)
    mode = stat.S_IMODE(metadata.st_mode)
    try:
        write_atomic(path, updated, mode, metadata.st_uid, metadata.st_gid)
        run_caddy(args.container, "validate")
        run_caddy(args.container, "reload")
    except Exception:
        write_atomic(
            path,
            backup.read_text(encoding="utf-8"),
            mode,
            metadata.st_uid,
            metadata.st_gid,
        )
        run_caddy(args.container, "validate")
        run_caddy(args.container, "reload")
        raise
    print(f"OK: added {ROUTE}; backup={backup}")


if __name__ == "__main__":
    main()
