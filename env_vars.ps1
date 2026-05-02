# Auto-generated - Strict Long-Path Parity & SDK Fix
# Generated: 2026-05-01 20:47

# --- MSVC & SDK Environment ---
$env:LIB                         = ""
$env:INCLUDE                     = ""
$env:LIBPATH                     = ""
$env:WindowsSdkDir               = "C:\\Program Files (x86)\\Windows Kits\\10\\"
$env:WindowsSdkVerBinPath        = "C:\\Program Files (x86)\\Windows Kits\\10\\bin\\10.0.26100.0\\"

# --- MSVC ---


# --- CUDA & cuDNN ---
$env:CUDA_HOME                   = "C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA\\v12.9"
$env:CUDA_PATH                   = "C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA\\v12.9"
$env:CUDNN_ROOT                  = "C:\\Program Files\\NVIDIA\\CUDNN\\v9.21"
$env:TORCH_CUDA_ARCH_LIST        = "6.0;12.0"

# --- Compiler Fix (NVCC Parity) ---
$env:CUDAHOSTCXX                 = "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\MSVC\\14.38.33130\\bin\\Hostx64\\x64\\cl.exe"
$env:CXX                         = "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\MSVC\\14.38.33130\\bin\\Hostx64\\x64\\cl.exe"
$env:CC                          = "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\MSVC\\14.38.33130\\bin\\Hostx64\\x64\\cl.exe"
$env:DISTUTILS_USE_SDK           = "1"
$env:CMAKE_GENERATOR             = "Ninja"
$env:CMAKE_GENERATOR_TOOLSET_VERSION = "14.38.33130"

# --- PATH (Unified Long-Path String including SDK) ---
$env:PATH = ";C:\Windows\System32;"

# --- CMake Search Paths ---
$env:CMAKE_PREFIX_PATH           = "C:\\ProgramData\\miniconda3\\envs\\pytorch-build;C:\\Program Files\\NVIDIA\\CUDNN\\v9.21;C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA\\v12.9"
$env:CMAKE_INCLUDE_PATH          = "C:\\ProgramData\\miniconda3\\envs\\pytorch-build\\Library\\include"
$env:MAGMA_HOME                  = ""

# --- Build Feature Flags ---
$env:USE_CUDA                    = "1"
$env:USE_CUDNN                   = "1"
$env:USE_FLASH_ATTENTION         = "1"
$env:USE_MKLDNN                  = "1"
$env:USE_DISTRIBUTED             = "1"
$env:USE_GLOO                    = "1"
$env:USE_NUMPY                   = "1"
$env:USE_KINETO                  = "1"
$env:USE_TEST                    = "0"
$env:BUILD_TEST                  = "0"
$env:INSTALL_TEST                = "0"
$env:USE_NNPACK                  = "0"

# --- Parallelism & Flags ---
$env:CMAKE_BUILD_PARALLEL_LEVEL  = "14"
$env:MAX_JOBS                    = "6"
$env:NVCC_APPEND_FLAGS           = "--diag-suppress=20092"

# --- Script Helpers ---
$script:VcvarsPath               = "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Auxiliary\\Build\\vcvarsall.bat"
$script:VcvarsVersion            = "14.38.33130"
$script:ChosenClExe              = "C:\\Program Files (x86)\\Microsoft Visual Studio\\2022\\BuildTools\\VC\\Tools\\MSVC\\14.38.33130\\bin\\Hostx64\\x64\\cl.exe"
$script:PyTorchDir               = "D:\\Workplace\\PyTorch-build\\pytorch"
$script:CondaPython              = "C:\\ProgramData\\miniconda3\\envs\\pytorch-build\\python.exe"
$script:CondaEnv                 = "pytorch-build"
$script:CondaPrefix              = "C:\\ProgramData\\miniconda3\\envs\\pytorch-build"
