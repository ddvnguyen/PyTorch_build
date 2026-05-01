import { EventEmitter } from "node:events";
import fs from "node:fs/promises";
import path from "node:path";
import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import type { BuildConfig, CommandPlan, PipelineRun, PipelineStage } from "./types.js";
import { runsDir } from "./paths.js";
import { createBuildPlan, createCheckoutPlan, createDependencyPlan } from "./commandPlan.js";
import { prepareEnvironment } from "./environment.js";

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

const runs = new Map<string, RuntimeRun>();

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

  emitStatus(runtime, true);
}

async function executePipeline(runtime: RuntimeRun, config: BuildConfig): Promise<void> {
  try {
    setStage(runtime, "checkout", "running");
    await runPlans(runtime, createCheckoutPlan(config));
    setStage(runtime, "checkout", "succeeded");

    setStage(runtime, "prepare", "running");
    const envJson = await prepareEnvironment(config);
    runtime.run.envJson = envJson;
    log(runtime, "Generated src/env.json");
    setStage(runtime, "prepare", "succeeded");

    setStage(runtime, "dependencies", "running");
    await runPlans(runtime, createDependencyPlan(config));
    setStage(runtime, "dependencies", "succeeded");

    setStage(runtime, "build", "running");
    await runPlans(runtime, createBuildPlan(config, envJson.build.python_executable, envJson.environment));
    setStage(runtime, "build", "succeeded");

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
