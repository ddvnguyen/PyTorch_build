import { EventEmitter } from "node:events";
import fs from "node:fs/promises";
import path from "node:path";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import type { BuildConfig, CommandPlan, PipelineRun, PipelineStage } from "./types.js";
import { runsDir } from "./paths.js";
import { createBuildPlan, createCheckoutPlan, createDependencyPlan } from "./commandPlan.js";
import { prepareEnvironment } from "./environment.js";
import { existsSync } from "node:fs";

interface RuntimeRun {
  run: PipelineRun;
  emitter: EventEmitter;
  child?: ChildProcessWithoutNullStreams;
  cancelled: boolean;
}

const stageTemplates: PipelineStage[] = [
  { id: "checkout", label: "Checkout source", status: "pending" },
  { id: "prepare", label: "Prepare env.json", status: "pending" },
  { id: "dependencies", label: "Install dependencies", status: "pending" },
  { id: "build", label: "Build wheel", status: "pending" }
];

export function getCurrentRun(): PipelineRun | null {
  for (const runtime of runs.values()) {
    if (runtime.run.status === "running") {
      return runtime.run;
    }
  }
  return null;
}

function cloneStages(): PipelineStage[] {
  return stageTemplates.map((stage) => ({ ...stage }));
}

function now(): string {
  return new Date().toISOString();
}

function emitStatus(runtime: RuntimeRun, done = false): void {
  runtime.emitter.emit(done ? "done" : "status", runtime.run);
}

function log(runtime: RuntimeRun, message: string): void {
  runtime.emitter.emit("log", message);
}

function setStage(runtime: RuntimeRun, stageId: string, status: PipelineStage["status"]): void {
  const stage = runtime.run.stages.find((item) => item.id === stageId);
  if (!stage) return;
  stage.status = status;
  if (status === "running") stage.startedAt = now();
  if (["succeeded", "failed", "cancelled"].includes(status)) stage.finishedAt = now();
  runtime.run.activeStage = status === "running" ? stageId : runtime.run.activeStage;
  emitStatus(runtime);
}

async function runCommand(runtime: RuntimeRun, plan: CommandPlan): Promise<void> {
  log(runtime, `$ ${plan.command} ${plan.args.join(" ")}`);
  await new Promise<void>((resolve, reject) => {
    const child = spawn(plan.command, plan.args, {
      cwd: plan.cwd,
      env: { ...process.env, ...(plan.env ?? {}) },
      windowsHide: true
    });
    runtime.child = child;

    child.stdout.on("data", (chunk) => log(runtime, String(chunk).trimEnd()));
    child.stderr.on("data", (chunk) => log(runtime, String(chunk).trimEnd()));
    child.on("error", reject);
    child.on("close", (code) => {
      runtime.child = undefined;
      if (runtime.cancelled) reject(new Error("Pipeline cancelled"));
      else if (code === 0) resolve();
      else reject(new Error(`${plan.label} failed with exit code ${code}`));
    });
  });
}

async function runPlans(runtime: RuntimeRun, plans: CommandPlan[]): Promise<void> {
  for (const plan of plans) {
    if (runtime.cancelled) throw new Error("Pipeline cancelled");
    log(runtime, plan.label);
    await runCommand(runtime, plan);
  }
}

async function finish(runtime: RuntimeRun, status: PipelineRun["status"], error?: string): Promise<void> {
  runtime.run.status = status;
  runtime.run.finishedAt = now();
  runtime.run.error = error;

  try {
    const dist = path.join(runtime.run.envJson ? String((runtime.run.envJson as { pytorch_dir?: string }).pytorch_dir ?? "") : "", "dist");
    const wheels = await fs.readdir(dist);
    const wheel = wheels.filter((file) => file.endsWith(".whl")).sort().at(-1);
    if (wheel) runtime.run.artifact = path.join(dist, wheel);
  } catch {
    // Artifact remains pending.
  }

  // Persist run state for future resumption
  await persistRunState(runtime.run);

  emitStatus(runtime, true);
}

async function persistRunState(run: PipelineRun): Promise<void> {
  try {
    const runPath = path.join(runsDir, `${run.id}.json`);
    await fs.writeFile(runPath, JSON.stringify(run, null, 2));
  } catch (error) {
    console.error("Failed to persist run state:", error);
  }
}

async function loadRunState(runId: string): Promise<PipelineRun | null> {
  try {
    const runPath = path.join(runsDir, `${runId}.json`);
    if (!existsSync(runPath)) return null;
    const data = await fs.readFile(runPath, "utf-8");
    return JSON.parse(data) as PipelineRun;
  } catch (error) {
    console.error("Failed to load run state:", error);
    return null;
  }
}

function getStageIndex(stageId: string): number {
  return stageTemplates.findIndex((s) => s.id === stageId);
}

async function isGitRepoValid(config: BuildConfig): Promise<boolean> {
  const repoGitPath = path.join(config.pytorchDir, ".git");
  if (!existsSync(repoGitPath)) return false;

  return new Promise<boolean>((resolve) => {
    const child = spawn("git", ["rev-parse", "--is-inside-work-tree"], {
      cwd: config.pytorchDir,
      windowsHide: true,
      stdio: ["ignore", "ignore", "ignore"]
    });

    child.on("error", () => resolve(false));
    child.on("close", (code) => resolve(code === 0));
  });
}

async function cleanupCheckoutFolder(config: BuildConfig): Promise<void> {
  if (!existsSync(config.pytorchDir)) return;

  const maxAttempts = 5;
  for (let attempt = 1; attempt <= maxAttempts; attempt += 1) {
    try {
      await fs.rm(config.pytorchDir, { recursive: true, force: true });
      return;
    } catch (error) {
      if (attempt === maxAttempts) throw error;
      if (error && typeof error === "object" && "code" in error && (error as any).code === "EBUSY") {
        await new Promise((resolve) => setTimeout(resolve, 250));
        continue;
      }
      throw error;
    }
  }
}

function shouldSkipStage(previousRun: PipelineRun, stageId: string, config: BuildConfig, resumeFromStage?: string): boolean {
  // Don't skip if this is the resume point
  if (resumeFromStage && stageId === resumeFromStage) return false;
  
  // Skip stages before the resume point
  if (resumeFromStage && getStageIndex(stageId) < getStageIndex(resumeFromStage)) {
    return true;
  }

  // Special handling for checkout: only skip if config hasn't changed
  if (stageId === "checkout") {
    const prevConfig = previousRun.buildConfig;
    if (!prevConfig) return false; // Don't skip if we don't have previous config
    
    // If ref or pytorch directory changed, we must re-checkout
    if (prevConfig.selectedRef !== config.selectedRef || prevConfig.pytorchDir !== config.pytorchDir) {
      return false;
    }
  }

  // Skip stages that already succeeded in the previous run
  const stage = previousRun.stages.find((s) => s.id === stageId);
  return stage?.status === "succeeded";
}

async function executePipeline(runtime: RuntimeRun, config: BuildConfig): Promise<void> {
  try {
    let previousRun: PipelineRun | null = null;
    let skippedStages: string[] = [];

    // Load previous run if resuming
    if (config.resumeFromRunId) {
      previousRun = await loadRunState(config.resumeFromRunId);
      if (previousRun) {
        runtime.run.resumedFromRunId = config.resumeFromRunId;
        log(runtime, `Resuming from run ${config.resumeFromRunId}`);
      }
    }

    // Store current build config for future resume operations
    runtime.run.buildConfig = {
      selectedRef: config.selectedRef,
      selectedRefKind: config.selectedRefKind,
      pytorchDir: config.pytorchDir
    };

    // Checkout stage
    if (previousRun && shouldSkipStage(previousRun, "checkout", config, config.resumeFromStage)) {
      const validCheckout = await isGitRepoValid(config);
      if (!validCheckout) {
        log(runtime, "Existing checkout is invalid; cleaning folder and retrying from scratch.");
        await cleanupCheckoutFolder(config);
        previousRun = null;
      }
    }

    if (!previousRun || !shouldSkipStage(previousRun, "checkout", config, config.resumeFromStage)) {
      setStage(runtime, "checkout", "running");
      try {
        await runPlans(runtime, createCheckoutPlan(config));
      } catch (error) {
        log(runtime, `Checkout failed: ${error instanceof Error ? error.message : String(error)}`);
        await cleanupCheckoutFolder(config);
        log(runtime, "Retrying checkout with a fresh clone.");
        await runPlans(runtime, createCheckoutPlan(config, true));
      }
      setStage(runtime, "checkout", "succeeded");
    } else {
      skippedStages.push("checkout");
      const stage = previousRun.stages.find((s) => s.id === "checkout");
      if (stage) {
        const stageIdx = runtime.run.stages.findIndex((s) => s.id === "checkout");
        if (stageIdx !== -1) runtime.run.stages[stageIdx] = { ...stage };
      }
      log(runtime, "Skipping checkout (already succeeded with same ref)");
    }

    // Prepare env.json stage
    let envJson = previousRun?.envJson;
    if (!previousRun || !shouldSkipStage(previousRun, "prepare", config, config.resumeFromStage)) {
      setStage(runtime, "prepare", "running");
      envJson = await prepareEnvironment(config);
      runtime.run.envJson = envJson;
      log(runtime, "Generated src/env.json");
      setStage(runtime, "prepare", "succeeded");
    } else {
      skippedStages.push("prepare");
      const stage = previousRun.stages.find((s) => s.id === "prepare");
      if (stage) {
        const stageIdx = runtime.run.stages.findIndex((s) => s.id === "prepare");
        if (stageIdx !== -1) runtime.run.stages[stageIdx] = { ...stage };
      }
      log(runtime, "Skipping prepare (already succeeded)");
    }

    // Dependencies stage
    if (!previousRun || !shouldSkipStage(previousRun, "dependencies", config, config.resumeFromStage)) {
      setStage(runtime, "dependencies", "running");
      await runPlans(runtime, createDependencyPlan(config));
      setStage(runtime, "dependencies", "succeeded");
    } else {
      skippedStages.push("dependencies");
      const stage = previousRun.stages.find((s) => s.id === "dependencies");
      if (stage) {
        const stageIdx = runtime.run.stages.findIndex((s) => s.id === "dependencies");
        if (stageIdx !== -1) runtime.run.stages[stageIdx] = { ...stage };
      }
      log(runtime, "Skipping dependencies (already succeeded)");
    }

    // Build stage (always run unless explicitly at this stage and skipping)
    if (!previousRun || !shouldSkipStage(previousRun, "build", config, config.resumeFromStage)) {
      setStage(runtime, "build", "running");
      if (!envJson) throw new Error("envJson is required for build stage");
      await runPlans(runtime, createBuildPlan(config, (envJson as any).build.python_executable, (envJson as any).environment));
      setStage(runtime, "build", "succeeded");
    } else {
      skippedStages.push("build");
      const stage = previousRun.stages.find((s) => s.id === "build");
      if (stage) {
        const stageIdx = runtime.run.stages.findIndex((s) => s.id === "build");
        if (stageIdx !== -1) runtime.run.stages[stageIdx] = { ...stage };
      }
      log(runtime, "Skipping build (already succeeded)");
    }

    runtime.run.skippedStages = skippedStages;
    await finish(runtime, "succeeded");
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    const activeStage = runtime.run.activeStage;
    if (activeStage) setStage(runtime, activeStage, runtime.cancelled ? "cancelled" : "failed");
    log(runtime, message);
    await finish(runtime, runtime.cancelled ? "cancelled" : "failed", message);
  }
}

export async function startPipeline(config: BuildConfig): Promise<PipelineRun> {
  await fs.mkdir(runsDir, { recursive: true });
  const id = `${Date.now()}`;
  const runtime: RuntimeRun = {
    run: {
      id,
      status: "running",
      startedAt: now(),
      stages: cloneStages()
    },
    emitter: new EventEmitter(),
    cancelled: false
  };
  runs.set(id, runtime);
  void executePipeline(runtime, config);
  return runtime.run;
}

export function getPipeline(id: string): PipelineRun | undefined {
  return runs.get(id)?.run;
}

export function getRuntime(id: string): RuntimeRun | undefined {
  return runs.get(id);
}

export function cancelPipeline(id: string): PipelineRun | undefined {
  const runtime = runs.get(id);
  if (!runtime) return undefined;
  runtime.cancelled = true;
  runtime.child?.kill();
  runtime.run.status = "cancelled";
  emitStatus(runtime, true);
  return runtime.run;
}

export async function listPreviousRuns(): Promise<PipelineRun[]> {
  try {
    await fs.mkdir(runsDir, { recursive: true });
    const files = await fs.readdir(runsDir);
    const runFiles = files.filter((f) => f.endsWith(".json"));
    const runs: PipelineRun[] = [];

    for (const file of runFiles) {
      try {
        const data = await fs.readFile(path.join(runsDir, file), "utf-8");
        const run = JSON.parse(data) as PipelineRun;
        runs.push(run);
      } catch (error) {
        console.error(`Failed to parse run file ${file}:`, error);
      }
    }

    // Sort by startedAt descending (newest first)
    return runs.sort((a, b) => new Date(b.startedAt).getTime() - new Date(a.startedAt).getTime());
  } catch (error) {
    console.error("Failed to list previous runs:", error);
    return [];
  }
}

export async function getPreviousRun(runId: string): Promise<PipelineRun | null> {
  return loadRunState(runId);
}

export async function getSuccessfulStages(runId: string): Promise<string[]> {
  const run = await loadRunState(runId);
  if (!run) return [];
  return run.stages.filter((s) => s.status === "succeeded").map((s) => s.id);
}
