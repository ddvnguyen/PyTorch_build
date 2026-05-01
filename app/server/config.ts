import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import type { BuildConfig } from "./types.js";
import { configPath, dataDir, repoRoot } from "./paths.js";

function defaultCudaRoot(): string {
  if (process.platform === "win32") return "C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA";
  return "/usr/local/cuda";
}

function defaultCudnnRoot(): string {
  if (process.platform === "win32") return "C:\\Program Files\\NVIDIA\\CUDNN";
  return "";
}

export function defaultConfig(): BuildConfig {
  const jobs = String(Math.max(1, os.cpus().length - 2));
  return {
    selectedRef: "main",
    selectedRefKind: "branch",
    pytorchDir: path.join(repoRoot, "pytorch"),
    condaEnv: "pytorch-build",
    pythonVersion: "3.12",
    cudaVersion: "12.9",
    cudaRoot: defaultCudaRoot(),
    cudnnRoot: defaultCudnnRoot(),
    magmaDir: "",
    gpuArchList: "6.0;12.0",
    maxJobs: jobs,
    cmakeBuildParallelLevel: jobs,
    buildOptions: {
      USE_CUDA: "1",
      USE_CUDNN: "1",
      USE_DISTRIBUTED: "1",
      USE_MKLDNN: "1",
      USE_FLASH_ATTENTION: "1",
      USE_TEST: "0"
    },
    extraEnv: {},
    skipTest: true,
    forceDependencies: false
  };
}

export async function loadConfig(): Promise<BuildConfig> {
  try {
    const raw = await fs.readFile(configPath, "utf8");
    return { ...defaultConfig(), ...(JSON.parse(raw) as Partial<BuildConfig>) };
  } catch {
    return defaultConfig();
  }
}

export async function saveConfig(config: BuildConfig): Promise<BuildConfig> {
  await fs.mkdir(dataDir, { recursive: true });
  const merged = { ...defaultConfig(), ...config };
  await fs.writeFile(configPath, JSON.stringify(merged, null, 2), "utf8");
  return merged;
}
