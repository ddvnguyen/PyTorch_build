# ============================================================
# 2_build.ps1
# Loads env vars written by 1_prepare.ps1, activates conda
# env, then launches the build directly (no piping) so you
# see live Ninja/CMake output in the terminal.
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Fail { param([string]$m) Write-Host "    [FAIL] $m" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------
# 1. Load env vars from prepare step
# ------------------------------------------------------------
$envFile = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "env_vars.ps1"
if (-not (Test-Path $envFile)) {
    Write-Fail "env_vars.ps1 not found -- run 1_prepare.ps1 first"
}

Write-Step "Loading environment from env_vars.ps1"
. $envFile
Write-OK "CUDAHOSTCXX          = $env:CUDAHOSTCXX"
Write-OK "TORCH_CUDA_ARCH_LIST = $env:TORCH_CUDA_ARCH_LIST"
Write-OK "CUDA_HOME            = $env:CUDA_HOME"
Write-OK "Build parallelism    = $env:CMAKE_BUILD_PARALLEL_LEVEL cores"
Write-OK "Python               = $script:CondaPython"
Write-OK "PyTorch source       = $script:PyTorchDir"

# ------------------------------------------------------------
# 2. Activate conda env
# ------------------------------------------------------------
Write-Step "Activating conda environment '$script:CondaEnv'"
conda activate $script:CondaEnv
Write-OK "Activated"

# ------------------------------------------------------------
# 3. Verify nvcc picks up the right cl.exe
# ------------------------------------------------------------
Write-Step "Verifying CUDA compiler"
$nvccVer = & "$env:CUDA_HOME\bin\nvcc.exe" --version 2>&1 | Select-String "release"
Write-OK "nvcc: $nvccVer"

# ------------------------------------------------------------
# 4. Launch build directly -- no pipe so output streams live
# ------------------------------------------------------------
Write-Step "Starting build (this will take 1-3 hours)"
Write-Host "    Output is live -- you will see CMake then Ninja progress" -ForegroundColor Gray
Write-Host ""

Push-Location $script:PyTorchDir
    $start = Get-Date

    # Direct call -- stdout and stderr both go straight to terminal
    & $script:CondaPython setup.py bdist_wheel

    $exitCode = $LASTEXITCODE
    $elapsed  = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
Pop-Location

Write-Host ""
if ($exitCode -ne 0) {
    Write-Fail "Build FAILED after $elapsed min (exit code $exitCode)"
}
Write-OK "Build completed in $elapsed minutes"

# ------------------------------------------------------------
# 5. Show wheel location
# ------------------------------------------------------------
$wheel = Get-ChildItem "$script:PyTorchDir\dist\torch-*.whl" |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
if ($wheel) {
    Write-OK "Wheel: $($wheel.FullName)"
} else {
    Write-Warn "No wheel found in $script:PyTorchDir\dist\ -- check build output"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Build done. Next step:"                                       -ForegroundColor Cyan
Write-Host ""
Write-Host "   .\3_test.ps1"                                              -ForegroundColor White
Write-Host "============================================================"  -ForegroundColor Cyan