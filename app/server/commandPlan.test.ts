import assert from "node:assert/strict";
import test from "node:test";
import path from "node:path";
import { createDependencyPlan } from "./commandPlan.js";
import type { BuildConfig } from "./types.js";

const config: BuildConfig = {
  selectedRef: "v2.11.0",
  selectedRefKind: "release",
  pytorchDir: path.join("Z:", "source", "PyTorch_build", "pytorch"),
  condaEnv: "pytorch-build",
  pythonVersion: "3.12",
  cudaVersion: "12.9",
  cudaRoot: "C:\\CUDA",
  cudnnRoot: "C:\\CUDNN",
  magmaDir: "",
  gpuArchList: "8.9",
  maxJobs: "6",
  cmakeBuildParallelLevel: "6",
  buildOptions: {},
  extraEnv: {},
  skipTest: true,
  forceDependencies: false
};

test("dependency plan uses spawned command and argument arrays", () => {
  const plans = createDependencyPlan(config);

  assert.ok(plans.length >= 2);
  assert.equal(plans[0].command, "conda");
  assert.deepEqual(plans[0].args.slice(0, 4), ["run", "--no-capture-output", "-n", "pytorch-build"]);
  assert.ok(plans.some((plan) => plan.args.includes(path.join(config.pytorchDir, "requirements.txt"))));
});
