#!/usr/bin/env python3
"""Smoke-test atomic client update publication without a real APK or VPS."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PUBLISHER = ROOT / "tools" / "publish_client_update.py"


def provenance(artifact: Path, version_code: int) -> dict:
    content = artifact.read_bytes()
    return {
        "packageFormat": 3,
        "clientVersion": f"1.1.{version_code}+{version_code}",
        "versionName": f"1.1.{version_code}",
        "versionCode": version_code,
        "createdAt": "2026-07-28T12:00:00Z",
        "sourceCommit": "0123456789abcdef0123456789abcdef01234567",
        "sourceDirty": False,
        "dataSource": "api_remote",
        "endpointMode": "runtime",
        "apiBase": "",
        "platform": "android",
        "signing": "debug-self-use",
        "networkPolicyVerified": True,
        "apk": artifact.name,
        "apkSizeBytes": len(content),
        "apkSha256": hashlib.sha256(content).hexdigest(),
    }


def windows_provenance(artifact: Path, version_code: int) -> dict:
    content = artifact.read_bytes()
    return {
        "packageFormat": 4,
        "clientVersion": f"1.2.0+{version_code}",
        "versionName": "1.2.0",
        "versionCode": version_code,
        "createdAt": "2026-07-29T12:00:00Z",
        "sourceCommit": "0123456789abcdef0123456789abcdef01234567",
        "sourceDirty": False,
        "dataSource": "api_remote",
        "endpointMode": "runtime",
        "apiBase": "",
        "platform": "windows",
        "networkPolicyVerified": True,
        "archive": artifact.name,
        "archiveSizeBytes": len(content),
        "archiveSha256": hashlib.sha256(content).hexdigest(),
    }


def run(*args: str, expect_ok: bool) -> subprocess.CompletedProcess[str]:
    result = subprocess.run(
        [sys.executable, str(PUBLISHER), *args],
        text=True,
        capture_output=True,
        check=False,
    )
    if (result.returncode == 0) != expect_ok:
        raise AssertionError(f"publisher result unexpected: {result.stdout}\n{result.stderr}")
    return result


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="finwealth-update-publish-") as raw:
        temp = Path(raw)
        updates = temp / "updates"
        artifact_v2 = temp / "finwealth-1.1.0+2-android.apk"
        artifact_v2.write_bytes(b"apk-v2")
        provenance_v2 = temp / "v2.manifest.json"
        provenance_v2.write_text(
            json.dumps(provenance(artifact_v2, 2)), encoding="utf-8"
        )
        run(
            str(artifact_v2),
            str(provenance_v2),
            "--update-dir",
            str(updates),
            "--note",
            "应用内更新",
            expect_ok=True,
        )
        latest_path = updates / "android/stable/latest.json"
        latest = json.loads(latest_path.read_text(encoding="utf-8"))
        assert latest["versionCode"] == 2
        assert latest["notes"] == ["应用内更新"]
        published_android_name = "finwealth-1.1.0-build2-android.apk"
        assert latest["asset"]["fileName"] == published_android_name
        assert "+" not in latest["asset"]["url"]
        release = updates / "android/stable/releases" / published_android_name
        assert release.read_bytes() == b"apk-v2"
        assert hashlib.sha256(release.read_bytes()).hexdigest() == latest["asset"]["sha256"]
        assert (release.with_name(f"{published_android_name}.sha256")).is_file()

        artifact_v1 = temp / "finwealth-1.0.0+1-android.apk"
        artifact_v1.write_bytes(b"apk-v1")
        provenance_v1 = temp / "v1.manifest.json"
        provenance_v1.write_text(
            json.dumps(provenance(artifact_v1, 1)), encoding="utf-8"
        )
        rejected = run(
            str(artifact_v1),
            str(provenance_v1),
            "--update-dir",
            str(updates),
            expect_ok=False,
        )
        assert "monotonically" in rejected.stderr
        assert json.loads(latest_path.read_text(encoding="utf-8"))["versionCode"] == 2

        tampered = temp / "tampered.apk"
        tampered.write_bytes(b"tampered")
        rejected = run(
            str(tampered),
            str(provenance_v2),
            "--update-dir",
            str(updates),
            expect_ok=False,
        )
        assert "file name" in rejected.stderr

        windows = temp / "finwealth-1.2.0+4-windows-x64.zip"
        windows.write_bytes(b"windows-zip-v4")
        windows_manifest = temp / "windows.manifest.json"
        windows_manifest.write_text(
            json.dumps(windows_provenance(windows, 4)), encoding="utf-8"
        )
        run(
            str(windows),
            str(windows_manifest),
            "--update-dir",
            str(updates),
            "--minimum-version-code",
            "3",
            expect_ok=True,
        )
        windows_latest = json.loads(
            (updates / "windows/stable/latest.json").read_text(encoding="utf-8")
        )
        assert windows_latest["platform"] == "windows"
        assert windows_latest["versionCode"] == 4
        assert windows_latest["asset"]["contentType"] == "application/zip"
        assert windows_latest["asset"]["url"].endswith(windows.name)

    print("Client update publish smoke passed.")


if __name__ == "__main__":
    main()
