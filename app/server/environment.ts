import fs from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import type { BuildConfig, BuildEnvironment } from "./types.js";
import { envJsonPath } from "./paths.js";

function isWindows(): boolean {
  return process.platform === "win32";
}

function cudaHome(config: BuildConfig): string {
  if (config.cudaVersion.toLowerCase() === "cpu") return "";
  if (isWindows()) return path.join(config.cudaRoot, `v${config.cudaVersion}`);
  return config.cudaRoot || "/usr/local/cuda";
}

function pathSeparator(): string {
  return isWindows() ? ";" : ":";
}

async function capture(command: string, args: string[], cwd?: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, windowsHide: true });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += String(chunk)));
    child.stderr.on("data", (chunk) => (stderr += String(chunk)));
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) resolve(stdout);
      else reject(new Error(stderr || `${command} exited with ${code}`));
    });
  });
}

async function condaPythonInfo(condaEnv: string): Promise<{ executable: string; prefix: string }> {
  const script = "import json, sys; print(json.dumps({'executable': sys.executable, 'prefix': sys.prefix}))";
  const raw = await capture("conda", ["run", "--no-capture-output", "-n", condaEnv, "python", "-c", script]);
  return JSON.parse(raw.trim()) as { executable: string; prefix: string };
}

async function ensureCondaEnv(config: BuildConfig): Promise<void> {
  const raw = await capture("conda", ["env", "list"]);
  if (raw.split(/\r?\n/).some((line) => line.trim().startsWith(`${config.condaEnv} `))) return;
  await capture("conda", ["create", "-n", config.condaEnv, `python=${config.pythonVersion}`, "-y"]);
}

async function findVswhere(): Promise<string> {
  const programFilesX86 = process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)";
  return path.join(programFilesX86, "Microsoft Visual Studio", "Installer", "vswhere.exe");
}

async function detectWindowsToolchain(): Promise<Record<string, string>> {
  const vswhere = await findVswhere();
  const installRaw = await capture(vswhere, ["-all", "-products", "*", "-property", "installationPath"]);
  const installPaths = installRaw.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  for (const installPath of installPaths) {
    const vcvarsPath = path.join(installPath, "VC", "Auxiliary", "Build", "vcvarsall.bat");
    const msvcRoot = path.join(installPath, "VC", "Tools", "MSVC");
    try {
      const entries = await fs.readdir(msvcRoot, { withFileTypes: true });
      const versions = entries.filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort().reverse();
      for (const version of versions) {
        const clPath = path.join(msvcRoot, version, "bin", "Hostx64", "x64", "cl.exe");
        try {
          await fs.access(clPath);
          return { vcvars_path: vcvarsPath, msvc_version: version, cl_path: clPath };
        } catch {
          // Try next toolset.
        }
      }
    } catch {
      // Try next installation.
    }
  }
  throw new Error("No usable MSVC x64 toolchain was found.");
}

async function captureVcvars(toolchain: Record<string, string>): Promise<Record<string, string>> {
  const command = `"${toolchain.vcvars_path}" x64 -vcvars_ver=${toolchain.msvc_version} && set`;
  const raw = await capture("cmd.exe", ["/d", "/s", "/c", command]);
  const env: Record<string, string> = {};
  for (const line of raw.split(/\r?\n/)) {
    const index = line.indexOf("=");
    if (index > 0) env[line.slice(0, index)] = line.slice(index + 1);
  }
  return env;
}

export async function prepareEnvironment(config: BuildConfig): Promise<BuildEnvironment> {
  await ensureCondaEnv(config);
  const python = await condaPythonInfo(config.condaEnv);
  const cuda = cudaHome(config);
  const sep = pathSeparator();
  const env: Record<string, string> = {};
  let toolchain: Record<string, string> = {};
  const pathEntries = new Set<string>();

  if (isWindows()) {
    toolchain = await detectWindowsToolchain();
    const vcvars = await captureVcvars(toolchain);
    for (const key of ["LIB", "INCLUDE", "LIBPATH", "WindowsSdkDir", "WindowsSdkVerBinPath"]) {
      if (vcvars[key]) env[key] = vcvars[key];
    }
    if (vcvars.Path) for (const entry of vcvars.Path.split(";")) if (entry) pathEntries.add(entry);
    pathEntries.add(path.dirname(toolchain.cl_path));
    env.CC = toolchain.cl_path;
    env.CXX = toolchain.cl_path;
    env.CUDAHOSTCXX = toolchain.cl_path;
    env.CMAKE_CUDA_HOST_COMPILER = toolchain.cl_path;
    env.DISTUTILS_USE_SDK = "1";
    env.CMAKE_GENERATOR_TOOLSET_VERSION = toolchain.msvc_version;
  } else {
    env.CMAKE_GENERATOR = "Ninja";
  }

  if (cuda) {
    env.CUDA_HOME = cuda;
    env.CUDA_PATH = cuda;
    pathEntries.add(path.join(cuda, "bin"));
  }
  if (config.cudnnRoot) {
    env.CUDNN_ROOT = config.cudnnRoot;
    env.CUDNN_ROOT_DIR = config.cudnnRoot;
  }
  if (config.magmaDir) env.MAGMA_HOME = config.magmaDir;

  env.CMAKE_GENERATOR = "Ninja";
  env.TORCH_CUDA_ARCH_LIST = config.gpuArchList;
  env.MAX_JOBS = config.maxJobs;
  env.CMAKE_BUILD_PARALLEL_LEVEL = config.cmakeBuildParallelLevel;
  env.CMAKE_PREFIX_PATH = [python.prefix, config.cudnnRoot, cuda].filter(Boolean).join(sep);

  for (const [key, value] of Object.entries(config.buildOptions)) env[key] = value;
  for (const [key, value] of Object.entries(config.extraEnv)) env[key] = value;
  if (config.skipTest) {
    env.USE_TEST = "0";
    env.BUILD_TEST = "0";
  }

  if (isWindows()) {
    pathEntries.add(path.join(python.prefix, "Scripts"));
    pathEntries.add(path.join(python.prefix, "Library", "bin"));
  } else {
    pathEntries.add(path.join(python.prefix, "bin"));
  }
  for (const entry of (process.env.PATH || "").split(sep)) if (entry) pathEntries.add(entry);
  env.PATH = [...pathEntries].join(sep);

  const buildEnv: BuildEnvironment = {
    generated_at: new Date().toISOString(),
    platform: isWindows() ? "windows" : "linux",
    pytorch_dir: config.pytorchDir,
    conda: {
      env_name: config.condaEnv,
      python_executable: python.executable,
      prefix: python.prefix,
      python_version: config.pythonVersion
    },
    cuda: {
      version: config.cudaVersion,
      cuda_home: cuda,
      cudnn_root: config.cudnnRoot,
      magma_dir: config.magmaDir
    },
    toolchain,
    build: {
      working_directory: config.pytorchDir,
      python_executable: python.executable,
      command: [python.executable, "setup.py", "bdist_wheel"],
      cleanup_paths: ["build", "dist", "build_python", "torch.egg-info"]
    },
    environment: env
  };

  await fs.mkdir(path.dirname(envJsonPath), { recursive: true });
  await fs.writeFile(envJsonPath, JSON.stringify(buildEnv, null, 2), "utf8");
  return buildEnv;
}
