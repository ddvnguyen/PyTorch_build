import type {
  BuildConfig,
  BuildOption,
  EnvironmentPrepareResult,
  EnvironmentStatus,
  PipelineRun,
  VersionsResponse
} from "./types";

async function request<T>(path: string, init?: RequestInit): Promise<T> {
  const response = await fetch(path, {
    headers: { "Content-Type": "application/json", ...(init?.headers ?? {}) },
    ...init
  });

  if (!response.ok) {
    const body = await response.text();
    throw new Error(body || `${response.status} ${response.statusText}`);
  }

  return (await response.json()) as T;
}

export const api = {
  versions: () => request<VersionsResponse>("/api/github/versions"),
  buildOptions: (ref: string) =>
    request<{ options: BuildOption[] }>(`/api/github/build-options?ref=${encodeURIComponent(ref)}`),
  environmentStatus: () => request<EnvironmentStatus>("/api/environment/status"),
  prepareEnvironment: () => request<EnvironmentPrepareResult>("/api/environment/prepare", { method: "POST" }),
  config: () => request<BuildConfig>("/api/config"),
  saveConfig: (config: BuildConfig) =>
    request<BuildConfig>("/api/config", { method: "PUT", body: JSON.stringify(config) }),
  startPipeline: (config: BuildConfig) =>
    request<PipelineRun>("/api/pipeline/start", { method: "POST", body: JSON.stringify(config) }),
  cancelPipeline: (runId: string) =>
    request<PipelineRun>(`/api/pipeline/${runId}/cancel`, { method: "POST" }),
  status: (runId: string) => request<PipelineRun>(`/api/pipeline/${runId}/status`)
};
