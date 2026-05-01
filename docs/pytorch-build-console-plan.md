# PyTorch Build Console Plan

## Goal And Scope

- [x] Create a tracked plan for the TypeScript + React PyTorch build console.
- [x] Provide a local web UI for configuring and running PyTorch source builds.
- [x] Use Node.js as the primary cross-platform runner on Windows and Linux.
- [x] Keep existing PowerShell scripts available as legacy fallback.
- [x] Store generated machine-local build state outside tracked source files.

## Architecture Summary

- [x] Root `npm` project using Vite, React, TypeScript, Express, and Server-Sent Events.
- [x] React client under `app/client`.
- [x] Node server under `app/server`.
- [x] One local server serves the UI and exposes build APIs.
- [x] GitHub metadata is fetched from `pytorch/pytorch` releases, tags, and selected-ref raw files.
- [x] Pipeline logs and run state are stored under `.pytorch-build-console`.
- [x] Generated environment JSON is written to `src/env.json`.

## API Contract

- [x] `GET /api/github/versions`
- [x] `GET /api/github/build-options?ref=<ref>`
- [x] `GET /api/config`
- [x] `PUT /api/config`
- [x] `POST /api/pipeline/start`
- [x] `POST /api/pipeline/:runId/cancel`
- [x] `GET /api/pipeline/:runId/status`
- [x] `GET /api/pipeline/:runId/events`

## UI Checklist

- [x] Follow the approved PyTorch Build Console concept.
- [x] Left configuration rail for project, version, CUDA, Python, conda, and paths.
- [x] Center pipeline view for checkout, prepare, dependencies, and build.
- [x] Right live log stream and `env.json` summary.
- [x] Bottom artifact and diagnostic strip.
- [x] Version selector prefers releases and includes tags.
- [x] CUDA and NVIDIA GPU architecture selectors.
- [x] Parsed plus curated build options from selected PyTorch ref.
- [x] Start, cancel, status, failure, and completion states.

## Runner Checklist

- [x] Clone or fetch local PyTorch checkout.
- [x] Checkout selected release/tag/ref.
- [x] Sync and update submodules recursively.
- [x] Detect conda, Python, CUDA, and platform toolchain.
- [x] Generate `src/env.json`.
- [x] Install common and platform-specific dependencies.
- [x] Run wheel build.
- [x] Stream stdout and stderr to the UI.
- [x] Support cancellation.

## Test Checklist

- [x] Type-check client and server.
- [x] Test GitHub build-option parsing with mocked source.
- [x] Test command planning without launching a real PyTorch build.
- [ ] Browser-test desktop layout.
- [ ] Browser-test mobile layout.
- [ ] Verify log streaming and cancellation.
- [ ] Verify generated `env.json` shape.

## Open Follow-Up Items

- [ ] Add editable/develop install target after wheel build is stable.
- [ ] Add richer CUDA/cuDNN compatibility hints from upstream release notes.
- [ ] Add optional PowerShell fallback execution from the UI.
- [ ] Add persisted run history and artifact indexing.
- [ ] Add automated browser smoke tests that can keep the local server alive for the browser runner.
