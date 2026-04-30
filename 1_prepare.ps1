# ============================================================
# 1_prepare.ps1
# Sets up conda env, installs deps, selects MSVC toolset,
# writes env vars to env_vars.ps1 for the build step to load.
# Run once (or with -Force to redo deps).
# ============================================================

param(
    [string]$PyTorchDir = "D:\Workplace\PyTorch-build\pytorch",
    [string]$CudaHome   = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.9",
    [string]$CondaEnv   = "pytorch-build",
    [string]$PythonVer  = "3.13",
    [switch]$Force          # re-install deps even if already present
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "    [FAIL] $m" -ForegroundColor Red; exit 1 }

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
            $edition = if ($vsDir -match "BuildTools") {"Build Tools"} elseif ($vsDir -match "Community") {"Community"} elseif ($vsDir -match "Professional") {"Professional"} elseif ($vsDir -match "Enterprise") {"Enterprise"} else {"Unknown"}
            $vsYear  = if ($vsDir -match "\\2022") {"2022"} elseif ($vsDir -match "\\2019") {"2019"} elseif ($vsDir -match "\\2017") {"2017"} elseif ($vsDir -match "\\18") {"2025"} else {"Unknown"}
            $supported = ([version]$msvcVer -ge [version]"14.10" -and [version]$msvcVer -lt [version]"14.50")
            $toolsets += [PSCustomObject]@{ Path=$_.FullName; MsvcVersion=$msvcVer; VSYear=$vsYear; Edition=$edition; CudaSupported=$supported }
        }
}

if ($toolsets.Count -eq 0) { Write-Fail "No MSVC toolsets found. Install Visual Studio 2022 Build Tools." }

# ------------------------------------------------------------
# 2. Toolset selection menu
# ------------------------------------------------------------
Write-Host ""
Write-Host ("  {0,-4} {1,-8} {2,-16} {3,-14} {4}" -f "#","VS Year","MSVC Ver","Edition","CUDA 12.9?") -ForegroundColor Gray
Write-Host ("  " + "-"*60) -ForegroundColor Gray
for ($i = 0; $i -lt $toolsets.Count; $i++) {
    $t = $toolsets[$i]
    $status = if ($t.CudaSupported) {"[supported]"} else {"[unsupported]"}
    $color  = if ($t.CudaSupported) {"Green"} else {"Yellow"}
    Write-Host ("  [{0}] VS {1,-6} MSVC {2,-14} {3,-14} {4}" -f ($i+1),$t.VSYear,$t.MsvcVersion,$t.Edition,$status) -ForegroundColor $color
}

$defaultIdx = 0
$supported  = $toolsets | Where-Object { $_.CudaSupported }
if ($supported) {
    $best = $supported | Sort-Object MsvcVersion -Descending | Select-Object -First 1
    $defaultIdx = [array]::IndexOf($toolsets, $best)
}

Write-Host ""
Write-Host ("  Press Enter to use [{0}] (recommended), or type a number: " -f ($defaultIdx+1)) -NoNewline -ForegroundColor White
$inp = Read-Host
$idx = if ($inp -match '^\d+$') { [int]$inp - 1 } else { $defaultIdx }
if ($idx -lt 0 -or $idx -ge $toolsets.Count) { Write-Fail "Invalid selection." }

$chosen = $toolsets[$idx]
Write-OK "Selected: VS $($chosen.VSYear) / MSVC $($chosen.MsvcVersion) / $($chosen.Edition)"
Write-OK "cl.exe  : $($chosen.Path)"

$allowUnsupported = -not $chosen.CudaSupported
if ($allowUnsupported) { Write-Warn "Unsupported toolset -- will add -allow-unsupported-compiler" }

# ------------------------------------------------------------
# 3. Prereq checks
# ------------------------------------------------------------
Write-Step "Checking prerequisites"

if (-not (Test-Path $PyTorchDir))              { Write-Fail "PyTorch source not found at $PyTorchDir" }
if (-not (Test-Path "$CudaHome\bin\nvcc.exe")) { Write-Fail "nvcc not found at $CudaHome\bin\nvcc.exe" }
Write-OK "PyTorch source : $PyTorchDir"
Write-OK "CUDA           : $CudaHome"
foreach ($cmd in @("conda","rustc","ninja")) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) { Write-Fail "$cmd not found in PATH" }
    Write-OK "$cmd found"
}

# ------------------------------------------------------------
# 4. Conda env
# ------------------------------------------------------------
Write-Step "Setting up conda environment '$CondaEnv'"
if (-not (conda env list | Select-String -Pattern "^$CondaEnv\s")) {
    conda create -n $CondaEnv python=$PythonVer -y
    Write-OK "Created env '$CondaEnv'"
} else {
    Write-OK "Env '$CondaEnv' already exists"
}

# ------------------------------------------------------------
# 5. Python deps
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
# 6. Get conda python path
# ------------------------------------------------------------
$condaPython = (conda run -n $CondaEnv python -c "import sys; print(sys.executable)" 2>$null).Trim()
if (-not $condaPython) { Write-Fail "Could not resolve python path in '$CondaEnv'" }

# ------------------------------------------------------------
# 7. Clear stale CMake cache
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
# 8. Write env_vars.ps1 for build step to dot-source
# ------------------------------------------------------------
Write-Step "Writing env_vars.ps1"

$envFile = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "env_vars.ps1"

$nvccFlags = if ($allowUnsupported) { '"-allow-unsupported-compiler"' } else { '""' }
$cuda13Escaped = [regex]::Escape("C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v13.2\bin;")

@"
# Auto-generated by 1_prepare.ps1 -- do not edit manually
`$env:CUDAHOSTCXX                = "$($chosen.Path)"
`$env:CUDA_HOME                  = "$CudaHome"
`$env:CUDA_PATH                  = "$CudaHome"
`$env:PATH                       = "$CudaHome\bin;$CudaHome\libnvvp;" + (`$env:PATH -replace "$cuda13Escaped", "")
`$env:TORCH_CUDA_ARCH_LIST       = "6.0;12.0"
`$env:USE_CUDA                   = "1"
`$env:USE_FLASH_ATTENTION        = "1"
`$env:USE_DISTRIBUTED            = "0"
`$env:USE_TEST                   = "0"
`$env:CMAKE_BUILD_PARALLEL_LEVEL = "$([Environment]::ProcessorCount)"
`$env:NVCC_APPEND_FLAGS          = $nvccFlags
`$script:CondaPython             = "$condaPython"
`$script:PyTorchDir              = "$PyTorchDir"
`$script:CondaEnv                = "$CondaEnv"
"@ | Set-Content -Path $envFile -Encoding UTF8

Write-OK "Written: $envFile"

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Preparation complete. Next step:"                            -ForegroundColor Cyan
Write-Host ""
Write-Host "   .\2_build.ps1"                                            -ForegroundColor White
Write-Host "============================================================"  -ForegroundColor Cyan