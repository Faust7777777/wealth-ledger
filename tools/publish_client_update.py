#!/usr/bin/env python3
"""Atomically publish a verified Finwealth client update on the VPS."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import tempfile
from datetime import datetime, timezone
from pathlib import Path


SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
CHANNEL_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,31}$")


def fail(message: str) -> None:
    raise SystemExit(f"Client update publish failed: {message}")


def load_json(path: Path) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read JSON {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"JSON root must be an object: {path}")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def atomic_write(path: Path, content: bytes, mode: int = 0o644) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp = Path(temp_name)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temp, mode)
        os.replace(temp, path)
    finally:
        temp.unlink(missing_ok=True)


def normalized_notes(args: argparse.Namespace) -> list[str]:
    notes = list(args.note)
    if args.notes_file:
        try:
            notes.extend(args.notes_file.read_text(encoding="utf-8").splitlines())
        except OSError as exc:
            fail(f"cannot read notes file: {exc}")
    notes = [line.strip() for line in notes if line.strip()]
    if len(notes) > 20 or any(len(line) > 240 for line in notes):
        fail("release notes allow at most 20 non-empty lines of 240 characters")
    return notes


def validate_android_provenance(artifact: Path, value: dict) -> tuple[str, int, str, str]:
    required = {
        "packageFormat": 3,
        "sourceDirty": False,
        "dataSource": "api_remote",
        "platform": "android",
        "networkPolicyVerified": True,
    }
    for key, expected in required.items():
        if value.get(key) != expected:
            fail(f"provenance field {key} must be {expected!r}")
    version_name = value.get("versionName")
    version_code = value.get("versionCode")
    source_commit = value.get("sourceCommit")
    expected_hash = value.get("apkSha256")
    expected_size = value.get("apkSizeBytes")
    if not isinstance(version_name, str) or not version_name.strip():
        fail("provenance versionName is missing")
    if not isinstance(version_code, int) or isinstance(version_code, bool) or version_code < 1:
        fail("provenance versionCode must be a positive integer")
    if not isinstance(source_commit, str) or not COMMIT_RE.fullmatch(source_commit):
        fail("provenance sourceCommit must be 40 lowercase hex characters")
    if not isinstance(expected_hash, str) or not SHA256_RE.fullmatch(expected_hash):
        fail("provenance apkSha256 is invalid")
    if value.get("apk") != artifact.name:
        fail("artifact file name does not match provenance")
    actual_size = artifact.stat().st_size
    if expected_size != actual_size:
        fail("artifact size does not match provenance")
    actual_hash = sha256_file(artifact)
    if actual_hash != expected_hash:
        fail("artifact SHA-256 does not match provenance")
    return version_name.strip(), version_code, source_commit, actual_hash


def publish(args: argparse.Namespace) -> Path:
    artifact = args.artifact.resolve(strict=True)
    provenance_path = args.provenance.resolve(strict=True)
    if not artifact.is_file() or artifact.suffix.lower() != ".apk":
        fail("the Android artifact must be a regular .apk file")
    if not CHANNEL_RE.fullmatch(args.channel):
        fail("channel must match ^[a-z0-9][a-z0-9-]{0,31}$")
    provenance = load_json(provenance_path)
    version_name, version_code, source_commit, sha256 = validate_android_provenance(
        artifact, provenance
    )
    if args.minimum_version_code < 1 or args.minimum_version_code > version_code:
        fail("minimum-version-code must be between 1 and the published versionCode")
    notes = normalized_notes(args)

    channel_dir = args.update_dir.resolve() / "android" / args.channel
    release_dir = channel_dir / "releases"
    latest_path = channel_dir / "latest.json"
    if latest_path.exists():
        current = load_json(latest_path)
        current_code = current.get("versionCode")
        if not isinstance(current_code, int):
            fail("existing latest.json has an invalid versionCode")
        if version_code <= current_code:
            fail(
                f"versionCode must increase monotonically: current={current_code}, new={version_code}"
            )

    release_dir.mkdir(parents=True, exist_ok=True)
    os.chmod(args.update_dir.resolve(), 0o755)
    os.chmod((args.update_dir.resolve() / "android"), 0o755)
    os.chmod(channel_dir, 0o755)
    os.chmod(release_dir, 0o755)
    destination = release_dir / artifact.name
    if destination.exists() or destination.with_name(f"{artifact.name}.sha256").exists():
        fail("versioned artifact already exists; refusing overwrite")

    with artifact.open("rb") as source:
        fd, temp_name = tempfile.mkstemp(prefix=f".{artifact.name}.", dir=release_dir)
        temp = Path(temp_name)
        try:
            with os.fdopen(fd, "wb") as target:
                shutil.copyfileobj(source, target, length=1024 * 1024)
                target.flush()
                os.fsync(target.fileno())
            os.chmod(temp, 0o644)
            if sha256_file(temp) != sha256:
                fail("staged artifact SHA-256 changed during copy")
            os.replace(temp, destination)
        finally:
            temp.unlink(missing_ok=True)

    sidecar = release_dir / f"{artifact.name}.sha256"
    atomic_write(sidecar, f"{sha256}  {artifact.name}\n".encode("ascii"))
    manifest = {
        "schemaVersion": 1,
        "platform": "android",
        "channel": args.channel,
        "versionName": version_name,
        "versionCode": version_code,
        "releasedAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
        "sourceCommit": source_commit,
        "mandatory": args.mandatory,
        "minimumVersionCode": args.minimum_version_code,
        "notes": notes,
        "asset": {
            "url": f"/v1/client-updates/android/{args.channel}/assets/{artifact.name}",
            "fileName": artifact.name,
            "sizeBytes": artifact.stat().st_size,
            "sha256": sha256,
            "contentType": "application/vnd.android.package-archive",
        },
    }
    encoded = (json.dumps(manifest, ensure_ascii=False, separators=(",", ":")) + "\n").encode(
        "utf-8"
    )
    atomic_write(latest_path, encoded)
    return latest_path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("artifact", type=Path)
    parser.add_argument("provenance", type=Path)
    parser.add_argument("--update-dir", type=Path, default=Path("/var/lib/finwealth-updates"))
    parser.add_argument("--channel", default="stable")
    parser.add_argument("--minimum-version-code", type=int, default=1)
    parser.add_argument("--mandatory", action="store_true")
    parser.add_argument("--note", action="append", default=[])
    parser.add_argument("--notes-file", type=Path)
    return parser.parse_args()


if __name__ == "__main__":
    published = publish(parse_args())
    print(f"Published client update manifest: {published}")
