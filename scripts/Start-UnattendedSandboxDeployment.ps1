#Requires -Version 5.1
#Requires -RunAsAdministrator

[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingPlainTextForPassword',
    '',
    Justification = 'Azure Run Command encrypts protected parameters, which are converted to DPAPI-protected PSCredentials immediately on the VM.'
)]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSAvoidUsingConvertToSecureStringWithPlainText',
    '',
    Justification = 'The protected parameter boundary must be converted before credentials can be persisted with DPAPI.'
)]
[CmdletBinding(DefaultParameterSetName = 'Initialize')]
param(
    [Parameter(Mandatory, ParameterSetName = 'Initialize')]
    [uri]$WindowsServerIsoUri,

    [Parameter(Mandatory, ParameterSetName = 'Initialize')]
    [uri]$AzureLocalIsoUri,

    [Parameter(Mandatory, ParameterSetName = 'Initialize')]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$WindowsServerIsoSha256,

    [Parameter(Mandatory, ParameterSetName = 'Initialize')]
    [ValidatePattern('^[A-Fa-f0-9]{64}$')]
    [string]$AzureLocalIsoSha256,

    [Parameter(ParameterSetName = 'Initialize')]
    [ValidateRange(1, 100)]
    [int]$WindowsServerImageIndex = 4,

    [Parameter(ParameterSetName = 'Initialize')]
    [ValidateRange(1, 100)]
    [int]$AzureLocalImageIndex = 1,

    [Parameter(Mandatory, ParameterSetName = 'Initialize')]
    [string]$LocalAdministratorPassword,

    [Parameter(Mandatory, ParameterSetName = 'Initialize')]
    [string]$DomainAdministratorPassword,

    [Parameter(Mandatory, ParameterSetName = 'Initialize')]
    [string]$LcmPassword,

    [Parameter(ParameterSetName = 'Initialize')]
    [string]$TargetSolutionVersion,

    [Parameter(Mandatory, ParameterSetName = 'Run')]
    [switch]$Run
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$sandboxRoot = 'C:\AzureLocalSandbox'
$mediaRoot = Join-Path $sandboxRoot 'Media'
$stateRoot = Join-Path $sandboxRoot 'State'
$logRoot = Join-Path $sandboxRoot 'Logs'
$configurationPath = Join-Path $stateRoot 'unattended-deployment.json'
$credentialPath = Join-Path $stateRoot 'unattended-credentials.clixml'
$statusPath = Join-Path $stateRoot 'unattended-status.json'
$transcriptPath = Join-Path $logRoot 'UnattendedDeployment.log'
$taskName = 'AzureLocalSandboxUnattendedDeployment'

function Write-UnattendedStatus {
    param(
        [Parameter(Mandatory)][string]$Phase,
        [Parameter(Mandatory)][string]$Message
    )

    [ordered]@{
        phase     = $Phase
        message   = $Message
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

function Save-VerifiedIso {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$DestinationPath,
        [Parameter(Mandatory)][string]$ExpectedSha256,
        [Parameter(Mandatory)][string]$Label
    )

    if (Test-Path -LiteralPath $DestinationPath) {
        $existingHash = (Get-FileHash -LiteralPath $DestinationPath -Algorithm SHA256).Hash
        if ($existingHash -eq $ExpectedSha256) {
            Write-Information "$Label is already downloaded and verified." -InformationAction Continue
            return
        }
        Remove-Item -LiteralPath $DestinationPath -Force
    }

    $partialPath = "$DestinationPath.partial"
    Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            Write-Information "Downloading $Label (attempt $attempt of 3)..." -InformationAction Continue
            Start-BitsTransfer -Source $Uri.AbsoluteUri -Destination $partialPath -TransferType Download -ErrorAction Stop
            $actualHash = (Get-FileHash -LiteralPath $partialPath -Algorithm SHA256).Hash
            if ($actualHash -ne $ExpectedSha256) {
                throw "$Label SHA-256 mismatch. Expected $ExpectedSha256; received $actualHash."
            }
            Move-Item -LiteralPath $partialPath -Destination $DestinationPath -Force
            Write-Information "$Label downloaded and verified." -InformationAction Continue
            return
        }
        catch {
            Remove-Item -LiteralPath $partialPath -Force -ErrorAction SilentlyContinue
            if ($attempt -eq 3) {
                throw
            }
            Write-Warning "$Label download failed: $($_.Exception.Message)"
            Start-Sleep -Seconds (30 * $attempt)
        }
    }
}

function Wait-HostReady {
    param([timespan]$Timeout = [timespan]::FromMinutes(30))

    $bootstrapStatePath = Join-Path $stateRoot 'bootstrap.json'
    $deadline = (Get-Date).Add($Timeout)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $bootstrapStatePath) {
            try {
                $bootstrapState = Get-Content -LiteralPath $bootstrapStatePath -Raw | ConvertFrom-Json
                if ($bootstrapState.phase -eq 'HostReady') {
                    return
                }
                if ($bootstrapState.phase -eq 'Failed') {
                    throw "Host bootstrap failed: $($bootstrapState.message)"
                }
            }
            catch {
                if ($_.Exception.Message -like 'Host bootstrap failed:*') {
                    throw
                }
            }
        }
        Start-Sleep -Seconds 30
    }

    throw "Host bootstrap did not reach HostReady within $($Timeout.TotalMinutes) minutes."
}

New-Item -Path $mediaRoot, $stateRoot, $logRoot -ItemType Directory -Force | Out-Null

if (-not $Run) {
    foreach ($password in @($LocalAdministratorPassword, $DomainAdministratorPassword, $LcmPassword)) {
        if ($password.Length -lt 14) {
            throw 'Every nested environment password must be at least 14 characters long.'
        }
    }

    $credentials = @(
        [PSCredential]::new('Administrator', (ConvertTo-SecureString $LocalAdministratorPassword -AsPlainText -Force))
        [PSCredential]::new('JUMPSTART\Administrator', (ConvertTo-SecureString $DomainAdministratorPassword -AsPlainText -Force))
        [PSCredential]::new('LocalBoxDeployUser', (ConvertTo-SecureString $LcmPassword -AsPlainText -Force))
    )
    $credentials | Export-Clixml -LiteralPath $credentialPath -Force

    [ordered]@{
        windowsServerIsoUri      = $WindowsServerIsoUri.AbsoluteUri
        azureLocalIsoUri         = $AzureLocalIsoUri.AbsoluteUri
        windowsServerIsoSha256   = $WindowsServerIsoSha256.ToUpperInvariant()
        azureLocalIsoSha256      = $AzureLocalIsoSha256.ToUpperInvariant()
        windowsServerImageIndex  = $WindowsServerImageIndex
        azureLocalImageIndex     = $AzureLocalImageIndex
        targetSolutionVersion    = $TargetSolutionVersion
    } | ConvertTo-Json | Set-Content -LiteralPath $configurationPath -Encoding UTF8

    $action = New-ScheduledTaskAction `
        -Execute 'powershell.exe' `
        -Argument "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Run"
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet `
        -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries `
        -ExecutionTimeLimit ([timespan]::Zero) `
        -RestartCount 3 `
        -RestartInterval (New-TimeSpan -Minutes 5)
    Register-ScheduledTask `
        -TaskName $taskName `
        -Action $action `
        -Principal $principal `
        -Settings $settings `
        -Force | Out-Null

    Write-UnattendedStatus -Phase 'Scheduled' -Message 'The unattended deployment task is starting.'
    Start-ScheduledTask -TaskName $taskName
    Write-Information "Started scheduled task '$taskName'." -InformationAction Continue
    return
}

$transcriptStarted = $false
try {
    Start-Transcript -Path $transcriptPath -Append | Out-Null
    $transcriptStarted = $true
    Write-UnattendedStatus -Phase 'WaitingForHost' -Message 'Waiting for the host bootstrap to finish.'
    Wait-HostReady
    Write-UnattendedStatus -Phase 'DownloadingMedia' -Message 'Downloading and verifying Microsoft ISO media.'

    $configuration = Get-Content -LiteralPath $configurationPath -Raw | ConvertFrom-Json
    $credentials = @(Import-Clixml -LiteralPath $credentialPath)
    if ($credentials.Count -ne 3) {
        throw 'The unattended credential file is missing or invalid.'
    }

    $windowsServerIsoPath = Join-Path $mediaRoot 'WindowsServer2025.iso'
    $azureLocalIsoPath = Join-Path $mediaRoot 'AzureLocal.iso'
    Save-VerifiedIso `
        -Uri ([uri]$configuration.windowsServerIsoUri) `
        -DestinationPath $windowsServerIsoPath `
        -ExpectedSha256 $configuration.windowsServerIsoSha256 `
        -Label 'Windows Server 2025 ISO'
    Save-VerifiedIso `
        -Uri ([uri]$configuration.azureLocalIsoUri) `
        -DestinationPath $azureLocalIsoPath `
        -ExpectedSha256 $configuration.azureLocalIsoSha256 `
        -Label 'Azure Local ISO'

    Write-UnattendedStatus -Phase 'Deploying' -Message 'Running the resumable sandbox deployment workflow.'
    $deploymentParameters = @{
        LocalAdministratorCredential  = $credentials[0]
        DomainAdministratorCredential = $credentials[1]
        LcmCredential                 = $credentials[2]
        WindowsServerIsoPath          = $windowsServerIsoPath
        AzureLocalIsoPath             = $azureLocalIsoPath
        WindowsServerIsoSha256        = $configuration.windowsServerIsoSha256
        AzureLocalIsoSha256            = $configuration.azureLocalIsoSha256
        WindowsServerImageIndex       = [int]$configuration.windowsServerImageIndex
        AzureLocalImageIndex          = [int]$configuration.azureLocalImageIndex
        Deploy                         = $true
    }
    if ($configuration.targetSolutionVersion) {
        $deploymentParameters.TargetSolutionVersion = [string]$configuration.targetSolutionVersion
    }

    & (Join-Path $PSScriptRoot 'Invoke-SandboxDeployment.ps1') @deploymentParameters
    Write-UnattendedStatus -Phase 'Completed' -Message 'The sandbox deployment and validation workflow completed.'
}
catch {
    Write-UnattendedStatus -Phase 'Failed' -Message $_.Exception.Message
    throw
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}