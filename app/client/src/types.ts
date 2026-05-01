export type VersionKind = "release" | "tag" | "branch";

export interface VersionOption {
  name: string;
  ref: string;
  kind: VersionKind;
  publishedAt?: string;
  isLatest?: boolean;
}

export interface BuildOption {
  name: string;
  defaultValue: string;
  description: string;
  category: string;
  source: "curated" | "parsed";
}

export interface BuildConfig {
  selectedRef: string;
  selectedRefKind: VersionKind;
  pytorchDir: string;
  condaEnv: string;
  pythonVersion: string;
  cudaVersion: string;
  cudaRoot: string;
  cudnnRoot: string;
  magmaDir: string;
  gpuArchList: string;
  maxJobs: string;
  cmakeBuildParallelLevel: string;
  buildOptions: Record<string, string>;
  extraEnv: Record<string, string>;
  skipTest: boolean;
  forceDependencies: boolean;
}

export type StageStatus = "pending" | "running" | "succeeded" | "failed" | "cancelled";

export interface PipelineStage {
  id: string;
  label: string;
  status: StageStatus;
  startedAt?: string;
  finishedAt?: string;
}

export interface PipelineRun {
  id: string;
  status: StageStatus;
  startedAt: string;
  finishedAt?: string;
  activeStage?: string;
  stages: PipelineStage[];
  artifact?: string;
  error?: string;
  envJson?: unknown;
}

export interface VersionsResponse {
  releases: VersionOption[];
  tags: VersionOption[];
  defaultRef: string;
}
