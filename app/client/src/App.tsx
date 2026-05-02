import { useEffect, useMemo, useState } from "react";
import {
  AlertTriangle,
  Box,
  CheckCircle2,
  Cpu,
  Database,
  GitBranch,
  Loader2,
  Play,
  Square,
  TerminalSquare
} from "lucide-react";
import { api } from "./api";
import type { BuildConfig, BuildOption, EnvironmentStatus, PipelineRun, VersionOption } from "./types";

const cudaVersions = ["13.0", "12.9", "12.8", "12.6", "12.4", "11.8", "cpu"];
const gpuArchitectures = [
  { label: "Blackwell SM 12.0", value: "12.0" },
  { label: "Hopper SM 9.0", value: "9.0" },
  { label: "Ada / Ampere SM 8.9 + 8.6", value: "8.9;8.6" },
  { label: "Turing SM 7.5", value: "7.5" },
  { label: "Volta SM 7.0", value: "7.0" },
  { label: "Pascal SM 6.0 + 6.1", value: "6.0;6.1" },
  { label: "Custom current", value: "custom" }
];

const defaultRun: PipelineRun = {
  id: "idle",
  status: "pending",
  startedAt: "",
  stages: [
    { id: "checkout", label: "Checkout source", status: "pending" },
    { id: "prepare", label: "Prepare env.json", status: "pending" },
    { id: "dependencies", label: "Install dependencies", status: "pending" },
    { id: "build", label: "Build wheel", status: "pending" }
  ]
};

function field<K extends keyof BuildConfig>(
  config: BuildConfig,
  key: K,
  value: BuildConfig[K]
): BuildConfig {
  return { ...config, [key]: value };
}

function statusLabel(status: string): string {
  return status[0].toUpperCase() + status.slice(1);
}

export function App() {
  const [config, setConfig] = useState<BuildConfig | null>(null);
  const [versions, setVersions] = useState<VersionOption[]>([]);
  const [options, setOptions] = useState<BuildOption[]>([]);
  const [environmentStatus, setEnvironmentStatus] = useState<EnvironmentStatus | null>(null);
  const [run, setRun] = useState<PipelineRun>(defaultRun);
  const [logs, setLogs] = useState<string[]>(["Ready"]);
  const [error, setError] = useState<string>("");

  async function refreshEnvironmentStatus() {
    try {
      setEnvironmentStatus(await api.environmentStatus());
    } catch (err: unknown) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  useEffect(() => {
    void Promise.all([api.config(), api.versions()])
      .then(([loadedConfig, versionResponse]) => {
        setConfig(loadedConfig);
        setVersions([...versionResponse.releases, ...versionResponse.tags]);
        void refreshEnvironmentStatus();
      })
      .catch((err: unknown) => setError(err instanceof Error ? err.message : String(err)));
  }, []);

  useEffect(() => {
    if (!config?.selectedRef) return;
    void api
      .buildOptions(config.selectedRef)
      .then((response) => setOptions(response.options))
      .catch((err: unknown) => setError(err instanceof Error ? err.message : String(err)));
  }, [config?.selectedRef]);

  useEffect(() => {
    if (!run.id || run.id === "idle" || run.status === "succeeded" || run.status === "failed") return;

    const events = new EventSource(`/api/pipeline/${run.id}/events`);
    events.addEventListener("log", (event) => {
      setLogs((current) => [...current.slice(-500), event instanceof MessageEvent ? event.data : ""]);
    });
    events.addEventListener("status", (event) => {
      if (event instanceof MessageEvent) setRun(JSON.parse(event.data) as PipelineRun);
    });
    events.addEventListener("done", (event) => {
      if (event instanceof MessageEvent) setRun(JSON.parse(event.data) as PipelineRun);
      events.close();
    });
    events.onerror = () => events.close();

    return () => events.close();
  }, [run.id, run.status]);

  const envPreview = useMemo(() => {
    if (!config) return "{}";
    const preview = {
      selectedRef: config.selectedRef,
      CUDA_HOME: config.cudaRoot,
      CUDNN_ROOT: config.cudnnRoot,
      TORCH_CUDA_ARCH_LIST: config.gpuArchList,
      MAX_JOBS: config.maxJobs,
      ...config.buildOptions,
      ...config.extraEnv
    };
    return JSON.stringify(preview, null, 2);
  }, [config]);

  if (!config) {
    return (
      <main className="loading-shell">
        <Loader2 className="spin" />
        <span>Loading PyTorch Build Console</span>
      </main>
    );
  }

  async function startPipeline() {
    if (!config) return;
    setError("");
    setLogs(["Starting pipeline"]);
    try {
      const saved = await api.saveConfig(config);
      setConfig(saved);
      await refreshEnvironmentStatus();
      const nextRun = await api.startPipeline(saved);
      setRun(nextRun);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function prepareEnvironment() {
    if (!config) return;
    setError("");
    try {
      const saved = await api.saveConfig(config);
      setConfig(saved);
      const result = await api.prepareEnvironment();
      setEnvironmentStatus(result.status);
    } catch (err) {
      setError(err instanceof Error ? err.message : String(err));
    }
  }

  async function cancelPipeline() {
    if (run.id === "idle") return;
    const nextRun = await api.cancelPipeline(run.id);
    setRun(nextRun);
  }

  function updateOption(name: string, value: string) {
    if (!config) return;
    setConfig({
      ...config,
      buildOptions: { ...config.buildOptions, [name]: value }
    });
  }

  return (
    <main className="app-shell">
      <aside className="config-rail">
        <div className="brand-row">
          <Box />
          <div>
            <h1>PyTorch Build Console</h1>
            <p>Local source build runner</p>
          </div>
        </div>

        <label>
          <span>Version</span>
          <select
            value={config.selectedRef}
            onChange={(event) => {
              const selected = versions.find((version) => version.ref === event.target.value);
              setConfig({
                ...config,
                selectedRef: event.target.value,
                selectedRefKind: selected?.kind ?? "tag"
              });
            }}
          >
            {versions.map((version) => (
              <option key={`${version.kind}-${version.ref}`} value={version.ref}>
                {version.name} {version.kind === "release" ? "release" : version.kind}
              </option>
            ))}
          </select>
        </label>

        <label>
          <span>Checkout path</span>
          <input
            value={config.pytorchDir}
            onChange={(event) => setConfig(field(config, "pytorchDir", event.target.value))}
          />
        </label>

        <div className="two-col">
          <label>
            <span>CUDA</span>
            <select
              value={config.cudaVersion}
              onChange={(event) => setConfig(field(config, "cudaVersion", event.target.value))}
            >
              {cudaVersions.map((version) => (
                <option key={version} value={version}>
                  {version}
                </option>
              ))}
            </select>
          </label>
          <label>
            <span>Python</span>
            <input
              value={config.pythonVersion}
              onChange={(event) => setConfig(field(config, "pythonVersion", event.target.value))}
            />
          </label>
        </div>

        <label>
          <span>GPU architecture</span>
          <select
            value={gpuArchitectures.some((arch) => arch.value === config.gpuArchList) ? config.gpuArchList : "custom"}
            onChange={(event) => {
              if (event.target.value !== "custom") setConfig(field(config, "gpuArchList", event.target.value));
            }}
          >
            {gpuArchitectures.map((arch) => (
              <option key={arch.value} value={arch.value}>
                {arch.label}
              </option>
            ))}
          </select>
        </label>

        <label>
          <span>TORCH_CUDA_ARCH_LIST</span>
          <input
            value={config.gpuArchList}
            onChange={(event) => setConfig(field(config, "gpuArchList", event.target.value))}
          />
        </label>

        <label>
          <span>Conda env</span>
          <input
            value={config.condaEnv}
            onChange={(event) => setConfig(field(config, "condaEnv", event.target.value))}
          />
        </label>

        <label>
          <span>CUDA root</span>
          <input value={config.cudaRoot} onChange={(event) => setConfig(field(config, "cudaRoot", event.target.value))} />
        </label>

        <label>
          <span>cuDNN root</span>
          <input value={config.cudnnRoot} onChange={(event) => setConfig(field(config, "cudnnRoot", event.target.value))} />
        </label>

        <section className="env-card compact">
          <div className="section-title">
            <CheckCircle2 size={18} />
            <h3>Environment</h3>
          </div>
          <p className={`env-summary ${environmentStatus?.ready ? "ready" : "not-ready"}`}>
            {environmentStatus?.ready ? "Ready for build" : "Needs attention"}
          </p>
          {environmentStatus?.conda ? (
            <div className="env-tool-row conda-row">
              <span>conda</span>
              <strong>
                {environmentStatus.conda.present ? "available" : "missing"}
                {environmentStatus.conda.bootstrapInstalled ? " (bootstrap)" : ""}
              </strong>
            </div>
          ) : null}
          <div className="env-tool-list">
            {environmentStatus ? (
              Object.entries(environmentStatus.tools)
                .slice(0, 6)
                .map(([name, tool]) => (
                  <div key={name} className="env-tool-row">
                    <span>{name}</span>
                    <strong>{tool.version || (tool.found ? "installed" : "missing")}</strong>
                  </div>
                ))
            ) : (
              <p>Load environment status to review prerequisites.</p>
            )}
          </div>
          {environmentStatus?.issues?.length ? (
            <div className="env-issues">
              {environmentStatus.issues.slice(0, 4).map((issue) => (
                <p key={`${issue.tool}-${issue.message}`} className={`issue ${issue.severity}`}>
                  {issue.message}
                </p>
              ))}
            </div>
          ) : null}
        </section>
      </aside>

      <section className="workflow-panel">
        <header className="top-bar">
          <div>
            <p className="eyebrow">Ready</p>
            <h2>Prepare, install dependencies, build wheel</h2>
          </div>
          <div className="actions">
            <button className="secondary" onClick={prepareEnvironment}>
              <Database size={16} /> Prepare environment
            </button>
            <button className="secondary" onClick={cancelPipeline} disabled={run.status !== "running"}>
              <Square size={16} /> Cancel
            </button>
            <button onClick={startPipeline} disabled={run.status === "running"}>
              <Play size={16} /> Run pipeline
            </button>
          </div>
        </header>

        {error && (
          <div className="error-banner">
            <AlertTriangle size={18} /> {error}
          </div>
        )}

        <div className="stage-grid">
          {run.stages.map((stage, index) => (
            <article className={`stage-card ${stage.status}`} key={stage.id}>
              <div className="stage-index">{index + 1}</div>
              <div>
                <h3>{stage.label}</h3>
                <p>{statusLabel(stage.status)}</p>
              </div>
              {stage.status === "running" ? <Loader2 className="spin" /> : <CheckCircle2 />}
            </article>
          ))}
        </div>

        <section className="options-panel">
          <div className="section-title">
            <Cpu size={18} />
            <h3>Build options</h3>
          </div>
          <div className="option-grid">
            {options.slice(0, 18).map((option) => (
              <label className="option-row" key={option.name}>
                <span>
                  <strong>{option.name}</strong>
                  <small>{option.description}</small>
                </span>
                <input
                  value={config.buildOptions[option.name] ?? option.defaultValue}
                  onChange={(event) => updateOption(option.name, event.target.value)}
                />
              </label>
            ))}
          </div>
        </section>
      </section>

      <aside className="telemetry-panel">
        <section className="log-card">
          <div className="section-title">
            <TerminalSquare size={18} />
            <h3>Live build log</h3>
          </div>
          <pre>{logs.join("\n")}</pre>
        </section>

        <section className="env-card">
          <div className="section-title">
            <Database size={18} />
            <h3>env.json</h3>
          </div>
          <pre>{envPreview}</pre>
        </section>
      </aside>

      <footer className="artifact-strip">
        <span>
          <GitBranch size={16} /> {config.selectedRef}
        </span>
        <span>Status: {statusLabel(run.status)}</span>
        <span>Artifact: {run.artifact ?? "pending"}</span>
      </footer>
    </main>
  );
}
