import assert from "node:assert/strict";
import test from "node:test";
import { mergeBuildOptions, parseBuildOptionsFromSources } from "./buildOptions.js";

test("parses env build options from PyTorch-like source", () => {
  const parsed = parseBuildOptionsFromSources([
    'check_env_flag("USE_CUDA")\nos.environ.get("BUILD_TEST")\nos.getenv("USE_DISTRIBUTED")'
  ]);

  assert.deepEqual(
    parsed.map((option) => option.name),
    ["BUILD_TEST", "USE_CUDA", "USE_DISTRIBUTED"]
  );
});

test("merge keeps curated options first and avoids duplicates", () => {
  const merged = mergeBuildOptions([
    {
      name: "USE_CUDA",
      defaultValue: "",
      description: "parsed duplicate",
      category: "parsed",
      source: "parsed"
    },
    {
      name: "CUSTOM_FLAG",
      defaultValue: "",
      description: "parsed",
      category: "parsed",
      source: "parsed"
    }
  ]);

  assert.equal(merged[0].name, "USE_CUDA");
  assert.equal(merged.filter((option) => option.name === "USE_CUDA").length, 1);
  assert.ok(merged.some((option) => option.name === "CUSTOM_FLAG"));
});
