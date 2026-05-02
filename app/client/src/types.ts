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

export type ToolStatus = "not_installed" | "installed" | "outdated" | "wrong_version";

export interface ToolVersion {
  found: boolean;
  version?: string;
  path?: string;
  status: ToolStatus;
}

export interface EnvironmentIssue {
  tool: string;
  severity: "info" | "warn" | "error";
  message: string;
}

export interface BuildConfig {
  selectedRef: string;
  selectedRefKind: VersionKind;
  pytorchDir: string;
  condaEnv: string;
  condaExecutable?: string;
  condaInstallRoot?: string;
  condaBootstrapInstalled?: boolean;
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

export interface EnvironmentStatus {
  ready: boolean;
  tools: Record<string, ToolVersion>;
  issues: EnvironmentIssue[];
  conda: {
    present: boolean;
    bootstrapInstalled: boolean;
    executable?: string;
    installRoot?: string;
  };
  selectedToolchain?: Record<string, string>;
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

export interface EnvironmentPrepareResult {
  status: EnvironmentStatus;
  environment: {
    generated_at: string;
    platform: "windows" | "linux";
    pytorch_dir: string;
    conda: {
      env_name: string;
      python_executable: string;
      prefix: string;
      python_version: string;
      executable?: string;
      install_root?: string;
      bootstrap_installed?: boolean;
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
  };
}
