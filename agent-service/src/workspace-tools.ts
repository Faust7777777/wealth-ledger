import { spawn } from "node:child_process";
import {
  access,
  lstat,
  mkdir,
  readFile,
  realpath,
  writeFile,
} from "node:fs/promises";
import { existsSync } from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";
import {
  createBashToolDefinition,
  createEditToolDefinition,
  createReadToolDefinition,
  createWriteToolDefinition,
  defineTool,
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

const MAX_DOCUMENT_TEXT_BYTES = 256 * 1024;
const XLSX_READER = String.raw`
import posixpath, sys, zipfile
import xml.etree.ElementTree as ET

MAIN = "{http://schemas.openxmlformats.org/spreadsheetml/2006/main}"
REL = "{http://schemas.openxmlformats.org/officeDocument/2006/relationships}"
PKG_REL = "{http://schemas.openxmlformats.org/package/2006/relationships}"

with zipfile.ZipFile(sys.argv[1]) as book:
    names = set(book.namelist())
    shared = []
    if "xl/sharedStrings.xml" in names:
        root = ET.fromstring(book.read("xl/sharedStrings.xml"))
        shared = ["".join(node.text or "" for node in item.iter(MAIN + "t")) for item in root]
    workbook = ET.fromstring(book.read("xl/workbook.xml"))
    relationships = ET.fromstring(book.read("xl/_rels/workbook.xml.rels"))
    targets = {item.attrib["Id"]: item.attrib["Target"] for item in relationships.iter(PKG_REL + "Relationship")}
    for sheet in workbook.iter(MAIN + "sheet"):
        target = targets.get(sheet.attrib.get(REL + "id", ""), "")
        path = posixpath.normpath(posixpath.join("xl", target))
        if not path.startswith("xl/") or path not in names:
            continue
        print("[" + sheet.attrib.get("name", "Sheet") + "]")
        root = ET.fromstring(book.read(path))
        for cell in root.iter(MAIN + "c"):
            kind = cell.attrib.get("t", "")
            if kind == "inlineStr":
                value = "".join(node.text or "" for node in cell.iter(MAIN + "t"))
            else:
                node = cell.find(MAIN + "v")
                value = node.text if node is not None and node.text is not None else ""
                if kind == "s" and value:
                    value = shared[int(value)]
            if value:
                print(cell.attrib.get("r", "?") + "\t" + value.replace("\n", " "))
`;

function isInside(root: string, target: string): boolean {
  const value = relative(root, target);
  return value === "" || (!value.startsWith(`..${sep}`) && value !== ".." && !isAbsolute(value));
}

async function readablePath(root: string, target: string): Promise<string> {
  const canonicalRoot = await realpath(root);
  const canonicalTarget = await realpath(target);
  if (!isInside(canonicalRoot, canonicalTarget)) throw new Error("workspace_path_forbidden");
  return canonicalTarget;
}

async function writablePath(root: string, target: string): Promise<string> {
  const canonicalRoot = await realpath(root);
  const resolved = resolve(target);
  if (!isInside(canonicalRoot, resolved)) throw new Error("workspace_path_forbidden");
  if (existsSync(resolved)) {
    const stats = await lstat(resolved);
    if (stats.isSymbolicLink()) throw new Error("workspace_path_forbidden");
    const canonicalTarget = await realpath(resolved);
    if (!isInside(canonicalRoot, canonicalTarget)) throw new Error("workspace_path_forbidden");
    return resolved;
  }
  let existingParent = dirname(resolved);
  while (!existsSync(existingParent)) {
    const next = dirname(existingParent);
    if (next === existingParent) throw new Error("workspace_path_forbidden");
    existingParent = next;
  }
  const canonicalParent = await realpath(existingParent);
  if (!isInside(canonicalRoot, canonicalParent)) throw new Error("workspace_path_forbidden");
  return resolved;
}

function safeShellEnvironment(): NodeJS.ProcessEnv {
  const allowed = [
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "NO_PROXY",
    "http_proxy",
    "https_proxy",
    "no_proxy",
    "LANG",
    "LC_ALL",
    "TZ",
  ];
  const env: NodeJS.ProcessEnv = { PATH: "/usr/local/bin:/usr/bin:/bin" };
  for (const name of allowed) {
    if (process.env[name]) env[name] = process.env[name];
  }
  return env;
}

function bubblewrapArguments(workspace: string, command: string): string[] {
  const args = [
    "--die-with-parent",
    "--new-session",
    "--unshare-all",
    "--share-net",
    "--proc", "/proc",
    "--dev", "/dev",
    "--tmpfs", "/tmp",
  ];
  for (const path of [
    "/usr", "/bin", "/lib", "/lib64",
    "/etc/ssl", "/etc/resolv.conf", "/etc/hosts", "/etc/nsswitch.conf",
    "/etc/passwd", "/etc/group", "/etc/localtime",
  ]) {
    if (existsSync(path)) args.push("--ro-bind", path, path);
  }
  args.push(
    "--bind", workspace, "/workspace",
    "--chdir", "/workspace",
    "--setenv", "HOME", "/workspace",
    "--setenv", "PATH", "/usr/local/bin:/usr/bin:/bin",
    "--",
    "/bin/bash", "-lc", command,
  );
  return args;
}

function shellQuote(value: string): string {
  return `'${value.replaceAll("'", `'"'"'`)}'`;
}

function readPdfText(
  workspace: string,
  relativePath: string,
  signal?: AbortSignal,
): Promise<string> {
  if (process.platform !== "linux") {
    return Promise.reject(new Error("workspace_shell_requires_linux_bubblewrap"));
  }
  return new Promise((resolvePromise, reject) => {
    const child = spawn(
      "bwrap",
      bubblewrapArguments(workspace, `pdftotext -- ${shellQuote(relativePath)} -`),
      {
        cwd: workspace,
        env: safeShellEnvironment(),
        stdio: ["ignore", "pipe", "pipe"],
      },
    );
    const chunks: Buffer[] = [];
    let bytes = 0;
    let settled = false;
    const finish = (error?: Error, value?: string): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      if (error) reject(error);
      else resolvePromise(value ?? "");
    };
    const abort = (): void => {
      child.kill("SIGKILL");
    };
    const timer = setTimeout(abort, 30_000);
    signal?.addEventListener("abort", abort, { once: true });
    child.stdout.on("data", (chunk: Buffer) => {
      bytes += chunk.length;
      if (bytes > MAX_DOCUMENT_TEXT_BYTES) {
        child.kill("SIGKILL");
        finish(new Error("workspace_document_too_large"));
        return;
      }
      chunks.push(Buffer.from(chunk));
    });
    child.on("error", (error) => finish(error));
    child.on("close", (exitCode) => {
      if (settled) return;
      if (signal?.aborted) {
        finish(new Error("agent_run_aborted"));
      } else if (exitCode !== 0) {
        finish(new Error("workspace_pdf_read_failed"));
      } else {
        finish(undefined, Buffer.concat(chunks).toString("utf8"));
      }
    });
  });
}

function readXlsxText(
  workspace: string,
  relativePath: string,
  signal?: AbortSignal,
): Promise<string> {
  const command = `python3 -c ${shellQuote(XLSX_READER)} ${shellQuote(relativePath)}`;
  if (process.platform !== "linux") {
    return Promise.reject(new Error("workspace_shell_requires_linux_bubblewrap"));
  }
  return new Promise((resolvePromise, reject) => {
    const child = spawn("bwrap", bubblewrapArguments(workspace, command), {
      cwd: workspace,
      env: safeShellEnvironment(),
      stdio: ["ignore", "pipe", "pipe"],
    });
    const chunks: Buffer[] = [];
    let bytes = 0;
    let settled = false;
    const finish = (error?: Error, value?: string): void => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      signal?.removeEventListener("abort", abort);
      if (error) reject(error);
      else resolvePromise(value ?? "");
    };
    const abort = (): void => { child.kill("SIGKILL"); };
    const timer = setTimeout(abort, 30_000);
    signal?.addEventListener("abort", abort, { once: true });
    child.stdout.on("data", (chunk: Buffer) => {
      bytes += chunk.length;
      if (bytes > MAX_DOCUMENT_TEXT_BYTES) {
        child.kill("SIGKILL");
        finish(new Error("workspace_document_too_large"));
        return;
      }
      chunks.push(Buffer.from(chunk));
    });
    child.on("error", (error) => finish(error));
    child.on("close", (exitCode) => {
      if (settled) return;
      if (signal?.aborted) finish(new Error("agent_run_aborted"));
      else if (exitCode !== 0) finish(new Error("workspace_xlsx_read_failed"));
      else finish(undefined, Buffer.concat(chunks).toString("utf8"));
    });
  });
}

export async function extractWorkspacePdfText(
  workspace: string,
  path: string,
  signal?: AbortSignal,
): Promise<string> {
  const target = await readablePath(workspace, resolve(workspace, path));
  if (!target.toLowerCase().endsWith(".pdf")) {
    throw new Error("workspace_pdf_required");
  }
  const relativeTarget = relative(workspace, target).replaceAll("\\", "/");
  return readPdfText(workspace, relativeTarget, signal);
}

export async function extractWorkspaceXlsxText(
  workspace: string,
  path: string,
  signal?: AbortSignal,
): Promise<string> {
  const target = await readablePath(workspace, resolve(workspace, path));
  if (!target.toLowerCase().endsWith(".xlsx")) {
    throw new Error("workspace_xlsx_required");
  }
  const relativeTarget = relative(workspace, target).replaceAll("\\", "/");
  return readXlsxText(workspace, relativeTarget, signal);
}

export function createWorkspaceTools(
  workspace: string,
): Array<ToolDefinition<any, any, any>> {
  const readOperations = {
    readFile: async (path: string) => readFile(await readablePath(workspace, path)),
    access: async (path: string) => access(await readablePath(workspace, path)),
  };
  const writeOperations = {
    writeFile: async (path: string, content: string) =>
      writeFile(await writablePath(workspace, path), content, { mode: 0o600 }),
    mkdir: async (path: string) =>
      mkdir(await writablePath(workspace, path), { recursive: true, mode: 0o700 }).then(() => undefined),
  };
  const editOperations = {
    ...readOperations,
    writeFile: writeOperations.writeFile,
  };
  const bash = createBashToolDefinition(workspace, {
    exposeSessionEnvironment: false,
    operations: {
      exec(command, cwd, options) {
        return new Promise((resolvePromise, reject) => {
          if (process.platform !== "linux") {
            reject(new Error("workspace_shell_requires_linux_bubblewrap"));
            return;
          }
          const child = spawn("bwrap", bubblewrapArguments(cwd, command), {
            cwd,
            env: safeShellEnvironment(),
            stdio: ["ignore", "pipe", "pipe"],
          });
          child.stdout.on("data", options.onData);
          child.stderr.on("data", options.onData);
          child.on("error", reject);
          child.on("close", (exitCode) => resolvePromise({ exitCode }));
          const abort = () => child.kill("SIGKILL");
          options.signal?.addEventListener("abort", abort, { once: true });
          const timer = options.timeout
            ? setTimeout(abort, options.timeout)
            : undefined;
          child.on("close", () => {
            if (timer) clearTimeout(timer);
            options.signal?.removeEventListener("abort", abort);
          });
        });
      },
    },
  });
  const pdf = defineTool({
    name: "finwealth_read_pdf_text",
    label: "读取 PDF",
    description:
      "从 Agent 专属工作区读取 PDF 的文字。PDF 附件必须用此工具，不要用 read、Python 或自写解析器。",
    promptSnippet: "用固定的 pdftotext 沙箱工具读取 PDF 附件。",
    parameters: Type.Object({
      path: Type.String({ description: "附件上下文中给出的工作区相对路径" }),
    }),
    async execute(_id, params, signal) {
      const text = await extractWorkspacePdfText(workspace, params.path, signal);
      return { content: [{ type: "text", text }], details: {} };
    },
  });
  const xlsx = defineTool({
    name: "finwealth_read_xlsx_text",
    label: "读取表格",
    description: "从 Agent 专属工作区确定性读取 XLSX 单元格文字。",
    promptSnippet: "用固定的隔离工具读取 XLSX 附件。",
    parameters: Type.Object({
      path: Type.String({ description: "附件上下文中给出的工作区相对路径" }),
    }),
    async execute(_id, params, signal) {
      const text = await extractWorkspaceXlsxText(workspace, params.path, signal);
      return { content: [{ type: "text", text }], details: {} };
    },
  });
  return [
    createReadToolDefinition(workspace, { operations: readOperations }),
    createWriteToolDefinition(workspace, { operations: writeOperations }),
    createEditToolDefinition(workspace, { operations: editOperations }),
    pdf,
    xlsx,
    bash,
  ];
}
