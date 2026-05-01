# ============================================================
# 1_prepare.ps1  (v4)
# Aligned with:
#   - PyTorch Windows FAQ (docs.pytorch.org/docs/2.11/notes/windows.html)[cite: 1]
#   - TorchAudio Windows build guide
# ============================================================

param(
    [string]$PyTorchDir  = "D:\Workplace\PyTorch-build\pytorch",
    [string]$CudaVersion = "12.9",
    [string]$CudaRoot    = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA",
    [string]$CudnnRoot   = "C:\Program Files\NVIDIA\CUDNN\v9.21",
    [string]$MagmaDir    = "",         # optional: path to extracted MAGMA dir
    [string]$CondaEnv    = "pytorch-build",
    [string]$PythonVer   = "3.12",
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
# 0. Admin Check for cuDNN Copy
# ============================================================
if ($CopyCudnn) {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Fail "-CopyCudnn requires Administrator privileges to write to $CudaRoot. Please restart PowerShell as Administrator."
    }
}

# ============================================================
# 1. Discover MSVC toolsets via vswhere
# ============================================================
Write-Step "Discovering installed MSVC toolsets"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstallDirs = @()
if (Test-Path $vswhere) {
    # Request JSON output for cleaner object parsing
    $vsData = & $vswhere -all -products * -format json | ConvertFrom-Json 2>$null
    if ($vsData) {
        $vsInstallDirs = $vsData.installationPath
        Write-OK "vswhere found -- $($vsInstallDirs.Count) VS install(s)"
    }
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
    Get-ChildItem "$vsDir\VC\Tools\MSVC" -Directory -ErrorAction SilentlyContinue |
        ForEach-Object {
            $msvcVer = $_.Name
            $clPath = "$($_.FullName)\bin\HostX64\x64\cl.exe"
            
            if (Test-Path $clPath) {
                $edition  = if ($vsDir -match "BuildTools")  {"Build Tools"}
                       elseif ($vsDir -match "Community")    {"Community"}
                       elseif ($vsDir -match "Professional") {"Professional"}
                       elseif ($vsDir -match "Enterprise")   {"Enterprise"}
                       else                                  {"Unknown"}
                $vsYear   = if ($vsDir -match "\\2022") {"2022"}
                       elseif ($vsDir -match "\\2019")   {"2019"}
                       elseif ($vsDir -match "\\2017")   {"2017"}
                       else                              {"Unknown"}
                
                # Try-catch in case MSVC version strings are malformed
                $supported = $false
                try {
                    $supported = ([version]$msvcVer -ge [version]"14.10" -and [version]$msvcVer -lt [version]"14.50")
                } catch { Write-Warn "Could not parse MSVC version $msvcVer" }

                $toolsets += [PSCustomObject]@{
                    Path          = $clPath
                    VcvarsPath    = $vcvars
                    VSDir         = $vsDir
                    MsvcVersion   = $msvcVer
                    VSYear        = $vsYear
                    Edition       = $edition
                    CudaSupported = $supported
                }
            }
        }
}

if ($toolsets.Count -eq 0) { Write-Fail "No MSVC x64 toolsets found. Install Visual Studio 2022 Build Tools with C++ workloads." }

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
    $best       = $supportedToolsets | Sort-Object { [version]$_.MsvcVersion } -Descending | Select-Object -First 1
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
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Write-Warn "$cmd not found in initial PATH. Ensuring conda provides it." }
    else { Write-OK "$cmd found" }
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
Write-Step "Detecting cuDNN (root: $CudnnRoot)"
$cudnnLayouts = @(
    @{ inc="$CudnnRoot\include\$CudaVersion"; lib="$CudnnRoot\lib\$CudaVersion\x64"; bin="$CudnnRoot\bin\$CudaVersion" },
    @{ inc="$CudnnRoot\include"; lib="$CudnnRoot\lib\x64"; bin="$CudnnRoot\bin" }
)
$cudnnInclude = $null; $cudnnLibDir = $null; $cudnnBinDir = $null
foreach ($layout in $cudnnLayouts) {
    if ((Test-Path "$($layout.inc)\cudnn.h") -and (Test-Path "$($layout.lib)\cudnn.lib")) {
        $cudnnInclude = $layout.inc; $cudnnLibDir = $layout.lib; $cudnnBinDir = $layout.bin; break
    }
}
if (-not $cudnnInclude) { Write-Fail "cuDNN not found." }

if ($CopyCudnn -and ($cudnnInclude -ne "$CudaHome\include")) {
    Write-Step "Copying cuDNN into CUDA toolkit"
    $copyJobs = @(
        @{ src=$cudnnInclude; dst="$CudaHome\include" },
        @{ src=$cudnnLibDir;  dst="$CudaHome\lib\x64" },
        @{ src=$cudnnBinDir;  dst="$CudaHome\bin"     }
    )
    # FIX: Use named variable $job to avoid $_ collision
    foreach ($job in $copyJobs) {
        if (Test-Path $job.src) {
            Get-ChildItem $job.src -File | ForEach-Object {
                $dest = Join-Path $job.dst $_.Name
                if (-not (Test-Path $dest)) { Copy-Item $_.FullName $dest -Force }
            }
        }
    }
    $cudnnInclude = "$CudaHome\include"; $cudnnLibDir = "$CudaHome\lib\x64"; $cudnnBinDir = "$CudaHome\bin"
    Write-OK "cuDNN copied into toolkit"
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
# 5. Conda env setup
# ============================================================

Write-Step "Setting up conda environment '$CondaEnv'"
if (-not (conda env list | Select-String -Pattern "^$CondaEnv\s")) {
    conda create -n $CondaEnv python=$PythonVer -y
    Write-OK "Created env '$CondaEnv'"
} else {
    Write-OK "Env '$CondaEnv' already exists"
}

# ============================================================
# 6. Python deps
# ============================================================
Write-Step "Installing Python build dependencies"
if ($Force -or -not (conda run -n $CondaEnv pip show pyyaml 2>$null)) {
    # Added intel-openmp as it is heavily tied to Windows MKL builds
    conda run -n $CondaEnv conda install cmake ninja 
    conda run -n $CondaEnv conda install -c https://software.repos.intel.com/python/conda/ -c conda-forge mkl mkl-static mkl-devel mkl-dpcpp mkl-devel-dpcpp mkl-include intel-openmp -y
    conda run -n $CondaEnv pip install pyyaml typing_extensions requests
    Push-Location $PyTorchDir
        conda run -n $CondaEnv pip install -r requirements.txt
    Pop-Location
    Write-OK "Deps installed"
} else {
    Write-OK "Deps already present (use -Force to reinstall)"
}

# ============================================================
# 7. Prefix and MKL paths setup
# ============================================================
$condaPython = (conda run -n $CondaEnv python -c "import sys; print(sys.executable)" 2>$null).Trim()
if (-not $condaPython) { Write-Fail "Could not resolve python path in '$CondaEnv'" }
$condaPrefix = Split-Path (Split-Path $condaPython)

Write-Step "Detecting MKL paths"
# Resolve ACTUAL MKL paths from the environment
$condaPython = (conda run -n $CondaEnv python -c "import sys; print(sys.executable)" 2>$null).Trim()
$envRoot = Split-Path (Split-Path $condaPython)
$mklInclude = "$envRoot\Library\include"
$mklLib     = "$envRoot\Library\lib"

if (Test-Path "$mklInclude\mkl.h") {
    Write-OK "MKL detected in environment: $envRoot"
} else {
    Write-Warn "MKL headers not found at $mklInclude. Using Eigen fallback."
    $mklInclude = ""; $mklLib = ""
}

# ============================================================
# 8. MAGMA detection
# ============================================================
Write-Step "Detecting MAGMA (optional)"
$magmaHome = ""
if ($MagmaDir -and (Test-Path "$MagmaDir\include\magma.h")) {
    $magmaHome = $MagmaDir
    Write-OK "MAGMA found : $magmaHome"
} else {
    Write-Warn "MAGMA not found -- GPU linear algebra ops will use fallback"
}

# ============================================================
# 9. Clear stale CMake cache
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
# 10. Write env_vars.ps1
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

$buildJobs = [math]::Max(1, [Environment]::ProcessorCount - 6)
$maxJobs   = 8

# Safer Array-based path cleaning (removes CUDA root from current path completely)
$pathArray = ($env:PATH -split ';') | Where-Object { $_ -notmatch [regex]::Escape($CudaRoot) -and $_.Trim() -ne "" }
$cleanPathStr = $pathArray -join ';'

@"
# Auto-generated by 1_prepare.ps1 (v4) -- do not edit manually
# Refs:
#   PyTorch Windows FAQ : https://docs.pytorch.org/docs/2.11/notes/windows.html
# Generated   : $(Get-Date -Format 'yyyy-MM-dd HH:mm')

# --- MSVC ---
`$script:VcvarsPath               = "$($chosen.VcvarsPath)"
`$script:ChosenClExe              = "$($chosen.Path)"

# --- cuDNN ---
`$env:CUDNN_ROOT                  = "$cudnnRoot"
`$env:CUDNN_ROOT_DIR              = "$cudnnRoot"
`$env:CUDNN_INCLUDE_PATH          = "$cudnnInclude"
`$env:CUDNN_LIBRARY_PATH          = "$cudnnLibDir"
`$env:CUDNN_LIBRARY               = "$cudnnLib"

# --- CUDA ---
`$env:CUDA_HOME                   = "$CudaHome"
`$env:CUDA_PATH                   = "$CudaHome"
`$env:TORCH_CUDA_ARCH_LIST        = "$archList"

# --- MSVC host compiler ---
`$env:CUDAHOSTCXX                 = "$($chosen.Path)"
`$env:CXX                         = "$($chosen.Path)"
`$env:CC                          = "$($chosen.Path)"
`$env:CMAKE_CUDA_HOST_COMPILER    = "$($chosen.Path)"
`$env:DISTUTILS_USE_SDK           = "1"

# --- CMAKE_GENERATOR ---
`$env:CMAKE_GENERATOR             = "Ninja"

# --- MKL paths ---
`$env:CMAKE_INCLUDE_PATH          = "$mklInclude"
`$env:LIB                         = "$mklLib;`$env:LIB"

# --- MAGMA ---
`$env:MAGMA_HOME                  = "$magmaHome"

# --- CMAKE_PREFIX_PATH ---
`$env:CMAKE_PREFIX_PATH           = "$cudnnRoot;$condaPrefix\Lib\site-packages;$CudaHome"

# --- PATH (Rebuilt with priority) ---
`$env:PATH = "$CudaHome\bin;$CudaHome\libnvvp;$cudnnBinDir;$condaPrefix\Scripts;$condaPrefix\Library\bin;$cleanPathStr"

# --- Build feature flags ---
`$env:USE_CUDA                    = "1"
`$env:USE_CUDNN                   = "1"
`$env:USE_MKLDNN                  = "1"
`$env:USE_DISTRIBUTED             = "1"
`$env:USE_GLOO                    = "1"
`$env:USE_NUMPY                   = "1"
`$env:USE_KINETO                  = "1"
`$env:USE_TEST                    = "0"
# Note: Flash attention can be tricky on Windows. Disable if compilation fails.
`$env:USE_FLASH_ATTENTION         = "1" 

# --- Parallelism ---
`$env:CMAKE_BUILD_PARALLEL_LEVEL  = "$buildJobs"
`$env:MAX_JOBS                    = "$maxJobs"

# --- NVCC flags ---
`$env:NVCC_APPEND_FLAGS           = "$nvccFlags"
`$env:REL_WITH_DEB_INFO           = "0"
`$env:EXTRA_CAFFE2_CMAKE_FLAGS    = "-DCMAKE_CXX_FLAGS_RELEASE=/Od"

# --- Shared with other scripts ---
`$script:CondaPython              = "$condaPython"
`$script:PyTorchDir               = "$PyTorchDir"
`$script:CondaEnv                 = "$CondaEnv"
`$script:CondaPrefix              = "$condaPrefix"
"@ | Set-Content -Path $envFile -Encoding UTF8

Write-OK "Written: $envFile"

# ============================================================
# Summary
# ============================================================
Write-Host "`n============================================================" -ForegroundColor Cyan
Write-Host " Preparation complete. Summary:"                              -ForegroundColor Cyan
Write-Host "   CUDA          : $CudaVersion"                              -ForegroundColor White
Write-Host "   cuDNN         : $cudnnVerString"                           -ForegroundColor White
Write-Host "   MSVC          : $($chosen.MsvcVersion) ($($chosen.Edition))"-ForegroundColor White
Write-Host ("   vcvarsall     : {0}"       -f (Test-Path $chosen.VcvarsPath))           -ForegroundColor White
Write-Host ("   MKL           : {0}"       -f $(if ($mklInclude) {"found"} else {"NOT found (Eigen fallback)"})) -ForegroundColor $(if ($mklInclude) {"White"} else {"Yellow"})
Write-Host ("   MAGMA         : {0}"       -f $(if ($magmaHome)  {"found"} else {"not provided (optional)"}))   -ForegroundColor White
Write-Host ("   Build cores   : {0}/{1}"   -f $buildJobs,[Environment]::ProcessorCount) -ForegroundColor White
if (-not $CopyCudnn -and ($cudnnInclude -ne "$CudaHome\include")) {
    Write-Host ""
    Write-Host " TIP: Re-run with -CopyCudnn to use official cuDNN layout" -ForegroundColor Yellow
}
Write-Host ""
Write-Host " Next step:"                                                   -ForegroundColor Cyan
Write-Host "   .\2_build.ps1"                                             -ForegroundColor White
Write-Host "============================================================"  -ForegroundColor Cyan