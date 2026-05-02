import express from "express";
import path from "node:path";
import { createServer as createViteServer } from "vite";
import { clientDistPath, isBuiltServer, repoRoot } from "./paths.js";
import { loadBuildOptions, loadVersions } from "./github.js";
import { loadConfig, saveConfig } from "./config.js";
import { cancelPipeline, getPipeline, getRuntime, startPipeline, listPreviousRuns, getPreviousRun, getSuccessfulStages, getCurrentRun } from "./pipeline.js";
import { detectEnvironment, getAvailableToolchains, prepareEnvironmentWithStatus } from "./environment.js";
import type { BuildConfig } from "./types.js";

const port = Number(process.env.PORT || 4173);
const app = express();

app.use(express.json({ limit: "1mb" }));

// Middleware to log all incoming requests
app.use((req, res, next) => {
  console.log(`[${new Date().toISOString()}] ${req.method} ${req.url}`);
  next();
});

app.get("/api/github/versions", async (_request, response, next) => {
  try {
    console.log("[SERVER] Fetching GitHub versions...");
    const versions = await loadVersions();
    console.log("[SERVER] Successfully fetched versions");
    response.json(versions);
  } catch (error) {
    console.error("[SERVER] Error fetching GitHub versions:", error);
    next(error);
  }
});

app.get("/api/github/build-options", async (request, response, next) => {
  try {
    const ref = String(request.query.ref || "main");
    console.log(`[SERVER] Fetching build options for ref: ${ref}`);
    const options = await loadBuildOptions(ref);
    response.json({ options });
  } catch (error) {
    console.error("[SERVER] Error fetching build options:", error);
    next(error);
  }
});

app.get("/api/config", async (_request, response, next) => {
  try {
    console.log("[SERVER] Loading configuration...");
    const config = await loadConfig();
    response.json(config);
  } catch (error) {
    console.error("[SERVER] Error loading config:", error);
    next(error);
  }
});

app.get("/api/environment/status", async (_request, response, next) => {
  try {
    const config = await loadConfig();
    response.json(await detectEnvironment(config));
  } catch (error) {
    next(error);
  }
});

app.post("/api/environment/prepare", async (_request, response, next) => {
  try {
    const config = await loadConfig();
    const result = await prepareEnvironmentWithStatus(config);
    response.json(result);
  } catch (error) {
    next(error);
  }
});

app.put("/api/config", async (request, response, next) => {
  try {
    console.log("[SERVER] Updating configuration...");
    const updatedConfig = await saveConfig(request.body as BuildConfig);
    console.log("[SERVER] Configuration updated successfully");
    response.json(updatedConfig);
  } catch (error) {
    console.error("[SERVER] Error updating config:", error);
    next(error);
  }
});

app.post("/api/pipeline/start", async (request, response, next) => {
  try {
    console.log("[SERVER] Starting new pipeline run with config:", request.body);
    const config = await saveConfig(request.body as BuildConfig);
    const run = await startPipeline(config);
    console.log("[SERVER] Pipeline started. Run ID:", run.id);
    response.json(run);
  } catch (error) {
    console.error("[SERVER] Error starting pipeline:", error);
    next(error);
  }
});

app.post("/api/pipeline/:runId/cancel", (request, response) => {
  console.log(`[SERVER] Attempting to cancel pipeline run: ${request.params.runId}`);
  const run = cancelPipeline(request.params.runId);
  if (!run) {
    console.warn(`[SERVER] Cancel failed: Run ${request.params.runId} not found`);
    response.status(404).json({ error: "Pipeline run not found" });
  } else {
    console.log(`[SERVER] Pipeline run ${request.params.runId} cancelled`);
    response.json(run);
  }
});

app.get("/api/pipeline/:runId/status", (request, response) => {
  const run = getPipeline(request.params.runId);
  if (!run) {
    console.warn(`[SERVER] Status check failed: Run ${request.params.runId} not found`);
    response.status(404).json({ error: "Pipeline run not found" });
  } else {
    response.json(run);
  }
});

app.get("/api/pipeline/:runId/events", (request, response, next) => {
  console.log(`[SERVER] SSE connection established for run: ${request.params.runId}`);
  const runtime = getRuntime(request.params.runId);
  if (!runtime) {
    console.warn(`[SERVER] Runtime not found for run: ${request.params.runId}`);
    response.status(404).end();
    return;
  }

  response.setHeader("Content-Type", "text/event-stream");
  response.setHeader("Cache-Control", "no-cache");
  response.setHeader("Connection", "keep-alive");
  response.flushHeaders();

  const send = (event: string, payload: unknown) => {
    response.write(`event: ${event}\n`);
    response.write(`data: ${typeof payload === "string" ? payload : JSON.stringify(payload)}\n\n`);
  };

  const onLog = (line: string) => send("log", line);
  const onStatus = (run: unknown) => send("status", run);
  const onDone = (run: unknown) => send("done", run);

  runtime.emitter.on("log", onLog);
  runtime.emitter.on("status", onStatus);
  runtime.emitter.on("done", onDone);
  send("status", runtime.run);

  request.on("close", () => {
    runtime.emitter.off("log", onLog);
    runtime.emitter.off("status", onStatus);
    runtime.emitter.off("done", onDone);
  });
});

app.get("/api/pipeline/previous-runs", async (_request, response, next) => {
  try {
    const runs = await listPreviousRuns();
    response.json(runs);
  } catch (error) {
    next(error);
  }
});

app.get("/api/pipeline/:runId/previous", async (request, response, next) => {
  try {
    const run = await getPreviousRun(request.params.runId);
    if (!run) response.status(404).json({ error: "Previous run not found" });
    else response.json(run);
  } catch (error) {
    next(error);
  }
});

app.get("/api/pipeline/:runId/successful-stages", async (request, response, next) => {
  try {
    console.log(`[SERVER] Fetching successful stages for: ${request.params.runId}`);
    const stages = await getSuccessfulStages(request.params.runId);
    response.json({ stages });
  } catch (error) {
    console.error("[SERVER] Error fetching successful stages:", error);
    next(error);
  }
});

app.get("/api/pipeline/current", async (_request, response, next) => {
  try {
    console.log("[SERVER] Fetching current pipeline run...");
    const currentRun = getCurrentRun();
    if (currentRun) {
      console.log(`[SERVER] Found current run: ${currentRun.id}`);
      response.json(currentRun);
    } else {
      console.log("[SERVER] No current running pipeline");
      response.status(404).json({ error: "No current pipeline run" });
    }
  } catch (error) {
    console.error("[SERVER] Error fetching current run:", error);
    next(error);
  }
});

app.get("/api/toolchains", async (_request, response, next) => {
  try {
    console.log("[SERVER] Fetching available toolchains...");
    const toolchains = await getAvailableToolchains();
    response.json({ toolchains });
  } catch (error) {
    console.error("[SERVER] Error fetching toolchains:", error);
    next(error);
  }
});

app.use((error: unknown, _request: express.Request, response: express.Response, _next: express.NextFunction) => {
  const message = error instanceof Error ? error.message : String(error);
  response.status(500).json({ error: message });
});

if (isBuiltServer || process.env.NODE_ENV === "production") {
  app.use(express.static(clientDistPath));
  app.use((_request, response) => {
    response.sendFile(path.join(clientDistPath, "index.html"));
  });
} else {
  // In development, we don't use vite middleware here. 
  // The client is served by the vite dev server.
  // This server only handles API requests.
}

app.listen(port, () => {
  console.log(`PyTorch Build Console API listening on http://localhost:${port}`);
});
