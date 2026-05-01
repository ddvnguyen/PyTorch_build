Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "`n==> $Message" -ForegroundColor Cyan
}

function Write-OK {
    param([string]$Message)
    Write-Host "    [OK] $Message" -ForegroundColor Green
}

function Write-Warn {
    param([string]$Message)
    Write-Host "    [WARN] $Message" -ForegroundColor Yellow
}

function Write-Fail {
    param([string]$Message)
    Write-Host "    [FAIL] $Message" -ForegroundColor Red
    exit 1
}

function Get-RepoRoot {
    return Split-Path -Parent $PSScriptRoot
}

function Get-DefaultPyTorchDir {
    $repoRoot = Get-RepoRoot
    $candidate = Join-Path $repoRoot "pytorch"
    if (Test-Path $candidate) {
        return (Resolve-Path $candidate).Path
    }

    return $candidate
}

function Resolve-ExistingPath {
    param([Parameter(Mandatory = $true)][string]$PathValue)

    if (-not (Test-Path $PathValue)) {
        return $PathValue
    }

    return (Resolve-Path $PathValue).Path
}

function Test-IsWindows {
    return [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform(
        [System.Runtime.InteropServices.OSPlatform]::Windows
    )
}

function Get-CommandPathOrNull {
    param([Parameter(Mandatory = $true)][string]$CommandName)

    $command = Get-Command $CommandName -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    return $null
}

function Invoke-CondaRun {
    param(
        [Parameter(Mandatory = $true)][string]$CondaEnv,
        [Parameter(Mandatory = $true)][string[]]$Arguments
    )

    $conda = Get-CommandPathOrNull -CommandName "conda"
    if (-not $conda) {
        Write-Fail "conda was not found in PATH"
    }

    $allArgs = @("run", "--no-capture-output", "-n", $CondaEnv) + $Arguments
    & $conda @allArgs
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "conda run failed: $($Arguments -join ' ')"
    }
}

function Get-CondaPythonInfo {
    param([Parameter(Mandatory = $true)][string]$CondaEnv)

    $conda = Get-CommandPathOrNull -CommandName "conda"
    if (-not $conda) {
        Write-Fail "conda was not found in PATH"
    }

    $command = @(
        "run", "--no-capture-output", "-n", $CondaEnv,
        "python", "-c",
        "import json, os, sys; print(json.dumps({'executable': sys.executable, 'prefix': sys.prefix}))"
    )
    $raw = & $conda @command
    if ($LASTEXITCODE -ne 0) {
        Write-Fail "Unable to resolve python from conda env '$CondaEnv'"
    }

    return ($raw | ConvertFrom-Json)
}

function Get-DefaultEnvFile {
    return Join-Path $PSScriptRoot "env.json"
}

function Save-EnvConfig {
    param(
        [Parameter(Mandatory = $true)]$Config,
        [Parameter(Mandatory = $true)][string]$EnvFile
    )

    $parent = Split-Path -Parent $EnvFile
    if ($parent -and -not (Test-Path $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    $Config | ConvertTo-Json -Depth 8 | Set-Content -Path $EnvFile -Encoding UTF8
}

function Load-EnvConfig {
    param([Parameter(Mandatory = $true)][string]$EnvFile)

    if (-not (Test-Path $EnvFile)) {
        Write-Fail "Environment file not found: $EnvFile"
    }

    return Get-Content -Raw $EnvFile | ConvertFrom-Json
}

function Set-EnvironmentFromMap {
    param([Parameter(Mandatory = $true)]$Map)

    foreach ($property in $Map.PSObject.Properties) {
        if ($null -ne $property.Value) {
            Set-Item -Path "env:$($property.Name)" -Value ([string]$property.Value)
        }
    }
}
