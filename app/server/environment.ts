import { spawn } from "node:child_process";
import fs from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import {
  BuildConfig,
  BuildEnvironment,
  EnvironmentIssue,
  EnvironmentPrepareResult,
  EnvironmentStatus,
  ToolStatus,
  ToolVersion
} from "./types.js";
import { cacheDir, envJsonPath } from "./paths.js";
import { saveConfig } from "./config.js";

type Toolchain = Record<string, string>;

interface CondaRuntime {
  executable: string;
  installRoot: string;
  bootstrapInstalled: boolean;
}

export interface BootstrapSpec {
  url: string;
  filename: string;
  installerArgs: string[];
}

function isWindows(): boolean {
  return process.platform === "win32";
}

function condaExecutablePath(installRoot: string): string {
  return isWindows() ? path.join(installRoot, "Scripts", "conda.exe") : path.join(installRoot, "bin", "conda");
}

function defaultBootstrapRoot(): string {
  return process.env.PYTORCH_BUILD_CONDA_ROOT || path.join(os.homedir(), ".pytorch-build-console", "miniconda3");
}

export function resolveCondaInstallRoot(executablePath: string): string {
  return path.resolve(executablePath, "..", "..");
}

function status(found: boolean, version?: string, pathValue?: string, toolStatus: ToolStatus = found ? "installed" : "not_installed"): ToolVersion {
  return { found, version, path: pathValue, status: toolStatus };
}

async function runCapture(command: string, args: string[], cwd?: string): Promise<string> {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { cwd, windowsHide: true });
    let stdout = "";
    let stderr = "";
    child.stdout.on("data", (chunk) => (stdout += String(chunk)));
    child.stderr.on("data", (chunk) => (stderr += String(chunk)));
    child.on("error", reject);
    child.on("close", (code) => {
      const combined = `${stdout}${stderr}`.trim();
      if (code === 0) resolve(combined);
      else reject(new Error(combined || `${command} exited with ${code}`));
    });
  });
}

async function tryCapture(command: string, args: string[], cwd?: string): Promise<string | null> {
  try {
    return await runCapture(command, args, cwd);
  } catch {
    return null;
  }
}

async function exists(filePath: string): Promise<boolean> {
  try {
    await fs.access(filePath);
    return true;
  } catch {
    return false;
  }
}

function parseVersion(text: string | null, pattern: RegExp): string | undefined {
  if (!text) return undefined;
  return text.match(pattern)?.[1];
}

async function commandVersion(command: string, args: string[], pattern: RegExp): Promise<ToolVersion> {
  const output = await tryCapture(command, args);
  return output ? status(true, parseVersion(output, pattern), command) : status(false, undefined, command);
}

async function findCommandOnPath(command: string): Promise<string | null> {
  const lookup = isWindows() ? ["where", command] : ["which", command];
  const output = await tryCapture(lookup[0], lookup.slice(1));
  if (!output) return null;
  return output
    .split(/\r?\n/)
    .map((line) => line.trim())
    .find(Boolean) ?? null;
}

async function condaPythonInfo(condaExecutable: string, condaEnv: string): Promise<{ executable: string; prefix: string }> {
  const script = "import json, sys; print(json.dumps({'executable': sys.executable, 'prefix': sys.prefix}))";
  const raw = await runCapture(condaExecutable, ["run", "--no-capture-output", "-n", condaEnv, "python", "-c", script]);
  return JSON.parse(raw.trim()) as { executable: string; prefix: string };
}

async function ensureCondaEnv(condaExecutable: string, config: BuildConfig): Promise<void> {
  const raw = await runCapture(condaExecutable, ["env", "list"]);
  const exists = raw
    .split(/\r?\n/)
    .some((line) => line.trim().startsWith(`${config.condaEnv} `) || line.trim().startsWith(`${config.condaEnv}\t`));

  if (!exists) {
    await runCapture(condaExecutable, ["create", "-n", config.condaEnv, `python=${config.pythonVersion}`, "-y"]);
  }
}

async function installDependencies(condaExecutable: string, config: BuildConfig): Promise<void> {
  await runCapture(condaExecutable, ["install", "-y", "-n", config.condaEnv, "cmake", "ninja"]);
  if (isWindows()) {
    await runCapture(condaExecutable, ["install", "-y", "-n", config.condaEnv, "-c", "conda-forge", "libuv=1.51"]);
  }
  await runCapture(condaExecutable, [
    "run",
    "--no-capture-output",
    "-n",
    config.condaEnv,
    "pip",
    "install",
    "mkl-static",
    "mkl-include",
    "pyyaml",
    "typing_extensions",
    "requests"
  ]);
  await runCapture(condaExecutable, ["run", "--no-capture-output", "-n", config.condaEnv, "pip", "install", "-r", path.join(config.pytorchDir, "requirements.txt")]);
}

async function findVswhere(): Promise<string | null> {
  if (!isWindows()) return null;
  const programFilesX86 = process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)";
  const candidate = path.join(programFilesX86, "Microsoft Visual Studio", "Installer", "vswhere.exe");
  return (await exists(candidate)) ? candidate : null;
}

export function getMinicondaBootstrapSpec(platform: NodeJS.Platform = process.platform, arch: string = process.arch): BootstrapSpec {
  if (platform === "darwin") {
    throw new Error("Miniconda bootstrap is configured for Windows and Linux only.");
  }

  if (platform === "win32") {
    const installerArch = arch === "arm64" ? "arm64" : "x86_64";
    return {
      url: `https://repo.anaconda.com/miniconda/Miniconda3-latest-Windows-${installerArch}.exe`,
      filename: `Miniconda3-latest-Windows-${installerArch}.exe`,
      installerArgs: []
    };
  }

  const linuxArch = arch === "arm64" ? "aarch64" : "x86_64";
  return {
    url: `https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-${linuxArch}.sh`,
    filename: `Miniconda3-latest-Linux-${linuxArch}.sh`,
    installerArgs: ["-b", "-p"]
  };
}

async function downloadInstaller(url: string, targetPath: string): Promise<void> {
  const response = await fetch(url);
  if (!response.ok || !response.body) {
    throw new Error(`Failed to download Miniconda installer: ${response.status} ${response.statusText}`);
  }

  await fs.mkdir(path.dirname(targetPath), { recursive: true });
  const buffer = Buffer.from(await response.arrayBuffer());
  await fs.writeFile(targetPath, buffer);
}

async function installBootstrapConda(config: BuildConfig): Promise<CondaRuntime> {
  const spec = getMinicondaBootstrapSpec();
  const installRoot = config.condaInstallRoot || defaultBootstrapRoot();
  const installerPath = path.join(cacheDir, spec.filename);

  await fs.mkdir(cacheDir, { recursive: true });
  await fs.mkdir(path.dirname(installRoot), { recursive: true });
  await downloadInstaller(spec.url, installerPath);

  if (isWindows()) {
    await runCapture(installerPath, [
      "/S",
      "/InstallationType=JustMe",
      "/RegisterPython=0",
      "/AddToPath=0",
      `/D=${installRoot}`
    ]);
  } else {
    await runCapture("bash", [installerPath, ...spec.installerArgs, installRoot]);
  }

  const executable = condaExecutablePath(installRoot);
  if (!(await exists(executable))) {
    throw new Error(`Miniconda installation completed, but ${executable} was not created.`);
  }

  return {
    executable,
    installRoot,
    bootstrapInstalled: true
  };
}

async function locateConfiguredConda(config: BuildConfig): Promise<CondaRuntime | null> {
  if (config.condaExecutable && (await exists(config.condaExecutable))) {
    const root = config.condaInstallRoot || resolveCondaInstallRoot(config.condaExecutable);
    return {
      executable: config.condaExecutable,
      installRoot: root,
      bootstrapInstalled: Boolean(config.condaBootstrapInstalled)
    };
  }

  const bootstrapRoot = config.condaInstallRoot || defaultBootstrapRoot();
  const bootstrapExecutable = condaExecutablePath(bootstrapRoot);
  if (await exists(bootstrapExecutable)) {
    return {
      executable: bootstrapExecutable,
      installRoot: bootstrapRoot,
      bootstrapInstalled: true
    };
  }

  const pathExecutable = await findCommandOnPath("conda");
  if (pathExecutable && (await exists(pathExecutable))) {
    return {
      executable: pathExecutable,
      installRoot: resolveCondaInstallRoot(pathExecutable),
      bootstrapInstalled: false
    };
  }

  return null;
}

async function resolveCondaRuntime(config: BuildConfig, allowBootstrap: boolean): Promise<CondaRuntime> {
  const existing = await locateConfiguredConda(config);
  if (existing) return existing;
  if (!allowBootstrap) {
    return {
      executable: "",
      installRoot: config.condaInstallRoot || defaultBootstrapRoot(),
      bootstrapInstalled: false
    };
  }
  return installBootstrapConda(config);
}

export async function getAvailableToolchains(): Promise<Toolchain[]> {
  if (!isWindows()) return [];

  const vswhere = await findVswhere();
  if (!vswhere) return [];

  const installRaw = await tryCapture(vswhere, ["-all", "-products", "*", "-property", "installationPath"]);
  if (!installRaw) return [];

  const installPaths = installRaw.split(/\r?\n/).map((line) => line.trim()).filter(Boolean);
  const toolchains: Toolchain[] = [];

  for (const installPath of installPaths) {
    const vcvarsPath = path.join(installPath, "VC", "Auxiliary", "Build", "vcvarsall.bat");
    const msvcRoot = path.join(installPath, "VC", "Tools", "MSVC");

    try {
      const entries = await fs.readdir(msvcRoot, { withFileTypes: true });
      const versions = entries.filter((entry) => entry.isDirectory()).map((entry) => entry.name).sort().reverse();

      for (const version of versions) {
        const clPath = path.join(msvcRoot, version, "bin", "Hostx64", "x64", "cl.exe");
        if (await exists(clPath)) {
          toolchains.push({
            vcvars_path: vcvarsPath,
            msvc_version: version,
            cl_path: clPath,
            install_path: installPath
          });
        }
      }
    } catch {
      // Try next installation.
    }
  }

  return toolchains;
}

async function captureVcvars(toolchain: Toolchain): Promise<Record<string, string>> {
  const command = `call "${toolchain.vcvars_path}" x64 -vcvars_ver=${toolchain.msvc_version} && set`;
  const raw = await runCapture("cmd.exe", ["/d", "/s", "/c", command]);
  const env: Record<string, string> = {};

  for (const line of raw.split(/\r?\n/)) {
    const index = line.indexOf("=");
    if (index > 0) {
      env[line.slice(0, index)] = line.slice(index + 1);
    }
  }

  return env;
}

function buildIssues(tools: Record<string, ToolVersion>, config: BuildConfig): EnvironmentIssue[] {
  const issues: EnvironmentIssue[] = [];
  const needsCuda = config.cudaVersion.toLowerCase() !== "cpu";

  if (!tools.git.found) issues.push({ tool: "git", severity: "error", message: "Git is required to fetch the PyTorch repository." });
  if (!tools.conda.found) issues.push({ tool: "conda", severity: "error", message: "Conda is required to create and prepare the build environment." });
  if (!tools.python.found) issues.push({ tool: "python", severity: "error", message: "Python is required in PATH or in the selected conda environment." });
  if (!tools.cmake.found) issues.push({ tool: "cmake", severity: "error", message: "CMake is required for the PyTorch build." });
  if (!tools.ninja.found) issues.push({ tool: "ninja", severity: "error", message: "Ninja is required for the PyTorch build." });
  if (needsCuda && !tools.cuda.found) issues.push({ tool: "cuda", severity: "error", message: "CUDA toolkit was not detected for the selected GPU build." });
  if (needsCuda && !tools.cudnn.found) issues.push({ tool: "cudnn", severity: "warn", message: "cuDNN was not detected. The build may fail until cuDNN is installed." });

  if (isWindows()) {
    if (!tools.msvc.found) issues.push({ tool: "msvc", severity: "error", message: "MSVC toolset was not detected." });
    if (!tools.vcvarsall.found) issues.push({ tool: "vcvarsall", severity: "error", message: "vcvarsall.bat was not detected." });
  }

  return issues;
}

async function detectCuda(): Promise<ToolVersion> {
  const output = await tryCapture("nvcc", ["--version"]);
  if (output) {
    return status(true, parseVersion(output, /release (\d+\.\d+)/i), "nvcc");
  }

  if (isWindows()) {
    const cudaPath = process.env.CUDA_PATH || process.env.CUDA_HOME;
    if (cudaPath) return status(true, undefined, cudaPath);
  }

  return status(false);
}

async function detectCudnn(): Promise<ToolVersion> {
  const candidates = [
    process.env.CUDNN_ROOT,
    process.env.CONDA_PREFIX ? path.join(process.env.CONDA_PREFIX, "Library") : undefined,
    process.env.CUDA_PATH,
    process.env.CUDA_HOME
  ].filter(Boolean) as string[];

  for (const root of candidates) {
    const headers = [
      path.join(root, "include", "cudnn_version.h"),
      path.join(root, "include", "cudnn.h"),
      path.join(root, "cudnn_version.h")
    ];

    for (const file of headers) {
      try {
        const text = await fs.readFile(file, "utf8");
        const major = parseVersion(text, /#define\s+CUDNN_MAJOR\s+(\d+)/);
        const minor = parseVersion(text, /#define\s+CUDNN_MINOR\s+(\d+)/);
        const patch = parseVersion(text, /#define\s+CUDNN_PATCHLEVEL\s+(\d+)/);
        if (major) {
          return status(true, [major, minor ?? "0", patch ?? "0"].join("."), root);
        }
      } catch {
        // Try next header.
      }
    }
  }

  return status(false);
}

async function condaStatus(config: BuildConfig, allowBootstrap: boolean): Promise<{ runtime: CondaRuntime; version?: string }> {
  const runtime = await resolveCondaRuntime(config, allowBootstrap);
  if (!runtime.executable) {
    return { runtime, version: undefined };
  }

  const output = await commandVersion(runtime.executable, ["--version"], /conda (\S+)/i);
  return { runtime, version: output.version };
}

async function buildEnvironment(config: BuildConfig, runtime: CondaRuntime): Promise<BuildEnvironment> {
  const python = await condaPythonInfo(runtime.executable, config.condaEnv);
  const cuda = config.cudaVersion.toLowerCase() === "cpu"
    ? ""
    : isWindows()
      ? path.join(config.cudaRoot, `v${config.cudaVersion}`)
      : config.cudaRoot || "/usr/local/cuda";
  const env: Record<string, string> = {};
  const pathEntries = new Set<string>();
  let toolchain: Toolchain = {};

  if (isWindows()) {
    const toolchains = await getAvailableToolchains();
    if (toolchains.length === 0) {
      throw new Error("No usable MSVC x64 toolchain was found.");
    }

    toolchain = config.selectedToolchain ?? toolchains[0];
    const vcvars = await captureVcvars(toolchain);

    for (const key of ["LIB", "INCLUDE", "LIBPATH", "WindowsSdkDir", "WindowsSdkVerBinPath"]) {
      if (vcvars[key]) env[key] = vcvars[key];
    }
    if (vcvars.Path) {
      for (const entry of vcvars.Path.split(";")) {
        if (entry) pathEntries.add(entry);
      }
    }
    pathEntries.add(path.dirname(toolchain.cl_path));
    env.CC = toolchain.cl_path;
    env.CXX = toolchain.cl_path;
    env.CUDAHOSTCXX = toolchain.cl_path;
    env.CMAKE_CUDA_HOST_COMPILER = toolchain.cl_path;
    env.DISTUTILS_USE_SDK = "1";
    env.CMAKE_GENERATOR_TOOLSET_VERSION = toolchain.msvc_version;
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

  if (config.magmaDir) {
    env.MAGMA_HOME = config.magmaDir;
  }

  env.CMAKE_GENERATOR = "Ninja";
  env.TORCH_CUDA_ARCH_LIST = config.gpuArchList;
  env.MAX_JOBS = config.maxJobs;
  env.CMAKE_BUILD_PARALLEL_LEVEL = config.cmakeBuildParallelLevel;
  env.CMAKE_PREFIX_PATH = [python.prefix, config.cudnnRoot, cuda].filter(Boolean).join(isWindows() ? ";" : ":");

  for (const [key, value] of Object.entries(config.buildOptions)) {
    env[key] = value;
  }
  for (const [key, value] of Object.entries(config.extraEnv)) {
    env[key] = value;
  }
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

  for (const entry of (process.env.PATH || "").split(isWindows() ? ";" : ":")) {
    if (entry) pathEntries.add(entry);
  }
  env.PATH = [...pathEntries].join(isWindows() ? ";" : ":");

  const buildEnv: BuildEnvironment = {
    generated_at: new Date().toISOString(),
    platform: isWindows() ? "windows" : "linux",
    pytorch_dir: config.pytorchDir,
    conda: {
      env_name: config.condaEnv,
      python_executable: python.executable,
      prefix: python.prefix,
      python_version: config.pythonVersion,
      executable: runtime.executable,
      install_root: runtime.installRoot,
      bootstrap_installed: runtime.bootstrapInstalled
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

export async function detectEnvironment(config: BuildConfig): Promise<EnvironmentStatus> {
  const conda = await condaStatus(config, false);
  const toolchains = await getAvailableToolchains();
  const tools: Record<string, ToolVersion> = {
    git: await commandVersion("git", ["--version"], /git version (\S+)/i),
    conda: conda.version ? status(true, conda.version, conda.runtime.executable) : status(false, undefined, conda.runtime.executable),
    python: await commandVersion("python", ["--version"], /Python (\S+)/i),
    cmake: await commandVersion("cmake", ["--version"], /cmake version (\S+)/i),
    ninja: await commandVersion("ninja", ["--version"], /(\S+)/i),
    sccache: await commandVersion("sccache", ["--version"], /(\S+)/i),
    winget: await commandVersion("winget", ["--version"], /(\S+)/i),
    cuda: await detectCuda(),
    cudnn: await detectCudnn(),
    msvc: toolchains.length > 0 ? status(true, toolchains[0].msvc_version, toolchains[0].cl_path) : status(false),
    vcvarsall: toolchains.length > 0 ? status(true, toolchains[0].vcvars_path, toolchains[0].vcvars_path) : status(false)
  };

  const issues = buildIssues(tools, config);
  return {
    ready: issues.every((issue) => issue.severity !== "error"),
    tools,
    issues,
    conda: {
      present: Boolean(conda.version),
      bootstrapInstalled: conda.runtime.bootstrapInstalled,
      executable: conda.runtime.executable || undefined,
      installRoot: conda.runtime.installRoot
    },
    selectedToolchain: toolchains[0]
  };
}

export async function prepareEnvironment(config: BuildConfig): Promise<BuildEnvironment> {
  const conda = await condaStatus(config, true);
  if (!conda.runtime.executable) {
    throw new Error("Conda could not be resolved or bootstrapped.");
  }

  if (conda.runtime.executable !== config.condaExecutable || conda.runtime.installRoot !== config.condaInstallRoot || conda.runtime.bootstrapInstalled !== Boolean(config.condaBootstrapInstalled)) {
    await saveConfig({
      ...config,
      condaExecutable: conda.runtime.executable,
      condaInstallRoot: conda.runtime.installRoot,
      condaBootstrapInstalled: conda.runtime.bootstrapInstalled
    });
  }

  await ensureCondaEnv(conda.runtime.executable, config);
  if (config.forceDependencies || !(await hasPreparedDependencies(conda.runtime.executable, config))) {
    await installDependencies(conda.runtime.executable, config);
  }

  return buildEnvironment(config, conda.runtime);
}

async function hasPreparedDependencies(condaExecutable: string, config: BuildConfig): Promise<boolean> {
  const output = await tryCapture(condaExecutable, ["run", "--no-capture-output", "-n", config.condaEnv, "pip", "show", "pyyaml"]);
  return Boolean(output && output.trim().length > 0);
}

export async function prepareEnvironmentWithStatus(config: BuildConfig): Promise<EnvironmentPrepareResult> {
  const environment = await prepareEnvironment(config);
  const status = await detectEnvironment({
    ...config,
    condaExecutable: environment.conda.executable,
    condaInstallRoot: environment.conda.install_root,
    condaBootstrapInstalled: environment.conda.bootstrap_installed
  });
  return { status, environment };
}
