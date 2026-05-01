param(
    [string]$PyTorchDir = "",
    [string]$CondaEnv = "pytorch-build",
    [string]$PythonVer = "3.12",
    [string]$CudaVersion = "12.9",
    [string]$CudaRoot = "",
    [string]$CudnnRoot = "",
    [string]$MagmaDir = "",
    [string]$EnvFile = "",
    [string]$VcvarsPath = "",
    [string]$MsvcVersion = "",
    [switch]$Force
)

. (Join-Path $PSScriptRoot "common.ps1")

if (-not $PyTorchDir) {
    $PyTorchDir = Get-DefaultPyTorchDir
}

if (-not $EnvFile) {
    $EnvFile = Get-DefaultEnvFile
}

function Get-OsName {
    if (Test-IsWindows) {
        return "windows"
    }

    return "linux"
}

function Resolve-CudaHome {
    param(
        [string]$CudaVersionValue,
        [string]$CudaRootValue
    )

    if ($CudaRootValue) {
        if (Test-IsWindows) {
            return Join-Path $CudaRootValue "v$CudaVersionValue"
        }

        return $CudaRootValue
    }

    if ($env:CUDA_HOME) {
        return $env:CUDA_HOME
    }

    if (Test-IsWindows) {
        return "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v$CudaVersionValue"
    }

    return "/usr/local/cuda"
}

function Get-WindowsToolchain {
    param(
        [string]$RequestedVcvarsPath,
        [string]$RequestedMsvcVersion
    )

    if ($RequestedVcvarsPath) {
        if (-not (Test-Path $RequestedVcvarsPath)) {
            Write-Fail "vcvarsall.bat not found at $RequestedVcvarsPath"
        }

        $resolvedVcvars = Resolve-ExistingPath -PathValue $RequestedVcvarsPath
        $toolRoot = Split-Path -Parent (Split-Path -Parent $resolvedVcvars)
        $msvcRoot = Join-Path $toolRoot "Tools\MSVC"
        $candidateVersions = @()
        if (Test-Path $msvcRoot) {
            $candidateVersions = Get-ChildItem $msvcRoot -Directory | Sort-Object Name -Descending
        }

        if ($RequestedMsvcVersion) {
            $selected = $candidateVersions | Where-Object { $_.Name -eq $RequestedMsvcVersion } | Select-Object -First 1
            if (-not $selected) {
                Write-Fail "MSVC version $RequestedMsvcVersion was not found under $msvcRoot"
            }
        } else {
            $selected = $candidateVersions | Select-Object -First 1
        }

        if (-not $selected) {
            Write-Fail "No MSVC toolsets were found under $msvcRoot"
        }

        $clPath = Join-Path $selected.FullName "bin\Hostx64\x64\cl.exe"
        if (-not (Test-Path $clPath)) {
            Write-Fail "cl.exe not found at $clPath"
        }

        return [PSCustomObject]@{
            VcvarsPath  = $resolvedVcvars
            MsvcVersion = $selected.Name
            ClPath      = (Resolve-ExistingPath -PathValue $clPath)
        }
    }

    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (-not (Test-Path $vswhere)) {
        Write-Fail "vswhere.exe not found. Install Visual Studio Build Tools or pass -VcvarsPath."
    }

    $installPaths = & $vswhere -all -products * -property installationPath 2>$null
    if (-not $installPaths) {
        Write-Fail "No Visual Studio installations were found."
    }

    $candidates = @()
    foreach ($installPath in $installPaths) {
        $vcvars = Join-Path $installPath "VC\Auxiliary\Build\vcvarsall.bat"
        $msvcRoot = Join-Path $installPath "VC\Tools\MSVC"
        if (-not (Test-Path $vcvars) -or -not (Test-Path $msvcRoot)) {
            continue
        }

        foreach ($toolset in Get-ChildItem $msvcRoot -Directory -ErrorAction SilentlyContinue) {
            $clPath = Join-Path $toolset.FullName "bin\Hostx64\x64\cl.exe"
            if (-not (Test-Path $clPath)) {
                continue
            }

            $candidates += [PSCustomObject]@{
                VcvarsPath  = (Resolve-ExistingPath -PathValue $vcvars)
                MsvcVersion = $toolset.Name
                ClPath      = (Resolve-ExistingPath -PathValue $clPath)
            }
        }
    }

    if (-not $candidates) {
        Write-Fail "No usable MSVC x64 toolsets were found."
    }

    if ($RequestedMsvcVersion) {
        $selectedCandidate = $candidates |
            Where-Object { $_.MsvcVersion -eq $RequestedMsvcVersion } |
            Sort-Object MsvcVersion -Descending |
            Select-Object -First 1
        if (-not $selectedCandidate) {
            Write-Fail "Requested MSVC version $RequestedMsvcVersion was not found."
        }

        return $selectedCandidate
    }

    return $candidates | Sort-Object MsvcVersion -Descending | Select-Object -First 1
}

function Get-WindowsVcvarsEnvironment {
    param(
        [string]$VcvarsPathValue,
        [string]$MsvcVersionValue
    )

    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        $vcvarsArg = if ($MsvcVersionValue) { "x64 -vcvars_ver=$MsvcVersionValue" } else { "x64" }
        cmd /c "`"$VcvarsPathValue`" $vcvarsArg && set" > $tempFile
        if ($LASTEXITCODE -ne 0) {
            Write-Fail "Failed to capture vcvarsall environment from $VcvarsPathValue"
        }

        $map = [ordered]@{}
        foreach ($line in Get-Content $tempFile) {
            if ($line -match "^(.*?)=(.*)$") {
                $map[$matches[1]] = $matches[2]
            }
        }

        return $map
    } finally {
        if (Test-Path $tempFile) {
            Remove-Item -LiteralPath $tempFile -Force
        }
    }
}

function Get-ArchList {
    param([string]$CudaVersionValue)

    switch -Wildcard ($CudaVersionValue) {
        "12.*" { return "6.0;12.0" }
        "13.*" { return "6.0;12.0" }
        default { return "6.0;7.0;7.5;8.0;8.6" }
    }
}

function Get-CondaPrefixLibraryPath {
    param([string]$CondaPrefix)

    if (Test-IsWindows) {
        return Join-Path $CondaPrefix "Library\bin"
    }

    return Join-Path $CondaPrefix "bin"
}

Write-Step "Preparing JSON build environment"

$resolvedPyTorchDir = Resolve-ExistingPath -PathValue $PyTorchDir
if (-not (Test-Path $resolvedPyTorchDir)) {
    Write-Fail "PyTorch source not found at $resolvedPyTorchDir"
}

$osName = Get-OsName
$cudaHome = Resolve-CudaHome -CudaVersionValue $CudaVersion -CudaRootValue $CudaRoot
$resolvedCudaHome = Resolve-ExistingPath -PathValue $cudaHome
$resolvedCudnnRoot = if ($CudnnRoot) { Resolve-ExistingPath -PathValue $CudnnRoot } else { "" }
$resolvedMagmaDir = if ($MagmaDir) { Resolve-ExistingPath -PathValue $MagmaDir } else { "" }

Write-Step "Ensuring conda environment '$CondaEnv' exists"
$condaEnvExists = conda env list | Select-String -Pattern "^\s*$([regex]::Escape($CondaEnv))\s"
if (-not $condaEnvExists) {
    conda create -n $CondaEnv "python=$PythonVer" -y
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Failed to create conda env '$CondaEnv'"
    }
    Write-OK "Created conda env '$CondaEnv'"
} else {
    Write-OK "Conda env '$CondaEnv' already exists"
}

Write-Step "Installing build dependencies"
if ($Force) {
    Write-Warn "Force requested. Reinstalling base build dependencies."
}

if ($osName -eq "windows") {
    Invoke-CondaRun -CondaEnv $CondaEnv -Arguments @("conda", "install", "-y", "cmake", "ninja")
    Invoke-CondaRun -CondaEnv $CondaEnv -Arguments @("conda", "install", "-y", "-c", "conda-forge", "libuv=1.51")
    Invoke-CondaRun -CondaEnv $CondaEnv -Arguments @(
        "pip", "install", "mkl-static", "mkl-include", "pyyaml", "typing_extensions", "requests"
    )
} else {
    Invoke-CondaRun -CondaEnv $CondaEnv -Arguments @("conda", "install", "-y", "cmake", "ninja")
    Invoke-CondaRun -CondaEnv $CondaEnv -Arguments @(
        "pip", "install", "pyyaml", "typing_extensions", "requests"
    )
}
Invoke-CondaRun -CondaEnv $CondaEnv -Arguments @("pip", "install", "-r", (Join-Path $resolvedPyTorchDir "requirements.txt"))
Write-OK "Dependency installation complete"

$pythonInfo = Get-CondaPythonInfo -CondaEnv $CondaEnv
$pythonExecutable = Resolve-ExistingPath -PathValue $pythonInfo.executable
$condaPrefix = Resolve-ExistingPath -PathValue $pythonInfo.prefix
$condaBinPath = Get-CondaPrefixLibraryPath -CondaPrefix $condaPrefix
$pathEntries = [System.Collections.Generic.List[string]]::new()

$environmentMap = [ordered]@{}
$toolchain = [ordered]@{}

if ($osName -eq "windows") {
    Write-Step "Capturing MSVC toolchain environment"
    $toolchainInfo = Get-WindowsToolchain -RequestedVcvarsPath $VcvarsPath -RequestedMsvcVersion $MsvcVersion
    $toolchain = [ordered]@{
        vcvars_path  = $toolchainInfo.VcvarsPath
        msvc_version = $toolchainInfo.MsvcVersion
        cl_path      = $toolchainInfo.ClPath
    }

    $vcvarsEnv = Get-WindowsVcvarsEnvironment -VcvarsPathValue $toolchainInfo.VcvarsPath -MsvcVersionValue $toolchainInfo.MsvcVersion
    foreach ($name in @("LIB", "INCLUDE", "LIBPATH", "WindowsSdkDir", "WindowsSdkVerBinPath")) {
        if ($vcvarsEnv.Contains($name)) {
            $environmentMap[$name] = $vcvarsEnv[$name]
        }
    }

    $pathEntries.Add((Split-Path -Parent $toolchainInfo.ClPath))
    if ($vcvarsEnv.Contains("Path")) {
        foreach ($entry in ($vcvarsEnv["Path"] -split ";")) {
            if ($entry) {
                $pathEntries.Add($entry)
            }
        }
    }

    $environmentMap["CC"] = $toolchainInfo.ClPath
    $environmentMap["CXX"] = $toolchainInfo.ClPath
    $environmentMap["CUDAHOSTCXX"] = $toolchainInfo.ClPath
    $environmentMap["CMAKE_CUDA_HOST_COMPILER"] = $toolchainInfo.ClPath
    $environmentMap["DISTUTILS_USE_SDK"] = "1"
    $environmentMap["CMAKE_GENERATOR"] = "Ninja"
    $environmentMap["CMAKE_GENERATOR_TOOLSET_VERSION"] = $toolchainInfo.MsvcVersion
} else {
    $ccPath = Get-CommandPathOrNull -CommandName "cc"
    $cxxPath = Get-CommandPathOrNull -CommandName "c++"
    if ($ccPath) { $environmentMap["CC"] = $ccPath }
    if ($cxxPath) { $environmentMap["CXX"] = $cxxPath }
    $environmentMap["CMAKE_GENERATOR"] = "Ninja"
}

if ($resolvedCudaHome) {
    $environmentMap["CUDA_HOME"] = $resolvedCudaHome
    $environmentMap["CUDA_PATH"] = $resolvedCudaHome
    if (Test-IsWindows) {
        $pathEntries.Add((Join-Path $resolvedCudaHome "bin"))
    } else {
        $pathEntries.Add((Join-Path $resolvedCudaHome "bin"))
    }
}

if ($resolvedCudnnRoot) {
    $environmentMap["CUDNN_ROOT"] = $resolvedCudnnRoot
    $environmentMap["CUDNN_ROOT_DIR"] = $resolvedCudnnRoot
}

if ($resolvedMagmaDir) {
    $environmentMap["MAGMA_HOME"] = $resolvedMagmaDir
}

$environmentMap["TORCH_CUDA_ARCH_LIST"] = Get-ArchList -CudaVersionValue $CudaVersion
$environmentMap["USE_CUDA"] = "1"
$environmentMap["USE_CUDNN"] = if ($resolvedCudnnRoot) { "1" } else { "0" }
$environmentMap["USE_FLASH_ATTENTION"] = "1"
$environmentMap["USE_MKLDNN"] = "1"
$environmentMap["USE_DISTRIBUTED"] = "1"
$environmentMap["USE_GLOO"] = "1"
$environmentMap["USE_NUMPY"] = "1"
$environmentMap["USE_KINETO"] = "1"
$environmentMap["USE_TEST"] = "0"
$environmentMap["CMAKE_BUILD_PARALLEL_LEVEL"] = [string][Math]::Max(1, [Environment]::ProcessorCount - 2)
$environmentMap["MAX_JOBS"] = [string][Math]::Max(1, [Environment]::ProcessorCount - 2)
$environmentMap["PYTORCH_BUILD_VERSION"] = ""
$environmentMap["PYTORCH_BUILD_NUMBER"] = ""

$prefixEntries = [System.Collections.Generic.List[string]]::new()
$prefixEntries.Add($condaPrefix)
if ($resolvedCudnnRoot) { $prefixEntries.Add($resolvedCudnnRoot) }
if ($resolvedCudaHome) { $prefixEntries.Add($resolvedCudaHome) }
$environmentMap["CMAKE_PREFIX_PATH"] = ($prefixEntries | Where-Object { $_ } | Select-Object -Unique) -join [IO.Path]::PathSeparator

if (Test-IsWindows) {
    $pathEntries.Add((Join-Path $condaPrefix "Scripts"))
}
$pathEntries.Add($condaBinPath)
if ($env:PATH) {
    foreach ($entry in ($env:PATH -split [IO.Path]::PathSeparator)) {
        if ($entry) {
            $pathEntries.Add($entry)
        }
    }
}
$environmentMap["PATH"] = ($pathEntries | Where-Object { $_ } | Select-Object -Unique) -join [IO.Path]::PathSeparator

$config = [ordered]@{
    generated_at = (Get-Date).ToString("s")
    platform = $osName
    pytorch_dir = $resolvedPyTorchDir
    conda = [ordered]@{
        env_name = $CondaEnv
        python_executable = $pythonExecutable
        prefix = $condaPrefix
        python_version = $PythonVer
    }
    cuda = [ordered]@{
        version = $CudaVersion
        cuda_home = $resolvedCudaHome
        cudnn_root = $resolvedCudnnRoot
        magma_dir = $resolvedMagmaDir
    }
    toolchain = $toolchain
    build = [ordered]@{
        working_directory = $resolvedPyTorchDir
        python_executable = $pythonExecutable
        command = @($pythonExecutable, "setup.py", "bdist_wheel")
        cleanup_paths = @("build", "dist", "build_python", "torch.egg-info")
    }
    environment = $environmentMap
}

$resolvedEnvFile = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path (Get-RepoRoot) $EnvFile }
Save-EnvConfig -Config $config -EnvFile $resolvedEnvFile

Write-OK "Wrote environment JSON: $resolvedEnvFile"
Write-Host ""
Write-Host "Next: pwsh ./src/build.ps1" -ForegroundColor Cyan
