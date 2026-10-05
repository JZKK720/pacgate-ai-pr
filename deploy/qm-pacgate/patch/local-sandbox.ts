import { createHash, randomUUID } from "node:crypto";
import { orgId as configOrgId } from "../config.ts";
import { arch } from "node:os";
import { join } from "node:path";
import { readdir, readFile as fsReadFile } from "node:fs/promises";
import type { WorkspaceLayer } from "../types.ts";
import type { WorkspaceStore } from "../workspace/workspace-store.ts";
import { createKeyedQueue, sleep } from "../util/async.ts";
import { swallowAs, errMessage } from "../util/errors.ts";
import { shq } from "../util/shell.ts";
import { nonInteractiveShellPrefix } from "./sandbox-env.ts";
import { createExecProcessSessions, type ExecProcessIo } from "./exec-process-session.ts";
import { materializeRoLayers } from "./ro-layers.ts";
import { createExecBackup, createExecFileOps, posixJoin } from "./exec-file-ops.ts";
import { spawnDockerExec, type DockerExec } from "./docker-exec.ts";
import { ephemeralCredLinkScript } from "../credentials/resident-paths.ts";
import { ephemeralCredLinkPaths } from "../credentials/resident-paths.ts";
import { shortHash } from "../util/crypto.ts";
import { killableScript, killScript } from "./exec-kill.ts";
import type {
  AgentComputerProfile,
  ExecOptions,
  ExecResult,
  ProvisionOptions,
  Sandbox,
  SandboxHandle,
  TeardownOptions,
} from "./sandbox.ts";

const DEFAULT_LOCAL_SANDBOX_IMAGE = "qm-sandbox-local:latest";
const HOME_DIR = "/root";
const WORKSPACE_BASENAME = "workspace";
const AGENT_PORT = 8080;
const RO_LAYERS_TAR = ".ro-layers.tar";
const RO_LAYERS_MANIFEST = ".ro-layers.manifest";
const FINGERPRINT_LABEL = "qm.sandbox-fingerprint";
const BUILD_HINT = "run `npm run sandbox:local:build`";

export type { DockerExec };

export interface LocalSandboxOptions {
  image?: string;
  dockerBin?: string;
  cpus?: number;
  memoryMb?: number;
  defaultTimeoutSec?: number;
  homeDir?: string;
  repoRoot?: string;
  dockerExec?: DockerExec;
  fetchImpl?: typeof fetch;
  onError?: (e: { category: string; code: string; message: string; scopeLabel?: string }) => void;
}

const FINGERPRINT_FIXED_SOURCES = ["fly/Dockerfile", "local/Dockerfile", "aws/microvm-agent/agent.mjs"];

export async function computeSandboxImageFingerprint(repoRoot: string): Promise<string | null> {
  try {
    const tools = (await readdir(join(repoRoot, "fly/tools"))).sort().map((f) => `fly/tools/${f}`);
    const paths = [...FINGERPRINT_FIXED_SOURCES, ...tools].sort();
    const fp = createHash("sha256");
    for (const p of paths) {
      fp.update(p);
      fp.update("\0");
      fp.update(
        createHash("sha256")
          .update(await fsReadFile(join(repoRoot, p)))
          .digest(),
      );
      fp.update("\n");
    }
    return fp.digest("hex");
  } catch {
    return null;
  }
}

export const localContainerName = (scopeId: string): string => `qm-sbx-${localSlug(scopeId)}`;
export const localVolumeName = (scopeId: string): string => `qm-home-${localSlug(scopeId)}`;
export const localNetworkName = (containerName: string): string =>
  `qm-net-${containerName.replace(/^qm-(sbx|scratch)-/, "")}`;
const localScratchName = (key: string): string => `qm-scratch-${localSlug(key)}`;

function localSlug(id: string): string {
  const cleaned = id
    .toLowerCase()
    .replace(/[^a-z0-9-]+/g, "-")
    .replace(/^-+|-+$/g, "");
  return `${cleaned.slice(0, 40).replace(/-+$/, "") || "scope"}-${shortHash(id)}`;
}

export function createLocalSandbox(workspace: WorkspaceStore, opts: LocalSandboxOptions = {}): Sandbox {
  const image = opts.image ?? DEFAULT_LOCAL_SANDBOX_IMAGE;
  const dexec = opts.dockerExec ?? spawnDockerExec(opts.dockerBin ?? "docker");
  const fetchImpl = opts.fetchImpl ?? fetch;
  const defaultTimeoutSec = opts.defaultTimeoutSec ?? 600;
  const homeDir = opts.homeDir ?? HOME_DIR;
  const workspaceDir = `${homeDir}/${WORKSPACE_BASENAME}`;
  const provisionQueue = createKeyedQueue<string>();

  const portByName = new Map<string, number>();
  const scopeByContainer = new Map<string, string>();
  const scratchByKey = new Map<string, string>();
  const activeByContainer = new Map<string, number>();

  let preflightDone: Promise<string> | undefined;
  let staleWarned = false;

  async function preflight(): Promise<string> {
    preflightDone ??= (async () => {
      const version = await dexec(["version"], 15_000);
      if (version.code !== 0) {
        preflightDone = undefined;
        throw new Error("SANDBOX_BACKEND=local requires a running Docker daemon (is Docker Desktop running?)");
      }
      const img = await dexec([
        "image",
        "inspect",
        "-f",
        `{{.Id}} {{if .Config.Labels}}{{index .Config.Labels "${FINGERPRINT_LABEL}"}}{{end}}`,
        image,
      ]);
      if (img.code !== 0) {
        preflightDone = undefined;
        throw new Error(`local sandbox image ${image} not found — ${BUILD_HINT}`);
      }
      const [imageId = "", labeled = ""] = img.stdout.trim().split(/\s+/);
      if (!staleWarned) {
        const want = await computeSandboxImageFingerprint(opts.repoRoot ?? process.cwd());
        if (want && labeled && labeled !== want) {
          staleWarned = true;
          console.warn(`[local-sandbox] sandbox image ${image} is stale — ${BUILD_HINT}`);
        }
      }
      return imageId;
    })();
    return preflightDone;
  }

  async function containerState(name: string): Promise<{ running: boolean; imageId: string } | null> {
    const r = await dexec(["inspect", "-f", "{{.State.Running}} {{.Image}}", name]);
    if (r.code !== 0) return null;
    const [running = "", imageId = ""] = r.stdout.trim().split(/\s+/);
    return { running: running === "true", imageId };
  }

  async function resolvePort(name: string): Promise<number> {
    const cached = portByName.get(name);
    if (cached) return cached;
    const r = await dexec(["port", name, `${AGENT_PORT}/tcp`]);
    const m = r.stdout
      .split("\n")[0]
      ?.trim()
      .match(/:(\d+)$/);
    if (r.code !== 0 || !m)
      throw new Error(`local sandbox ${name}: cannot resolve agent port: ${r.stderr.trim() || r.stdout.trim()}`);
    const port = Number(m[1]);
    portByName.set(name, port);
    return port;
  }

  // ── Pacgate: reach the agent daemon via the container IP ──────────────
  //
  // Upstream fetches http://127.0.0.1:<published-port> and that works when
  // core runs directly on the docker host (upstream's `qm up` path): the
  // 127.0.0.1 the publish binds IS the host's loopback.
  //
  // Our deployment runs core INSIDE a container (compose.qm.yaml), so core's
  // 127.0.0.1 is core's own network namespace, NOT the host loopback where
  // Docker publishes the port. Every daemon() call got "Connection refused",
  // surfaced to agents as "exec daemon never became reachable: fetch failed"
  // (tape-verified 2026-10-05), then the provision-failure path stopped the
  // container (exit 137) so the next attempt spawned a fresh sandbox that hit
  // the same wall.
  //
  // Fix: resolve the sandbox's IP on its own bridge network (core can route
  // to it - different bridge subnets but both docker-managed) and hit that
  // directly. `docker inspect` runs through the SAME docker CLI/socket the
  // rest of this backend uses. Loopback stays as a fallback for the upstream
  // on-host layout.
  const ipByContainer = new Map<string, string>();

  async function resolveDaemonBase(name: string): Promise<string> {
    const ip = ipByContainer.get(name);
    if (ip) return `http://${ip}:${AGENT_PORT}`;
    const r = await dexec(["inspect", "-f", "{{json .NetworkSettings.Networks}}", name]);
    if (r.code === 0) {
      const m = r.stdout.match(/"IPAddress":"(10\.\d+\.\d+\.\d+|172\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+)"/);
      if (m) {
        ipByContainer.set(name, m[1]);
        return `http://${m[1]}:${AGENT_PORT}`;
      }
    }
    return `http://127.0.0.1:${await resolvePort(name)}`;
  }

  async function daemon(
    name: string,
    path: string,
    body?: unknown,
    timeoutMs?: number,
    signal?: AbortSignal,
  ): Promise<{ status: number; text: string }> {
    const base = await resolveDaemonBase(name);
    const signals = [AbortSignal.timeout(timeoutMs ?? 30_000), ...(signal ? [signal] : [])];
    const res = await fetchImpl(`${base}${path}`, {
      method: body === undefined ? "GET" : "POST",
      ...(body === undefined ? {} : { body: JSON.stringify(body), headers: { "content-type": "application/json" } }),
      signal: AbortSignal.any(signals),
    });
    return { status: res.status, text: await res.text() };
  }

  async function waitDaemon(name: string): Promise<void> {
    const deadline = Date.now() + 30_000;
    let lastErr = "";
    while (Date.now() < deadline) {
      try {
        const res = await daemon(name, "/health", undefined, 3000);
        if (res.status === 200) return;
        lastErr = `http ${res.status}`;
      } catch (e) {
        lastErr = errMessage(e);
      }
      await sleep(300);
    }
    throw new Error(`local sandbox ${name}: exec daemon never became reachable: ${lastErr}`);
  }

  async function startContainer(name: string): Promise<void> {
    portByName.delete(name);
    ipByContainer.delete(name);
    const r = await dexec(["start", name]);
    if (r.code !== 0) throw new Error(`docker start ${name} failed: ${r.stderr.trim()}`);
    await waitDaemon(name);
  }

  async function ensureRunning(name: string): Promise<void> {
    const state = await containerState(name);
    if (!state) throw new Error(`local sandbox container ${name} is gone`);
    if (!state.running) await startContainer(name);
  }

  async function execRaw(name: string, command: string, timeoutSec: number, signal?: AbortSignal): Promise<ExecResult> {
    const res = await daemon(name, "/exec", { cmd: command, timeoutSec }, (timeoutSec + 15) * 1000, signal);
    if (res.status !== 200) throw new Error(`local sandbox exec failed (${res.status}): ${res.text.slice(0, 300)}`);
    const j = JSON.parse(res.text) as { stdout: string; stderr: string; code: number; timedOut: boolean };
    return { stdout: j.stdout ?? "", stderr: j.stderr ?? "", code: j.code, timedOut: !!j.timedOut };
  }

  async function writeAbsBytes(name: string, absPath: string, data: Uint8Array): Promise<void> {
    const res = await daemon(name, "/write", { path: absPath, b64: Buffer.from(data).toString("base64") }, 120_000);
    if (res.status !== 200)
      throw new Error(`local sandbox write ${absPath} failed (${res.status}): ${res.text.slice(0, 200)}`);
  }

  async function readAbsBytes(name: string, absPath: string): Promise<Uint8Array | null> {
    const res = await daemon(name, "/read", { path: absPath }, 120_000);
    if (res.status === 404) return null;
    if (res.status !== 200)
      throw new Error(`local sandbox read ${absPath} failed (${res.status}): ${res.text.slice(0, 200)}`);
    return Buffer.from((JSON.parse(res.text) as { b64: string }).b64, "base64");
  }

  async function ensureNetwork(name: string): Promise<string> {
    const net = localNetworkName(name);
    if ((await dexec(["network", "inspect", net])).code !== 0) {
      const r = await dexec(["network", "create", net]);
      if (r.code !== 0 && !/already exists/i.test(r.stderr)) {
        throw new Error(`docker network create ${net} failed: ${r.stderr.trim()}`);
      }
    }
    return net;
  }

  async function runContainer(name: string, scope: string | undefined, withVolume: boolean): Promise<void> {
    const net = await ensureNetwork(name);
    const args = [
      "run",
      "-d",
      "--name",
      name,
      "--label",
      "qm.sandbox=1",
      ...(scope ? ["--label", `qm.scope=${scope}`] : []),
      "--label",
      `qm.org=${configOrgId()}`,
      "--label",
      "agent_env=dev",
      "--network",
      net,
      ...(withVolume && scope ? ["-v", `${localVolumeName(scope)}:${homeDir}`] : []),
      "-p",
      `127.0.0.1:0:${AGENT_PORT}`,
      "--add-host=host.docker.internal:host-gateway",
      // Pacgate (verified 2026-10-05): FLY_RESIDENT_ENV_* exists in the core
      // process env (compose.qm.yaml) but NOTHING in this core build reads it -
      // that prefix is the upstream Fly backend's carrier, and the local
      // backend has no reader. Shell tools in the sandbox (pacgate-qm) need
      // these as bare env names, so forward each non-empty value here with the
      // prefix stripped via `docker run -e`. Resident keys reach the daemon
      // every exec path (run() and process sessions source handle/env the same
      // way), egress stays `none`, and the single-firm AIPC model keeps this
      // acceptable. Only container-CREATION sees -e; removed/re-created
      // sandboxes pick it up, paused ones re-created by image change do too.
      ...Object.entries(process.env)
        .filter(([k, v]) => k.startsWith("FLY_RESIDENT_ENV_") && v && v.trim() !== "")
        .flatMap(([k, v]) => ["-e", `${k.slice("FLY_RESIDENT_ENV_".length)}=${v}`]),
      ...(opts.cpus ? ["--cpus", String(opts.cpus)] : []),
      ...(opts.memoryMb ? ["--memory", `${opts.memoryMb}m`] : []),
      image,
    ];
    const r = await dexec(args, 120_000);
    if (r.code !== 0) throw new Error(`docker run ${name} failed: ${r.stderr.trim()}`);
    portByName.delete(name);
    ipByContainer.delete(name);
    await waitDaemon(name);
  }

  async function ensureContainer(scope: string): Promise<{ name: string; coldStart: boolean }> {
    return provisionQueue(scope, async () => {
      const imageId = await preflight();
      const name = localContainerName(scope);
      scopeByContainer.set(name, scope);
      const state = await containerState(name);
      if (state && state.imageId === imageId) {
        if (!state.running) await startContainer(name);
        activeByContainer.set(name, (activeByContainer.get(name) ?? 0) + 1);
        return { name, coldStart: false };
      }
      if (state) await dexec(["rm", "-f", name]);
      const volume = localVolumeName(scope);
      const hadVolume = (await dexec(["volume", "inspect", volume])).code === 0;
      if (!hadVolume) {
        const created = await dexec(["volume", "create", volume]);
        if (created.code !== 0) throw new Error(`docker volume create ${volume} failed: ${created.stderr.trim()}`);
      }
      await runContainer(name, scope, true);
      activeByContainer.set(name, (activeByContainer.get(name) ?? 0) + 1);
      return { name, coldStart: !hadVolume };
    });
  }

  async function ensureScratch(key: string): Promise<{ name: string; coldStart: boolean }> {
    return provisionQueue(`scratch:${key}`, async () => {
      await preflight();
      const name = localScratchName(key);
      scratchByKey.set(key, name);
      const state = await containerState(name);
      if (state) {
        if (!state.running) await startContainer(name);
        activeByContainer.set(name, (activeByContainer.get(name) ?? 0) + 1);
        return { name, coldStart: false };
      }
      await runContainer(name, undefined, false);
      activeByContainer.set(name, (activeByContainer.get(name) ?? 0) + 1);
      return { name, coldStart: true };
    });
  }

  function teardownQueueKey(handle: SandboxHandle): string {
    if (handle.scratch) {
      for (const [k, name] of scratchByKey) if (name === handle.id) return `scratch:${k}`;
      return handle.id;
    }
    return scopeByContainer.get(handle.id) ?? handle.id;
  }

  const profile: AgentComputerProfile = {
    backend: "local-docker",
    writablePersistence: "resident_disk",
    processSessions: true,
    egressEnforcement: "none",
    spec: {
      os: `Debian 12 (bookworm), glibc — local Docker container on a ${arch()} host (dev only)`,
      runtimes: ["Node 24", "Python 3 (venv on PATH — `pip install` just works)"],
      tools: ["git", "curl", "wget", "jq", "unzip", "gnupg", "python3", "gh", "aws (CLI v2)"],
      notInstalled: ["gcloud", "kubectl", "flyctl", "glab"],
      ...(opts.cpus ? { cpus: opts.cpus } : {}),
      ...(opts.memoryMb ? { memoryMb: opts.memoryMb } : {}),
      homeDir,
      workdir: workspaceDir,
    },
  };

  const procIo: ExecProcessIo = {
    async run(handle, command, execOpts): Promise<ExecResult> {
      const timeoutSec = execOpts?.timeoutMs ? Math.ceil(execOpts.timeoutMs / 1000) : defaultTimeoutSec;
      await ensureRunning(handle.id);
      return execRaw(handle.id, command, timeoutSec);
    },
  };
  const procSessions = createExecProcessSessions(procIo);

  const execFileOps = createExecFileOps({
    label: "local",
    exec: (id, script, t) => execRaw(id, script, t),
    writeInline: (id, abs, data) => writeAbsBytes(id, abs, data),
  });

  const execBackup = createExecBackup({
    label: "local",
    exec: (id, script, t) => execRaw(id, script, t),
    readAbsBytes,
    defaultHomeDir: homeDir,
    ephemeralCredentialPrefixes: ephemeralCredLinkPaths().map(({ rel }) => rel),
  });

  const sandbox: Sandbox = {
    profile,
    startProcess: procSessions.startProcess,
    readProcess: procSessions.readProcess,
    writeStdin: procSessions.writeStdin,
    signalProcess: procSessions.signalProcess,
    listProcesses: procSessions.listProcesses,
    ...execFileOps,

    async provision(layers: WorkspaceLayer[], provOpts?: ProvisionOptions): Promise<SandboxHandle> {
      const scratch = provOpts?.scratch;
      const writable = layers.find((l) => l.mode === "rw") ?? layers[0];
      const scope = writable?.scopeId ?? "default";
      const body = scratch ? await ensureScratch(scratch.key) : await ensureContainer(scope);
      const name = body.name;

      const env = provOpts?.env && Object.keys(provOpts.env).length ? provOpts.env : undefined;
      const handle: SandboxHandle = {
        id: name,
        rootDir: workspaceDir,
        homeDir,
        coldStart: body.coldStart,
        ...(scratch ? { scratch: true } : {}),
        ...(env ? { env } : {}),
      };

      try {
        const prep = await execRaw(name, `mkdir -p ${shq(workspaceDir)} && ${ephemeralCredLinkScript(homeDir)}`, 30);
        if (prep.code !== 0) throw new Error(`local sandbox provision prep failed: ${prep.stderr.slice(0, 200)}`);

        await materializeRoLayers(
          workspace,
          layers,
          handle,
          {
            readFile: (h, rel) => sandbox.readFile(h, rel),
            writeFileBytes: (h, rel, data) => sandbox.writeFileBytes(h, rel, data),
            exec: (script, t) => execRaw(name, script, t),
          },
          { manifest: RO_LAYERS_MANIFEST, tar: RO_LAYERS_TAR, label: "local" },
        );

        return handle;
      } catch (err) {
        await sandbox.teardown(handle).catch(swallowAs("local-sandbox: teardown after failed provision", undefined));
        throw err;
      }
    },

    async run(handle, command, execOpts?: ExecOptions): Promise<ExecResult> {
      const timeoutSec = execOpts?.timeoutMs ? Math.ceil(execOpts.timeoutMs / 1000) : defaultTimeoutSec;
      await ensureRunning(handle.id);
      const exports = Object.entries(handle.env ?? {})
        .map(([k, v]) => `export ${k}=${shq(v)}`)
        .join("; ");
      const script = `${nonInteractiveShellPrefix()}${exports ? exports + "; " : ""}cd ${handle.rootDir} 2>/dev/null; ${command}`;
      const signal = execOpts?.signal;
      if (!signal) return execRaw(handle.id, script, timeoutSec);
      const killUid = randomUUID();
      const fireKill = () => {
        execRaw(handle.id, killScript(killUid), 15).catch(swallowAs("local-sandbox: kill in-flight exec", undefined));
      };
      if (signal.aborted) fireKill();
      const onAbort = () => fireKill();
      signal.addEventListener("abort", onAbort, { once: true });
      try {
        return await execRaw(handle.id, killableScript(script, killUid), timeoutSec, signal);
      } finally {
        signal.removeEventListener("abort", onAbort);
      }
    },

    async writeFileBytes(handle, relPath, data): Promise<void> {
      await writeAbsBytes(handle.id, posixJoin(handle.rootDir, relPath), data);
    },
    async writeFile(handle, relPath, data): Promise<void> {
      await sandbox.writeFileBytes(handle, relPath, Buffer.from(data, "utf8"));
    },
    async readFileBytes(handle, relPath): Promise<Uint8Array | null> {
      return readAbsBytes(handle.id, posixJoin(handle.rootDir, relPath));
    },
    async readFile(handle, relPath): Promise<string | null> {
      const bytes = await sandbox.readFileBytes(handle, relPath);
      return bytes === null ? null : Buffer.from(bytes).toString("utf8");
    },

    backupComputer: execBackup.backupComputer,

    async teardown(handle, tdOpts?: TeardownOptions): Promise<void> {
      return provisionQueue(teardownQueueKey(handle), async () => {
        const remaining = (activeByContainer.get(handle.id) ?? 1) - 1;
        if (remaining > 0) {
          activeByContainer.set(handle.id, remaining);
          return;
        }
        activeByContainer.delete(handle.id);

        if (handle.scratch) {
          for (const [k, name] of scratchByKey) if (name === handle.id) scratchByKey.delete(k);
          if (tdOpts?.destroy) await dexec(["rm", "-f", handle.id]);
          else await dexec(["rm", "-f", handle.id]).catch(swallowAs("local-sandbox: scratch rm", undefined));
          await dexec(["network", "rm", localNetworkName(handle.id)]).catch(
            swallowAs("local-sandbox: scratch network rm", undefined),
          );
          portByName.delete(handle.id);
          ipByContainer.delete(handle.id);
          return;
        }

        if (tdOpts?.keepWarm) return;

        if (tdOpts?.destroy) {
          await dexec(["rm", "-f", handle.id]).catch(swallowAs("local-sandbox: destroy rm", undefined));
          await dexec(["network", "rm", localNetworkName(handle.id)]).catch(
            swallowAs("local-sandbox: destroy network rm", undefined),
          );
          const scope = scopeByContainer.get(handle.id);
          if (scope)
            await dexec(["volume", "rm", localVolumeName(scope)]).catch(
              swallowAs("local-sandbox: destroy volume rm", undefined),
            );
          scopeByContainer.delete(handle.id);
          portByName.delete(handle.id);
          ipByContainer.delete(handle.id);
          return;
        }

        const r = await dexec(["stop", "-t", "2", handle.id], 60_000);
        if (r.code !== 0)
          opts.onError?.({
            category: "sandbox_park",
            code: "docker_stop_failed",
            message: r.stderr.trim(),
            ...(scopeByContainer.get(handle.id) ? { scopeLabel: scopeByContainer.get(handle.id)! } : {}),
          });
        portByName.delete(handle.id);
        ipByContainer.delete(handle.id);
      });
    },
  };

  return sandbox;
}
