"""Production-topology smoke for the private VPS mode.

Runs a real persistent Rust server behind a local TLS reverse proxy. It verifies
Host filtering, required auth, idempotent writes, subscription confirmation,
process restart persistence, refresh-token rotation, and ledger/auth validators.
Only temporary test data and a one-day test CA are used.
"""

from __future__ import annotations

import http.client
import json
import os
import shutil
import socket
import ssl
import subprocess
import sys
import tempfile
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "server-rs" / "Cargo.toml"
TEST_HOST = "api.finwealth.test"
TEST_USERNAME = "production-smoke-user"
TEST_PASSWORD = "production-smoke-password-not-a-secret"


def free_port() -> int:
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])


def cargo_path() -> str:
    cargo = shutil.which("cargo")
    if cargo:
        return cargo
    fallback = Path.home() / ".cargo" / "bin" / ("cargo.exe" if os.name == "nt" else "cargo")
    if fallback.exists():
        return str(fallback)
    raise RuntimeError("cargo not found")


def server_binary() -> Path:
    subprocess.run(
        [cargo_path(), "build", "--quiet", "--manifest-path", str(MANIFEST)],
        cwd=ROOT,
        check=True,
    )
    suffix = ".exe" if os.name == "nt" else ""
    binary = ROOT / "server-rs" / "target" / "debug" / f"finwealth-server{suffix}"
    if not binary.is_file():
        raise RuntimeError(f"server binary missing after build: {binary}")
    return binary


def password_hash(binary: Path) -> str:
    result = subprocess.run(
        [str(binary), "--hash-password-stdin"],
        input=TEST_PASSWORD + "\n",
        text=True,
        capture_output=True,
        check=True,
    )
    value = next((line for line in result.stdout.splitlines() if line.startswith("$argon2")), "")
    if not value:
        raise RuntimeError("server did not produce an Argon2 hash")
    return value


def production_env(port: int, password_hash_value: str) -> dict[str, str]:
    env = os.environ.copy()
    env.update(
        {
            "FINWEALTH_REQUIRE_AUTH": "true",
            "FINWEALTH_AUTH_USERNAME": TEST_USERNAME,
            "FINWEALTH_AUTH_PASSWORD_HASH": password_hash_value,
            "FINWEALTH_RS_ADDR": f"127.0.0.1:{port}",
            "FINWEALTH_ALLOWED_HOSTS": TEST_HOST,
            "FINWEALTH_QUOTE_PROVIDER": "none",
        }
    )
    for unsafe in ("FINWEALTH_AUTH_PASSWORD", "FINWEALTH_ALLOW_LEDGER_SCENARIO"):
        env.pop(unsafe, None)
    return env


class RustServer:
    def __init__(self, binary: Path, ledger: Path, port: int, env: dict[str, str]) -> None:
        self.binary = binary
        self.ledger = ledger
        self.port = port
        self.env = env
        self.process: subprocess.Popen[str] | None = None

    def start(self) -> None:
        if self.process is not None:
            raise RuntimeError("server already started")
        self.process = subprocess.Popen(
            [
                str(self.binary),
                "--addr",
                f"127.0.0.1:{self.port}",
                "--ledger-path",
                str(self.ledger),
            ],
            cwd=ROOT,
            env=self.env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
        )
        last_error: Exception | None = None
        for _ in range(80):
            if self.process.poll() is not None:
                output = self.process.stdout.read() if self.process.stdout else ""
                raise RuntimeError(f"Rust server exited early ({self.process.returncode}): {output}")
            try:
                status, payload, _ = direct_request(self.port, "/v1/health")
                if status == 200 and payload.get("ok") is True:
                    return
            except Exception as error:  # pragma: no cover - timing dependent
                last_error = error
            time.sleep(0.1)
        self.stop()
        raise RuntimeError(f"Rust server did not become ready: {last_error}")

    def stop(self) -> None:
        process, self.process = self.process, None
        if process is None:
            return
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def direct_request(
    port: int,
    path: str,
    *,
    host: str = "127.0.0.1",
) -> tuple[int, dict[str, Any], dict[str, str]]:
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=3)
    try:
        connection.request("GET", path, headers={"Host": host, "Connection": "close"})
        response = connection.getresponse()
        raw = response.read()
        return response.status, decode_json(raw), {key.lower(): value for key, value in response.headers.items()}
    finally:
        connection.close()


class ProxyHandler(BaseHTTPRequestHandler):
    backend_port = 0
    protocol_version = "HTTP/1.1"

    def do_GET(self) -> None:  # noqa: N802
        self._proxy()

    def do_POST(self) -> None:  # noqa: N802
        self._proxy()

    def do_PATCH(self) -> None:  # noqa: N802
        self._proxy()

    def _proxy(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length else None
        headers = {
            key: value
            for key, value in self.headers.items()
            if key.lower() not in {"connection", "content-length"}
        }
        headers["Host"] = self.headers.get("Host", TEST_HOST)
        headers["Connection"] = "close"
        backend = http.client.HTTPConnection("127.0.0.1", self.backend_port, timeout=10)
        try:
            backend.request(self.command, self.path, body=body, headers=headers)
            response = backend.getresponse()
            payload = response.read()
            self.send_response(response.status)
            for key, value in response.headers.items():
                if key.lower() in {"content-type", "idempotency-replayed"}:
                    self.send_header(key, value)
            self.send_header("Content-Length", str(len(payload)))
            self.send_header("Connection", "close")
            self.end_headers()
            self.wfile.write(payload)
        finally:
            backend.close()
            self.close_connection = True

    def log_message(self, _format: str, *_args: object) -> None:
        return


class TlsProxy:
    def __init__(self, backend_port: int, cert: Path, key: Path) -> None:
        handler = type("BoundProxyHandler", (ProxyHandler,), {"backend_port": backend_port})
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.minimum_version = ssl.TLSVersion.TLSv1_2
        context.load_cert_chain(certfile=cert, keyfile=key)
        self.server.socket = context.wrap_socket(self.server.socket, server_side=True)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    @property
    def port(self) -> int:
        return int(self.server.server_address[1])

    def start(self) -> None:
        self.thread.start()

    def stop(self) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)


def create_test_certificate(directory: Path) -> tuple[Path, Path]:
    openssl = shutil.which("openssl")
    if not openssl:
        raise RuntimeError("openssl not found")
    cert = directory / "tls-cert.pem"
    key = directory / "tls-key.pem"
    config = directory / "openssl.cnf"
    config.write_text(
        "\n".join(
            [
                "[req]",
                "distinguished_name = dn",
                "x509_extensions = extensions",
                "prompt = no",
                "[dn]",
                f"CN = {TEST_HOST}",
                "[extensions]",
                f"subjectAltName = DNS:{TEST_HOST}",
                "keyUsage = critical,digitalSignature,keyEncipherment",
                "extendedKeyUsage = serverAuth",
            ]
        ),
        encoding="utf-8",
    )
    subprocess.run(
        [
            openssl,
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "1",
            "-keyout",
            str(key),
            "-out",
            str(cert),
            "-config",
            str(config),
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    return cert, key


def decode_json(raw: bytes) -> dict[str, Any]:
    return {} if not raw else json.loads(raw.decode("utf-8"))


def tls_request(
    proxy_port: int,
    cert: Path,
    path: str,
    *,
    method: str = "GET",
    body: dict[str, Any] | None = None,
    token: str | None = None,
    idempotency_key: str | None = None,
    expected_status: int = 200,
) -> tuple[dict[str, Any], dict[str, str]]:
    encoded = None if body is None else json.dumps(body).encode("utf-8")
    headers = {
        "Host": TEST_HOST,
        "Connection": "close",
        "Accept": "application/json",
    }
    if encoded is not None:
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = str(len(encoded))
    if token:
        headers["Authorization"] = f"Bearer {token}"
    if method in {"POST", "PATCH", "PUT", "DELETE"} and not path.startswith("/v1/auth/"):
        headers["Idempotency-Key"] = idempotency_key or f"production-smoke-{uuid.uuid4()}"
    request_head = f"{method} {path} HTTP/1.1\r\n" + "".join(
        f"{key}: {value}\r\n" for key, value in headers.items()
    ) + "\r\n"
    context = ssl.create_default_context(cafile=str(cert))
    with socket.create_connection(("127.0.0.1", proxy_port), timeout=5) as raw_socket:
        with context.wrap_socket(raw_socket, server_hostname=TEST_HOST) as tls_socket:
            tls_socket.sendall(request_head.encode("ascii") + (encoded or b""))
            response = http.client.HTTPResponse(tls_socket)
            response.begin()
            payload = response.read()
            status = response.status
            response_headers = {
                key.lower(): value for key, value in response.headers.items()
            }
    if status != expected_status:
        raise AssertionError(
            f"{method} {path}: expected {expected_status}, got {status}: {payload.decode('utf-8', errors='replace')}"
        )
    return decode_json(payload), response_headers


def data(payload: dict[str, Any]) -> Any:
    if payload.get("ok") is not True:
        raise AssertionError(payload)
    return payload["data"]


def run() -> None:
    binary = server_binary()
    with tempfile.TemporaryDirectory(prefix="finwealth-production-topology-") as temporary:
        root = Path(temporary)
        ledger = root / "ledger.json"
        auth = root / "ledger.auth.json"
        cert, key = create_test_certificate(root)
        backend_port = free_port()
        password_hash_value = password_hash(binary)
        env = production_env(backend_port, password_hash_value)

        subprocess.run(
            [str(binary), "--check-production-config"],
            cwd=ROOT,
            env=env,
            stdout=subprocess.DEVNULL,
            check=True,
        )

        rust = RustServer(binary, ledger, backend_port, env)
        rust.start()
        proxy = TlsProxy(backend_port, cert, key)
        proxy.start()
        try:
            bad_host_status, bad_host, _ = direct_request(
                backend_port, "/v1/health", host="attacker.invalid"
            )
            assert bad_host_status == 403
            assert bad_host["error"]["code"] == "host_header_forbidden"

            health, _ = tls_request(proxy.port, cert, "/v1/health")
            assert data(health)["status"] == "ok"
            unauthenticated, _ = tls_request(
                proxy.port, cert, "/v1/accounts", expected_status=401
            )
            assert unauthenticated["error"]["code"] == "auth_required"
            wrong, _ = tls_request(
                proxy.port,
                cert,
                "/v1/auth/login",
                method="POST",
                body={
                    "username": TEST_USERNAME,
                    "password": "wrong-password",
                    "deviceName": "production smoke",
                },
                expected_status=401,
            )
            assert wrong["error"]["code"] == "invalid_credentials"
            login, _ = tls_request(
                proxy.port,
                cert,
                "/v1/auth/login",
                method="POST",
                body={
                    "username": TEST_USERNAME,
                    "password": TEST_PASSWORD,
                    "deviceName": "production smoke",
                },
            )
            session = data(login)
            access = session["accessToken"]
            refresh = session["refreshToken"]

            account_key = "production-topology-account"
            account_payload = {
                "displayName": "Production topology cash",
                "institutionName": "smoke",
                "accountType": "bank",
                "defaultCurrency": "CNY",
                "supportedCurrencies": ["CNY"],
                "includeInNetWorth": True,
                "balanceMode": "cash_balance",
                "openingBalances": [
                    {"currency": "CNY", "amount": "100.00", "quality": "exact"}
                ],
            }
            created, headers = tls_request(
                proxy.port,
                cert,
                "/v1/accounts",
                method="POST",
                body=account_payload,
                token=access,
                idempotency_key=account_key,
                expected_status=201,
            )
            assert "idempotency-replayed" not in headers
            account = data(created)
            replay, replay_headers = tls_request(
                proxy.port,
                cert,
                "/v1/accounts",
                method="POST",
                body=account_payload,
                token=access,
                idempotency_key=account_key,
                expected_status=201,
            )
            assert data(replay) == account
            assert replay_headers.get("idempotency-replayed") == "true"

            subscription, _ = tls_request(
                proxy.port,
                cert,
                "/v1/subscriptions",
                method="POST",
                token=access,
                body={
                    "displayName": "ChatGPT Plus",
                    "provider": "OpenAI",
                    "planName": "Plus",
                    "amount": {"amount": "10.00", "currency": "CNY"},
                    "paymentAccountId": account["id"],
                    "billingCycle": {"unit": "month", "interval": 1},
                    "startDate": "2026-01-31",
                    "duration": {"unit": "month", "count": 3},
                    "autoRenew": False,
                    "reminderDaysBefore": 3,
                },
                expected_status=201,
            )
            subscription = data(subscription)
            scan, _ = tls_request(
                proxy.port,
                cert,
                "/v1/subscriptions/charge-proposals/due-scan",
                method="POST",
                token=access,
                body={"throughDate": "2026-01-31", "limit": 100},
            )
            scan = data(scan)
            assert scan["createdCount"] == 1
            group = scan["created"][0]
            before, _ = tls_request(
                proxy.port, cert, f"/v1/accounts/{account['id']}", token=access
            )
            assert data(before)["cashBalances"][0]["amount"] == "100.00"
            confirmation, _ = tls_request(
                proxy.port,
                cert,
                f"/v1/atomic-groups/{group['id']}/confirm",
                method="POST",
                token=access,
            )
            assert data(confirmation)["ledgerWrite"] is True
            after, _ = tls_request(
                proxy.port, cert, f"/v1/accounts/{account['id']}", token=access
            )
            assert data(after)["cashBalances"][0]["amount"] == "90.00"
            charged, _ = tls_request(
                proxy.port,
                cert,
                f"/v1/subscriptions/{subscription['id']}",
                token=access,
            )
            charged = data(charged)
            assert charged["lastChargeDate"] == "2026-01-31"
            assert charged["nextChargeDate"] == "2026-02-28"

            rust.stop()
            subprocess.run(
                [str(binary), "--validate-ledger", str(ledger)],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                check=True,
            )
            subprocess.run(
                [str(binary), "--validate-auth-state", str(auth)],
                cwd=ROOT,
                stdout=subprocess.DEVNULL,
                check=True,
            )
            rust.start()

            refreshed, _ = tls_request(
                proxy.port,
                cert,
                "/v1/auth/refresh",
                method="POST",
                body={"refreshToken": refresh},
            )
            refreshed = data(refreshed)
            old_access, _ = tls_request(
                proxy.port,
                cert,
                "/v1/accounts",
                token=access,
                expected_status=401,
            )
            assert old_access["error"]["code"] == "auth_required"
            accounts, _ = tls_request(
                proxy.port,
                cert,
                "/v1/accounts",
                token=refreshed["accessToken"],
            )
            persisted = data(accounts)
            assert len(persisted) == 1
            assert persisted[0]["cashBalances"][0]["amount"] == "90.00"
        finally:
            proxy.stop()
            rust.stop()

    print("OK: production TLS/auth/persistence topology smoke passed")


if __name__ == "__main__":
    try:
        run()
    except Exception as error:
        print(f"FAIL: production topology smoke: {error}", file=sys.stderr)
        raise
