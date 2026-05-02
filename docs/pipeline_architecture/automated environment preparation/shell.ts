import { execSync, spawn, SpawnOptions } from "node:child_process";
import fs from "node:fs";
import path from "node:path";

// ─── Run a PowerShell command and return stdout ───────────────────────────────

export function runPS(script: string, elevated = false): string {
  const args = ["-NoProfile", "-NonInteractive", "-Command", script];

  if (elevated) {
    // Wrap in Start-Process -Verb RunAs for elevation
    const escaped = script.replace(/"/g, '\\"');
    const elevateScript = `Start-Process powershell -Verb RunAs -Wait -ArgumentList '-NoProfile -NonInteractive -Command "${escaped}"'`;
    return execSync(`powershell.exe -NoProfile -NonInteractive -Command "${elevateScript}"`, {
      encoding: "utf8",
      windowsHide: true,
    }).trim();
  }

  return execSync(`powershell.exe ${args.map((a) => `"${a}"`).join(" ")}`, {
    encoding: "utf8",
    windowsHide: true,
  }).trim();
}

// ─── Spawn a process and stream output (used for long installers) ─────────────

export function spawnAndWait(
  cmd: string,
  args: string[],
  opts: SpawnOptions & { logFile?: string } = {}
): Promise<number> {
  return new Promise((resolve, reject) => {
    const logStream = opts.logFile
      ? fs.createWriteStream(opts.logFile, { flags: "a" })
      : null;

    const child = spawn(cmd, args, {
      shell: true,
      windowsHide: true,
      ...opts,
    });

    const pipe = (data: Buffer) => {
      process.stdout.write(data);
      logStream?.write(data);
    };

    child.stdout?.on("data", pipe);
    child.stderr?.on("data", pipe);
    child.on("error", reject);
    child.on("close", (code) => {
      logStream?.end();
      resolve(code ?? 1);
    });
  });
}

// ─── Check if a command exists in PATH ───────────────────────────────────────

export function commandExists(cmd: string): boolean {
  try {
    execSync(`where.exe ${cmd}`, { stdio: "pipe", windowsHide: true });
    return true;
  } catch {
    return false;
  }
}

// ─── Read version from a command like `nvcc --version` ───────────────────────

export function getVersionOutput(cmd: string): string | null {
  try {
    return execSync(cmd, { encoding: "utf8", stdio: "pipe", windowsHide: true }).trim();
  } catch {
    return null;
  }
}

// ─── Set a persistent system environment variable (requires admin) ────────────

export function setSystemEnvVar(name: string, value: string): void {
  runPS(`[System.Environment]::SetEnvironmentVariable('${name}', '${value}', 'Machine')`, true);
  // Also set in current process so subsequent steps see it
  process.env[name] = value;
}

// ─── Append to system PATH (requires admin) ───────────────────────────────────

export function appendToSystemPath(dir: string): void {
  const currentPath = runPS(`[System.Environment]::GetEnvironmentVariable('PATH', 'Machine')`);
  if (!currentPath.includes(dir)) {
    setSystemEnvVar("PATH", `${currentPath};${dir}`);
  }
}

// ─── Check if process is running as administrator ─────────────────────────────

export function isAdmin(): boolean {
  try {
    const result = runPS(
      `([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)`
    );
    return result.trim().toLowerCase() === "true";
  } catch {
    return false;
  }
}

// ─── Download a file via PowerShell Invoke-WebRequest ────────────────────────

export async function downloadFile(url: string, dest: string): Promise<void> {
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  console.log(`  Downloading ${path.basename(dest)}...`);

  // Use BitsTransfer for large files (better progress, resumable)
  const script = `
    $ProgressPreference = 'SilentlyContinue'
    try {
      Import-Module BitsTransfer -ErrorAction SilentlyContinue
      Start-BitsTransfer -Source '${url}' -Destination '${dest}'
    } catch {
      Invoke-WebRequest -Uri '${url}' -OutFile '${dest}' -UseBasicParsing
    }
  `;

  const code = await spawnAndWait("powershell.exe", [
    "-NoProfile", "-NonInteractive", "-Command", script,
  ]);

  if (code !== 0) throw new Error(`Download failed for ${url}`);
}
