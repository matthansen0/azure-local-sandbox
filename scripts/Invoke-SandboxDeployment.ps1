#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCredential]$LocalAdministratorCredential,

    [Parameter(Mandatory)]
    [PSCredential]$DomainAdministratorCredential,

    [Parameter(Mandatory)]
    [PSCredential]$LcmCredential,

    [uri]$WindowsServerUri,

    [uri]$AzureLocalUri,

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$WindowsServerSha256,

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$AzureLocalSha256,

    [string]$WindowsServerIsoPath,

    [string]$AzureLocalIsoPath,

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$WindowsServerIsoSha256,

    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$AzureLocalIsoSha256,

    [ValidateRange(0, 100)]
    [int]$WindowsServerImageIndex = 0,

    [ValidateRange(0, 100)]
    [int]$AzureLocalImageIndex = 0,

    [string]$TargetSolutionVersion,

    [switch]$Deploy,

    # Runs the host and Azure checks, then stops before any stage that costs time or money.
    [switch]$PreflightOnly,

    [switch]$SkipAzurePreflight,

    # Purging is irreversible, so a blocking vault is reported rather than removed unless this is set.
    [switch]$PurgeSoftDeletedKeyVault,

    [ValidateSet('Images', 'NestedVMs', 'GuestDisks', 'LevelOne', 'ManagementPlane', 'ArcRegistration', 'Validation', 'Deployment')]
    [string[]]$ForceStage = @(),

    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..\config\lab.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$stateRoot = 'C:\AzureLocalSandbox\State'
$logRoot = 'C:\AzureLocalSandbox\Logs'
$localCredential = $LocalAdministratorCredential
$domainCredential = $DomainAdministratorCredential
$deploymentCredential = $LcmCredential
$solutionVersion = $TargetSolutionVersion
$forcedStages = @($ForceStage)
$labConfigurationPath = $ConfigurationPath

function Get-StatePhase {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        return (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json).phase
    }
    catch {
        return $null
    }
}

function Test-StageComplete {
    param(
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)][string[]]$ExpectedPhases
    )

    if ($Stage -in $forcedStages) {
        return $false
    }

    return (Get-StatePhase -Path $StatePath) -in $ExpectedPhases
}

function Test-ImageState {
    param([Parameter(Mandatory)][string]$StatePath)

    if ('Images' -in $forcedStages -or -not (Test-Path -LiteralPath $StatePath)) {
        return $false
    }

    try {
        $state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json
        if ($state.phase -ne 'ImagesVerified' -or @($state.images).Count -ne 2) {
            return $false
        }

        foreach ($image in @($state.images)) {
            if (-not (Test-Path -LiteralPath $image.Path)) {
                return $false
            }
            if ((Get-FileHash -LiteralPath $image.Path -Algorithm SHA256).Hash -ne $image.Sha256) {
                return $false
            }
        }

        return $true
    }
    catch {
        return $false
    }
}

function Invoke-Stage {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    # 6>&1 because a Windows PowerShell 5.1 transcript does not record the information stream.
    Write-Information "[$(Get-Date -Format o)] Starting stage: $Name" -InformationAction Continue 6>&1
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    & $Action 6>&1
    $stopwatch.Stop()
    Write-Information "[$(Get-Date -Format o)] Completed stage: $Name in $($stopwatch.Elapsed.ToString('hh\:mm\:ss'))" -InformationAction Continue 6>&1
}

if ($localCredential.Password.Length -lt 14) {
    throw 'The nested local Administrator password must be at least 14 characters long.'
}
if ($domainCredential.Password.Length -lt 14) {
    throw 'The domain Administrator password must be at least 14 characters long.'
}
if ($deploymentCredential.Password.Length -lt 14) {
    throw 'The LCM deployment password must be at least 14 characters long.'
}

New-Item -Path $stateRoot -ItemType Directory -Force | Out-Null

# A run lasts hours and the console that started it is often gone by the time anyone looks, so the
# whole thing is transcribed to disk, starting before the gates so a failed check is captured too.
New-Item -Path $logRoot -ItemType Directory -Force | Out-Null
$transcriptPath = Join-Path $logRoot "sandbox-deployment-$(Get-Date -Format 'yyyyMMdd-HHmmss').log"
$transcriptStarted = $false
try {
    Start-Transcript -Path $transcriptPath | Out-Null
    $transcriptStarted = $true
    Write-Information "Logging this run to $transcriptPath" -InformationAction Continue 6>&1
}
catch {
    Write-Warning "Could not start a transcript, continuing without one: $($_.Exception.Message)"
}

try {
    & (Join-Path $PSScriptRoot 'Test-HostReadiness.ps1') 6>&1

    if (-not $SkipAzurePreflight) {
        & (Join-Path $PSScriptRoot 'Test-DeploymentPreflight.ps1') `
            -ConfigurationPath $labConfigurationPath `
            -PurgeSoftDeletedKeyVault:$PurgeSoftDeletedKeyVault 6>&1
    }

    if ($PreflightOnly) {
        Write-Information 'Preflight only: every check passed and no stage was started.' -InformationAction Continue 6>&1
        return
    }

    # A resumed run that still has downstream state but has lost its parent images would silently rebuild
    # them and then fail later against differencing disks that no longer have a parent.
    $imagesVerified = Test-ImageState -StatePath (Join-Path $stateRoot 'images.json')
    if (-not $imagesVerified -and (Test-Path -LiteralPath (Join-Path $stateRoot 'nested-vms.json'))) {
        throw 'Nested VM state exists but the verified parent images are missing or no longer match their recorded hashes. Restore V:\VHDs or remove the nested VMs and their state before resuming.'
    }

    if ('Images' -in $forcedStages -and (Test-Path -LiteralPath (Join-Path $stateRoot 'nested-vms.json'))) {
        throw 'Parent images cannot be replaced after differencing disks exist. Remove the nested VMs and their state before forcing Images.'
    }
    if ('GuestDisks' -in $forcedStages -and (Test-Path -LiteralPath (Join-Path $stateRoot 'level-one-guests.json'))) {
        throw 'Guest disks cannot be re-specialized after first boot. Rebuild the nested VMs instead of forcing GuestDisks.'
    }

    $imageStatePath = Join-Path $stateRoot 'images.json'
    if (-not (Test-ImageState -StatePath $imageStatePath)) {
        $vhdxInputs = @($WindowsServerUri, $AzureLocalUri, $WindowsServerSha256, $AzureLocalSha256)
        $isoInputs = @(
            $WindowsServerIsoPath
            $AzureLocalIsoPath
            $WindowsServerIsoSha256
            $AzureLocalIsoSha256
            $WindowsServerImageIndex
            $AzureLocalImageIndex
        )
        $hasVhdxInput = @($vhdxInputs | Where-Object { $_ }).Count -gt 0
        $hasIsoInput = @($isoInputs | Where-Object { $_ }).Count -gt 0
        if ($hasVhdxInput -and $hasIsoInput) {
            throw 'Choose either verified VHDX URLs or local ISO media, not both.'
        }
        if (-not $hasVhdxInput -and -not $hasIsoInput) {
            throw 'Verified images are unavailable. Supply either both VHDX URLs and hashes or both local ISO paths, hashes, and image indexes.'
        }

        Invoke-Stage -Name 'Images' -Action {
            if ($hasIsoInput) {
                & (Join-Path $PSScriptRoot 'Convert-LabIsoMedia.ps1') `
                    -WindowsServerIsoPath $WindowsServerIsoPath `
                    -AzureLocalIsoPath $AzureLocalIsoPath `
                    -WindowsServerIsoSha256 $WindowsServerIsoSha256 `
                    -AzureLocalIsoSha256 $AzureLocalIsoSha256 `
                    -WindowsServerImageIndex $WindowsServerImageIndex `
                    -AzureLocalImageIndex $AzureLocalImageIndex `
                    -StateFile $imageStatePath `
                    -Force:('Images' -in $forcedStages)
            }
            else {
                if (@($vhdxInputs | Where-Object { -not $_ }).Count -gt 0) {
                    throw 'Both VHDX URLs and both publisher-provided SHA-256 values are required.'
                }
                & (Join-Path $PSScriptRoot 'Get-LabImages.ps1') `
                    -WindowsServerUri $WindowsServerUri `
                    -AzureLocalUri $AzureLocalUri `
                    -WindowsServerSha256 $WindowsServerSha256 `
                    -AzureLocalSha256 $AzureLocalSha256 `
                    -StateFile $imageStatePath `
                    -Force:('Images' -in $forcedStages)
            }
        }
    }

    $nestedVmStatePath = Join-Path $stateRoot 'nested-vms.json'
    if (-not (Test-StageComplete `
        -Stage 'NestedVMs' `
        -StatePath $nestedVmStatePath `
        -ExpectedPhases @('NestedVMsCreated', 'NestedVMsStarted'))) {
        Invoke-Stage -Name 'NestedVMs' -Action {
            & (Join-Path $PSScriptRoot 'New-NestedLab.ps1') `
                -ConfigurationPath $labConfigurationPath
        }
    }

    $guestDiskStatePath = Join-Path $stateRoot 'guest-disks.json'
    if (-not (Test-StageComplete `
        -Stage 'GuestDisks' `
        -StatePath $guestDiskStatePath `
        -ExpectedPhases @('GuestDisksSpecialized'))) {
        Invoke-Stage -Name 'GuestDisks' -Action {
            & (Join-Path $PSScriptRoot 'Initialize-GuestDisks.ps1') `
                -ConfigurationPath $labConfigurationPath `
                -LocalAdministratorCredential $localCredential
        }
    }

    $levelOneStatePath = Join-Path $stateRoot 'level-one-guests.json'
    if (-not (Test-StageComplete `
        -Stage 'LevelOne' `
        -StatePath $levelOneStatePath `
        -ExpectedPhases @('LevelOneGuestsReady'))) {
        Invoke-Stage -Name 'LevelOne' -Action {
            & (Join-Path $PSScriptRoot 'Initialize-LevelOneGuests.ps1') `
                -ConfigurationPath $labConfigurationPath `
                -LocalAdministratorCredential $localCredential
        }
    }

    $managementStatePath = Join-Path $stateRoot 'management-plane.json'
    if (-not (Test-StageComplete `
        -Stage 'ManagementPlane' `
        -StatePath $managementStatePath `
        -ExpectedPhases @('ManagementPlaneReady'))) {
        Invoke-Stage -Name 'ManagementPlane' -Action {
            & (Join-Path $PSScriptRoot 'Initialize-ManagementPlane.ps1') `
                -ConfigurationPath $labConfigurationPath `
                -LocalAdministratorCredential $localCredential `
                -DomainAdministratorCredential $domainCredential `
                -LcmCredential $deploymentCredential
        }
    }

    $arcStatePath = Join-Path $stateRoot 'arc-registration.json'
    if (-not (Test-StageComplete `
        -Stage 'ArcRegistration' `
        -StatePath $arcStatePath `
        -ExpectedPhases @('AzureLocalNodesArcConnected'))) {
        Invoke-Stage -Name 'ArcRegistration' -Action {
            & (Join-Path $PSScriptRoot 'Register-AzureLocalNodes.ps1') `
                -ConfigurationPath $labConfigurationPath `
                -LocalAdministratorCredential $localCredential `
                -TargetSolutionVersion $solutionVersion
        }
    }

    $deploymentStatePath = Join-Path $stateRoot 'azure-local-deployment.json'
    if (-not (Test-StageComplete `
        -Stage 'Validation' `
        -StatePath $deploymentStatePath `
        -ExpectedPhases @('AzureLocalValidated', 'AzureLocalDeployed'))) {
        Invoke-Stage -Name 'Validation' -Action {
            & (Join-Path $PSScriptRoot 'Deploy-AzureLocal.ps1') `
                -Mode Validate `
                -ConfigurationPath $labConfigurationPath `
                -LocalAdministratorCredential $localCredential `
                -LcmCredential $deploymentCredential `
                -PurgeSoftDeletedKeyVault:$PurgeSoftDeletedKeyVault
        }
    }

    if ($Deploy -and -not (Test-StageComplete `
        -Stage 'Deployment' `
        -StatePath $deploymentStatePath `
        -ExpectedPhases @('AzureLocalDeployed'))) {
        Invoke-Stage -Name 'Deployment' -Action {
            & (Join-Path $PSScriptRoot 'Deploy-AzureLocal.ps1') `
                -Mode Deploy `
                -ConfigurationPath $labConfigurationPath `
                -LocalAdministratorCredential $localCredential `
                -LcmCredential $deploymentCredential `
                -PurgeSoftDeletedKeyVault:$PurgeSoftDeletedKeyVault
        }
    }

    Invoke-Stage -Name 'FinalValidation' -Action {
        & (Join-Path $PSScriptRoot 'Test-SandboxDeployment.ps1') `
            -ConfigurationPath $labConfigurationPath `
            -LocalAdministratorCredential $localCredential `
            -DomainAdministratorCredential $domainCredential `
            -RequireAzureLocalDeployment:$Deploy
    }

    [ordered]@{
        phase     = if ($Deploy) { 'Complete' } else { 'Validated' }
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content `
        -LiteralPath (Join-Path $stateRoot 'orchestration.json') `
        -Encoding UTF8

    Remove-Item -LiteralPath (Join-Path $stateRoot 'last-error.json') -Force -ErrorAction SilentlyContinue
}
catch {
    # The terminating error is written by the host only after the transcript has stopped, so the
    # reason for the failure is recorded here while the transcript is still running.
    $failureRecord = [ordered]@{
        failedAt         = (Get-Date).ToUniversalTime().ToString('o')
        message          = $_.Exception.Message
        exceptionType    = $_.Exception.GetType().FullName
        position         = $_.InvocationInfo.PositionMessage
        scriptStackTrace = $_.ScriptStackTrace
        transcript       = $transcriptPath
    }
    try {
        $failureRecord | ConvertTo-Json -Depth 4 | Set-Content `
            -LiteralPath (Join-Path $stateRoot 'last-error.json') `
            -Encoding UTF8
    }
    catch {
        Write-Warning "Could not write last-error.json: $($_.Exception.Message)"
    }

    Write-Warning "Sandbox deployment failed: $($failureRecord.message)"
    Write-Information $failureRecord.position -InformationAction Continue 6>&1
    Write-Information "Script stack trace:$([Environment]::NewLine)$($failureRecord.scriptStackTrace)" -InformationAction Continue 6>&1
    Write-Information "Failure details: $(Join-Path $stateRoot 'last-error.json')" -InformationAction Continue 6>&1
    throw
}
finally {
    if ($transcriptStarted) {
        Write-Information "Run log: $transcriptPath" -InformationAction Continue 6>&1
        Stop-Transcript | Out-Null
    }
}