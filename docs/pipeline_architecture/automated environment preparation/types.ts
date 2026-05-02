// ─── Core types for Windows PyTorch environment automation ───────────────────

export type Backend = "cuda" | "rocm" | "cpu";
export type InstallMethod = "winget" | "exe_silent" | "conda" | "pip" | "manual";
export type InstallStatus = "not_installed" | "installed" | "outdated" | "wrong_version";

export interface ToolVersion {
  found: boolean;
  version?: string;
  path?: string;
  status: InstallStatus;
}

export interface EnvConfig {
  backend: Backend;
  cudaVersion?: string;       // e.g. "12.4"
  cudnnVersion?: string;      // e.g. "9.2"
  pythonVersion: string;      // e.g. "3.11"
  condaEnvName: string;
  vsVersion: "2019" | "2022";
  maxJobs: number;
  workDir: string;
}

export interface InstallStep {
  id: string;
  name: string;
  description: string;
  method: InstallMethod;
  required: boolean;
  checkFn: () => Promise<ToolVersion>;
  installFn: (cfg: EnvConfig) => Promise<void>;
  verifyFn: () => Promise<boolean>;
  rebootRequired?: boolean;
  mustPrecedeIds?: string[];   // steps that must run before this one
}

export interface EnvReport {
  timestamp: string;
  config: EnvConfig;
  tools: Record<string, ToolVersion>;
  envVars: Record<string, string>;
  ready: boolean;
  issues: string[];
}
