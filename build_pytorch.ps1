# ============================================================
# PyTorch build script -- sm_60 (P100) + sm_120 (RTX 5060 Ti)
# Run from: Any PowerShell (as Administrator)
# v3: auto-detects all installed MSVC toolsets, lets you pick
# ============================================================

param(
    [string]$PyTorchDir  = ".\pytorch",
    [string]$CudaHome    = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.9",
    [string]$CondaEnv    = "pytorch-build",
    [string]$PythonVer   = "3.13",
    [switch]$SkipDeps,          # skip pip install step
    [switch]$AllowUnsupported   # pass -allow-unsupported-compiler to nvcc
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$msg) Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Write-OK   { param([string]$msg) Write-Host "    [OK] $msg" -ForegroundColor Green }
function Write-Warn { param([string]$msg) Write-Host "    [WARN] $msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$msg) Write-Host "    [FAIL] $msg" -ForegroundColor Red; exit 1 }

# ============================================================
# SECTION 1 -- Discover all installed MSVC cl.exe toolsets
# ============================================================
Write-Step "Discovering installed MSVC toolsets"

# Known VS install roots (covers Community/Professional/Enterprise/BuildTools)
$vsRoots = @(
    "C:\Program Files\Microsoft Visual Studio",
    "C:\Program Files (x86)\Microsoft Visual Studio"
)

# Also try vswhere if available (most reliable)
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstallDirs = @()
if (Test-Path $vswhere) {
    $vsInstallDirs = & $vswhere -all -products * -property installationPath 2>$null
    Write-OK "vswhere found -- scanning $($vsInstallDirs.Count) VS install(s)"
} else {
    Write-Warn "vswhere not found -- falling back to directory scan"
    foreach ($root in $vsRoots) {
        if (Test-Path $root) {
            Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                ForEach-Object {
                    Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue |
                        ForEach-Object { $vsInstallDirs += $_.FullName }
                }
        }
    }
}

# Find every cl.exe under HostX64\x64 across all installs
$toolsets = @()
foreach ($vsDir in $vsInstallDirs) {
    $clExes = Get-ChildItem "$vsDir\VC\Tools\MSVC" -Recurse -Filter "cl.exe" -ErrorAction SilentlyContinue |
              Where-Object { $_.FullName -match "HostX64\\x64" }
    foreach ($cl in $clExes) {
        # Parse VS edition and MSVC version from path
        $msvcVer  = ($cl.FullName -split "\\MSVC\\")[1] -split "\\" | Select-Object -First 1
        $edition  = if ($vsDir -match "BuildTools") { "Build Tools" }
                    elseif ($vsDir -match "Community")    { "Community"    }
                    elseif ($vsDir -match "Professional") { "Professional" }
                    elseif ($vsDir -match "Enterprise")   { "Enterprise"   }
                    else                                  { "Unknown"      }
        $vsYear   = if ($vsDir -match "\\2022") { "2022" }
                    elseif ($vsDir -match "\\2019") { "2019" }
                    elseif ($vsDir -match "\\2017") { "2017" }
                    elseif ($vsDir -match "\\18")   { "2025" }
                    else { "Unknown" }

        # CUDA 12.9 supports VS 2017-2022 (MSVC 14.10-14.39)
        $msvcMajorMinor = [version]$msvcVer
        $cudaSupported  = ($msvcMajorMinor -ge [version]"14.10" -and $msvcMajorMinor -lt [version]"14.50")

        $toolsets += [PSCustomObject]@{
            Path          = $cl.FullName
            MsvcVersion   = $msvcVer
            VSYear        = $vsYear
            Edition       = $edition
            CudaSupported = $cudaSupported
        }
    }
}

if ($toolsets.Count -eq 0) {
    Write-Fail "No MSVC cl.exe toolsets found. Install Visual Studio 2022 (with C++ workload)."
}

# ============================================================
# SECTION 2 -- Display menu and let user pick
# ============================================================
Write-Host ""
Write-Host "  Found $($toolsets.Count) MSVC toolset(s):" -ForegroundColor White
Write-Host ""
Write-Host ("  {0,-4} {1,-8} {2,-14} {3,-12} {4}" -f "#", "VS Year", "MSVC Ver", "Edition", "CUDA 12.9 OK?") -ForegroundColor Gray
Write-Host ("  {0}" -f ("-" * 70)) -ForegroundColor Gray

for ($i = 0; $i -lt $toolsets.Count; $i++) {
    $t      = $toolsets[$i]
    $status = if ($t.CudaSupported) { "[supported]" } else { "[unsupported]" }
    $color  = if ($t.CudaSupported) { "Green" } else { "Yellow" }
    $line   = "  [{0}] VS {1,-6} MSVC {2,-14} {3,-14} {4}" -f ($i+1), $t.VSYear, $t.MsvcVersion, $t.Edition, $status
    Write-Host $line -ForegroundColor $color
}

# Pre-select: prefer highest supported version, fall back to first entry
$defaultIdx = 0
$supported  = $toolsets | Where-Object { $_.CudaSupported }
if ($supported) {
    $best       = $supported | Sort-Object MsvcVersion -Descending | Select-Object -First 1
    $defaultIdx = [array]::IndexOf($toolsets, $best)
}

Write-Host ""
Write-Host ("  Press Enter to use [{0}] (recommended), or type a number: " -f ($defaultIdx + 1)) -NoNewline -ForegroundColor White
$input = Read-Host

$selectedIdx = if ($input -match '^\d+$') { [int]$input - 1 } else { $defaultIdx }

if ($selectedIdx -lt 0 -or $selectedIdx -ge $toolsets.Count) {
    Write-Fail "Invalid selection '$input'. Please run again and choose 1-$($toolsets.Count)."
}

$chosen = $toolsets[$selectedIdx]
Write-Host ""
Write-OK "Selected: VS $($chosen.VSYear) / MSVC $($chosen.MsvcVersion) / $($chosen.Edition)"
Write-OK "cl.exe  : $($chosen.Path)"

if (-not $chosen.CudaSupported) {
    Write-Warn "This toolset (MSVC $($chosen.MsvcVersion)) is outside CUDA 12.9's supported range (14.10-14.39)."
    Write-Warn "Adding -allow-unsupported-compiler to nvcc flags automatically."
    $AllowUnsupported = $true
}

# ============================================================
# SECTION 3 -- Prerequisites check
# ============================================================
Write-Step "Checking prerequisites"

if (-not (Test-Path $PyTorchDir)) {
    Write-Fail "PyTorch source not found at $PyTorchDir`n    Clone: git clone --recursive https://github.com/pytorch/pytorch $PyTorchDir"
}
Write-OK "PyTorch source: $PyTorchDir"

if (-not (Test-Path "$CudaHome\bin\nvcc.exe")) {
    Write-Fail "nvcc not found at $CudaHome\bin\nvcc.exe -- check CUDA 12.9 install path"
}
Write-OK "CUDA: $CudaHome"

foreach ($cmd in @("conda","rustc","ninja")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Write-Fail "$cmd not found in PATH"
    }
    Write-OK "$cmd found"
}

# ============================================================
# SECTION 4 -- Conda env
# ============================================================
Write-Step "Setting up conda environment '$CondaEnv'"

$envExists = conda env list | Select-String -Pattern "^$CondaEnv\s"
if (-not $envExists) {
    Write-Host "    Creating conda env '$CondaEnv' (Python $PythonVer)..."
    conda create -n $CondaEnv python=$PythonVer -y
    Write-OK "Conda env created"
} else {
    Write-OK "Conda env '$CondaEnv' already exists"
}

# ============================================================
# SECTION 5 -- Python deps (skippable)
# ============================================================
if (-not $SkipDeps) {
    Write-Step "Installing Python build dependencies"
    conda run -n $CondaEnv pip install cmake ninja mkl-static mkl-include pyyaml typing_extensions requests
    Push-Location $PyTorchDir
        conda run -n $CondaEnv pip install -r requirements.txt
    Pop-Location
    Write-OK "Python deps installed"
} else {
    Write-Step "Skipping deps install (-SkipDeps)"
}

# ============================================================
# SECTION 6 -- Build environment variables
# ============================================================
Write-Step "Configuring build environment"

# Point nvcc at the chosen cl.exe
$env:CUDAHOSTCXX                 = $chosen.Path
$env:CudaToolkitRoot             = $CudaHome
$env:CUDA_HOME                   = $CudaHome
$env:CUDA_PATH                   = $CudaHome

# Prepend CUDA 12.9 bin FIRST -- prevents CUDA 13.2 from hijacking nvcc
$env:PATH = "$CudaHome\bin;$CudaHome\libnvvp;" + ($env:PATH -replace [regex]::Escape("C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2\bin;"), "")

$env:TORCH_CUDA_ARCH_LIST        = "6.0;12.0"
$env:USE_CUDA                    = "1"
$env:USE_FLASH_ATTENTION         = "1"
$env:USE_DISTRIBUTED             = "0"
$env:USE_TEST                    = "0"
$env:CMAKE_BUILD_PARALLEL_LEVEL  = [string][Environment]::ProcessorCount

if ($AllowUnsupported) {
    $env:NVCC_APPEND_FLAGS = "-allow-unsupported-compiler"
    Write-Warn "NVCC_APPEND_FLAGS = -allow-unsupported-compiler"
}

Write-OK "CUDAHOSTCXX          = $env:CUDAHOSTCXX"
Write-OK "TORCH_CUDA_ARCH_LIST = $env:TORCH_CUDA_ARCH_LIST"
Write-OK "CUDA_HOME            = $env:CUDA_HOME"
Write-OK "Build parallelism    = $env:CMAKE_BUILD_PARALLEL_LEVEL cores"

# ============================================================
# SECTION 7 -- Clear stale CMake cache
# ============================================================
Write-Step "Clearing stale CMake cache"

$buildDir = Join-Path $PyTorchDir "build"
if (Test-Path $buildDir) {
    Remove-Item -Recurse -Force $buildDir
    Write-OK "Removed $buildDir"
} else {
    Write-OK "No existing cache -- clean start"
}
Get-ChildItem $PyTorchDir -Filter "torch.egg-info" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -Recurse -Force $_.FullName }

# ============================================================
# SECTION 8 -- Build (direct invoke for live output)
# ============================================================
Write-Step "Building PyTorch wheel (1-3 hours on $env:CMAKE_BUILD_PARALLEL_LEVEL cores)"
Write-Host "    Live output streaming -- full log saved to build_log.txt" -ForegroundColor Gray

# Get python path inside the conda env
$condaPython = (conda run -n $CondaEnv python -c "import sys; print(sys.executable)" 2>$null).Trim()
if (-not $condaPython) { Write-Fail "Could not find python in conda env '$CondaEnv'" }
Write-OK "Using Python: $condaPython"

# Activate conda env in current shell so the python is on PATH
conda activate $CondaEnv

$logFile   = Join-Path $PyTorchDir "build_log.txt"
$buildStart = Get-Date

Push-Location $PyTorchDir
    # Run directly (not via conda run) so stdout/stderr stream live
    # Tee-Object mirrors output to console AND saves to log file
    $PSNativeCommandUseErrorActionPreference = $false
    & $condaPython setup.py bdist_wheel 2>&1 | ForEach-Object {
        Write-Host $_
        Add-Content -Path $logFile -Value $_
    }
    $exitCode = $LASTEXITCODE
Pop-Location

$elapsed = (Get-Date) - $buildStart

if ($exitCode -ne 0) {
    Write-Host ""
    Write-Fail "Build failed after $([math]::Round($elapsed.TotalMinutes,1)) min -- see $logFile for full output"
}
Write-OK "Build completed in $([math]::Round($elapsed.TotalMinutes,1)) minutes"
Write-OK "Full log: $logFile"

# ============================================================
# SECTION 9 -- Install wheel
# ============================================================
Write-Step "Installing built wheel"

$wheel = Get-ChildItem "$PyTorchDir\dist\torch-*.whl" |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $wheel) { Write-Fail "No wheel found in $PyTorchDir\dist\" }

Write-Host "    Installing $($wheel.Name)..."
& $condaPython -m pip install $wheel.FullName --force-reinstall
if ($LASTEXITCODE -ne 0) { Write-Fail "Wheel install failed" }
Write-OK "Installed: $($wheel.Name)"

# ============================================================
# SECTION 10 -- Verify
# ============================================================
Write-Step "Verifying installation"

$verifyPy = Join-Path $env:TEMP "verify_torch.py"
Set-Content -Path $verifyPy -Encoding UTF8 -Value @'
import torch, sys
print("PyTorch :", torch.__version__)
print("CUDA    :", torch.version.cuda)
print("Archs   :", torch.cuda.get_arch_list())
archs    = torch.cuda.get_arch_list()
sm60_ok  = "sm_60"  in archs
sm120_ok = "sm_120" in archs
print("sm_60   :", "OK" if sm60_ok  else "MISSING")
print("sm_120  :", "OK" if sm120_ok else "MISSING")
for i in range(torch.cuda.device_count()):
    p = torch.cuda.get_device_properties(i)
    cap = f"sm_{p.major}{p.minor}"
    ok  = cap in archs
    print(f"GPU {i}  : {p.name} ({cap}) -- {'OK' if ok else 'NOT IN ARCH LIST'}")
sys.exit(0 if (sm60_ok and sm120_ok) else 1)
'@

& $condaPython $verifyPy
if ($LASTEXITCODE -ne 0) {
    Write-Warn "One or both architectures missing from arch list"
} else {
    Write-OK "Both sm_60 and sm_120 confirmed"
}
Remove-Item $verifyPy -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Done!  conda activate $CondaEnv"                             -ForegroundColor Cyan
Write-Host "============================================================"  -ForegroundColor Cyan


