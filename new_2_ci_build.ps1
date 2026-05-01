# ============================================================
# new_2_ci_build.ps1 (v8) - Robust Path Handling
# ============================================================
param(
    [switch]$Clean,       
    [switch]$NoDedup      
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Fail { param([string]$m) Write-Host "    [FAIL] $m" -ForegroundColor Red; exit 1 }

# IMPROVED: Helper to force Long Paths without crashing on system folders
function Canonicalize-Path {
    param([string]$p)
    if (-not $p) { return $p }
    # Remove leading/trailing quotes or spaces that might confuse Get-Item
    $cleanP = $p.Trim().Trim('"')
    try {
        if (Test-Path $cleanP -ErrorAction SilentlyContinue) { 
            return (Get-Item $cleanP -ErrorAction SilentlyContinue).FullName 
        }
    } catch {
        # If we can't resolve it (permissions, etc.), just return the trimmed original
    }
    return $cleanP
}

# Ensure sccache is stopped
stop-process -name sccache -Force -ErrorAction SilentlyContinue

# 1. Load env vars
$envFile = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "env_vars.ps1"
if (-not (Test-Path $envFile)) { Write-Fail "env_vars.ps1 not found." }
. $envFile

# 2. Activate MSVC
Write-Step "Activating MSVC and Canonicalizing Environment"
$tempBatch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "load_vs_env.bat")
$envLog = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "vs_env.txt")
$vcvarsArgs = if ($script:VcvarsVersion) { "x64 -vcvars_ver=$($script:VcvarsVersion)" } else { "x64" }

Set-Content -Path $tempBatch -Value "@echo off`ncall `"$script:VcvarsPath`" $vcvarsArgs`nset > `"$envLog`"" -Encoding ASCII
& "$env:SystemRoot\System32\cmd.exe" /c "set PATH=C:\Windows\system32;C:\Windows && $tempBatch"

# 3. Cleanup
if ($Clean) {
    Write-Step "Cleaning build artifacts"
    @("$script:PyTorchDir\build", "$script:PyTorchDir\dist") | ForEach-Object {
        if (Test-Path $_) { Remove-Item -Recurse -Force $_ }
    }
}

# 4. Sync CUDAHOSTCXX and Finalize
conda activate $script:CondaEnv

# 5. Build
Write-Step "Building PyTorch wheel"
if ($env:CMAKE_CUDA_COMPILER_LAUNCHER) { 
    & $env:CMAKE_CUDA_COMPILER_LAUNCHER --start-server 2>$null 
}

Push-Location $script:PyTorchDir
    $start = Get-Date
    # Use the canonicalized python path
    & (Canonicalize-Path $script:CondaPython) setup.py bdist_wheel
    $exitCode = $LASTEXITCODE
    $elapsed = [math]::Round(((Get-Date)-$start).TotalMinutes,1)
Pop-Location

if ($exitCode -ne 0) { Write-Fail "Build FAILED after $elapsed min" }
Write-OK "Build Successful in $elapsed minutes!"