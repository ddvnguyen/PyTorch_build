# ============================================================
# 3_test.ps1
# Installs the built wheel and runs verification:
#   - arch list check (sm_60 + sm_120)
#   - per-GPU matmul test
#   - fp16 test
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
Write-OK "Python     = $script:CondaPython"
Write-OK "PyTorchDir = $script:PyTorchDir"

# ------------------------------------------------------------
# 2. Install wheel
# ------------------------------------------------------------
Write-Step "Installing built wheel"

$wheel = Get-ChildItem "$script:PyTorchDir\dist\torch-*.whl" |
         Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $wheel) {
    Write-Fail "No wheel found in $script:PyTorchDir\dist\ -- run 2_build.ps1 first"
}

Write-Host "    Installing $($wheel.Name)..."
& $script:CondaPython -m pip install $wheel.FullName --force-reinstall
if ($LASTEXITCODE -ne 0) { Write-Fail "Wheel install failed" }
Write-OK "Installed: $($wheel.Name)"

# ------------------------------------------------------------
# 3. Write and run verification script
# ------------------------------------------------------------
Write-Step "Running GPU verification tests"

$testPy = Join-Path $env:TEMP "pytorch_gpu_test.py"
Set-Content -Path $testPy -Encoding UTF8 -Value @'
import torch, sys

print("=" * 56)
print(f"PyTorch  : {torch.__version__}")
print(f"CUDA     : {torch.version.cuda}")
print(f"cuDNN    : {torch.backends.cudnn.version()}")
print(f"GPU count: {torch.cuda.device_count()}")
archs = torch.cuda.get_arch_list()
print(f"Arch list: {archs}")
print("=" * 56)

# Arch check
failures = []
sm60_ok  = "sm_60"  in archs
sm120_ok = "sm_120" in archs
print(f"sm_60  (P100)        : {'OK' if sm60_ok  else 'MISSING'}")
print(f"sm_120 (RTX 5060 Ti) : {'OK' if sm120_ok else 'MISSING'}")
if not sm60_ok:  failures.append("sm_60 missing from arch list")
if not sm120_ok: failures.append("sm_120 missing from arch list")

print()

# Per-GPU tests
for i in range(torch.cuda.device_count()):
    p   = torch.cuda.get_device_properties(i)
    cap = f"sm_{p.major}{p.minor}"
    ok  = cap in archs
    print(f"GPU {i}: {p.name}")
    print(f"  Compute cap : {p.major}.{p.minor} ({cap}) -- {'OK' if ok else 'NOT IN ARCH LIST'}")
    print(f"  VRAM        : {p.total_memory / 1024**3:.1f} GB")

    # matmul test
    try:
        x = torch.randn(1024, 1024, device=f"cuda:{i}")
        y = torch.matmul(x, x.T)
        torch.cuda.synchronize(i)
        print(f"  matmul test : PASS (mean={y.mean():.4f})")
    except Exception as e:
        print(f"  matmul test : FAIL -- {e}")
        failures.append(f"GPU {i} matmul failed: {e}")

    # fp16 test
    if p.major < 7:
        print(f"  fp16 test   : SKIPPED (sm_{p.major}{p.minor} has limited fp16)")
    else:
        try:
            x16 = torch.randn(512, 512, device=f"cuda:{i}", dtype=torch.float16)
            y16 = torch.matmul(x16, x16.T)
            torch.cuda.synchronize(i)
            print(f"  fp16 test   : PASS")
        except Exception as e:
            print(f"  fp16 test   : FAIL -- {e}")
            failures.append(f"GPU {i} fp16 failed: {e}")
    print()

print("=" * 56)
if failures:
    print("RESULT: FAILED")
    for f in failures:
        print(f"  - {f}")
    sys.exit(1)
else:
    print("RESULT: ALL TESTS PASSED")
    sys.exit(0)
'@

& $script:CondaPython $testPy
$exitCode = $LASTEXITCODE
Remove-Item $testPy -ErrorAction SilentlyContinue

Write-Host ""
if ($exitCode -ne 0) {
    Write-Warn "Some tests failed -- see output above"
} else {
    Write-OK "All tests passed"
}

Write-Host ""
Write-Host "============================================================" -ForegroundColor Cyan
Write-Host " Done!  Activate your env with:"                              -ForegroundColor Cyan
Write-Host "   conda activate $script:CondaEnv"                          -ForegroundColor White
Write-Host "============================================================"  -ForegroundColor Cyan