# Improve PyTorch Build Pipeline Automation

## Summary
Stabilize the current Node/React build console around reliable phase-based automation: checkout, conda bootstrap, environment preparation, dependency install, and wheel build. Use the updated docs as guidance, but do not copy draft installer code directly. Keep Server-Sent Events and defer Ninja batch retry/windowing until the phase pipeline is robust.

## Key Changes
- [x] Fix the current broken server baseline first:
  - [x] Repair `app/server/environment.ts`, especially the malformed `getAvailableToolchains` / toolchain detection section.
  - [x] Align client/server `BuildConfig` and `PipelineRun` types for resume/toolchain fields.
  - [x] Ensure `npm run typecheck`, `npm test`, and `npm run build` pass again.
- [x] Add environment readiness automation:
  - [x] Automatically bootstrap Miniconda when `conda` is missing, then remember the resolved executable path for later runs.
  - [x] Implement safe prerequisite detection for Git, conda, Python, CUDA, cuDNN, MSVC/vcvarsall, CMake, Ninja, and sccache.
  - [x] Add `GET /api/environment/status` returning detected tools, versions, paths, readiness, and issues.
  - [x] Add `POST /api/environment/prepare` that creates the conda env and installs conda/pip dependencies only.
  - [x] Do not run winget, CUDA installers, MSVC installers, or machine-level PATH changes in v1; surface manual remediation text instead.
- [x] Improve pipeline reliability:
  - [x] Persist run state after each phase transition.
  - [x] Support phase resume using existing `resumeFromRunId` and `resumeFromStage`.
  - [x] Make checkout safer: validate existing checkout, fetch/checkout selected ref, sync submodules, and avoid destructive cleanup unless explicitly requested by config.
  - [x] Generate `src/env.json` from detected environment and selected config.
  - [x] Keep dependency install and build as separate phases with clear logs and cancellation.
- [x] Improve UI and docs:
  - [x] Show environment readiness before `Run pipeline`.
  - [x] Add a “Prepare environment” action for conda/pip dependencies.
  - [x] Show selected MSVC toolchain when on Windows.
  - [x] Create root `README.md` with install, dev, build, start, and pipeline usage instructions.

## API / Types
- [x] Add environment types:
  - [x] `ToolVersion`, `EnvironmentStatus`, `EnvironmentIssue`, `EnvironmentPrepareResult`.
- [x] Add or update endpoints:
  - [x] `GET /api/environment/status`
  - [x] `POST /api/environment/prepare`
  - [x] Keep existing pipeline endpoints and SSE log streaming.
- [x] Keep SSE rather than WebSockets for now because current streaming is one-way log/status updates.

## Test Plan
- [x] Typecheck client and server.
- [x] Unit-test environment detection parsing with mocked command outputs.
- [x] Unit-test Miniconda bootstrap planning for Windows and Linux.
- [x] Unit-test command planning for checkout, dependency install, prepare, and build.
- [x] Unit-test resume decisions: same ref skips completed phases; changed ref reruns checkout.
- [ ] Smoke-test APIs without launching a real PyTorch build:
  - [ ] `/api/config`
  - [ ] `/api/environment/status`
  - [ ] `/api/github/build-options?ref=main`
- [ ] Browser-test the app after implementation if the local server can be kept reachable.

## Assumptions
- V1 automation may install conda/pip dependencies inside the selected conda env, but does not install system CUDA/MSVC/cuDNN automatically.
- Existing PowerShell scripts remain as legacy fallback.
- Ninja batch retry/checkpointing from `docs/pipeline_architecture/ARCHITECTURE.md` is deferred.
- The README should be added at repo root because no README currently exists.
