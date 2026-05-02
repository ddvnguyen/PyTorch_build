export type VersionKind = "release" | "tag" | "branch";
export type StageStatus = "pending" | "running" | "succeeded" | "failed" | "cancelled";

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
  resumeFromStage?: string;
  resumeFromRunId?: string;
  selectedToolchain?: Record<string, string>;
}

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
  resumedFromRunId?: string;
  skippedStages?: string[];
  error?: string;
  envJson?: unknown;
  buildConfig?: {
    selectedRef: string;
    selectedRefKind: VersionKind;
    pytorchDir: string;
  };
}

export interface CommandPlan {
  command: string;
  args: string[];
  cwd?: string;
  env?: Record<string, string>;
  label: string;
}

export interface BuildEnvironment {
  generated_at: string;
  platform: "windows" | "linux";
  pytorch_dir: string;
  conda: {
    env_name: string;
    python_executable: string;
    prefix: string;
    python_version: string;
  };
  cuda: {
    version: string;
    cuda_home: string;
    cudnn_root: string;
    magma_dir: string;
  };
  toolchain: Record<string, string>;
  build: {
    working_directory: string;
    python_executable: string;
    command: string[];
    cleanup_paths: string[];
  };
  environment: Record<string, string>;
}
