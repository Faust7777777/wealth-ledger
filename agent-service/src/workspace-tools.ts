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
  type ToolDefinition,
} from "@earendil-works/pi-coding-agent";

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
  return [
    createReadToolDefinition(workspace, { operations: readOperations }),
    createWriteToolDefinition(workspace, { operations: writeOperations }),
    createEditToolDefinition(workspace, { operations: editOperations }),
    bash,
  ];
}
