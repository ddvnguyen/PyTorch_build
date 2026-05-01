# ============================================================
# 2_dev_build.ps1
# Development build (in-place) - much faster than bdist_wheel
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

# ------------------------------------------------------------
# 2. Load VS vcvarsall.bat environment (PATH limit workaround)
# ------------------------------------------------------------
Write-Step "Sourcing vcvarsall.bat for x64"

if (-not (Test-Path $script:VcvarsPath)) {
    Write-Fail "vcvarsall.bat not found at $script:VcvarsPath."
}

$originalPath = $env:Path
$env:Path = "C:\Windows\system32;C:\Windows;C:\Windows\System32\Wbem"

$tempBatch = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "load_vs_env_dev.bat")
$envLog = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), "vs_env_dev.txt")

$batchContent = "@echo off`ncall `"$script:VcvarsPath`" x64`nset > `"$envLog`""
Set-Content -Path $tempBatch -Value $batchContent -Encoding ASCII

cmd /c $tempBatch

if (-not (Test-Path $envLog)) {
    Write-Fail "Environment log was not created. vcvarsall.bat failed to run."
}

Get-Content $envLog | Foreach-Object {
    if ($_ -match "^(.*?)=(.*)$") {
        $name = $matches[1]
        $value = $matches[2]
        
        if ($name -ieq "Path") {
            $combinedPaths = $value.Split(';') + $originalPath.Split(';')
            $cleanPaths = $combinedPaths | Where-Object { $_ -ne "" } | Select-Object -Unique
            $env:Path = ($cleanPaths -join ";")
        } elseif ($name -notmatch "^prompt$|^=") {
            Set-Item "env:$name" $value
        }
    }
}

$pathList = $env:Path.Split(';')
$uniquePath = $pathList | Select-Object -Unique
$env:Path = $uniquePath -join ";"

Write-OK "Environment merged."
Remove-Item $tempBatch, $envLog -ErrorAction SilentlyContinue

# ------------------------------------------------------------
# 3. Activate conda env
# ------------------------------------------------------------
Write-Step "Activating conda environment '$script:CondaEnv'"
conda activate $script:CondaEnv
Write-OK "Activated"

# ------------------------------------------------------------
# 4. Verify nvcc picks up the right cl.exe
# ------------------------------------------------------------
Write-Step "Verifying CUDA compiler"
$nvccVer = & "$env:CUDA_HOME\bin\nvcc.exe" --version 2>&1 | Select-String "release"
Write-OK "nvcc: $nvccVer"

# Sync CUDAHOSTCXX and Finalize
conda activate $script:CondaEnv

# FORCE CUDAHOSTCXX to be the exact same string found in PATH
if ($env:CUDAHOSTCXX) { $env:CUDAHOSTCXX = Canonicalize-Path $env:CUDAHOSTCXX }
# Also set CC and CXX to ensure PyTorch's setup.py doesn't guess wrong
$env:CC = $env:CUDAHOSTCXX
$env:CXX = $env:CUDAHOSTCXX

# ------------------------------------------------------------
# 6. Launch build directly -- in-place development mode
# ------------------------------------------------------------
Write-Step "Starting dev build (in-place setup.py develop)"
Write-Host "    Output is live -- you will see CMake then Ninja progress" -ForegroundColor Gray

Push-Location $script:PyTorchDir
    $start = Get-Date
    $cleanHostCxx = (Get-Item $env:CUDAHOSTCXX).FullName

    # Force CMake to use the VS 2022 compiler
    $env:CMAKE_ARGS = "-DCMAKE_C_COMPILER=`"$cleanHostCxx`" " + `
                      "-DCMAKE_CXX_COMPILER=`"$cleanHostCxx`" " + `
                      "-DCMAKE_CUDA_HOST_COMPILER=`"$cleanHostCxx`" " + `
                      "-DCAFFE2_USE_MSVC_STATIC_RUNTIME=OFF"

    $msvc_bin = Split-Path $env:CUDAHOSTCXX
    $env:PATH = "$msvc_bin;" + $env:PATH

    # Use 'develop' instead of 'bdist_wheel' for faster iteration
    & $script:CondaPython setup.py develop

    $exitCode = $LASTEXITCODE
    $elapsed  = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
Pop-Location

Write-Host ""
if ($exitCode -ne 0) {
    Write-Fail "Dev build FAILED after $elapsed min (exit code $exitCode)"
}
Write-OK "Dev build completed in $elapsed minutes"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Done!  Next step:"                                       -ForegroundColor Cyan
Write-Host ""
Write-Host "   .\smoke_test.ps1"                                              -ForegroundColor White
Write-Host "============================================================"  -ForegroundColor Cyan