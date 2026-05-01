# ============================================================
# smoke_test.ps1
# Lightweight verification for development (no pip install)
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step { param([string]$m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param([string]$m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn { param([string]$m) Write-Host "    [WARN] $m" -ForegroundColor Yellow }
function Write-Fail { param([string]$m) Write-Host "    [FAIL] $m" -ForegroundColor Red; exit 1 }

# ------------------------------------------------------------
# 1. Load env vars
# ------------------------------------------------------------
$envFile = Join-Path (Split-Path $MyInvocation.MyCommand.Path) "env_vars.ps1"
if (-not (Test-Path $envFile)) {
    Write-Fail "env_vars.ps1 not found -- run 1_prepare.ps1 first"
}
Write-Step "Loading environment from env_vars.ps1"
. $envFile

# ------------------------------------------------------------
# 2. Setup PYTHONPATH for local build testing
# ------------------------------------------------------------
Write-Step "Configuring PYTHONPATH to point to PyTorch source"
$originalPythonPath = $env:PYTHONPATH
$env:PYTHONPATH = "$script:PyTorchDir;$originalPythonPath"

# ------------------------------------------------------------
# 3. Run quick verification script
# ------------------------------------------------------------
Write-Step "Running smoke test (GPU availability & basic math)"
$testPy = Join-Path $env:TEMP "pytorch_smoke_test.py"
Set-Content -Path $testPy -Encoding UTF8 -Value @'
import torch, sys
try:
    import torch
    print(f"Module loaded: {torch.__version__}")
except ImportError as e:
    print(f"Import Error: {e}")
    sys.exit(1)

print(f"CUDA available: {torch.cuda.is_available()}")
if torch.cuda.is_available():
    print(f"Device count: {torch.cuda.device_count()}")
    dev = torch.cuda.current_device()
    print(f"Current device: {torch.cuda.get_device_name(dev)}")
    # Quick math test
    x = torch.randn(10, 10).cuda()
    y = x @ x
    print("Basic CUDA matmul: PASS")
else:
    print("CUDA NOT available - check build/drivers")
    sys.exit(1)

sys.exit(0)
'@

& $script:CondaPython $testPy
$exitCode = $LASTEXITCODE
Remove-Item $testPy -ErrorAction SilentlyContinue

Write-Host ""
if ($exitCode -ne 0) {
    Write-Fail "Smoke test failed"
} else {
    Write-OK "Smoke test passed (Fast verification)"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Done!  To run full install/test, use:"                              -ForegroundColor Cyan
Write-Host "   .\3_test.ps1"                                              -ForegroundColor White
Write-Host "============================================================"  -ForegroundColor Cyan