import fs from "node:fs";
import path from "node:path";
import type { BuildConfig, CommandPlan } from "./types.js";

const repoUrl = "https://github.com/pytorch/pytorch.git";

function condaCommand(config: BuildConfig): string {
  return config.condaExecutable || "conda";
}

export function createCheckoutPlan(config: BuildConfig, forceClone = false): CommandPlan[] {
  const hasCheckout = fs.existsSync(path.join(config.pytorchDir, ".git"));
  if (!hasCheckout || forceClone) {
    return [
      {
        label: "Clone PyTorch source",
        command: "git",
        args: ["clone", "--recursive", repoUrl, config.pytorchDir]
      },
      {
        label: `Checkout ${config.selectedRef}`,
        command: "git",
        args: ["checkout", config.selectedRef],
        cwd: config.pytorchDir
      },
      {
        label: "Sync submodules",
        command: "git",
        args: ["submodule", "sync", "--recursive"],
        cwd: config.pytorchDir
      },
      {
        label: "Update submodules",
        command: "git",
        args: ["submodule", "update", "--init", "--recursive"],
        cwd: config.pytorchDir
      }
    ];
  }

  return [
    {
      label: "Prune remote refs",
      command: "git",
      args: ["remote", "prune", "origin"],
      cwd: config.pytorchDir
    },
    {
      label: "Fetch PyTorch source and tags",
      command: "git",
      args: ["fetch", "--prune", "--tags", "--force", "origin"],
      cwd: config.pytorchDir
    },
    {
      label: `Checkout ${config.selectedRef}`,
      command: "git",
      args: ["checkout", config.selectedRef],
      cwd: config.pytorchDir
    },
    {
      label: "Sync submodules",
      command: "git",
      args: ["submodule", "sync", "--recursive"],
      cwd: config.pytorchDir
    },
    {
      label: "Update submodules",
      command: "git",
      args: ["submodule", "update", "--init", "--recursive"],
      cwd: config.pytorchDir
    }
  ];
}

export function createDependencyPlan(config: BuildConfig): CommandPlan[] {
  const conda = condaCommand(config);
  const plans: CommandPlan[] = [
    {
      label: "Install cmake and ninja",
      command: conda,
      args: ["install", "-y", "-n", config.condaEnv, "cmake", "ninja"]
    }
  ];

  if (process.platform === "win32") {
    plans.push({
      label: "Install Windows libuv",
      command: conda,
      args: [
        "install",
        "-y",
        "-n",
        config.condaEnv,
        "-c",
        "conda-forge",
        "libuv=1.51"
      ]
    });
  }

  plans.push(
    {
      label: "Install Python build packages",
      command: conda,
      args: [
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
      ]
    },
    {
      label: "Install PyTorch requirements",
      command: conda,
      args: [
        "run",
        "--no-capture-output",
        "-n",
        config.condaEnv,
        "pip",
        "install",
        "-r",
        path.join(config.pytorchDir, "requirements.txt")
      ]
    }
  );

  return plans;
}

export function createBuildPlan(config: BuildConfig, pythonExecutable: string, env: Record<string, string>): CommandPlan[] {
  return [
    {
      label: "Build PyTorch wheel",
      command: pythonExecutable,
      args: ["setup.py", "bdist_wheel"],
      cwd: config.pytorchDir,
      env
    }
  ];
}
