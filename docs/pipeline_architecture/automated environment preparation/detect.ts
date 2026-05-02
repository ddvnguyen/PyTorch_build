import fs from "node:fs";
import path from "node:path";
import { ToolVersion } from "../core/types.js";
import { runPS, getVersionOutput, commandExists } from "../core/shell.js";

// ─── NVIDIA Driver ────────────────────────────────────────────────────────────

export function detectNvidiaDriver(): ToolVersion {
  const out = getVersionOutput("nvidia-smi --query-gpu=driver_version --format=csv,noheader");
  if (!out) return { found: false, status: "not_installed" };
  return { found: true, version: out.trim().split("\n")[0], path: "nvidia-smi", status: "installed" };
}

// ─── CUDA Toolkit ─────────────────────────────────────────────────────────────

export function detectCuda(): ToolVersion {
  const out = getVersionOutput("nvcc --version");
  if (!out) {
    // Also check registry
    try {
      const reg = runPS(
        `(Get-ItemProperty 'HKLM:\\SOFTWARE\\NVIDIA Corporation\\GPU Computing Toolkit\\CUDA' -ErrorAction SilentlyContinue).Version`
      );
      if (reg && reg.length > 0) {
        return { found: true, version: reg.trim(), path: process.env.CUDA_PATH, status: "installed" };
      }
    } catch {}
    return { found: false, status: "not_installed" };
  }

  const match = out.match(/release (\d+\.\d+)/);
  const version = match?.[1];
  const cudaPath = process.env.CUDA_PATH ||
    `C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA\\v${version}`;

  return { found: true, version, path: cudaPath, status: "installed" };
}

// ─── cuDNN ────────────────────────────────────────────────────────────────────

export function detectCudnn(cudaPath?: string): ToolVersion {
  const searchPaths = [
    cudaPath ? path.join(cudaPath, "include", "cudnn_version.h") : null,
    `C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA\\v12.4\\include\\cudnn_version.h`,
    `C:\\Program Files\\NVIDIA\\CUDNN\\v9\\include\\cudnn_version.h`,
  ].filter(Boolean) as string[];

  for (const p of searchPaths) {
    if (fs.existsSync(p)) {
      const content = fs.readFileSync(p, "utf8");
      const major = content.match(/#define CUDNN_MAJOR (\d+)/)?.[1];
      const minor = content.match(/#define CUDNN_MINOR (\d+)/)?.[1];
      const patch = content.match(/#define CUDNN_PATCHLEVEL (\d+)/)?.[1];
      if (major) {
        return {
          found: true,
          version: `${major}.${minor}.${patch}`,
          path: path.dirname(path.dirname(p)),
          status: "installed",
        };
      }
    }
  }

  // Check conda env
  const condaPrefix = process.env.CONDA_PREFIX;
  if (condaPrefix) {
    const condaCudnn = path.join(condaPrefix, "Library", "include", "cudnn_version.h");
    if (fs.existsSync(condaCudnn)) {
      const content = fs.readFileSync(condaCudnn, "utf8");
      const major = content.match(/#define CUDNN_MAJOR (\d+)/)?.[1];
      return { found: true, version: major, path: condaPrefix, status: "installed" };
    }
  }

  return { found: false, status: "not_installed" };
}

// ─── Visual Studio / MSVC ─────────────────────────────────────────────────────

export function detectMSVC(): ToolVersion {
  const paths = [
    "C:\\Program Files\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\MSVC",
    "C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Tools\\MSVC",
    "C:\\Program Files\\Microsoft Visual Studio\\2022\\Professional\\VC\\Tools\\MSVC",
    "C:\\Program Files (x86)\\Microsoft Visual Studio\\2019\\BuildTools\\VC\\Tools\\MSVC",
  ];

  for (const p of paths) {
    if (fs.existsSync(p)) {
      const versions = fs.readdirSync(p).filter((d) => /^\d+\./.test(d)).sort().reverse();
      if (versions.length > 0) {
        return { found: true, version: versions[0], path: path.join(p, versions[0]), status: "installed" };
      }
    }
  }

  // Try where cl.exe
  const clOut = getVersionOutput("where.exe cl.exe");
  if (clOut) {
    return { found: true, path: clOut.split("\n")[0].trim(), status: "installed" };
  }

  return { found: false, status: "not_installed" };
}

// ─── vcvarsall.bat location ───────────────────────────────────────────────────

export function detectVcvarsall(): ToolVersion {
  const candidates = [
    "C:\\Program Files\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvarsall.bat",
    "C:\\Program Files\\Microsoft Visual Studio\\2022\\Community\\VC\\Auxiliary\\Build\\vcvarsall.bat",
    "C:\\Program Files\\Microsoft Visual Studio\\2022\\Professional\\VC\\Auxiliary\\Build\\vcvarsall.bat",
    "C:\\Program Files (x86)\\Microsoft Visual Studio\\2019\\BuildTools\\VC\\Auxiliary\\Build\\vcvarsall.bat",
  ];

  for (const p of candidates) {
    if (fs.existsSync(p)) {
      return { found: true, path: p, status: "installed" };
    }
  }
  return { found: false, status: "not_installed" };
}

// ─── CMake ────────────────────────────────────────────────────────────────────

export function detectCMake(): ToolVersion {
  const out = getVersionOutput("cmake --version");
  if (!out) return { found: false, status: "not_installed" };
  const match = out.match(/cmake version (\d+\.\d+\.\d+)/);
  const version = match?.[1];
  // Warn if 3.30+ (known Ninja breakage)
  const [major, minor] = (version ?? "0.0").split(".").map(Number);
  const status = major === 3 && minor >= 30 ? "outdated" : "installed";
  return { found: true, version, status };
}

// ─── Ninja ───────────────────────────────────────────────────────────────────

export function detectNinja(): ToolVersion {
  const out = getVersionOutput("ninja --version");
  if (!out) return { found: false, status: "not_installed" };
  return { found: true, version: out.trim(), status: "installed" };
}

// ─── Python ──────────────────────────────────────────────────────────────────

export function detectPython(): ToolVersion {
  const out = getVersionOutput("python --version");
  if (!out) return { found: false, status: "not_installed" };
  const match = out.match(/Python (\d+\.\d+\.\d+)/);
  return { found: true, version: match?.[1], status: "installed" };
}

// ─── Conda ───────────────────────────────────────────────────────────────────

export function detectConda(): ToolVersion {
  const out = getVersionOutput("conda --version");
  if (!out) return { found: false, status: "not_installed" };
  const match = out.match(/conda (\d+\.\d+\.\d+)/);
  return { found: true, version: match?.[1], status: "installed" };
}

// ─── Git ─────────────────────────────────────────────────────────────────────

export function detectGit(): ToolVersion {
  const out = getVersionOutput("git --version");
  if (!out) return { found: false, status: "not_installed" };
  const match = out.match(/git version (\S+)/);
  return { found: true, version: match?.[1], status: "installed" };
}

// ─── sccache ─────────────────────────────────────────────────────────────────

export function detectSccache(): ToolVersion {
  const out = getVersionOutput("sccache --version");
  if (!out) return { found: false, status: "not_installed" };
  return { found: true, version: out.trim(), status: "installed" };
}

// ─── Winget ──────────────────────────────────────────────────────────────────

export function detectWinget(): ToolVersion {
  const out = getVersionOutput("winget --version");
  if (!out) return { found: false, status: "not_installed" };
  return { found: true, version: out.trim(), status: "installed" };
}

// ─── Run all detections and return a snapshot ────────────────────────────────

export function detectAll(): Record<string, ToolVersion> {
  return {
    nvidiaDriver: detectNvidiaDriver(),
    cuda: detectCuda(),
    cudnn: detectCudnn(detectCuda().path),
    msvc: detectMSVC(),
    vcvarsall: detectVcvarsall(),
    cmake: detectCMake(),
    ninja: detectNinja(),
    python: detectPython(),
    conda: detectConda(),
    git: detectGit(),
    sccache: detectSccache(),
    winget: detectWinget(),
  };
}
