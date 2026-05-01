# ============================================================
# 1_prepare.ps1
# Sets up conda env, installs deps, selects MSVC toolset,
# writes env_vars.ps1 for the build step to load.
# Run once (or with -Force to redo deps).
# ============================================================

param(
    [string]$PyTorchDir  = "D:\Workplace\PyTorch-build\pytorch",
    [string]$CudaVersion = "12.9",           # <-- new: default 12.9, pass e.g. -CudaVersion 13.2
    [string]$CudaRoot    = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA",
    [string]$CudnnRoot   = "C:\Program Files\NVIDIA\CUDNN\v9.21",
    [string]$CondaEnv    = "pytorch-build",
    [string]$PythonVer   = "3.13",
    [switch]$Force       # re-install deps even if already present
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "    [FAIL] $m" -ForegroundColor Red; exit 1 }

# Derive full CUDA home from root + version
$CudaHome = "$CudaRoot\v$CudaVersion"

# ------------------------------------------------------------
# 1. Discover MSVC toolsets
# ------------------------------------------------------------
Write-Step "Discovering installed MSVC toolsets"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstallDirs = @()
if (Test-Path $vswhere) {
    $vsInstallDirs = & $vswhere -all -products * -property installationPath 2>$null
    Write-OK "vswhere found -- $($vsInstallDirs.Count) VS install(s)"
} else {
    Write-Warn "vswhere not found -- falling back to directory scan"
    foreach ($root in @("C:\Program Files\Microsoft Visual Studio","C:\Program Files (x86)\Microsoft Visual Studio")) {
        if (Test-Path $root) {
            Get-ChildItem $root -Directory -ErrorAction SilentlyContinue |
                ForEach-Object { Get-ChildItem $_.FullName -Directory -ErrorAction SilentlyContinue |
                    ForEach-Object { $vsInstallDirs += $_.FullName } }
        }
    }
}

$toolsets = @()
foreach ($vsDir in $vsInstallDirs) {
    Get-ChildItem "$vsDir\VC\Tools\MSVC" -Recurse -Filter "cl.exe" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "HostX64\\x64" } |
        ForEach-Object {
            $msvcVer = ($_.FullName -split "\\MSVC\\")[1] -split "\\" | Select-Object -First 1
            $edition = if ($vsDir -match "BuildTools")   {"Build Tools"}
                  elseif ($vsDir -match "Community")     {"Community"}
                  elseif ($vsDir -match "Professional")  {"Professional"}
                  elseif ($vsDir -match "Enterprise")    {"Enterprise"}
                  else                                   {"Unknown"}
            $vsYear  = if ($vsDir -match "\\2022")  {"2022"}
                  elseif ($vsDir -match "\\2019")    {"2019"}
                  elseif ($vsDir -match "\\2017")    {"2017"}
                  elseif ($vsDir -match "\\18")      {"2025"}
                  else                               {"Unknown"}
            # CUDA 12.x requires MSVC < 14.50
            $supported = ([version]$msvcVer -ge [version]"14.10" -and [version]$msvcVer -lt [version]"14.50")
            $toolsets += [PSCustomObject]@{
                Path          = $_.FullName
                MsvcVersion   = $msvcVer
                VSYear        = $vsYear
                Edition       = $edition
                CudaSupported = $supported
            }
        }
}

if ($toolsets.Count -eq 0) { Write-Fail "No MSVC toolsets found. Install Visual Studio 2022 Build Tools." }

# ------------------------------------------------------------
# 2. Toolset selection menu
# ------------------------------------------------------------
Write-Host ""
Write-Host ("  {0,-4} {1,-8} {2,-16} {3,-14} {4}" -f "#","VS Year","MSVC Ver","Edition","CUDA $CudaVersion ?") -ForegroundColor Gray
Write-Host ("  " + "-"*62) -ForegroundColor Gray
for ($i = 0; $i -lt $toolsets.Count; $i++) {
    $t      = $toolsets[$i]
    $status = if ($t.CudaSupported) {"[supported]"} else {"[unsupported]"}
    $color  = if ($t.CudaSupported) {"Green"} else {"Yellow"}
    Write-Host ("  [{0}] VS {1,-6} MSVC {2,-14} {3,-14} {4}" -f ($i+1),$t.VSYear,$t.MsvcVersion,$t.Edition,$status) -ForegroundColor $color
}

$defaultIdx = 0
$supportedToolsets = $toolsets | Where-Object { $_.CudaSupported }
if ($supportedToolsets) {
    $best       = $supportedToolsets | Sort-Object MsvcVersion -Descending | Select-Object -First 1
    $defaultIdx = [array]::IndexOf($toolsets, $best)
}

Write-Host ""
Write-Host ("  Press Enter to use [{0}] (recommended), or type a number: " -f ($defaultIdx+1)) -NoNewline -ForegroundColor White
$inp = Read-Host
$idx = if ($inp -match '^\d+$') { [int]$inp - 1 } else { $defaultIdx }
if ($idx -lt 0 -or $idx -ge $toolsets.Count) { Write-Fail "Invalid selection." }

$chosen = $toolsets[$idx]
Write-OK "Selected  : VS $($chosen.VSYear) / MSVC $($chosen.MsvcVersion) / $($chosen.Edition)"
Write-OK "cl.exe    : $($chosen.Path)"

$allowUnsupported = -not $chosen.CudaSupported
if ($allowUnsupported) { Write-Warn "Unsupported toolset -- will add -allow-unsupported-compiler" }

# ------------------------------------------------------------
# 3. Prereq checks
# ------------------------------------------------------------
Write-Step "Checking prerequisites"

if (-not (Test-Path $PyTorchDir))              { Write-Fail "PyTorch source not found at $PyTorchDir" }
if (-not (Test-Path "$CudaHome\bin\nvcc.exe")) { Write-Fail "nvcc not found at $CudaHome\bin\nvcc.exe -- is CUDA $CudaVersion installed?" }
Write-OK "PyTorch source : $PyTorchDir"
Write-OK "CUDA $CudaVersion    : $CudaHome"

foreach ($cmd in @("conda","rustc","ninja")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Write-Fail "$cmd not found in PATH" }
    Write-OK "$cmd found"
}

# ------------------------------------------------------------
# 4. cuDNN detection
# ------------------------------------------------------------
Write-Step "Detecting cuDNN (root: $CudnnRoot)"

if (-not (Test-Path $CudnnRoot)) {
    Write-Fail "cuDNN root not found at $CudnnRoot. Install cuDNN or set -CudnnRoot."
}

# cuDNN v9+ installs headers/libs under a CUDA-version subfolder.
# Try exact version first, then major-only, then flat (legacy layout).
$cudaVerMajor = $CudaVersion.Split(".")[0]  # e.g. "12" from "12.9"

$cudnnCandidates = @(
    "$CudnnRoot"                       # flat legacy layout
)

$cudnnBase = $null
foreach ($candidate in $cudnnCandidates) {
    $testHeader = "$candidate\include\$CudaVersion\cudnn.h"
    $testLib    = "$candidate\lib\$CudaVersion\x64\cudnn.lib"
    if ((Test-Path $testHeader) -and (Test-Path $testLib)) {
        $cudnnBase = $candidate
        break
    }
}

if (-not $cudnnBase) {
    # Print what we actually found to help diagnose
    Write-Host ""
    Write-Host "    Searched for cudnn.h + cudnn.lib under:" -ForegroundColor Yellow
    foreach ($c in $cudnnCandidates) { Write-Host "      $c\include\  /  $c\lib\x64\" -ForegroundColor Yellow }
    Write-Host ""
    Write-Host "    Actual contents of $CudnnRoot :" -ForegroundColor Yellow
    Get-ChildItem $CudnnRoot -ErrorAction SilentlyContinue | ForEach-Object {
        Write-Host "      $($_.Name)" -ForegroundColor Yellow
    }
    Write-Fail "cudnn.h / cudnn.lib not found. Check -CudnnRoot and that the CUDA $CudaVersion subfolder exists."
}

$cudnnInclude = "$cudnnBase\include\$CudaVersion"
$cudnnLibDir  = "$cudnnBase\lib\$CudaVersion\x64"
$cudnnLib     = "$cudnnLibDir\cudnn.lib"

# Read cuDNN version from header
$cudnnVerString = "unknown"
$verHeader = "$cudnnInclude\cudnn_version.h"
if (-not (Test-Path $verHeader)) { $verHeader = "$cudnnInclude\cudnn.h" }
if (Test-Path $verHeader) {
    $major = (Select-String -Path $verHeader -Pattern '#define\s+CUDNN_MAJOR\s+(\d+)' | Select-Object -First 1).Matches.Groups[1].Value
    $minor = (Select-String -Path $verHeader -Pattern '#define\s+CUDNN_MINOR\s+(\d+)' | Select-Object -First 1).Matches.Groups[1].Value
    $patch = (Select-String -Path $verHeader -Pattern '#define\s+CUDNN_PATCHLEVEL\s+(\d+)' | Select-Object -First 1).Matches.Groups[1].Value
    if ($major) { $cudnnVerString = "$major.$minor.$patch" }
}

Write-OK "cuDNN version  : $cudnnVerString"
Write-OK "cuDNN base     : $cudnnBase"
Write-OK "cuDNN include  : $cudnnInclude"
Write-OK "cuDNN lib      : $cudnnLib"

# ------------------------------------------------------------
# 5. Conda env
# ------------------------------------------------------------
Write-Step "Setting up conda environment '$CondaEnv'"
if (-not (conda env list | Select-String -Pattern "^$CondaEnv\s")) {
    conda create -n $CondaEnv python=$PythonVer -y
    Write-OK "Created env '$CondaEnv'"
} else {
    Write-OK "Env '$CondaEnv' already exists"
}

# ------------------------------------------------------------
# 6. Python deps
# ------------------------------------------------------------
Write-Step "Installing Python build dependencies"
if ($Force -or -not (conda run -n $CondaEnv pip show pyyaml 2>$null)) {
    conda run -n $CondaEnv pip install cmake ninja mkl-static mkl-include pyyaml typing_extensions requests
    Push-Location $PyTorchDir
        conda run -n $CondaEnv pip install -r requirements.txt
    Pop-Location
    Write-OK "Deps installed"
} else {
    Write-OK "Deps already present (use -Force to reinstall)"
}

# ------------------------------------------------------------
# 7. Get conda python path
# ------------------------------------------------------------
$condaPython = (conda run -n $CondaEnv python -c "import sys; print(sys.executable)" 2>$null).Trim()
if (-not $condaPython) { Write-Fail "Could not resolve python path in '$CondaEnv'" }

# ------------------------------------------------------------
# 8. Clear stale CMake cache
# ------------------------------------------------------------
Write-Step "Clearing stale CMake cache"
$buildDir = Join-Path $PyTorchDir "build"
if (Test-Path $buildDir) {
    Remove-Item -Recurse -Force $buildDir
    Write-OK "Removed $buildDir"
} else {
    Write-OK "No existing cache"
}
Get-ChildItem $PyTorchDir -Filter "torch.egg-info" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -Recurse -Force $_.FullName }

# ------------------------------------------------------------
# 9. Write env_vars.ps1 for build step
# ------------------------------------------------------------
Write-Step "Writing env_vars.ps1"

$envFile    = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "env_vars.ps1"
$nvccFlags  = if ($allowUnsupported) { '"-allow-unsupported-compiler"' } else { '""' }
$cudaVerEsc = [regex]::Escape("$CudaRoot\v")

# Compute TORCH_CUDA_ARCH_LIST from version:
#   12.x -> sm_60 baseline + sm_120 (Blackwell)
#   older -> sm_60 baseline only (safe default)
$archList = switch -Wildcard ($CudaVersion) {
    "12.*" { "6.0;12.0" }
    "13.*" { "6.0;12.0" }   # update when sm_130 is confirmed
    default { "6.0;7.0;7.5;8.0;8.6" }
}

@"
# Auto-generated by 1_prepare.ps1 -- do not edit manually
# CUDA version : $CudaVersion
# cuDNN version: $cudnnVerString

# --- cuDNN ---
`$env:CUDNN_ROOT                  = "$cudnnBase"
`$env:CUDNN_ROOT_DIR              = "$cudnnBase"
`$env:CUDNN_INCLUDE_PATH          = "$cudnnInclude"
`$env:CUDNN_LIBRARY_PATH          = "$cudnnLibDir"
`$env:CUDNN_LIBRARY               = "$cudnnLib"

# --- CUDA ---
`$env:CUDA_HOME                   = "$CudaHome"
`$env:CUDA_PATH                   = "$CudaHome"
`$env:TORCH_CUDA_ARCH_LIST        = "$archList"

# --- MSVC host compiler (keep consistent for both CMake and NVCC) ---
`$env:CUDAHOSTCXX                 = "$($chosen.Path)"
`$env:CXX                         = "$($chosen.Path)"
`$env:CC                          = "$($chosen.Path)"
`$env:CMAKE_CUDA_HOST_COMPILER    = "$($chosen.Path)"

# --- PATH: put selected CUDA first, strip other CUDA versions ---
`$env:PATH = "$CudaHome\bin;$CudaHome\libnvvp;" + (`$env:PATH -replace [regex]::Escape("$CudaRoot\v") + '[^;]+;', "")

# Add cuDNN to PATH so the build can find the DLLs
`$env:PATH = "C:\Program Files\NVIDIA\CUDNN\v9.21\bin\12.9\x64;" + "$env:PATH"

# --- Build feature flags ---
`$env:USE_CUDA                    = "1"
`$env:USE_CUDNN                   = "1"
`$env:USE_FLASH_ATTENTION         = "1"
`$env:USE_MKLDNN                  = "1"
`$env:USE_DISTRIBUTED             = "1"
`$env:USE_GLOO                    = "1"
`$env:USE_NUMPY                   = "1"
`$env:USE_KINETO                  = "1"
`$env:USE_TEST                    = "0"

# --- Parallelism ---
`$env:CMAKE_BUILD_PARALLEL_LEVEL  = "$([Environment]::ProcessorCount - 4)"
`$env:MAX_JOBS                    = "4"

# --- NVCC extra flags ---
`$env:NVCC_APPEND_FLAGS           = $nvccFlags
`$env:REL_WITH_DEB_INFO           = "0"
`$env:EXTRA_CAFFE2_CMAKE_FLAGS    = "-DCMAKE_CXX_FLAGS_RELEASE=/O1"
`$env:NVCC_APPEND_FLAGS           = "--diag-suppress=20092"

# --- Shared with 2_build.ps1 ---
`$script:CondaPython              = "$condaPython"
`$script:PyTorchDir               = "$PyTorchDir"
`$script:CondaEnv                 = "$CondaEnv"
"@ | Set-Content -Path $envFile -Encoding UTF8

Write-OK "Written: $envFile"

# ------------------------------------------------------------
# Summary
# ------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Preparation complete. Summary:"                              -ForegroundColor Cyan
Write-Host ""
Write-Host ("   CUDA          : {0}"   -f $CudaVersion)                 -ForegroundColor White
Write-Host ("   cuDNN         : {0}"   -f $cudnnVerString)              -ForegroundColor White
Write-Host ("   MSVC          : {0} ({1})" -f $chosen.MsvcVersion, $chosen.Edition) -ForegroundColor White
Write-Host ("   Arch list     : {0}"   -f $archList)                    -ForegroundColor White
Write-Host ""
Write-Host " Next step:"                                                  -ForegroundColor Cyan
Write-Host ""
Write-Host "   .\2_build.ps1"                                            -ForegroundColor White
Write-Host "============================================================" -ForegroundColor Cyan