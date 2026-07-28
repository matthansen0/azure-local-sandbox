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

    [ValidateSet('Images', 'NestedVMs', 'GuestDisks', 'LevelOne', 'ManagementPlane', 'ArcRegistration', 'Validation', 'Deployment')]
    [string[]]$ForceStage = @(),

    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..\config\lab.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$stateRoot = 'C:\AzureLocalSandbox\State'
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

    Write-Information "[$(Get-Date -Format o)] Starting stage: $Name" -InformationAction Continue
    & $Action
    Write-Information "[$(Get-Date -Format o)] Completed stage: $Name" -InformationAction Continue
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

& (Join-Path $PSScriptRoot 'Test-HostReadiness.ps1')

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
                -LcmCredential $deploymentCredential
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
                -LcmCredential $deploymentCredential
        }
    }

    Invoke-Stage -Name 'FinalValidation' -Action {
        & (Join-Path $PSScriptRoot 'Test-SandboxDeployment.ps1') `
            -ConfigurationPath $labConfigurationPath `
            -LocalAdministratorCredential $localCredential `
            -RequireAzureLocalDeployment:$Deploy
    }

[ordered]@{
    phase     = if ($Deploy) { 'Complete' } else { 'Validated' }
    updatedAt = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json | Set-Content `
    -LiteralPath (Join-Path $stateRoot 'orchestration.json') `
    -Encoding UTF8