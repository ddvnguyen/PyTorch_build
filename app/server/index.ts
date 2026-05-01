import express from "express";
import path from "node:path";
import { createServer as createViteServer } from "vite";
import { clientDistPath, isBuiltServer, repoRoot } from "./paths.js";
import { loadBuildOptions, loadVersions } from "./github.js";
import { loadConfig, saveConfig } from "./config.js";
import { cancelPipeline, getPipeline, getRuntime, startPipeline, listPreviousRuns, getPreviousRun, getSuccessfulStages } from "./pipeline.js";
import type { BuildConfig } from "./types.js";

const port = Number(process.env.PORT || 4173);
const app = express();

app.use(express.json({ limit: "1mb" }));

app.get("/api/github/versions", async (_request, response, next) => {
  try {
    response.json(await loadVersions());
  } catch (error) {
    next(error);
  }
});

app.get("/api/github/build-options", async (request, response, next) => {
  try {
    const ref = String(request.query.ref || "main");
    response.json({ options: await loadBuildOptions(ref) });
  } catch (error) {
    next(error);
  }
});

app.get("/api/config", async (_request, response, next) => {
  try {
    response.json(await loadConfig());
  } catch (error) {
    next(error);
  }
});

app.put("/api/config", async (request, response, next) => {
  try {
    response.json(await saveConfig(request.body as BuildConfig));
  } catch (error) {
    next(error);
  }
});

app.post("/api/pipeline/start", async (request, response, next) => {
  try {
    const config = await saveConfig(request.body as BuildConfig);
    response.json(await startPipeline(config));
  } catch (error) {
    next(error);
  }
});

app.post("/api/pipeline/:runId/cancel", (request, response) => {
  const run = cancelPipeline(request.params.runId);
  if (!run) response.status(404).json({ error: "Pipeline run not found" });
  else response.json(run);
});

app.get("/api/pipeline/:runId/status", (request, response) => {
  const run = getPipeline(request.params.runId);
  if (!run) response.status(404).json({ error: "Pipeline run not found" });
  else response.json(run);
});

app.get("/api/pipeline/:runId/events", (request, response) => {
  const runtime = getRuntime(request.params.runId);
  if (!runtime) {
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
    const stages = await getSuccessfulStages(request.params.runId);
    response.json({ stages });
  } catch (error) {
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
  const vite = await createViteServer({
    root: path.join(repoRoot, "app", "client"),
    server: { middlewareMode: true },
    appType: "spa"
  });
  app.use(vite.middlewares);
}

app.listen(port, () => {
  console.log(`PyTorch Build Console listening on http://localhost:${port}`);
});
