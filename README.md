# PyTorch Build Console

Local web app for preparing a PyTorch build environment and running source builds from one Node.js-backed dashboard.

## What It Does

- Loads PyTorch release and tag options from GitHub.
- Detects local prerequisites such as Git, Python, conda, CMake, Ninja, CUDA, cuDNN, and MSVC on Windows.
- Boots Miniconda into a user-local folder when `conda` is missing, then reuses that executable on later runs.
- Creates the conda build environment and installs Python/build dependencies.
- Generates `src/env.json` for the current build configuration.
- Runs the PyTorch checkout, prepare, dependency install, and wheel build pipeline.

## Requirements

- Node.js 24 or newer.
- Git.
- Conda, or network access for the Miniconda bootstrap flow.
- Python.
- CMake and Ninja.
- CUDA + cuDNN for GPU builds.
- Visual Studio Build Tools with MSVC on Windows.

## Start The Project

```powershell
npm install
npm run dev
```

Open the client at `http://localhost:5173`.

The Vite dev server proxies `/api/*` requests to the Node backend on `http://localhost:4173`.

## Production Run

```powershell
npm run build
npm start
```

Open the built app at `http://localhost:4173`.

## Build Flow

1. Pick a PyTorch version from GitHub releases or tags.
2. Set CUDA, cuDNN, Python, conda env, and checkout path.
3. Click `Prepare environment` to bootstrap Miniconda if needed, then create/update the conda env and install build dependencies.
4. Click `Run pipeline` to checkout PyTorch, generate `src/env.json`, and build the wheel.

## Generated Files

- `src/env.json` contains the resolved build environment used by the pipeline.
- `.pytorch-build-console/` stores local cache and run state.

## Notes

- Existing PowerShell scripts remain in the repo as legacy fallback.
- Ninja batch retry and checkpoint windowing are deferred until the phase pipeline is stable.
