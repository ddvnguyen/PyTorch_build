# Architecture: PyTorch Build Automation — Web UI + Node.js Backend

## 1. Purpose

This document extends the original Node.js + TypeScript orchestration architecture to add:

- A **browser-based build dashboard** (client-side React/HTML UI)
- A **Node.js HTTP + WebSocket backend** that runs the builder
- **Granular step checkpointing** — every individual build step has a unique ID and persisted state
- **Batch-windowed retry** — PyTorch's ~7500 compilation steps are grouped into configurable windows (e.g. steps 1–100, 101–200) so failures can be retried at the batch level without restarting from zero
- Full **resumability** across process restarts

---

## 2. System Overview

```
Browser (React UI)
    │  HTTP REST + WebSocket
    ▼
Node.js Backend  (Express + ws)
    ├── BuildOrchestrator
    │     ├── CheckpointStore  (JSON on disk)
    │     ├── StepBatcher      (splits ~7500 steps into windows)
    │     └── PlatformRunner   (Linux / Windows)
    └── LogStreamer            (tail logs → WS → browser)
```

---

## 3. What Is New vs the Original Architecture

| Concern | Original | This Document |
|---|---|---|
| UI | CLI only | Browser dashboard |
| Communication | None (local process) | HTTP REST + WebSocket |
| Step granularity | ~6 coarse phases | Each individual cmake/ninja step |
| Retry | Restart entire build | Retry a specific batch window |
| State persistence | None | `checkpoint.json` on disk |
| Log access | stdout only | Streamed live to browser |
| Parallelism control | `MAX_JOBS` env var | Configurable per run |

---

## 4. Checkpoint Model

Every step in the entire build pipeline — from `git clone` through each of PyTorch's ~7500 compilation units — is represented as a `CheckpointStep`.

```ts
export type StepStatus = "pending" | "running" | "done" | "failed" | "skipped";

export interface CheckpointStep {
  id: string;              // unique, stable across restarts e.g. "compile:0042"
  batchId: string;         // e.g. "compile:b01" (steps 1–100)
  name: string;            // human label
  status: StepStatus;
  startedAt?: number;
  finishedAt?: number;
  exitCode?: number;
  logFile: string;         // path to per-step log
  retryCount: number;
}

export interface BatchWindow {
  id: string;              // e.g. "compile:b01"
  label: string;           // "Compilation steps 1–100"
  stepIds: string[];
  status: StepStatus;
  retryCount: number;
}

export interface CheckpointState {
  runId: string;
  config: BuildConfig;
  platform: PlatformName;
  phases: CheckpointStep[];   // setup / clone / deps / compile / validate
  batches: BatchWindow[];     // compile steps grouped into windows
  createdAt: number;
  updatedAt: number;
}
```

The checkpoint is written to disk atomically after every step transition. On restart, the orchestrator loads the checkpoint and skips all `done` steps, resuming from the first `pending` or `failed` step.

---

## 5. Batch Windowing for Compilation Steps

PyTorch's CMake/Ninja build emits roughly 7500 individual compilation and link steps. Rather than treating this as one monolithic phase, the orchestrator:

1. **Parses** Ninja's build graph (`ninja -t commands`) at plan-time to enumerate every step
2. **Groups** them into windows of configurable size (default `batchSize: 100`)
3. **Runs** each batch as a unit: `ninja -j{maxJobs} -k0 {targets-in-batch}`
4. **Checkpoints** the batch as `done` on success
5. On failure, **retries** that batch up to `maxBatchRetries` times before marking it `failed` and pausing

```ts
export interface BatchConfig {
  batchSize: number;        // default 100
  maxBatchRetries: number;  // default 3
  continueOnBatchFail: boolean; // false = pause; true = skip and continue
}
```

This gives the user a retry button per batch in the UI rather than a binary "restart everything" choice.

---

## 6. Updated Project Structure

```text
pytorch-build-web/
  package.json
  tsconfig.json
  ARCHITECTURE.md

  backend/
    src/
      index.ts                  ← Express + WebSocket server entrypoint
      api/
        routes.ts               ← REST endpoints
        ws-handler.ts           ← WebSocket message handler
      core/
        command.ts              ← spawn wrapper with per-step logging
        logger.ts               ← structured logger
        platform.ts             ← OS detection
        paths.ts                ← path utilities
      build/
        orchestrator.ts         ← top-level build runner
        step-batcher.ts         ← ninja graph parsing + batch windowing
        linux-builder.ts
        windows-builder.ts
        validator.ts
      checkpoint/
        store.ts                ← read/write checkpoint.json atomically
        schema.ts               ← types (CheckpointStep, BatchWindow, …)

  frontend/
    index.html
    src/
      App.tsx
      components/
        BuildControls.tsx       ← start / pause / resume / retry
        PhaseList.tsx           ← coarse phases (clone, deps, compile, …)
        BatchGrid.tsx           ← 75 batch cards (each = 100 steps)
        StepDetail.tsx          ← single step log viewer
        LogStream.tsx           ← live tail of current step output
        StatusBadge.tsx

  configs/
    linux.cpu.json
    linux.cuda.json
    windows.cpu.json
    windows.cuda.json

  logs/                         ← per-step log files land here
  checkpoints/                  ← checkpoint.json per run
```

---

## 7. REST API

| Method | Path | Description |
|---|---|---|
| `POST` | `/api/build/start` | Start a new build from a config |
| `POST` | `/api/build/pause` | Pause after current step |
| `POST` | `/api/build/resume` | Resume from checkpoint |
| `POST` | `/api/build/retry-batch/:batchId` | Retry a specific failed batch |
| `POST` | `/api/build/cancel` | Cancel and clean up |
| `GET`  | `/api/build/status` | Full checkpoint state snapshot |
| `GET`  | `/api/build/log/:stepId` | Fetch log for a specific step |
| `GET`  | `/api/builds` | List past runs (from checkpoints/) |

---

## 8. WebSocket Events

The server pushes events over a single WebSocket connection.

```ts
// Server → Client
type ServerEvent =
  | { type: "step:start";    stepId: string; batchId: string; name: string }
  | { type: "step:done";     stepId: string; batchId: string }
  | { type: "step:failed";   stepId: string; batchId: string; exitCode: number }
  | { type: "batch:start";   batchId: string; label: string }
  | { type: "batch:done";    batchId: string }
  | { type: "batch:failed";  batchId: string; retryCount: number }
  | { type: "log:line";      stepId: string; line: string }
  | { type: "build:paused" }
  | { type: "build:done" }
  | { type: "build:error";   message: string };

// Client → Server
type ClientMessage =
  | { type: "subscribe:log"; stepId: string }
  | { type: "unsubscribe:log" };
```

---

## 9. Checkpoint Store

```ts
import fs from "node:fs";
import path from "node:path";

const CHECKPOINT_DIR = "./checkpoints";

export function loadCheckpoint(runId: string): CheckpointState | null {
  const file = path.join(CHECKPOINT_DIR, `${runId}.json`);
  if (!fs.existsSync(file)) return null;
  return JSON.parse(fs.readFileSync(file, "utf8")) as CheckpointState;
}

export function saveCheckpoint(state: CheckpointState): void {
  fs.mkdirSync(CHECKPOINT_DIR, { recursive: true });
  const file = path.join(CHECKPOINT_DIR, `${state.runId}.json`);
  const tmp = file + ".tmp";
  fs.writeFileSync(tmp, JSON.stringify(state, null, 2), "utf8");
  fs.renameSync(tmp, file); // atomic on POSIX; near-atomic on Windows NTFS
}

export function markStepDone(state: CheckpointState, stepId: string): void {
  const step = state.phases.find(s => s.id === stepId)
             ?? state.batches.flatMap(b => b.stepIds).find(id => id === stepId);
  // update and persist
}
```

---

## 10. Step Batcher

```ts
import { execSync } from "node:child_process";

export function enumerateNinjaSteps(buildDir: string): string[] {
  const raw = execSync("ninja -t commands", { cwd: buildDir }).toString();
  return raw.split("\n").filter(Boolean);
}

export function createBatches(steps: string[], batchSize: number): BatchWindow[] {
  const batches: BatchWindow[] = [];
  for (let i = 0; i < steps.length; i += batchSize) {
    const slice = steps.slice(i, i + batchSize);
    const batchNum = Math.floor(i / batchSize) + 1;
    const id = `compile:b${String(batchNum).padStart(3, "0")}`;
    batches.push({
      id,
      label: `Compilation steps ${i + 1}–${i + slice.length}`,
      stepIds: slice.map((_, j) => `compile:${String(i + j + 1).padStart(4, "0")}`),
      status: "pending",
      retryCount: 0
    });
  }
  return batches;
}
```

---

## 11. Command Runner (with per-step log file)

```ts
import { spawn } from "node:child_process";
import fs from "node:fs";

export function runCommand(
  spec: CommandSpec,
  logFile: string,
  onLine?: (line: string) => void
): Promise<number> {
  return new Promise((resolve, reject) => {
    const out = fs.createWriteStream(logFile, { flags: "a" });
    const child = spawn(spec.command, spec.args, {
      cwd: spec.cwd,
      env: { ...process.env, ...spec.env },
      shell: process.platform === "win32"
    });

    const pump = (data: Buffer) => {
      out.write(data);
      String(data).split("\n").forEach(line => onLine?.(line));
    };

    child.stdout.on("data", pump);
    child.stderr.on("data", pump);
    child.on("error", reject);
    child.on("close", code => {
      out.end();
      resolve(code ?? 1);
    });
  });
}
```

---

## 12. Orchestrator (Resumable)

```ts
export async function runBuild(
  config: BuildConfig,
  runId: string,
  emit: (event: ServerEvent) => void
): Promise<void> {
  let state = loadCheckpoint(runId) ?? createFreshState(runId, config);

  for (const step of state.phases) {
    if (step.status === "done") continue;
    if (step.status === "failed" && step.retryCount >= MAX_RETRIES) {
      emit({ type: "build:error", message: `Step ${step.id} failed after retries` });
      return;
    }

    emit({ type: "step:start", stepId: step.id, batchId: step.batchId, name: step.name });
    step.status = "running";
    step.startedAt = Date.now();
    saveCheckpoint(state);

    const code = await runCommand(step.run, step.logFile, line =>
      emit({ type: "log:line", stepId: step.id, line })
    );

    step.exitCode = code;
    step.finishedAt = Date.now();
    step.status = code === 0 ? "done" : "failed";
    if (code !== 0) step.retryCount++;
    saveCheckpoint(state);

    if (code !== 0) {
      emit({ type: "step:failed", stepId: step.id, batchId: step.batchId, exitCode: code });
      return;
    }
    emit({ type: "step:done", stepId: step.id, batchId: step.batchId });
  }

  // Run compilation batches
  for (const batch of state.batches) {
    if (batch.status === "done") continue;
    await runBatch(batch, state, config, emit);
  }

  await validateBuild(config);
  emit({ type: "build:done" });
}
```

---

## 13. UI Component Map

```
App
├── BuildControls          start | pause | resume | cancel
├── ConfigEditor           JSON editor for build profile
├── ProgressBar            overall % done (steps done / total)
├── PhaseList              clone → deps → compile → validate
│   └── PhaseRow           status badge + duration
├── BatchGrid              75 cards × 100 steps = 7500 steps
│   └── BatchCard          color-coded: pending/running/done/failed
│       └── retry button   per-failed-batch
└── LogPanel
    ├── LogStream          live tail (WebSocket log:line events)
    └── StepDetail         static log for completed/failed step
```

---

## 14. Practical Notes

- The `checkpoint.json` is the source of truth. The UI is a view over it.
- On Windows, run the backend from Developer PowerShell so MSVC is on `PATH`.
- The Ninja step enumeration (`ninja -t commands`) requires a first CMake configure pass before batches can be created. The orchestrator runs CMake configure as a regular setup step, then enumerates and batches before compilation begins.
- `batchSize: 100` is the default. For machines with more RAM and faster I/O, `batchSize: 250` reduces checkpoint overhead.
- Each batch log file accumulates all stdout/stderr from the steps in that batch so failures are inspectable after the fact.
- The WebSocket server broadcasts to all connected clients — safe to open the dashboard on multiple tabs.

---

## 15. Next Implementation Tasks

1. Implement `step-batcher.ts` with real Ninja graph parsing
2. Wire `orchestrator.ts` to emit WS events through `ws-handler.ts`
3. Build `BatchGrid` component with color-coded batch cards
4. Add per-batch retry endpoint and UI button
5. Add config JSON schema validation with `zod`
6. Add prerequisite checker (Git, Python, CMake, Ninja, MSVC/GCC, CUDA)
7. Add estimated time remaining based on rolling step duration
8. Add GitHub Actions YAML export (generate a workflow from the current config)
