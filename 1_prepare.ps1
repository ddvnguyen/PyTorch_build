# ============================================================
# 1_prepare.ps1  (v3)
# Aligned with:
#   - PyTorch Windows FAQ (docs.pytorch.org/docs/2.11/notes/windows.html)
#   - TorchAudio Windows build guide (docs.pytorch.org/audio/2.8/build.windows.html)
#
# Changes vs v2:
#   - CMAKE_GENERATOR=Ninja (FAQ: VS doesn't support parallel custom tasks)
#   - CMAKE_INCLUDE_PATH + LIB set for MKL (FAQ: required for MKL detection)
#   - MAGMA detection + MAGMA_HOME (FAQ: optional GPU linear algebra)
#   - vcvarsall.bat x64 activation written into env_vars.ps1
#   - cuDNN into conda dirs option (official TorchAudio method)
#   - Clean PATH at load time
# ============================================================

param(
    [string]$PyTorchDir  = "D:\Workplace\PyTorch-build\pytorch",
    [string]$CudaVersion = "12.9",
    [string]$CudaRoot    = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA",
    [string]$CudnnRoot   = "C:\Program Files\NVIDIA\CUDNN\v9.21",
    [string]$MagmaDir    = "",         # optional: path to extracted MAGMA dir
    [string]$CondaEnv    = "pytorch-build",
    [string]$PythonVer   = "3.13",
    [switch]$Force,                    # re-install pip deps
    [switch]$CopyCudnn                 # copy cuDNN into CUDA toolkit (official method)
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "    [FAIL] $m" -ForegroundColor Red; exit 1 }

$CudaHome  = "$CudaRoot\v$CudaVersion"
$cudaMajor = $CudaVersion.Split(".")[0]

# ============================================================
# 1. Discover MSVC toolsets via vswhere
# ============================================================
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
    $vcvars = "$vsDir\VC\Auxiliary\Build\vcvarsall.bat"
    Get-ChildItem "$vsDir\VC\Tools\MSVC" -Recurse -Filter "cl.exe" -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -match "HostX64\\x64" } |
        ForEach-Object {
            $msvcVer  = ($_.FullName -split "\\MSVC\\")[1] -split "\\" | Select-Object -First 1
            $edition  = if ($vsDir -match "BuildTools")  {"Build Tools"}
                   elseif ($vsDir -match "Community")    {"Community"}
                   elseif ($vsDir -match "Professional") {"Professional"}
                   elseif ($vsDir -match "Enterprise")   {"Enterprise"}
                   else                                  {"Unknown"}
            $vsYear   = if ($vsDir -match "\\2022") {"2022"}
                   elseif ($vsDir -match "\\2019")   {"2019"}
                   elseif ($vsDir -match "\\2017")   {"2017"}
                   elseif ($vsDir -match "\\18")     {"2025"}
                   else                              {"Unknown"}
            $supported = ([version]$msvcVer -ge [version]"14.10" -and [version]$msvcVer -lt [version]"14.50")
            $toolsets += [PSCustomObject]@{
                Path          = $_.FullName
                VcvarsPath    = $vcvars
                VSDir         = $vsDir
                MsvcVersion   = $msvcVer
                VSYear        = $vsYear
                Edition       = $edition
                CudaSupported = $supported
            }
        }
}

if ($toolsets.Count -eq 0) { Write-Fail "No MSVC toolsets found. Install Visual Studio 2022 Build Tools." }

# ============================================================
# 2. Toolset selection menu
# ============================================================
Write-Host ""
Write-Host ("  {0,-4} {1,-8} {2,-16} {3,-14} {4,-12} {5}" -f "#","VS Year","MSVC Ver","Edition","vcvarsall","CUDA $CudaVersion") -ForegroundColor Gray
Write-Host ("  " + "-"*72) -ForegroundColor Gray
for ($i = 0; $i -lt $toolsets.Count; $i++) {
    $t       = $toolsets[$i]
    $status  = if ($t.CudaSupported) {"[supported]"} else {"[unsupported]"}
    $hasVars = if (Test-Path $t.VcvarsPath) {"yes"} else {"NO "}
    $color   = if ($t.CudaSupported) {"Green"} else {"Yellow"}
    Write-Host ("  [{0}] VS {1,-6} MSVC {2,-14} {3,-14} {4,-12} {5}" -f ($i+1),$t.VSYear,$t.MsvcVersion,$t.Edition,$hasVars,$status) -ForegroundColor $color
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

$chosen           = $toolsets[$idx]
$allowUnsupported = -not $chosen.CudaSupported
Write-OK "Selected  : VS $($chosen.VSYear) / MSVC $($chosen.MsvcVersion) / $($chosen.Edition)"
Write-OK "cl.exe    : $($chosen.Path)"
Write-OK "vcvarsall : $($chosen.VcvarsPath)"
if ($allowUnsupported) { Write-Warn "Unsupported toolset -- will add -allow-unsupported-compiler" }

# ============================================================
# 3. Prereq checks
# ============================================================
Write-Step "Checking prerequisites"

if (-not (Test-Path $PyTorchDir))              { Write-Fail "PyTorch source not found at $PyTorchDir" }
if (-not (Test-Path "$CudaHome\bin\nvcc.exe")) { Write-Fail "nvcc not found at $CudaHome\bin\nvcc.exe" }
Write-OK "PyTorch source : $PyTorchDir"
Write-OK "CUDA $CudaVersion    : $CudaHome"
foreach ($cmd in @("conda","rustc","ninja")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Write-Fail "$cmd not found in PATH" }
    Write-OK "$cmd found"
}

# ============================================================
# 4. cuDNN detection
# ============================================================
Write-Step "Detecting cuDNN (root: $CudnnRoot)"

if (-not (Test-Path $CudnnRoot)) { Write-Fail "cuDNN root not found at $CudnnRoot" }

$cudnnLayouts = @(
    @{ inc="$CudnnRoot\include\$CudaVersion"; lib="$CudnnRoot\lib\$CudaVersion\x64"; bin="$CudnnRoot\bin\$CudaVersion" },
    @{ inc="$CudnnRoot\include\$CudaVersion"; lib="$CudnnRoot\lib\$CudaVersion\x64"; bin="$CudnnRoot\bin\$CudaVersion\x64" },
    @{ inc="$CudnnRoot\include\$cudaMajor";   lib="$CudnnRoot\lib\$cudaMajor\x64";   bin="$CudnnRoot\bin\$cudaMajor"   },
    @{ inc="$CudnnRoot\include";              lib="$CudnnRoot\lib\x64";              bin="$CudnnRoot\bin"              },
    @{ inc="$CudaHome\include";               lib="$CudaHome\lib\x64";               bin="$CudaHome\bin"               }
)

$cudnnInclude = $null; $cudnnLibDir = $null; $cudnnBinDir = $null
foreach ($layout in $cudnnLayouts) {
    if ((Test-Path "$($layout.inc)\cudnn.h") -and (Test-Path "$($layout.lib)\cudnn.lib")) {
        $cudnnInclude = $layout.inc; $cudnnLibDir = $layout.lib; $cudnnBinDir = $layout.bin; break
    }
}

if (-not $cudnnInclude) {
    Write-Warn "Standard layouts not found -- recursive search under $CudnnRoot"
    $fH = Get-ChildItem $CudnnRoot -Recurse -Filter "cudnn.h"       -ErrorAction SilentlyContinue | Select-Object -First 1
    $fL = Get-ChildItem $CudnnRoot -Recurse -Filter "cudnn.lib"     -ErrorAction SilentlyContinue | Select-Object -First 1
    $fD = Get-ChildItem $CudnnRoot -Recurse -Filter "cudnn64_*.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fH -and $fL) {
        $cudnnInclude = $fH.DirectoryName; $cudnnLibDir = $fL.DirectoryName
        $cudnnBinDir  = if ($fD) { $fD.DirectoryName } else { $fL.DirectoryName }
        Write-Warn "Found via recursive search"
    } else {
        Write-Host "    Tip: extract cuDNN into $CudaHome (official method) or set -CudnnRoot" -ForegroundColor Yellow
        Write-Fail "cuDNN not found."
    }
}

$cudnnLib = "$cudnnLibDir\cudnn.lib"

$cudnnVerString = "unknown"
foreach ($vf in @("$cudnnInclude\cudnn_version.h","$cudnnInclude\cudnn.h")) {
    if (Test-Path $vf) {
        $maj = (Select-String $vf -Pattern '#define\s+CUDNN_MAJOR\s+(\d+)'      | Select-Object -First 1).Matches.Groups[1].Value
        $min = (Select-String $vf -Pattern '#define\s+CUDNN_MINOR\s+(\d+)'      | Select-Object -First 1).Matches.Groups[1].Value
        $pat = (Select-String $vf -Pattern '#define\s+CUDNN_PATCHLEVEL\s+(\d+)' | Select-Object -First 1).Matches.Groups[1].Value
        if ($maj) { $cudnnVerString = "$maj.$min.$pat"; break }
    }
}
Write-OK "cuDNN $cudnnVerString : $cudnnInclude"

# ============================================================
# 4b. Optionally copy cuDNN into CUDA toolkit
# ============================================================
if ($CopyCudnn -and ($cudnnInclude -ne "$CudaHome\include")) {
    Write-Step "Copying cuDNN into CUDA toolkit (official layout)"
    
    $copyTargets = @(
        @{ src=$cudnnInclude; dst="$CudaHome\include" },
        @{ src=$cudnnLibDir;  dst="$CudaHome\lib\x64" },
        @{ src=$cudnnBinDir;  dst="$CudaHome\bin"     }
    )
    
    foreach ($target in $copyTargets) {
        if (Test-Path $target.src) {
            Get-ChildItem $target.src -File | ForEach-Object {
                $d = Join-Path $target.dst $_.Name
                if (-not (Test-Path $d)) { 
                    Copy-Item $_.FullName $d -Force -ErrorAction Stop 
                }
            }
        }
    }
    
    $cudnnInclude = "$CudaHome\include"
    $cudnnLibDir  = "$CudaHome\lib\x64"
    $cudnnBinDir  = "$CudaHome\bin"
    $cudnnLib     = "$cudnnLibDir\cudnn.lib"
    Write-OK "cuDNN copied into CUDA toolkit -- find_package will auto-detect"
} elseif (-not $CopyCudnn -and ($cudnnInclude -ne "$CudaHome\include")) {
    Write-Warn "cuDNN not inside CUDA toolkit. Re-run with -CopyCudnn if CMake can't find it."
}

# ============================================================
# 5. MKL detection  (FAQ: CMAKE_INCLUDE_PATH + LIB needed)
# ============================================================
Write-Step "Detecting MKL"

$condaCheckPython = (& conda run -n $CondaEnv python -c "import sys; print(sys.executable)" 2>$null).Trim()
$condaPrefix = if ($condaCheckPython) { Split-Path (Split-Path $condaCheckPython) } else { "" }

# MKL from conda env (most reliable on Windows)
$mklInclude = ""
$mklLib     = ""
$mklFound   = $false

$mklCandidates = @(
    "$condaPrefix\Library\include",
    "$condaPrefix\Lib\site-packages\mkl_include"  # pip mkl-include
)
$mklLibCandidates = @(
    "$condaPrefix\Library\lib",
    "$condaPrefix\Library\mingw-w64\lib"
)

foreach ($inc in $mklCandidates) {
    if (Test-Path "$inc\mkl.h") { $mklInclude = $inc; break }
}
foreach ($lib in $mklLibCandidates) {
    if (Test-Path "$lib\mkl_core.lib") { $mklLib = $lib; break }
}

if ($mklInclude -and $mklLib) {
    $mklFound = $true
    Write-OK "MKL include : $mklInclude"
    Write-OK "MKL lib     : $mklLib"
} else {
    Write-Warn "MKL not found in conda env -- build will fall back to Eigen (slower)"
    Write-Warn "Install with: conda install mkl mkl-include -n $CondaEnv"
}

# ============================================================
# 6. MAGMA detection  (FAQ: MAGMA_HOME optional GPU linalg)
# ============================================================
Write-Step "Detecting MAGMA (optional)"

$magmaHome = ""
if ($MagmaDir -and (Test-Path "$MagmaDir\include\magma.h")) {
    $magmaHome = $MagmaDir
    Write-OK "MAGMA found : $magmaHome"
} else {
    Write-Warn "MAGMA not found -- GPU linear algebra ops will use fallback"
    Write-Warn "To enable: download from https://s3.amazonaws.com/ossci-windows/"
    Write-Warn "           extract and pass -MagmaDir "
}

# ============================================================
# 7. Conda env
# ============================================================
Write-Step "Setting up conda environment '$CondaEnv'"
if (-not (conda env list | Select-String -Pattern "^$CondaEnv\s")) {
    conda create -n $CondaEnv python=$PythonVer -y
    Write-OK "Created env '$CondaEnv'"
} else {
    Write-OK "Env '$CondaEnv' already exists"
}

# ============================================================
# 8. Python deps  (FAQ: install ninja; official: conda install cmake ninja)
# ============================================================
Write-Step "Installing Python build dependencies"
if ($Force -or -not (conda run -n $CondaEnv pip show pyyaml 2>$null)) {
    conda run -n $CondaEnv conda install cmake ninja -y
    conda run -n $CondaEnv pip install mkl-static mkl-include pyyaml typing_extensions requests
    Push-Location $PyTorchDir
        conda run -n $CondaEnv pip install -r requirements.txt
    Pop-Location
    Write-OK "Deps installed"
} else {
    Write-OK "Deps already present (use -Force to reinstall)"
}

# ============================================================
# 9. Conda python path + prefix
# ============================================================
$condaPython = (conda run -n $CondaEnv python -c "import sys; print(sys.executable)" 2>$null).Trim()
if (-not $condaPython) { Write-Fail "Could not resolve python path in '$CondaEnv'" }
$condaPrefix = Split-Path (Split-Path $condaPython)

# MKL paths from the build env (re-check after deps install)
if (-not $mklInclude) {
    $chk = "$condaPrefix\Library\include"
    if (Test-Path "$chk\mkl.h") { $mklInclude = $chk }
}
if (-not $mklLib) {
    $chk = "$condaPrefix\Library\lib"
    if (Test-Path "$chk\mkl_core.lib") { $mklLib = $chk }
}

# ============================================================
# 10. Clear stale CMake cache
# ============================================================
Write-Step "Clearing stale CMake cache"
$buildDir = Join-Path $PyTorchDir "build"
if (Test-Path $buildDir) {
    Remove-Item -Recurse -Force $buildDir
    Write-OK "Removed $buildDir"
} else { Write-OK "No existing cache" }
Get-ChildItem $PyTorchDir -Filter "torch.egg-info" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -Recurse -Force $_.FullName }

# ============================================================
# 11. Write env_vars.ps1
# ============================================================
Write-Step "Writing env_vars.ps1"

$envFile   = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "env_vars.ps1"
$nvccFlags = "--diag-suppress=20092"
if ($allowUnsupported) { $nvccFlags = "-allow-unsupported-compiler $nvccFlags" }

$archList = switch -Wildcard ($CudaVersion) {
    "12.*" { "6.0;12.0" }
    "13.*" { "6.0;12.0" }
    default { "6.0;7.0;7.5;8.0;8.6" }
}

$buildJobs = [math]::Max(1, [Environment]::ProcessorCount - 2)
$maxJobs   = [math]::Max(1, [math]::Min(8, [int]([Environment]::ProcessorCount / 2)))

# Escape all paths for embedding in here-string
function EscPath($p) { $p -replace '\\','\\' }

$clE         = EscPath $chosen.Path
$vcvarsE     = EscPath $chosen.VcvarsPath
$cudaHomeE   = EscPath $CudaHome
$cudaRootE   = EscPath $CudaRoot
$cudnnIncE   = EscPath $cudnnInclude
$cudnnLibE   = EscPath $cudnnLibDir
$cudnnLibFE  = EscPath $cudnnLib
$cudnnBinE   = EscPath $cudnnBinDir
$cudnnRootE  = EscPath $CudnnRoot
$condaPrefE  = EscPath $condaPrefix
$condaPyE    = EscPath $condaPython
$pyTorchE    = EscPath $PyTorchDir
$mklIncE     = EscPath $mklInclude
$mklLibE     = EscPath $mklLib
$magmaE      = EscPath $magmaHome

$cmakePrefix = "$cudnnRootE;$condaPrefE\\Lib\\site-packages;$cudaHomeE"

@"
# Auto-generated by 1_prepare.ps1 (v3) -- do not edit manually
# Refs:
#   PyTorch Windows FAQ : https://docs.pytorch.org/docs/2.11/notes/windows.html
#   TorchAudio Windows  : https://docs.pytorch.org/audio/2.8/build.windows.html
# CUDA version : $CudaVersion
# cuDNN version: $cudnnVerString
# Generated   : $(Get-Date -Format 'yyyy-MM-dd HH:mm')

# --- MSVC: vcvarsall.bat path (used by 2_build.ps1 to activate full MSVC env) ---
# Per official docs: use vcvarsall.bat x64 to enable the MSVC x64 toolset
`$script:VcvarsPath               = "$vcvarsE"
`$script:ChosenClExe              = "$clE"

# --- cuDNN ---
`$env:CUDNN_ROOT                  = "$cudnnRootE"
`$env:CUDNN_ROOT_DIR              = "$cudnnRootE"
`$env:CUDNN_INCLUDE_PATH          = "$cudnnIncE"
`$env:CUDNN_LIBRARY_PATH          = "$cudnnLibE"
`$env:CUDNN_LIBRARY               = "$cudnnLibFE"

# --- CUDA ---
`$env:CUDA_HOME                   = "$cudaHomeE"
`$env:CUDA_PATH                   = "$cudaHomeE"
`$env:TORCH_CUDA_ARCH_LIST        = "$archList"

# --- MSVC host compiler ---
`$env:CUDAHOSTCXX                 = "$clE"
`$env:CXX                         = "$clE"
`$env:CC                          = "$clE"
`$env:CMAKE_CUDA_HOST_COMPILER    = "$clE"

# --- CMAKE_GENERATOR: Ninja required per Windows FAQ ---
# "Visual Studio doesn't support parallel custom task currently"
`$env:CMAKE_GENERATOR             = "Ninja"

# --- MKL paths (Windows FAQ: CMAKE_INCLUDE_PATH + LIB must be set) ---
`$env:CMAKE_INCLUDE_PATH          = "$mklIncE"
`$env:LIB                         = "$mklLibE;`$env:LIB"

# --- MAGMA (optional GPU linear algebra -- Windows FAQ) ---
`$env:MAGMA_HOME                  = "$magmaE"

# --- CMAKE_PREFIX_PATH: cuDNN + conda + CUDA ---
`$env:CMAKE_PREFIX_PATH           = "$cmakePrefix"

# --- PATH: rebuilt at load time from live session PATH ---
`$_cleanPath = `$env:PATH -replace ('(?i)' + [regex]::Escape("$cudaRootE") + '\\v[^;]+;'), ''
`$env:PATH = "$cudaHomeE\bin;$cudaHomeE\libnvvp;$cudnnBinE;$condaPrefE\Scripts;$condaPrefE\Library\bin;`$_cleanPath"

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
`$env:CMAKE_BUILD_PARALLEL_LEVEL  = "$buildJobs"
`$env:MAX_JOBS                    = "$maxJobs"

# --- NVCC flags ---
# --diag-suppress=20092 : clusterlaunchcontrol.h ASM constraint error on sm_60
`$env:NVCC_APPEND_FLAGS           = "$nvccFlags"
`$env:REL_WITH_DEB_INFO           = "0"

# --- MSVC ICE workaround (/Od on release build for sdp.cpp) ---
`$env:EXTRA_CAFFE2_CMAKE_FLAGS    = "-DCMAKE_CXX_FLAGS_RELEASE=/Od"

# --- Shared with other scripts ---
`$script:CondaPython              = "$condaPyE"
`$script:PyTorchDir               = "$pyTorchE"
`$script:CondaEnv                 = "$CondaEnv"
`$script:CondaPrefix              = "$condaPrefE"
"@ | Set-Content -Path $envFile -Encoding UTF8

Write-OK "Written: $envFile"

# ============================================================
# Summary
# ============================================================
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Preparation complete. Summary:"                              -ForegroundColor Cyan
Write-Host ""
Write-Host ("   CUDA          : {0}"       -f $CudaVersion)                             -ForegroundColor White
Write-Host ("   cuDNN         : {0}"       -f $cudnnVerString)                          -ForegroundColor White
Write-Host ("   MSVC          : {0} ({1})" -f $chosen.MsvcVersion,$chosen.Edition)      -ForegroundColor White
Write-Host ("   vcvarsall     : {0}"       -f (Test-Path $chosen.VcvarsPath))           -ForegroundColor White
Write-Host ("   Ninja         : {0}"       -f (Get-Command ninja -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name))  -ForegroundColor White
Write-Host ("   MKL           : {0}"       -f $(if ($mklInclude) {"found"} else {"NOT found (Eigen fallback)"})) -ForegroundColor $(if ($mklInclude) {"White"} else {"Yellow"})
Write-Host ("   MAGMA         : {0}"       -f $(if ($magmaHome)  {"found"} else {"not provided (optional)"}))   -ForegroundColor White
Write-Host ("   Arch list     : {0}"       -f $archList)                                -ForegroundColor White
Write-Host ("   Build cores   : {0}/{1}"   -f $buildJobs,[Environment]::ProcessorCount) -ForegroundColor White
if (-not $CopyCudnn -and ($cudnnInclude -ne "$CudaHome\include")) {
    Write-Host ""
    Write-Host " TIP: Re-run with -CopyCudnn to use official cuDNN layout" -ForegroundColor Yellow
}
Write-Host ""
Write-Host " Next step:"                                                   -ForegroundColor Cyan
Write-Host "   .\2_build.ps1"                                             -ForegroundColor White
Write-Host "============================================================"  -ForegroundColor Cyan