import type { BuildOption } from "./types.js";

const curatedOptions: BuildOption[] = [
  {
    name: "USE_CUDA",
    defaultValue: "1",
    description: "Enable CUDA support. Set to 0 for CPU-only builds.",
    category: "accelerator",
    source: "curated"
  },
  {
    name: "USE_CUDNN",
    defaultValue: "1",
    description: "Enable cuDNN when CUDA is enabled.",
    category: "accelerator",
    source: "curated"
  },
  {
    name: "USE_DISTRIBUTED",
    defaultValue: "1",
    description: "Build distributed package support.",
    category: "features",
    source: "curated"
  },
  {
    name: "USE_GLOO",
    defaultValue: "1",
    description: "Build Gloo backend for distributed support.",
    category: "features",
    source: "curated"
  },
  {
    name: "USE_MKLDNN",
    defaultValue: "1",
    description: "Enable oneDNN/MKLDNN CPU kernels.",
    category: "features",
    source: "curated"
  },
  {
    name: "USE_FLASH_ATTENTION",
    defaultValue: "1",
    description: "Build Flash Attention kernels where supported.",
    category: "features",
    source: "curated"
  },
  {
    name: "USE_TEST",
    defaultValue: "0",
    description: "Build PyTorch tests.",
    category: "build",
    source: "curated"
  },
  {
    name: "BUILD_TEST",
    defaultValue: "0",
    description: "CMake test build switch passed through CMAKE_ARGS.",
    category: "build",
    source: "curated"
  },
  {
    name: "MAX_JOBS",
    defaultValue: "6",
    description: "Maximum parallel jobs for PyTorch build.",
    category: "build",
    source: "curated"
  },
  {
    name: "CMAKE_BUILD_PARALLEL_LEVEL",
    defaultValue: "6",
    description: "Parallelism used by CMake/Ninja.",
    category: "build",
    source: "curated"
  },
  {
    name: "CMAKE_ARGS",
    defaultValue: "",
    description: "Additional CMake arguments.",
    category: "advanced",
    source: "curated"
  }
];

const envPatterns = [
  /(?:check_env_flag|check_negative_env_flag|get_env)\(\s*["']([A-Z][A-Z0-9_]+)["']/g,
  /(?:os\.environ\.get|os\.getenv)\(\s*["']([A-Z][A-Z0-9_]+)["']/g,
  /\b([A-Z][A-Z0-9_]{3,})\b/g
];

const ignoredNames = new Set([
  "TRUE",
  "FALSE",
  "ON",
  "OFF",
  "TODO",
  "CUDA",
  "CUDNN",
  "CMAKE",
  "NINJA",
  "MSVC",
  "GCC",
  "CLANG"
]);

export function parseBuildOptionsFromSources(sources: string[]): BuildOption[] {
  const names = new Set<string>();

  for (const source of sources) {
    for (const pattern of envPatterns) {
      let match: RegExpExecArray | null;
      while ((match = pattern.exec(source)) !== null) {
        const name = match[1];
        if (!ignoredNames.has(name) && /_/.test(name)) names.add(name);
      }
    }
  }

  return [...names]
    .sort()
    .slice(0, 120)
    .map((name) => ({
      name,
      defaultValue: "",
      description: "Detected from selected PyTorch source ref.",
      category: "parsed",
      source: "parsed" as const
    }));
}

export function mergeBuildOptions(parsed: BuildOption[]): BuildOption[] {
  const curatedNames = new Set(curatedOptions.map((option) => option.name));
  return [...curatedOptions, ...parsed.filter((option) => !curatedNames.has(option.name))];
}

export { curatedOptions };
