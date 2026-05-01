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
# Patch: disable /O2 -> /Od for sdp.cpp to avoid MSVC ICE
# ------------------------------------------------------------
Write-Step "Patching oneDNN sdp.cpp for MSVC ICE workaround"

$sdpCpp = "$script:PyTorchDir\third_party\ideep\mkl-dnn\src\graph\backend\dnnl\patterns\sdp.cpp"
$sdpFlag = "$script:PyTorchDir\third_party\ideep\mkl-dnn\src\graph\backend\dnnl\CMakeLists.txt"

# Add compile flag override for just that file
$flagsFile = "$script:PyTorchDir\cmake\ice_workaround.cmake"
Set-Content -Path $flagsFile -Encoding UTF8 -Value @'
# Workaround: MSVC ICE on sdp.cpp with /O2 optimization
set_source_files_properties(
    "${CMAKE_CURRENT_SOURCE_DIR}/patterns/sdp.cpp"
    PROPERTIES COMPILE_FLAGS "/Od"
)
'@

# Inject include into the affected CMakeLists.txt if not already there
$cmakeContent = Get-Content $sdpFlag -Raw
if ($cmakeContent -notmatch "ice_workaround") {
    $cmakeContent = $cmakeContent -replace 
        "(project\(dnnl.*?\))", 
        "`$1`ninclude(`"$($script:PyTorchDir -replace '\\','/')/cmake/ice_workaround.cmake`")"
    Set-Content -Path $sdpFlag -Value $cmakeContent -Encoding UTF8
    Write-OK "Patched CMakeLists.txt with ICE workaround"
} else {
    Write-OK "ICE workaround already applied"
}

# ------------------------------------------------------------
# 4. Launch build directly -- no pipe so output streams live
# ------------------------------------------------------------
Write-Step "Starting build (this will take 1-3 hours)"
Write-Host "    Output is live -- you will see CMake then Ninja progress" -ForegroundColor Gray
Write-Host ""

Push-Location $script:PyTorchDir
    $start = Get-Date

    # Force CMake to use the VS 2022 compiler defined in your env_vars.ps1
    # This prevents Ninja from picking up VS 2025 (v18) by default.
    $env:CMAKE_ARGS = "-DCMAKE_C_COMPILER=`"$env:CUDAHOSTCXX`" " + `
                      "-DCMAKE_CXX_COMPILER=`"$env:CUDAHOSTCXX`" " + `
                      "-DCMAKE_CUDA_HOST_COMPILER=`"$env:CUDAHOSTCXX`" " + `
                      "-DCAFFE2_USE_MSVC_STATIC_RUNTIME=OFF"

    # Put the 2022 compiler folder at the VERY START of the PATH
    # This prevents Ninja from seeing VS 2025 at all.
    $msvc_bin = Split-Path $env:CUDAHOSTCXX
    $env:PATH = "$msvc_bin;" + $env:PATH

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