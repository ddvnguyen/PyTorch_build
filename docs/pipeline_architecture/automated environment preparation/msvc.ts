import { EnvConfig } from "../core/types.js";
import { spawnAndWait, runPS, isAdmin } from "../core/shell.js";
import { detectMSVC, detectVcvarsall } from "../detect/detect.js";

// ─── MSVC / Visual Studio Build Tools installer ───────────────────────────────
//
// Strategy (mirrors what PyTorch CI does):
//   1. Install VS 2022 Build Tools via winget with --override to pass VS
//      installer args directly.
//   2. The --override string adds:
//       - Microsoft.VisualStudio.Workload.VCTools  (MSVC, CMake, MSBuild)
//       - Microsoft.VisualStudio.Component.Windows11SDK.22621
//       - Microsoft.VisualStudio.Component.VC.CMake.Project
//   3. --wait ensures winget blocks until VS installer finishes (critical!).
//   4. Exit code 3010 = success, reboot required.

const VS_WINGET_ID_2022 = "Microsoft.VisualStudio.2022.BuildTools";
const VS_WINGET_ID_2019 = "Microsoft.VisualStudio.2019.BuildTools";

// Workloads needed for PyTorch:
//   VCTools     → MSVC compiler, MSBuild, vcvarsall
//   NativeDesktop → adds Windows SDK, ATL, etc.
const REQUIRED_WORKLOADS = [
  "Microsoft.VisualStudio.Workload.VCTools",
  "--includeRecommended",
].join(" --add ");

const REQUIRED_COMPONENTS = [
  "Microsoft.VisualStudio.Component.Windows11SDK.22621",
  "Microsoft.VisualStudio.Component.VC.CMake.Project",
].map((c) => `--add ${c}`).join(" ");

export async function installMSVC(cfg: EnvConfig): Promise<void> {
  if (!isAdmin()) {
    throw new Error("MSVC installation requires Administrator privileges. Re-run as admin.");
  }

  const wingetId = cfg.vsVersion === "2022" ? VS_WINGET_ID_2022 : VS_WINGET_ID_2019;

  const overrideArgs = [
    "--quiet",
    "--norestart",
    `--add ${REQUIRED_WORKLOADS}`,
    REQUIRED_COMPONENTS,
  ].join(" ");

  console.log("  Installing Visual Studio Build Tools via winget...");
  console.log(`  Workloads: VCTools + Windows SDK`);
  console.log("  This takes 5-15 minutes...");

  const code = await spawnAndWait("winget", [
    "install",
    "--id", wingetId,
    "--exact",
    "--accept-package-agreements",
    "--accept-source-agreements",
    "--wait",         // CRITICAL: wait for VS installer to finish, not just the bootstrap
    "--override", overrideArgs,
  ], { logFile: "logs/msvc-install.log" });

  // 3010 = success but reboot needed
  if (code !== 0 && code !== 3010) {
    throw new Error(`VS Build Tools installer exited with code ${code}. Check logs/msvc-install.log`);
  }

  if (code === 3010) {
    console.warn("  [WARN] MSVC installed — reboot required before building.");
  }
}

// ─── VS config file approach (alternative for controlled environments) ────────
//
// Instead of inline --override, write a .vsconfig and pass --config.
// This is more maintainable for CI pipelines.

export function writeVSConfig(outputPath: string): void {
  const config = {
    version: "1.0",
    components: [
      "Microsoft.VisualStudio.Workload.VCTools",
      "Microsoft.VisualStudio.Component.Windows11SDK.22621",
      "Microsoft.VisualStudio.Component.VC.CMake.Project",
      "Microsoft.VisualStudio.Component.VC.Tools.x86.x64",
      "Microsoft.VisualStudio.Component.VC.Redist.14.Latest",
    ],
  };

  const fs = await import("node:fs");
  fs.writeFileSync(outputPath, JSON.stringify(config, null, 2), "utf8");
  console.log(`  Wrote VS config to ${outputPath}`);
}

// ─── Load MSVC environment into current process ───────────────────────────────
//
// After install, every build command must run in an environment where
// vcvarsall.bat has been called. We do this by:
//   1. Running vcvarsall.bat x64
//   2. Capturing the resulting env vars with `set`
//   3. Injecting them into process.env
//
// This is the Node.js equivalent of "Developer PowerShell for VS".

export function loadMSVCEnvironment(vcvarsallPath: string): void {
  console.log("  Loading MSVC build environment (vcvarsall x64)...");

  // Run vcvarsall then dump all env vars
  const script = `
    cmd /c "call \\"${vcvarsallPath}\\" x64 && set"
  `;

  const output = runPS(script);
  const lines = output.split("\n");

  let injected = 0;
  for (const line of lines) {
    const eq = line.indexOf("=");
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    const val = line.slice(eq + 1).trim();
    if (key && val) {
      process.env[key] = val;
      injected++;
    }
  }

  console.log(`  Injected ${injected} MSVC environment variables into process.`);
}

// ─── Verify MSVC is working ───────────────────────────────────────────────────

export async function verifyMSVC(): Promise<boolean> {
  const result = detectMSVC();
  if (!result.found) return false;

  const vcvarsall = detectVcvarsall();
  if (!vcvarsall.found) return false;

  return true;
}
