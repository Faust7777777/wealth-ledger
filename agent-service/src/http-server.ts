import { createHash, timingSafeEqual } from "node:crypto";
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import Busboy from "busboy";
import { AgentService } from "./agent-service.js";
import type { AgentEvent, Principal } from "./types.js";

const MAX_JSON_BYTES = 1024 * 1024;
const MAX_ATTACHMENT_BYTES = 15 * 1024 * 1024;

function sendJson(
  response: ServerResponse,
  status: number,
  value: unknown,
): void {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    "content-type": "application/json; charset=utf-8",
    "content-length": Buffer.byteLength(body),
    "cache-control": "no-store",
  });
  response.end(body);
}

function ok(response: ServerResponse, data: unknown, status = 200): void {
  sendJson(response, status, { ok: true, data });
}

function fail(
  response: ServerResponse,
  status: number,
  code: string,
  message: string,
  retryable = false,
): void {
  sendJson(response, status, {
    ok: false,
    error: { code, message, retryable },
  });
}

function safeTokenEqual(left: string | undefined, right: string): boolean {
  if (!left) return false;
  const leftBytes = Buffer.from(left);
  const rightBytes = Buffer.from(right);
  return (
    leftBytes.length === rightBytes.length && timingSafeEqual(leftBytes, rightBytes)
  );
}

function principalFrom(request: IncomingMessage): Principal | undefined {
  const userId = request.headers["x-finwealth-user-id"];
  const ledgerId = request.headers["x-finwealth-ledger-id"];
  const deviceId = request.headers["x-finwealth-device-id"];
  if (
    typeof userId !== "string" ||
    typeof ledgerId !== "string" ||
    typeof deviceId !== "string"
  ) {
    return undefined;
  }
  return { userId, ledgerId, deviceId };
}

async function readJson(request: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let length = 0;
  for await (const chunk of request) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    length += buffer.length;
    if (length > MAX_JSON_BYTES) throw new Error("request_too_large");
    chunks.push(buffer);
  }
  if (chunks.length === 0) return {};
  const value: unknown = JSON.parse(Buffer.concat(chunks).toString("utf8"));
  if (typeof value !== "object" || value === null || Array.isArray(value)) {
    throw new Error("invalid_json_body");
  }
  return value as Record<string, unknown>;
}

function writeEvent(response: ServerResponse, event: AgentEvent): void {
  response.write(`id: ${event.cursor}\n`);
  response.write(`event: ${event.type}\n`);
  response.write(`data: ${JSON.stringify(event.data)}\n\n`);
}

function errorStatus(code: string): number {
  if (code.endsWith("_not_found")) return 404;
  if (code === "agent_model_not_allowed") return 403;
  if (code === "agent_model_unavailable") return 503;
  if (
    code === "conversation_archived" ||
    code === "primary_conversation_cannot_be_archived" ||
    code === "agent_memory_already_reviewed" ||
    code === "idempotency_key_reused"
  ) {
    return 409;
  }
  return 400;
}

function idempotencyKey(request: IncomingMessage): string {
  const value = request.headers["idempotency-key"];
  if (typeof value !== "string") throw new Error("invalid_idempotency_key");
  return value;
}

function markReplay(response: ServerResponse, replayed: boolean): void {
  if (replayed) response.setHeader("idempotency-replayed", "true");
}

async function readAttachment(request: IncomingMessage): Promise<{
  fileName: string;
  mimeType: string;
  bytes: Buffer;
  sha256: string;
}> {
  return new Promise((resolve, reject) => {
    let found = false;
    let rejected = false;
    let result: { fileName: string; mimeType: string; bytes: Buffer } | undefined;
    const failOnce = (error: Error): void => {
      if (rejected) return;
      rejected = true;
      reject(error);
    };
    let parser: ReturnType<typeof Busboy>;
    try {
      parser = Busboy({
        headers: request.headers,
        limits: { files: 1, fields: 0, fileSize: MAX_ATTACHMENT_BYTES },
      });
    } catch {
      failOnce(new Error("invalid_attachment_request"));
      return;
    }
    parser.on("file", (_field, stream, info) => {
      if (found) {
        stream.resume();
        failOnce(new Error("invalid_attachment_request"));
        return;
      }
      found = true;
      const chunks: Buffer[] = [];
      stream.on("data", (chunk: Buffer) => chunks.push(Buffer.from(chunk)));
      stream.on("limit", () => failOnce(new Error("invalid_attachment_size")));
      stream.on("end", () => {
        if (rejected) return;
        result = {
          fileName: info.filename.replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 255),
          mimeType: info.mimeType.toLowerCase(),
          bytes: Buffer.concat(chunks),
        };
      });
    });
    parser.on("filesLimit", () => failOnce(new Error("invalid_attachment_request")));
    parser.on("error", () => failOnce(new Error("invalid_attachment_request")));
    parser.on("finish", () => {
      if (rejected) return;
      if (!result) {
        failOnce(new Error("invalid_attachment_request"));
        return;
      }
      resolve({
        ...result,
        sha256: createHash("sha256").update(result.bytes).digest("hex"),
      });
    });
    request.pipe(parser);
  });
}

export function createAgentHttpServer(
  service: AgentService,
  internalToken: string,
) {
  return createServer(async (request, response) => {
    if (
      !safeTokenEqual(
        typeof request.headers["x-finwealth-internal-token"] === "string"
          ? request.headers["x-finwealth-internal-token"]
          : undefined,
        internalToken,
      )
    ) {
      fail(response, 401, "internal_auth_required", "Internal authentication is required.");
      return;
    }
    const principal = principalFrom(request);
    if (!principal) {
      fail(response, 401, "principal_required", "Authenticated principal is required.");
      return;
    }

    const url = new URL(request.url ?? "/", "http://127.0.0.1");
    const path = url.pathname;
    try {
      if (request.method === "GET" && path === "/v1/agent/status") {
        ok(response, await service.status(principal));
        return;
      }
      if (request.method === "GET" && path === "/v1/agent/models") {
        ok(response, await service.listModels());
        return;
      }
      if (request.method === "GET" && path === "/v1/agent/memories") {
        ok(response, await service.listMemories(principal));
        return;
      }
      if (request.method === "POST" && path === "/v1/agent/attachments") {
        const file = await readAttachment(request);
        const result = await service.idempotent(
          principal,
          idempotencyKey(request),
          "POST /v1/agent/attachments",
          { fileName: file.fileName, mimeType: file.mimeType, sha256: file.sha256 },
          () => service.createAttachment(principal, file),
        );
        markReplay(response, result.replayed);
        ok(response, result.value, 201);
        return;
      }
      let match = path.match(/^\/v1\/agent\/attachments\/([^/]+)\/content$/);
      if (match?.[1] && request.method === "GET") {
        const content = await service.getAttachmentContent(principal, match[1]);
        response.writeHead(200, {
          "content-type": content.metadata.mimeType,
          "content-length": content.bytes.length,
          "cache-control": "private, no-store",
          etag: `"sha256-${content.metadata.sha256}"`,
          "x-content-type-options": "nosniff",
        });
        response.end(content.bytes);
        return;
      }
      match = path.match(/^\/v1\/agent\/attachments\/([^/]+)$/);
      if (match?.[1] && request.method === "GET") {
        ok(response, await service.getAttachment(principal, match[1]));
        return;
      }
      if (path === "/v1/agent/conversations") {
        if (request.method === "GET") {
          ok(response, await service.listConversations(principal));
          return;
        }
        if (request.method === "POST") {
          const body = await readJson(request);
          const title = typeof body.title === "string" ? body.title : undefined;
          const result = await service.idempotent(
            principal,
            idempotencyKey(request),
            "POST /v1/agent/conversations",
            { title },
            () => service.createConversation(principal, title),
          );
          markReplay(response, result.replayed);
          ok(response, result.value, 201);
          return;
        }
      }

      match = path.match(/^\/v1\/agent\/conversations\/([^/]+)$/);
      if (match?.[1] && request.method === "PATCH") {
        const conversationId = match[1];
        const body = await readJson(request);
        const patch: {
          title?: string;
          status?: "active" | "archived";
          modelId?: string;
        } = {};
        if (typeof body.title === "string") patch.title = body.title;
        if (body.status === "active" || body.status === "archived") {
          patch.status = body.status;
        }
        if (typeof body.modelId === "string") patch.modelId = body.modelId;
        const result = await service.idempotent(
          principal,
          idempotencyKey(request),
          `PATCH /v1/agent/conversations/${conversationId}`,
          patch,
          () => service.updateConversation(principal, conversationId, patch),
        );
        markReplay(response, result.replayed);
        ok(response, result.value);
        return;
      }

      match = path.match(/^\/v1\/agent\/conversations\/([^/]+)\/messages$/);
      if (match?.[1]) {
        if (request.method === "GET") {
          ok(response, await service.listMessages(principal, match[1]));
          return;
        }
        if (request.method === "POST") {
          const conversationId = match[1];
          const body = await readJson(request);
          if (typeof body.text !== "string") throw new Error("invalid_agent_message");
          const text = body.text;
          const attachmentIds = body.attachmentIds === undefined
            ? []
            : Array.isArray(body.attachmentIds) && body.attachmentIds.every(
                (item) => typeof item === "string",
              )
              ? body.attachmentIds as string[]
              : (() => { throw new Error("invalid_agent_attachments"); })();
          const result = await service.idempotent(
            principal,
            idempotencyKey(request),
            `POST /v1/agent/conversations/${conversationId}/messages`,
            { text, attachmentIds },
            () => service.sendMessage(
              principal,
              conversationId,
              text,
              attachmentIds,
            ),
          );
          markReplay(response, result.replayed);
          ok(response, result.value, 202);
          return;
        }
      }

      match = path.match(/^\/v1\/agent\/conversations\/([^/]+)\/events$/);
      if (match?.[1] && request.method === "GET") {
        const afterHeader = request.headers["last-event-id"];
        const rawAfter = url.searchParams.get("after") ??
          (typeof afterHeader === "string" ? afterHeader : "0");
        const after = Number.parseInt(rawAfter, 10);
        if (!Number.isSafeInteger(after) || after < 0) {
          throw new Error("invalid_event_cursor");
        }
        const conversationId = match[1];
        const existing = await service.listEvents(
          principal,
          conversationId,
          after,
        );
        response.writeHead(200, {
          "content-type": "text/event-stream; charset=utf-8",
          "cache-control": "no-cache, no-transform",
          connection: "keep-alive",
          "x-accel-buffering": "no",
        });
        for (const event of existing) writeEvent(response, event);
        const unsubscribe = service.events.subscribe(conversationId, (event) =>
          writeEvent(response, event),
        );
        const heartbeat = setInterval(() => response.write(": keep-alive\n\n"), 15_000);
        request.on("close", () => {
          clearInterval(heartbeat);
          unsubscribe();
          response.end();
        });
        return;
      }

      match = path.match(/^\/v1\/agent\/runs\/([^/]+)\/cancel$/);
      if (match?.[1] && request.method === "POST") {
        const runId = match[1];
        const result = await service.idempotent(
          principal,
          idempotencyKey(request),
          `POST /v1/agent/runs/${runId}/cancel`,
          {},
          async () => ({ cancelled: await service.cancelRun(principal, runId) }),
        );
        markReplay(response, result.replayed);
        ok(response, result.value);
        return;
      }

      match = path.match(/^\/v1\/agent\/memories\/([^/]+)\/review$/);
      if (match?.[1] && request.method === "POST") {
        const memoryId = match[1];
        const body = await readJson(request);
        if (body.decision !== "active" && body.decision !== "rejected") {
          throw new Error("invalid_agent_memory_decision");
        }
        const decision = body.decision;
        const result = await service.idempotent(
          principal,
          idempotencyKey(request),
          `POST /v1/agent/memories/${memoryId}/review`,
          { decision },
          () => service.reviewMemory(principal, memoryId, decision),
        );
        markReplay(response, result.replayed);
        ok(response, result.value);
        return;
      }

      fail(response, 404, "agent_route_not_found", "Agent route was not found.");
    } catch (error) {
      const code =
        error instanceof Error && /^[a-z0-9_]+$/.test(error.message)
          ? error.message
          : "agent_request_invalid";
      fail(
        response,
        errorStatus(code),
        code,
        code === "agent_model_unavailable"
          ? "No configured Agent model is available."
          : "Agent request could not be completed.",
        code === "agent_model_unavailable",
      );
    }
  });
}
