# Stage contract

`scripts/Invoke-SandboxDeployment.ps1` runs the in-VM deployment as a sequence of resumable stages. Each
stage records a phase in a JSON file under `C:\AzureLocalSandbox\State`, and the orchestrator skips a
stage whose recorded phase is already one of its expected phases. This document is the contract those
stages honour.

## Before any stage

Two gates run first, and neither costs meaningful time or money:

1. `Test-HostReadiness.ps1` checks the host itself: operating system, memory, virtualization, the `V:`
   volume and its filesystem, the sandbox source tree, the virtual switches, the host NAT, and whether
   Windows Update is able to restart the host mid-deployment.
2. `Test-DeploymentPreflight.ps1` checks Azure: the deployment context, the Azure Local region, the
   managed-identity sign-in, the sandbox resource group, and the soft-deleted key vault collision.

`-PreflightOnly` stops after these. `-SkipAzurePreflight` runs only the first.

A resumed run additionally fails if `nested-vms.json` exists while the verified parent images do not,
because rebuilding parent images under existing differencing disks produces guests that cannot boot.

## Stages

| # | Stage | State file | Completing phase | Typical duration |
|---|---|---|---|---|
| 1 | Images | `images.json` | `ImagesVerified` | 20-60 min |
| 2 | NestedVMs | `nested-vms.json` | `NestedVMsCreated`, `NestedVMsStarted` | ~5 min |
| 3 | GuestDisks | `guest-disks.json` | `GuestDisksSpecialized` | ~10 min |
| 4 | LevelOne | `level-one-guests.json` | `LevelOneGuestsReady` | ~10 min |
| 5 | ManagementPlane | `management-plane.json` | `ManagementPlaneReady` | 15-20 min |
| 6 | ArcRegistration | `arc-registration.json` | `AzureLocalNodesArcConnected` | up to 60 min |
| 7 | Validation | `azure-local-deployment.json` | `AzureLocalValidated`, `AzureLocalDeployed` | 2.5-3 h |
| 8 | Deployment | `azure-local-deployment.json` | `AzureLocalDeployed` | 2.5-3 h |
| 9 | FinalValidation | none | none | ~5 min |

Stage 8 runs only with `-Deploy`. Stage 9 always runs; it has no state file and is therefore never
skipped.

Stages 7 and 8 are executed by the Azure Local service rather than by this repository, so their duration
is not something the sandbox can shorten. That is why the checks that can fail a deployment are pulled
forward into preflight instead.

## Resume semantics

`Images` is verified rather than trusted. `Test-ImageState` re-reads `images.json`, confirms both images
exist, and re-hashes each one against the recorded SHA-256. Every other stage is trusted on its recorded
phase alone.

State lives on the OS disk (`C:`) and the parent images live on the data disk (`V:`). Both survive a
deallocate, so a stopped and restarted host resumes from the last completed stage. Losing either one
independently is the case the parent-image guard exists to catch.

State markers are administrative resume markers, not signed evidence that a stage was performed
correctly.

## Forcing a stage

`-ForceStage` re-runs a stage even when its phase says it is complete. Two combinations are rejected
because they cannot produce a working lab:

- Forcing `Images` while `nested-vms.json` exists. Differencing disks reference the parent images, so
  replacing a parent orphans every guest built on it.
- Forcing `GuestDisks` while `level-one-guests.json` exists. Disks are specialized once, before first
  boot, and re-specializing a booted guest does not undo what first boot already wrote.

Forcing `ArcRegistration`, `Validation`, or `Deployment` is safe; each is idempotent against Azure.

## Failure handling inside stages

- `Images` monitors DISM for CPU and disk progress and stops it after `-ApplyStallMinutes` (default 20)
  without either. A stall is reported as a hang rather than left to run out the clock.
- `ArcRegistration` retries `Invoke-AzStackHciArcInitialization` up to `-ArcInitializationAttempts`
  (default 3) times, but only when the failure is `PrepareKvaTimeoutError`, the appliance image download
  timeout. Every other failure is raised immediately. The ARM token is re-issued per attempt.
- `Validation` and `Deployment` delete a `deploymentSettings` resource left in a `Failed` state before
  resubmitting, because otherwise Azure returns the previous failure forever.
