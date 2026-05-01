# ============================================================
# 1_prepare.ps1  (v4)
# Aligned with pytorch CI: .ci/pytorch/win-test-helpers/build_pytorch.bat
# and official README / Windows FAQ.
#
# New in v4 vs v3:
#   - CMAKE_GENERATOR_TOOLSET_VERSION + DISTUTILS_USE_SDK=1  (README)
#   - CONDA_PREFIX exported so libuv / cmake find_package works (README)
#   - libuv installed via conda-forge (README: required for USE_DISTRIBUTED)
#   - sccache detection + CMAKE_CUDA_COMPILER_LAUNCHER  (CI script)
#   - vcvarsall called with -vcvars_ver pin  (CI script)
#   - BUILD_TEST=OFF added to EXTRA_CAFFE2_CMAKE_FLAGS  (fixes test build errors)
#   - sccache optional install helper
# ============================================================

param(
    [string]$PyTorchDir  = "D:\Workplace\PyTorch-build\pytorch",
    [string]$CudaVersion = "12.9",
    [string]$CudaRoot    = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA",
    [string]$CudnnRoot   = "C:\Program Files\NVIDIA\CUDNN\v9.21",
    [string]$MagmaDir    = "",
    [string]$CondaEnv    = "pytorch-build",
    [string]$PythonVer   = "3.12",
    [switch]$Force,
    [switch]$CopyCudnn,
    [switch]$InstallSccache   # download + install sccache for faster rebuilds
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
# 1. Discover MSVC toolsets
# ============================================================
Write-Step "Discovering installed MSVC toolsets"

$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vsInstallDirs = @()
if (Test-Path $vswhere) {
    $vsInstallDirs = & $vswhere -all -products * -property installationPath 2>$null
    Write-OK "vswhere found -- $($vsInstallDirs.Count) VS install(s)"
} else {
    Write-Warn "vswhere not found -- directory scan fallback"
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
if ($toolsets.Count -eq 0) { Write-Fail "No MSVC toolsets found." }

# ============================================================
# 2. Toolset selection menu
# ============================================================
Write-Host ""
Write-Host ("  {0,-4} {1,-8} {2,-16} {3,-14} {4,-12} {5}" -f "#","VS Year","MSVC Ver","Edition","vcvarsall","CUDA $CudaVersion") -ForegroundColor Gray
Write-Host ("  " + "-"*72) -ForegroundColor Gray
for ($i = 0; $i -lt $toolsets.Count; $i++) {
    $t      = $toolsets[$i]
    $status = if ($t.CudaSupported) {"[supported]"} else {"[unsupported]"}
    $hasV   = if (Test-Path $t.VcvarsPath) {"yes"} else {"NO "}
    $color  = if ($t.CudaSupported) {"Green"} else {"Yellow"}
    Write-Host ("  [{0}] VS {1,-6} MSVC {2,-14} {3,-14} {4,-12} {5}" -f ($i+1),$t.VSYear,$t.MsvcVersion,$t.Edition,$hasV,$status) -ForegroundColor $color
}
$defaultIdx = 0
$supp = $toolsets | Where-Object { $_.CudaSupported }
if ($supp) { $defaultIdx = [array]::IndexOf($toolsets, ($supp | Sort-Object MsvcVersion -Descending | Select-Object -First 1)) }
Write-Host ""
Write-Host ("  Press Enter for [{0}] (recommended), or type a number: " -f ($defaultIdx+1)) -NoNewline -ForegroundColor White
$inp = Read-Host
$idx = if ($inp -match '^\d+$') { [int]$inp - 1 } else { $defaultIdx }
if ($idx -lt 0 -or $idx -ge $toolsets.Count) { Write-Fail "Invalid selection." }

$chosen           = $toolsets[$idx]
$allowUnsupported = -not $chosen.CudaSupported
Write-OK "Selected  : VS $($chosen.VSYear) / MSVC $($chosen.MsvcVersion) / $($chosen.Edition)"
Write-OK "vcvarsall : $($chosen.VcvarsPath)"
if ($allowUnsupported) { Write-Warn "Unsupported toolset -- will add -allow-unsupported-compiler" }

# ============================================================
# 3. Prereq checks
# ============================================================
Write-Step "Checking prerequisites"
if (-not (Test-Path $PyTorchDir))              { Write-Fail "PyTorch source not found at $PyTorchDir" }
if (-not (Test-Path "$CudaHome\bin\nvcc.exe")) { Write-Fail "nvcc not found at $CudaHome\bin\nvcc.exe" }
Write-OK "PyTorch : $PyTorchDir"
Write-OK "CUDA    : $CudaHome"
foreach ($cmd in @("conda","rustc","ninja")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Write-Fail "$cmd not found in PATH" }
    Write-OK "$cmd found"
}

# ============================================================
# 4. sccache (optional, mirrors CI which uses it for caching)
#    CI: CMAKE_CUDA_COMPILER_LAUNCHER wraps nvcc with sccache
# ============================================================
Write-Step "Checking sccache (optional compiler cache)"
$sccachePath = ""
$sccacheExe  = Get-Command sccache -ErrorAction SilentlyContinue
if ($sccacheExe) {
    $sccachePath = $sccacheExe.Source
    Write-OK "sccache found: $sccachePath"
} elseif ($InstallSccache) {
    Write-Host "    Installing sccache via cargo..."
    cargo install sccache
    $sccacheExe = Get-Command sccache -ErrorAction SilentlyContinue
    if ($sccacheExe) { $sccachePath = $sccacheExe.Source; Write-OK "sccache installed: $sccachePath" }
} else {
    Write-Warn "sccache not found -- builds won't be cached (pass -InstallSccache to install)"
    Write-Warn "Install manually: cargo install sccache  or  scoop install sccache"
}

# ============================================================
# 5. cuDNN detection
# ============================================================
Write-Step "Detecting cuDNN"
if (-not (Test-Path $CudnnRoot)) { Write-Fail "cuDNN root not found at $CudnnRoot" }

$cudnnLayouts = @(
    @{ inc="$CudnnRoot\include\$CudaVersion"; lib="$CudnnRoot\lib\$CudaVersion\x64"; bin="$CudnnRoot\bin\$CudaVersion"     },
    @{ inc="$CudnnRoot\include\$CudaVersion"; lib="$CudnnRoot\lib\$CudaVersion\x64"; bin="$CudnnRoot\bin\$CudaVersion\x64" },
    @{ inc="$CudnnRoot\include\$cudaMajor";   lib="$CudnnRoot\lib\$cudaMajor\x64";   bin="$CudnnRoot\bin\$cudaMajor"       },
    @{ inc="$CudnnRoot\include";              lib="$CudnnRoot\lib\x64";              bin="$CudnnRoot\bin"                  },
    @{ inc="$CudaHome\include";               lib="$CudaHome\lib\x64";               bin="$CudaHome\bin"                   }
)
$cudnnInclude=$null; $cudnnLibDir=$null; $cudnnBinDir=$null
foreach ($l in $cudnnLayouts) {
    if ((Test-Path "$($l.inc)\cudnn.h") -and (Test-Path "$($l.lib)\cudnn.lib")) {
        $cudnnInclude=$l.inc; $cudnnLibDir=$l.lib; $cudnnBinDir=$l.bin; break
    }
}
if (-not $cudnnInclude) {
    Write-Warn "Trying recursive search..."
    $fH = Get-ChildItem $CudnnRoot -Recurse -Filter "cudnn.h"       -ErrorAction SilentlyContinue | Select-Object -First 1
    $fL = Get-ChildItem $CudnnRoot -Recurse -Filter "cudnn.lib"     -ErrorAction SilentlyContinue | Select-Object -First 1
    $fD = Get-ChildItem $CudnnRoot -Recurse -Filter "cudnn64_*.dll" -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($fH -and $fL) {
        $cudnnInclude=$fH.DirectoryName; $cudnnLibDir=$fL.DirectoryName
        $cudnnBinDir=if($fD){$fD.DirectoryName}else{$fL.DirectoryName}
    } else { Write-Fail "cuDNN not found. Use -CopyCudnn or -CudnnRoot." }
}
$cudnnLib = "$cudnnLibDir\cudnn.lib"
$cudnnVerString = "unknown"
foreach ($vf in @("$cudnnInclude\cudnn_version.h","$cudnnInclude\cudnn.h")) {
    if (Test-Path $vf) {
        $maj=(Select-String $vf -Pattern '#define\s+CUDNN_MAJOR\s+(\d+)'      | Select-Object -First 1).Matches.Groups[1].Value
        $min=(Select-String $vf -Pattern '#define\s+CUDNN_MINOR\s+(\d+)'      | Select-Object -First 1).Matches.Groups[1].Value
        $pat=(Select-String $vf -Pattern '#define\s+CUDNN_PATCHLEVEL\s+(\d+)' | Select-Object -First 1).Matches.Groups[1].Value
        if ($maj) { $cudnnVerString="$maj.$min.$pat"; break }
    }
}
Write-OK "cuDNN $cudnnVerString : $cudnnInclude"

if ($CopyCudnn -and ($cudnnInclude -ne "$CudaHome\include")) {
    Write-Step "Copying cuDNN into CUDA toolkit (official method)"
    Write-Host "    From : $CudnnRoot" -ForegroundColor Gray
    Write-Host "    To   : $CudaHome"  -ForegroundColor Gray

    # Use named variable $copySpec to avoid $_ shadowing in nested ForEach-Object
    $copySpecs = @(
        @{ src = $cudnnInclude; dst = "$CudaHome\include" },
        @{ src = $cudnnLibDir;  dst = "$CudaHome\lib\x64" },
        @{ src = $cudnnBinDir;  dst = "$CudaHome\bin"     }
    )

    foreach ($copySpec in $copySpecs) {
        $srcDir = $copySpec.src
        $dstDir = $copySpec.dst

        if (-not (Test-Path $srcDir)) {
            Write-Warn "Source not found, skipping: $srcDir"
            continue
        }

        # Ensure destination exists
        if (-not (Test-Path $dstDir)) {
            New-Item -ItemType Directory -Path $dstDir -Force | Out-Null
        }

        $files = Get-ChildItem $srcDir -File -ErrorAction SilentlyContinue
        $count = 0
        foreach ($file in $files) {
            $dest = Join-Path $dstDir $file.Name
            if (-not (Test-Path $dest)) {
                Copy-Item $file.FullName $dest -ErrorAction SilentlyContinue
                $count++
            }
        }
        Write-OK "Copied $count file(s): $srcDir -> $dstDir"
    }

    # Update paths to reflect new location inside CUDA toolkit
    $cudnnInclude = "$CudaHome\include"
    $cudnnLibDir  = "$CudaHome\lib\x64"
    $cudnnBinDir  = "$CudaHome\bin"
    $cudnnLib     = "$cudnnLibDir\cudnn.lib"
    Write-OK "cuDNN now inside CUDA toolkit -- find_package will auto-detect"
} 
elseif (-not $CopyCudnn -and ($cudnnInclude -ne "$CudaHome\include")) 
{
    Write-Warn "cuDNN not inside CUDA toolkit. Re-run with -CopyCudnn if CMake can't find it."
}

# ============================================================
# 6. Conda env + libuv (README: required for USE_DISTRIBUTED)
# ============================================================

Write-Step "Setting up conda environment '$CondaEnv'"
if (-not (conda env list | Select-String -Pattern "^$CondaEnv\s")) {
    conda create -n $CondaEnv python=$PythonVer -y
    Write-OK "Created '$CondaEnv'"
} else { Write-OK "Env '$CondaEnv' exists" }

# ============================================================
# 7. Python deps (official: conda install cmake ninja libuv)
# ============================================================
Write-Step "Installing build dependencies"
if ($Force -or -not (conda run -n $CondaEnv pip show pyyaml 2>$null)) 
{
    # README: use conda for cmake/ninja on Windows
    conda run -n $CondaEnv conda install -y cmake ninja
    # README: libuv required for USE_DISTRIBUTED on Windows
    conda run -n $CondaEnv conda install -y -c conda-forge libuv=1.51
    conda run -n $CondaEnv pip install mkl-static mkl-include pyyaml typing_extensions requests
    Push-Location $PyTorchDir
        conda run -n $CondaEnv pip install -r requirements.txt
    Pop-Location
    Write-OK "Deps installed"
} else { Write-OK "Deps present (use -Force to reinstall)" }

# ============================================================
# 8. Resolve paths
# ============================================================
$condaPython = (conda run -n $CondaEnv python -c "import sys; print(sys.executable)" 2>$null).Trim()
if (-not $condaPython) { Write-Fail "Could not resolve python in '$CondaEnv'" }
$condaPrefix = Split-Path $condaPython

# MKL from conda Library
$mklInclude=""; $mklLib=""
if (Test-Path "$condaPrefix\Library\include\mkl.h")    { $mklInclude="$condaPrefix\Library\include" }
if (Test-Path "$condaPrefix\Library\lib\mkl_core.lib") { $mklLib="$condaPrefix\Library\lib" }
if ($mklInclude) { Write-OK "MKL include : $mklInclude" } else { Write-Warn "MKL not found (Eigen fallback)" }

# MAGMA
$magmaHome = if ($MagmaDir -and (Test-Path "$MagmaDir\include\magma.h")) { $MagmaDir } else { "" }
if ($magmaHome) { Write-OK "MAGMA : $magmaHome" } else { Write-Warn "MAGMA not provided (optional)" }

# ============================================================
# 9. Clear stale CMake cache
# ============================================================

Write-Step "Clearing stale CMake cache"
$buildDir = Join-Path $PyTorchDir "build"
if (Test-Path $buildDir) { Remove-Item -Recurse -Force $buildDir; Write-OK "Removed $buildDir" }
else { Write-OK "No existing cache" }
Get-ChildItem $PyTorchDir -Filter "torch.egg-info" -Directory -ErrorAction SilentlyContinue |
    ForEach-Object { Remove-Item -Recurse -Force $_.FullName }

# ============================================================
# 10. Write env_vars.ps1 (Fixed: SDK Tools & NVCC Parity)
# ============================================================
Write-Step "Writing env_vars.ps1"

function Get-LongPath { 
    param($p) 
    if($p -and (Test-Path $p)){ 
        $long = (Get-Item $p).FullName
        return $long -replace '\\','\\' 
    }
    return ""
}

# 1. Capture MSVC Environment (includes SDK paths)
Write-Host "    Capturing MSVC and SDK environment..." -ForegroundColor Gray
$tempFile = [System.IO.Path]::GetTempFileName()
cmd /c "`"$($chosen.VcvarsPath)`" x64 -vcvars_ver=$($chosen.MsvcVersion) && set" > $tempFile

$msvcVars = @{}
Get-Content $tempFile | ForEach-Object {
    if ($_ -match "^(.*?)=(.*)$") { $msvcVars[$matches[1]] = $matches[2] }
}
Remove-Item $tempFile

# 2. Identify critical Toolset & SDK directories
$rawClPath = Join-Path $msvcVars['VCToolsInstallDir'] "bin\Hostx64\x64\cl.exe"
$clExePath = (Get-Item $rawClPath).FullName 
$msvcBinDir = Split-Path $clExePath

# Windows SDK bin for rc.exe and mt.exe
$sdkBinRoot = $msvcVars['WindowsSdkVerBinPath']
if (-not $sdkBinRoot) { $sdkBinRoot = Join-Path $msvcVars['WindowsSdkDir'] "bin\$($msvcVars['WindowsSDKLibVersion'])\x64" }

# 3. Reconstruct PATH with absolute Long Paths
$pathBuilder = @()
$pathBuilder += "$msvcBinDir"                    # 1. Compiler (Must be first for NVCC)
$pathBuilder += "$sdkBinRoot"                    # 2. SDK Tools (rc.exe, mt.exe)
$pathBuilder += $msvcVars['Path'].Split(';')     # 3. Remainder of MSVC/Windows paths
$pathBuilder += "$CudaHome\bin"                  # 4. CUDA
$pathBuilder += "$condaPrefix\Scripts"           # 5. Conda
$pathBuilder += "$condaPrefix\Library\bin"       # 6. Conda Libs (Ninja, CMake)
$pathBuilder += "C:\Program Files\Git\cmd"

$finalPathString = ($pathBuilder | ForEach-Object { 
    if ($_ -and (Test-Path $_)) { (Get-Item $_).FullName } 
} | Select-Object -Unique) -join ";"

# 4. Generate File Content
$envFile = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "env_vars.ps1"
$longCl  = Get-LongPath $clExePath

$envContent = @"
# Auto-generated - Strict Long-Path Parity & SDK Fix
# Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm')

# --- MSVC & SDK Environment ---
`$env:LIB                         = "$(Get-LongPath $msvcVars['LIB'])"
`$env:INCLUDE                     = "$(Get-LongPath $msvcVars['INCLUDE'])"
`$env:LIBPATH                     = "$(Get-LongPath $msvcVars['LIBPATH'])"
`$env:WindowsSdkDir               = "$(Get-LongPath $msvcVars['WindowsSdkDir'])"
`$env:WindowsSdkVerBinPath        = "$(Get-LongPath $sdkBinRoot)"

# --- MSVC ---


# --- CUDA & cuDNN ---
`$env:CUDA_HOME                   = "$(Get-LongPath $CudaHome)"
`$env:CUDA_PATH                   = "$(Get-LongPath $CudaHome)"
`$env:CUDNN_ROOT                  = "$(Get-LongPath $CudnnRoot)"
`$env:TORCH_CUDA_ARCH_LIST        = "$(switch -Wildcard ($CudaVersion) { "12.*" {"6.0;12.0"}; default {"6.0;7.0;7.5;8.0;8.6"} })"

# --- Compiler Fix (NVCC Parity) ---
`$env:CUDAHOSTCXX                 = "$longCl"
`$env:CXX                         = "$longCl"
`$env:CC                          = "$longCl"
`$env:DISTUTILS_USE_SDK           = "1"
`$env:CMAKE_GENERATOR             = "Ninja"
`$env:CMAKE_GENERATOR_TOOLSET_VERSION = "$($chosen.MsvcVersion)"

# --- PATH (Unified Long-Path String including SDK) ---
`$env:PATH = "$(Get-LongPath $finalPathString);C:\Windows\System32;"

# --- CMake Search Paths ---
`$env:CMAKE_PREFIX_PATH           = "$(Get-LongPath $condaPrefix);$(Get-LongPath $CudnnRoot);$(Get-LongPath $CudaHome)"
`$env:CMAKE_INCLUDE_PATH          = "$(Get-LongPath $mklInclude)"
`$env:MAGMA_HOME                  = "$(Get-LongPath $magmaHome)"

# --- Build Feature Flags ---
`$env:USE_CUDA                    = "1"
`$env:USE_CUDNN                   = "1"
`$env:USE_FLASH_ATTENTION         = "1"
`$env:USE_MKLDNN                  = "1"
`$env:USE_DISTRIBUTED             = "1"
`$env:USE_GLOO                    = "1"
`$env:USE_NUMPY                   = "1"
`$env:USE_KINETO                  = "1"
`$env:USE_TEST                    = "0"

# --- Parallelism & Flags ---
`$env:CMAKE_BUILD_PARALLEL_LEVEL  = "$([math]::Max(1,[Environment]::ProcessorCount - 6))"
`$env:MAX_JOBS                    = "6"
`$env:NVCC_APPEND_FLAGS           = "--diag-suppress=20092"

# --- Script Helpers ---
`$script:VcvarsPath               = "$(Get-LongPath $chosen.VcvarsPath)"
`$script:VcvarsVersion            = "$($chosen.MsvcVersion)"
`$script:ChosenClExe              = "$longCl"
`$script:PyTorchDir               = "$(Get-LongPath $PyTorchDir)"
`$script:CondaPython              = "$(Get-LongPath $condaPython)"
`$script:CondaEnv                 = "$CondaEnv"
`$script:CondaPrefix              = "$(Get-LongPath $condaPrefix)"
"@

$envContent | Set-Content -Path $envFile -Encoding UTF8
Write-OK "Written MSVC-aligned: $envFile"

# Summary
Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Preparation complete:"                                        -ForegroundColor Cyan
Write-Host ("   CUDA     : {0}"        -f $CudaVersion)                   -ForegroundColor White
Write-Host ("   cuDNN    : {0}"        -f $cudnnVerString)                -ForegroundColor White
Write-Host ("   MSVC     : {0} ({1})"  -f $chosen.MsvcVersion,$chosen.Edition) -ForegroundColor White
Write-Host ("   MKL      : {0}"        -f $(if($mklInclude){"found"}else{"NOT found (Eigen fallback)"})) -ForegroundColor $(if($mklInclude){"White"}else{"Yellow"})
Write-Host ("   MAGMA    : {0}"        -f $(if($magmaHome){"found"}else{"not provided"})) -ForegroundColor White
Write-Host ("   sccache  : {0}"        -f $(if($sccachePath){"found -- builds will be cached"}else{"not found"})) -ForegroundColor $(if($sccachePath){"White"}else{"Yellow"})
Write-Host ("   libuv    : installed via conda-forge")                    -ForegroundColor White
Write-Host ""
Write-Host " Next:  .\2_build.ps1"                                        -ForegroundColor Cyan
Write-Host "============================================================"  -ForegroundColor Cyan