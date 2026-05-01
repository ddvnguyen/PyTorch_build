# Build Pipeline Resume Feature

## Overview

The build pipeline has been enhanced to support resuming from previous passing runs. This allows users to skip stages that have already completed successfully, reducing build time significantly when dealing with long-running builds that fail partway through.

## Key Features

### 1. **Automatic Stage Persistence**
- All pipeline runs are now persisted to disk in `.pytorch-build-console/runs/` directory
- Each run is saved as a JSON file containing full stage status, timing, and environment information
- Run state is automatically saved when the pipeline completes (success, failure, or cancellation)

### 2. **Resume from Previous Run**
- Users can resume a failed or previous build by specifying:
  - `resumeFromRunId`: The ID of the previous run to resume from
  - `resumeFromStage`: Optional stage ID to start from (if not specified, skips all passed stages)

### 3. **Smart Stage Skipping**
- When resuming, stages that previously succeeded are automatically skipped
- Skipped stages maintain their historical timing and status information
- Avoids re-running time-consuming operations like dependency installation
- A log message indicates which stages were skipped

### 4. **Build Configuration Updates**
The `BuildConfig` type now includes:
```typescript
resumeFromStage?: string;     // Stage ID to resume from
resumeFromRunId?: string;     // Previous run ID to resume from
```

### 5. **Pipeline Run Tracking**
The `PipelineRun` type now includes:
```typescript
resumedFromRunId?: string;    // ID of the run this resumed from
skippedStages?: string[];     // List of stages that were skipped
```

## API Endpoints

### List Previous Runs
```
GET /api/pipeline/previous-runs
```
Returns a list of all previous pipeline runs sorted by date (newest first).

**Response:**
```json
[
  {
    "id": "1234567890",
    "status": "succeeded",
    "startedAt": "2026-05-01T10:30:00.000Z",
    "finishedAt": "2026-05-01T12:45:00.000Z",
    "stages": [...],
    "artifact": "path/to/wheel.whl"
  }
]
```

### Get Previous Run Details
```
GET /api/pipeline/{runId}/previous
```
Retrieves the full details of a specific previous run.

### Get Successful Stages
```
GET /api/pipeline/{runId}/successful-stages
```
Returns only the stages that completed successfully in a given run.

**Response:**
```json
{
  "stages": ["checkout", "prepare", "dependencies", "build"]
}
```

### Start Pipeline with Resume
```
POST /api/pipeline/start
```
Request body can now include resume parameters:
```json
{
  "selectedRef": "main",
  "pytorchDir": "...",
  "condaEnv": "pytorch_build",
  ...
  "resumeFromRunId": "1234567890",
  "resumeFromStage": "build"
}
```

## Pipeline Stages

1. **checkout** - Clone/fetch PyTorch source
2. **prepare** - Generate environment configuration (env.json)
3. **dependencies** - Install build dependencies
4. **build** - Build the PyTorch wheel

## Usage Example

### Scenario: Build fails at the build stage

1. First attempt: User starts a build that fails at the "build" stage
2. Run ID: `1234567890`
3. Stages completed: `checkout`, `prepare`, `dependencies`

### Resume the build

```typescript
const config = {
  ...previousConfig,
  resumeFromRunId: "1234567890",
  resumeFromStage: "build"  // Optional: resume from this stage
};

const result = await startPipeline(config);
```

**Result:** 
- The pipeline skips `checkout`, `prepare`, and `dependencies`
- Logs indicate: "Skipping checkout (already succeeded)", etc.
- Only runs the `build` stage
- Reuses the environment configuration (envJson) from the previous run

## Benefits

1. **Time Savings**: Skip time-consuming stages that already passed
   - Checkout: Could take several minutes for large repo
   - Dependencies: Often the longest stage
   - Prepare: Minimal time but still avoids redundant work

2. **Reliability**: Enables iteration on failures without full rebuild
   - Fix a build issue
   - Resume from build stage
   - No need to reconfigure environment

3. **Resource Efficiency**: Reduces unnecessary CPU and network usage

## Implementation Details

### Stage Skipping Logic
```typescript
function shouldSkipStage(previousRun: PipelineRun, stageId: string, resumeFromStage?: string): boolean {
  // Don't skip if this is the resume point
  if (resumeFromStage && stageId === resumeFromStage) return false;
  
  // Skip stages before the resume point
  if (resumeFromStage && getStageIndex(stageId) < getStageIndex(resumeFromStage)) {
    return true;
  }

  // Skip stages that already succeeded in the previous run
  const stage = previousRun.stages.find((s) => s.id === stageId);
  return stage?.status === "succeeded";
}
```

### Run Persistence
- All run state is persisted after completion
- Files stored in: `.pytorch-build-console/runs/{runId}.json`
- Includes full stage information, timing, and environment data
- Allows offline inspection of previous runs

## Future Enhancements

1. **Run Cleanup**: Add ability to delete old runs from history
2. **Run Comparison**: Compare builds to identify performance regressions
3. **Selective Rebuild**: Force rebuild specific stages even if they passed
4. **Run Annotations**: Allow users to tag/label important runs
5. **Incremental Dependencies**: Cache and compare dependency trees
