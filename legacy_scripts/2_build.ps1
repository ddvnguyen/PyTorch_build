# ============================================================
# 2_build.ps1 (Modified with Skip-Test and Clean-Build)
# ============================================================

param(
    [switch]$SkipTest = $false,
    [switch]$Clean    = $false
)

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
# 2. Cleanup (Optional)
# ------------------------------------------------------------
if ($Clean) {
    Write-Step "Cleaning build artifacts..."
    $pathsToClean = @("build", "dist", "build_python")
    foreach ($p in $pathsToClean) {
        $fullPath = Join-Path $script:PyTorchDir $p
        if (Test-Path $fullPath) {
            Write-Host "    Removing $fullPath" -ForegroundColor Gray
            Remove-Item -Recurse -Force $fullPath
        }
    }
    Write-OK "Clean completed"
}

# ------------------------------------------------------------
# 3. Load VS vcvarsall.bat environment
# ------------------------------------------------------------
Write-Step "Sourcing vcvarsall.bat for x64"

# Typically located in a path like C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvarsall.bat
# We use the parent directory of your CUDAHOSTCXX to find the VS root if not explicitly set
if (-not (Test-Path $script:VcvarsPath)) {
    Write-Fail "vcvarsall.bat not found at $script:VcvarsPath. Please verify your VS 2022 installation path."
}

# This trick runs the batch file and exports the resulting environment to a temp file
$tempFile = [System.IO.Path]::GetTempFileName()
cmd /c "`"$script:VcvarsPath`" x64 && set" > $tempFile

# Parse the temp file and set variables in the current PowerShell session
Get-Content $tempFile | Foreach-Object {
    if ($_ -match "^(.*?)=(.*)$") {
        $name = $matches[1]
        $value = $matches[2]
        if ($name -ieq "Path") {
            # Special handling for Path to append/prepend rather than overwrite if desired, 
            # but usually overwriting with the VS-defined path is what you want for the build.
            $env:Path = $value
        } else {
            Set-Item "env:$name" $value
        }
    }
}
Remove-Item $tempFile
Write-OK "Visual Studio environment loaded"

# ------------------------------------------------------------
# Activate conda env
# ------------------------------------------------------------
Write-Step "Activating conda environment '$script:CondaEnv'"
conda activate $script:CondaEnv
Write-OK "Activated"

# ------------------------------------------------------------
# Verify nvcc picks up the right cl.exe
# ------------------------------------------------------------
Write-Step "Verifying CUDA compiler"
$nvccVer = & "$env:CUDA_HOME\bin\nvcc.exe" --version 2>&1 | Select-String "release"
Write-OK "nvcc: $nvccVer"

# ------------------------------------------------------------
# 5. Launch build
# ------------------------------------------------------------
Write-Step "Starting build"
if ($SkipTest) { Write-Host "    [!] BUILD_TEST is DISABLED" -ForegroundColor Yellow }

Push-Location $script:PyTorchDir
    $start = Get-Date

    $cleanHostCxx = (Get-Item $env:CUDAHOSTCXX).FullName

    # Force CMake to use the VS 2022 compiler defined in your env_vars.ps1
    # This prevents Ninja from picking up VS 2025 (v18) by default.
    $env:CMAKE_ARGS = "-DCMAKE_C_COMPILER=`"$cleanHostCxx`" " + `
                      "-DCMAKE_CXX_COMPILER=`"$cleanHostCxx`" " + `
                      "-DCMAKE_CUDA_HOST_COMPILER=`"$cleanHostCxx`" " + `
                      "-DCAFFE2_USE_MSVC_STATIC_RUNTIME=OFF" 

    if ($SkipTest) 
    { 
        $env:CMAKE_ARGS += " -DBUILD_TEST=OFF" 
    }

    # Put the 2022 compiler folder at the VERY START of the PATH
    # This prevents Ninja from seeing VS 2025 at all.
    $msvc_bin = Split-Path $env:CUDAHOSTCXX
    $env:PATH = "$msvc_bin;" + $env:PATH

    & $script:CondaPython setup.py bdist_wheel

    $exitCode = $LASTEXITCODE
    $elapsed  = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)
Pop-Location

Write-Host ""
if ($exitCode -ne 0) 
{ 
    Write-Fail "Build FAILED after $elapsed min (exit code $exitCode)"
}
Write-OK "Build completed in $elapsed minutes"

# ------------------------------------------------------------
# 7. Show wheel location
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