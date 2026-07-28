#!/usr/bin/env python3
"""Real-model PDF/XLSX workspace smoke for an installed Linux sidecar."""

from __future__ import annotations

import json
import os
import secrets
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path


BASE = "http://127.0.0.1:8792/v1/agent"
TIMEOUT_SECONDS = 600


def headers(*, idempotency_key: str | None = None) -> dict[str, str]:
    token = os.environ.get("FINWEALTH_AGENT_INTERNAL_TOKEN")
    if not token:
        raise RuntimeError("FINWEALTH_AGENT_INTERNAL_TOKEN is required")
    result = {
        "x-finwealth-internal-token": token,
        "x-finwealth-user-id": "usr_owner",
        "x-finwealth-ledger-id": "ledger_default",
        "x-finwealth-device-id": "vps_document_smoke",
    }
    if idempotency_key:
        result["idempotency-key"] = idempotency_key
    return result


def request(
    method: str,
    path: str,
    *,
    body: object | None = None,
    idempotency_key: str | None = None,
    content_type: str = "application/json",
    raw_body: bytes | None = None,
) -> object:
    data = raw_body
    if data is None and body is not None:
        data = json.dumps(body, ensure_ascii=False).encode("utf-8")
    request_headers = headers(idempotency_key=idempotency_key)
    if data is not None:
        request_headers["content-type"] = content_type
    with urllib.request.urlopen(
        urllib.request.Request(
            f"{BASE}{path}",
            data=data,
            headers=request_headers,
            method=method,
        ),
        timeout=30,
    ) as response:
        return json.loads(response.read().decode("utf-8"))["data"]


def pdf_bytes(marker: str) -> bytes:
    stream = f"BT /F1 24 Tf 72 720 Td ({marker}) Tj ET".encode("ascii")
    objects = [
        b"<< /Type /Catalog /Pages 2 0 R >>",
        b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>",
        b"<< /Length " + str(len(stream)).encode("ascii") + b" >>\nstream\n" + stream + b"\nendstream",
        b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    ]
    output = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
    offsets = [0]
    for index, value in enumerate(objects, start=1):
        offsets.append(len(output))
        output.extend(f"{index} 0 obj\n".encode("ascii"))
        output.extend(value)
        output.extend(b"\nendobj\n")
    xref = len(output)
    output.extend(f"xref\n0 {len(objects) + 1}\n".encode("ascii"))
    output.extend(b"0000000000 65535 f \n")
    for offset in offsets[1:]:
        output.extend(f"{offset:010d} 00000 n \n".encode("ascii"))
    output.extend(
        f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode(
            "ascii"
        )
    )
    return bytes(output)


def write_xlsx(path: Path, marker: str) -> None:
    files = {
        "[Content_Types].xml": """<?xml version="1.0" encoding="UTF-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
  <Default Extension="xml" ContentType="application/xml"/>
  <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
  <Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/>
</Types>""",
        "_rels/.rels": """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
</Relationships>""",
        "xl/workbook.xml": """<?xml version="1.0" encoding="UTF-8"?>
<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
  <sheets><sheet name="Smoke" sheetId="1" r:id="rId1"/></sheets>
</workbook>""",
        "xl/_rels/workbook.xml.rels": """<?xml version="1.0" encoding="UTF-8"?>
<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
  <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/>
</Relationships>""",
        "xl/worksheets/sheet1.xml": f"""<?xml version="1.0" encoding="UTF-8"?>
<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
  <sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>{marker}</t></is></c></row></sheetData>
</worksheet>""",
    }
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, content in files.items():
            archive.writestr(name, content)


def upload(path: Path, mime_type: str, key: str) -> str:
    boundary = f"----finwealth-{secrets.token_hex(16)}"
    content = path.read_bytes()
    body = b"".join(
        [
            f"--{boundary}\r\n".encode(),
            f'Content-Disposition: form-data; name="file"; filename="{path.name}"\r\n'.encode(),
            f"Content-Type: {mime_type}\r\n\r\n".encode(),
            content,
            f"\r\n--{boundary}--\r\n".encode(),
        ]
    )
    metadata = request(
        "POST",
        "/attachments",
        raw_body=body,
        content_type=f"multipart/form-data; boundary={boundary}",
        idempotency_key=key,
    )
    assert isinstance(metadata, dict) and isinstance(metadata.get("id"), str)
    return metadata["id"]


def run_event_summary(conversation_id: str, run_id: str) -> list[str]:
    result: list[str] = []
    event_type = ""
    with urllib.request.urlopen(
        urllib.request.Request(
            f"{BASE}/conversations/{conversation_id}/events?after=0",
            headers=headers(),
            method="GET",
        ),
        timeout=30,
    ) as response:
        for raw_line in response:
            line = raw_line.decode("utf-8").rstrip("\r\n")
            if line.startswith("event: "):
                event_type = line[7:]
            elif line.startswith("data: "):
                data = json.loads(line[6:])
                if data.get("runId") != run_id:
                    continue
                if event_type == "tool.completed":
                    result.append(f"{data.get('name', 'unknown')}:{data.get('isError') is True}")
                if event_type in {"run.completed", "run.failed"}:
                    return result
    return result


def run_document(file_path: Path, mime_type: str, marker: str, instructions: str) -> None:
    nonce = secrets.token_hex(8)
    conversation = request(
        "POST",
        "/conversations",
        body={"title": f"Document smoke {nonce}"},
        idempotency_key=f"vps-doc-conversation-{nonce}",
    )
    assert isinstance(conversation, dict)
    models = request("GET", "/models")
    model = next(item for item in models if item.get("provider") == "lore")
    conversation = request(
        "PATCH",
        f"/conversations/{conversation['id']}",
        body={"modelId": model["id"]},
        idempotency_key=f"vps-doc-model-{nonce}",
    )
    attachment_id = upload(file_path, mime_type, f"vps-doc-upload-{nonce}")
    accepted = request(
        "POST",
        f"/conversations/{conversation['id']}/messages",
        body={"text": instructions, "attachmentIds": [attachment_id]},
        idempotency_key=f"vps-doc-message-{nonce}",
    )
    deadline = time.monotonic() + TIMEOUT_SECONDS
    while time.monotonic() < deadline:
        messages = request("GET", f"/conversations/{conversation['id']}/messages")
        assistant = next(
            (
                item
                for item in messages
                if item.get("role") == "assistant" and item.get("runId") == accepted["runId"]
            ),
            None,
        )
        if assistant and assistant.get("status") == "failed":
            raise RuntimeError(f"document Agent run failed: {assistant.get('errorCode', 'unknown')}")
        if assistant and assistant.get("status") == "completed":
            tool_summary = run_event_summary(conversation["id"], accepted["runId"])
            if marker not in assistant.get("text", ""):
                tools = ",".join(tool_summary) if tool_summary else "none"
                raise RuntimeError(f"document marker was not returned (tools={tools})")
            if "bash:False" not in tool_summary:
                tools = ",".join(tool_summary) if tool_summary else "none"
                raise RuntimeError(f"document was not read by successful isolated bash (tools={tools})")
            return
        time.sleep(0.25)
    raise TimeoutError("document Agent run timed out")


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="finwealth-vps-document-") as directory:
        root = Path(directory)
        pdf_marker = "FINWEALTH_PDF_7P3"
        pdf = root / "smoke.pdf"
        pdf.write_bytes(pdf_bytes(pdf_marker))
        extracted = subprocess.run(
            ["pdftotext", str(pdf), "-"],
            check=True,
            capture_output=True,
            text=True,
        ).stdout
        if pdf_marker not in extracted:
            raise RuntimeError("synthetic PDF preflight failed")
        xlsx_marker = "FINWEALTH_XLSX_4M8"
        xlsx = root / "smoke.xlsx"
        write_xlsx(xlsx, xlsx_marker)
        run_document(
            pdf,
            "application/pdf",
            pdf_marker,
            "使用隔离 bash 运行 pdftotext 读取所附 PDF，只回复文件中的标记。",
        )
        run_document(
            xlsx,
            "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
            xlsx_marker,
            "使用隔离 bash 中的 python3 zipfile/XML 读取所附 XLSX，只回复第一个单元格的标记。",
        )
    print("OK: production Pi model read PDF and XLSX inside the isolated workspace.")


if __name__ == "__main__":
    main()
