param(
    [string]$EnvFile = "",
    [switch]$Clean,
    [switch]$SkipTest
)

. (Join-Path $PSScriptRoot "common.ps1")

if (-not $EnvFile) {
    $EnvFile = Get-DefaultEnvFile
}

function Invoke-BuildProcess {
    param(
        [Parameter(Mandatory = $true)][string]$WorkingDirectory,
        [Parameter(Mandatory = $true)][string[]]$Command
    )

    Push-Location $WorkingDirectory
    try {
        & $Command[0] $Command[1..($Command.Length - 1)]
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

$resolvedEnvFile = if ([System.IO.Path]::IsPathRooted($EnvFile)) { $EnvFile } else { Join-Path (Get-RepoRoot) $EnvFile }
Write-Step "Loading build environment from JSON"
$config = Load-EnvConfig -EnvFile $resolvedEnvFile

if (-not (Test-Path $config.build.working_directory)) {
    Write-Fail "PyTorch source directory not found: $($config.build.working_directory)"
}

Set-EnvironmentFromMap -Map $config.environment

if ($SkipTest) {
    $existingArgs = if ($env:CMAKE_ARGS) { $env:CMAKE_ARGS } else { "" }
    $env:CMAKE_ARGS = ($existingArgs, "-DBUILD_TEST=OFF" | Where-Object { $_ }) -join " "
}

if ($Clean) {
    Write-Step "Cleaning build outputs"
    foreach ($relativePath in $config.build.cleanup_paths) {
        $targetPath = Join-Path $config.build.working_directory $relativePath
        if (Test-Path $targetPath) {
            Remove-Item -LiteralPath $targetPath -Recurse -Force
            Write-OK "Removed $targetPath"
        }
    }
}

$command = @()
foreach ($item in $config.build.command) {
    $command += [string]$item
}

Write-Step "Running PyTorch build"
$start = Get-Date
$exitCode = Invoke-BuildProcess -WorkingDirectory $config.build.working_directory -Command $command
$elapsedMinutes = [math]::Round(((Get-Date) - $start).TotalMinutes, 1)

if ($exitCode -ne 0) {
    Write-Fail "Build failed after $elapsedMinutes minutes (exit code $exitCode)"
}

Write-OK "Build completed in $elapsedMinutes minutes"
$distDir = Join-Path $config.build.working_directory "dist"
if (Test-Path $distDir) {
    $wheel = Get-ChildItem $distDir -Filter "torch-*.whl" | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($wheel) {
        Write-OK "Wheel: $($wheel.FullName)"
    }
}
