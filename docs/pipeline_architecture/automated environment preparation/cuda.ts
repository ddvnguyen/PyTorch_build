import path from "node:path";
import fs from "node:fs";
import { EnvConfig } from "../core/types.js";
import { spawnAndWait, downloadFile, setSystemEnvVar, appendToSystemPath } from "../core/shell.js";
import { detectCuda, detectCudnn } from "../detect/detect.js";

// ─── CUDA Toolkit download URLs ───────────────────────────────────────────────
//
// The .exe network installer is the smallest download (~50MB).
// It downloads only selected subpackages at install time.
// Format: cuda_<version>_<driver>_windows.exe
//
// NVIDIA also provides direct .exe local installers (~3GB) for air-gapped installs.

const CUDA_DOWNLOAD_BASE = "https://developer.download.nvidia.com/compute/cuda/";

const CUDA_VERSIONS: Record<string, { exe: string; subpackages: string[] }> = {
  "12.4": {
    exe: `${CUDA_DOWNLOAD_BASE}12.4.0/network_installers/cuda_12.4.0_windows_network.exe`,
    subpackages: [
      "nvcc_12.4",
      "visual_studio_integration_12.4",
      "cublas_12.4",
      "cublas_dev_12.4",
      "cudart_12.4",
      "cuobjdump_12.4",
      "cupti_12.4",
      "nvtx_12.4",          // REQUIRED for PyTorch — Nsight Compute
      "nvml_dev_12.4",
      "thrust_12.4",
    ],
  },
  "12.6": {
    exe: `${CUDA_DOWNLOAD_BASE}12.6.2/network_installers/cuda_12.6.2_windows_network.exe`,
    subpackages: [
      "nvcc_12.6", "visual_studio_integration_12.6",
      "cublas_12.6", "cublas_dev_12.6", "cudart_12.6",
      "cuobjdump_12.6", "cupti_12.6", "nvtx_12.6", "nvml_dev_12.6", "thrust_12.6",
    ],
  },
  "12.8": {
    exe: `${CUDA_DOWNLOAD_BASE}12.8.0/network_installers/cuda_12.8.0_windows_network.exe`,
    subpackages: [
      "nvcc_12.8", "visual_studio_integration_12.8",
      "cublas_12.8", "cublas_dev_12.8", "cudart_12.8",
      "cuobjdump_12.8", "cupti_12.8", "nvtx_12.8", "nvml_dev_12.8", "thrust_12.8",
    ],
  },
};

// ─── Install CUDA Toolkit via silent .exe ─────────────────────────────────────
//
// Silent mode: cuda_xxx.exe -s [subpackage1] [subpackage2] ...
// -n  = no automatic reboot
// -s  = silent (no UI)
// Subpackages: install only what PyTorch needs (saves time vs full 3GB install)
//
// IMPORTANT: Visual Studio must be installed BEFORE CUDA so that
// visual_studio_integration subpackage can register itself.

export async function installCudaToolkit(cfg: EnvConfig): Promise<void> {
  const version = cfg.cudaVersion ?? "12.4";
  const cudaSpec = CUDA_VERSIONS[version];

  if (!cudaSpec) {
    throw new Error(
      `No download spec for CUDA ${version}. Available: ${Object.keys(CUDA_VERSIONS).join(", ")}`
    );
  }

  const existing = detectCuda();
  if (existing.found && existing.version?.startsWith(version)) {
    console.log(`  CUDA ${version} already installed at ${existing.path} — skipping.`);
    return;
  }

  // Download the network installer
  const installerPath = path.join(cfg.workDir, `cuda_${version}_network.exe`);
  if (!fs.existsSync(installerPath)) {
    await downloadFile(cudaSpec.exe, installerPath);
  }

  // Silent install with only the subpackages PyTorch needs
  const subpkgArgs = cudaSpec.subpackages;
  console.log(`  Installing CUDA ${version} silently (subpackages: ${subpkgArgs.length})...`);
  console.log("  This takes 5-15 minutes depending on internet speed...");

  const code = await spawnAndWait(installerPath, [
    "-s",           // silent
    "-n",           // no auto-reboot
    ...subpkgArgs,
  ], { logFile: `logs/cuda-${version}-install.log` });

  // CUDA installer exit codes: 0=success, 1=reboot needed, others=error
  if (code > 1) {
    throw new Error(`CUDA installer exited with code ${code}. Check logs/cuda-${version}-install.log`);
  }

  // Set environment variables
  const cudaPath = `C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA\\v${version}`;
  setSystemEnvVar("CUDA_PATH", cudaPath);
  setSystemEnvVar("CUDA_HOME", cudaPath);
  appendToSystemPath(`${cudaPath}\\bin`);
  appendToSystemPath(`${cudaPath}\\libnvvp`);

  console.log(`  CUDA ${version} installed. CUDA_PATH=${cudaPath}`);

  if (code === 1) {
    console.warn("  [WARN] Reboot required to complete CUDA installation.");
  }
}

// ─── Alternative: Install CUDA via conda (per-env, no admin needed) ───────────
//
// PyTorch CI uses system CUDA, but for local development, conda CUDA is
// more flexible and doesn't require admin rights.
// Trade-off: only works inside the conda env, not system-wide.

export async function installCudaViaConda(cfg: EnvConfig): Promise<void> {
  const version = cfg.cudaVersion ?? "12.4";
  const [major, minor] = version.split(".");

  console.log(`  Installing CUDA ${version} via conda (no admin required)...`);

  const code = await spawnAndWait("conda", [
    "install", "-y",
    "-c", `nvidia/label/cuda-${version}.0`,
    "-c", "nvidia",
    "cuda",
  ], { logFile: `logs/cuda-conda-install.log` });

  if (code !== 0) {
    throw new Error(`conda CUDA install failed with code ${code}`);
  }

  // Set CMAKE_PREFIX_PATH so CMake finds conda CUDA
  const condaPrefix = process.env.CONDA_PREFIX ?? "";
  process.env.CUDA_HOME = condaPrefix;
  process.env.CUDA_PATH = condaPrefix;

  console.log(`  CUDA ${version} installed into conda env.`);
}

// ─── cuDNN Installation ───────────────────────────────────────────────────────
//
// cuDNN options (in order of preference for automation):
//
//   1. conda install -c nvidia cudnn         ← Easiest, no NVIDIA account needed
//   2. pip install nvidia-cudnn-cu12         ← pip, pinned to CUDA 12.x
//   3. Manual zip extract into CUDA dir      ← Requires NVIDIA developer account
//
// PyTorch's own CI uses cuDNN installed into the Docker image's CUDA dir.
// For Windows automation, conda is the most reliable path.

export async function installCudnnViaConda(cfg: EnvConfig): Promise<void> {
  const existing = detectCudnn();
  if (existing.found) {
    console.log(`  cuDNN ${existing.version} already present — skipping.`);
    return;
  }

  console.log("  Installing cuDNN via conda (nvidia channel)...");

  const cudnnVersion = cfg.cudnnVersion;
  const pkgSpec = cudnnVersion ? `cudnn=${cudnnVersion}` : "cudnn";

  const code = await spawnAndWait("conda", [
    "install", "-y",
    "-c", "nvidia",
    pkgSpec,
  ], { logFile: "logs/cudnn-conda-install.log" });

  if (code !== 0) throw new Error(`cuDNN conda install failed with code ${code}`);

  console.log("  cuDNN installed via conda.");
}

export async function installCudnnViaPip(cfg: EnvConfig): Promise<void> {
  const cudaVersion = cfg.cudaVersion ?? "12";
  const major = cudaVersion.split(".")[0];

  console.log(`  Installing nvidia-cudnn-cu${major} via pip...`);

  const code = await spawnAndWait("pip", [
    "install", `nvidia-cudnn-cu${major}`,
  ], { logFile: "logs/cudnn-pip-install.log" });

  if (code !== 0) throw new Error(`pip cuDNN install failed with code ${code}`);
}

// ─── Extract cuDNN from .zip (manual download path) ──────────────────────────
//
// If the user has downloaded the cuDNN zip from developer.nvidia.com,
// this copies the headers + libs into the CUDA toolkit directory.

export async function extractCudnnZip(zipPath: string, cudaPath: string): Promise<void> {
  if (!fs.existsSync(zipPath)) {
    throw new Error(`cuDNN zip not found: ${zipPath}`);
  }

  console.log(`  Extracting cuDNN from ${path.basename(zipPath)} into ${cudaPath}...`);

  const extractDir = path.join(path.dirname(zipPath), "cudnn_extracted");
  fs.mkdirSync(extractDir, { recursive: true });

  // Use PowerShell Expand-Archive
  const code = await spawnAndWait("powershell", [
    "-Command",
    `Expand-Archive -Path '${zipPath}' -DestinationPath '${extractDir}' -Force`,
  ]);

  if (code !== 0) throw new Error("cuDNN zip extraction failed");

  // Copy bin/include/lib into CUDA dir
  const subdirs = ["bin", "include", "lib"];
  for (const sub of subdirs) {
    const src = path.join(extractDir, "cuda", sub);
    const dst = path.join(cudaPath, sub);
    if (fs.existsSync(src)) {
      await spawnAndWait("robocopy", [src, dst, "/E", "/NP", "/NFL", "/NDL"]);
      // robocopy exit codes < 8 are success
    }
  }

  console.log("  cuDNN extracted and merged into CUDA toolkit directory.");
}

export async function verifyCuda(): Promise<boolean> {
  const cuda = detectCuda();
  if (!cuda.found) return false;

  const code = await spawnAndWait("nvcc", ["--version"], { stdio: "pipe" } as any);
  return code === 0;
}
