#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param(
    [switch]$Continue,

    [string]$SubscriptionId,

    [string]$TenantId,

    [string]$ResourceGroupName,

    [string]$AzureLocation,

    [string]$HciResourceProviderObjectId,

    [string]$SourceArchiveUriBase64,

    [string]$SourceArchiveSha256Base64
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$SandboxRoot = 'C:\AzureLocalSandbox'
$ScriptsPath = Join-Path $SandboxRoot 'Scripts'
$LogsPath = Join-Path $SandboxRoot 'Logs'
$StatePath = Join-Path $SandboxRoot 'State'
$InstalledScriptPath = Join-Path $ScriptsPath 'Bootstrap.ps1'
$StateFile = Join-Path $StatePath 'bootstrap.json'
$ContinuationTaskName = 'AzureLocalSandbox-ContinueBootstrap'
$StoragePoolName = 'AzureLocalSandboxPool'
$VirtualDiskName = 'NestedVMStorage'
$VolumeLabel = 'NestedVMs'
$DeploymentContextFile = Join-Path $StatePath 'deployment-context.json'
$SourcePath = Join-Path $SandboxRoot 'Source'
$MediaPath = Join-Path $SandboxRoot 'Media'
$SetupLauncherPath = Join-Path $ScriptsPath 'Launch-SandboxSetup.ps1'

function Initialize-SetupLauncher {
    New-Item -Path $MediaPath -ItemType Directory -Force | Out-Null

    @'
$setupScript = 'C:\AzureLocalSandbox\Source\scripts\Start-SandboxSetup.ps1'
if (-not (Test-Path -LiteralPath $setupScript)) {
    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show("Setup script not found: $setupScript", 'Azure Local Sandbox') | Out-Null
    exit 1
}

$arguments = "-NoLogo -NoProfile -NoExit -ExecutionPolicy Bypass -File `"$setupScript`""
Start-Process `
    -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
    -ArgumentList $arguments `
    -Verb RunAs
'@ | Set-Content -LiteralPath $SetupLauncherPath -Encoding UTF8

    $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    if (-not $publicDesktop) {
        $publicDesktop = 'C:\Users\Public\Desktop'
    }
    New-Item -Path $publicDesktop -ItemType Directory -Force | Out-Null

    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut((Join-Path $publicDesktop 'Azure Local Sandbox Setup.lnk'))
    $shortcut.TargetPath = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    $shortcut.Arguments = "-NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$SetupLauncherPath`""
    $shortcut.WorkingDirectory = $SourcePath
    $shortcut.Description = 'Continue Azure Local sandbox setup after downloading licensed ISO media.'
    $shortcut.IconLocation = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe,0"
    $shortcut.Save()
}

function Initialize-SandboxSource {
    param(
        [string]$ArchiveUriBase64,
        [string]$ArchiveSha256Base64,
        [bool]$IsContinuation
    )

    if ((Test-Path -LiteralPath (Join-Path $SourcePath 'scripts\Invoke-SandboxDeployment.ps1')) -and
        (Test-Path -LiteralPath (Join-Path $SourcePath 'config\lab.psd1'))) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($ArchiveUriBase64) -or
        [string]::IsNullOrWhiteSpace($ArchiveSha256Base64)) {
        if ($IsContinuation) {
            throw "Sandbox source is missing from '$SourcePath' and no source archive was supplied."
        }
        throw 'SourceArchiveUriBase64 is required.'
    }

    try {
        $sourceArchiveValue = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($ArchiveUriBase64)
        )
        $sourceArchive = [uri]$sourceArchiveValue
        $sourceArchiveSha256 = [Text.Encoding]::UTF8.GetString(
            [Convert]::FromBase64String($ArchiveSha256Base64)
        ).ToUpperInvariant()
    }
    catch {
        throw 'The source archive URI is not valid base64-encoded UTF-8.'
    }

    if (-not $sourceArchive.IsAbsoluteUri -or $sourceArchive.Scheme -ne 'https') {
        throw 'The source archive must use an absolute HTTPS URI.'
    }
    if ($sourceArchiveSha256 -notmatch '^[A-F0-9]{64}$') {
        throw 'The source archive SHA-256 is invalid.'
    }

    $downloadPath = Join-Path $env:TEMP 'AzureLocalSandboxSource.zip'
    $extractPath = Join-Path $env:TEMP 'AzureLocalSandboxSource'
    Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue

    try {
        Invoke-WebRequest -Uri $sourceArchive -OutFile $downloadPath -UseBasicParsing
        $downloadHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
        if ($downloadHash -ne $sourceArchiveSha256) {
            throw "Source archive SHA-256 mismatch. Expected $sourceArchiveSha256; received $downloadHash."
        }
        Expand-Archive -LiteralPath $downloadPath -DestinationPath $extractPath -Force

        $archiveRoot = Get-ChildItem -LiteralPath $extractPath -Directory |
            Where-Object {
                (Test-Path -LiteralPath (Join-Path $_.FullName 'scripts\Invoke-SandboxDeployment.ps1')) -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'config\lab.psd1'))
            } |
            Select-Object -First 1
        if (-not $archiveRoot) {
            throw 'The source archive does not contain the expected scripts and configuration directories.'
        }

        Remove-Item -LiteralPath $SourcePath -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $SourcePath -ItemType Directory -Force | Out-Null
        Copy-Item -Path (Join-Path $archiveRoot.FullName '*') -Destination $SourcePath -Recurse -Force
    }
    finally {
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    [ordered]@{
        phase     = 'SourceReady'
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content `
        -LiteralPath (Join-Path $StatePath 'source.json') `
        -Encoding UTF8
}

function Write-DeploymentContext {
    param(
        [string]$ContextSubscriptionId,
        [string]$ContextTenantId,
        [string]$ContextResourceGroupName,
        [string]$ContextAzureLocation,
        [string]$ContextHciResourceProviderObjectId
    )

    $contextValues = @(
        $ContextSubscriptionId
        $ContextTenantId
        $ContextResourceGroupName
        $ContextAzureLocation
        $ContextHciResourceProviderObjectId
    )
    if (@($contextValues | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        if (-not $Continue) {
            throw 'Azure deployment context is incomplete.'
        }
        return
    }

    [ordered]@{
        subscriptionId              = $ContextSubscriptionId
        tenantId                    = $ContextTenantId
        resourceGroupName           = $ContextResourceGroupName
        azureLocation               = $ContextAzureLocation
        hciResourceProviderObjectId = $ContextHciResourceProviderObjectId
    } | ConvertTo-Json | Set-Content -LiteralPath $DeploymentContextFile -Encoding UTF8
}

function Write-DeploymentState {
    param(
        [Parameter(Mandatory)]
        [string]$Phase,

        [Parameter(Mandatory)]
        [string]$Message
    )

    [ordered]@{
        phase     = $Phase
        message   = $Message
        updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Register-ContinuationTask {
    $taskArguments = '-NoLogo -NoProfile -ExecutionPolicy Bypass -File "{0}" -Continue' -f $InstalledScriptPath
    $taskAction = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $taskArguments
    $taskTrigger = New-ScheduledTaskTrigger -AtStartup
    $taskPrincipal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $taskSettings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)

    Register-ScheduledTask `
        -TaskName $ContinuationTaskName `
        -Action $taskAction `
        -Trigger $taskTrigger `
        -Principal $taskPrincipal `
        -Settings $taskSettings `
        -Force | Out-Null
}

function Initialize-NestedVmStorage {
    $existingVolume = Get-Volume -DriveLetter V -ErrorAction SilentlyContinue
    if ($existingVolume) {
        if ($existingVolume.FileSystemLabel -ne $VolumeLabel) {
            throw "Drive V: is already assigned to volume '$($existingVolume.FileSystemLabel)'."
        }

        return
    }

    $storagePool = Get-StoragePool -FriendlyName $StoragePoolName -ErrorAction SilentlyContinue
    if (-not $storagePool) {
        $poolableDisks = @(Get-PhysicalDisk | Where-Object { $_.CanPool })
        if ($poolableDisks.Count -lt 4) {
            throw "At least four poolable data disks are required; found $($poolableDisks.Count)."
        }

        $storageSubsystem = Get-StorageSubSystem |
            Where-Object { $_.FriendlyName -like 'Windows Storage*' } |
            Select-Object -First 1

        if (-not $storageSubsystem) {
            throw 'The Windows Storage subsystem was not found.'
        }

        $storagePool = New-StoragePool `
            -FriendlyName $StoragePoolName `
            -StorageSubsystemUniqueId $storageSubsystem.UniqueId `
            -PhysicalDisks $poolableDisks
    }

    $virtualDisk = Get-VirtualDisk -FriendlyName $VirtualDiskName -ErrorAction SilentlyContinue
    if (-not $virtualDisk) {
        $virtualDisk = New-VirtualDisk `
            -StoragePoolFriendlyName $storagePool.FriendlyName `
            -FriendlyName $VirtualDiskName `
            -ProvisioningType Fixed `
            -ResiliencySettingName Simple `
            -UseMaximumSize
    }

    $disk = $virtualDisk | Get-Disk
    if ($disk.PartitionStyle -eq 'RAW') {
        $disk = $disk | Initialize-Disk -PartitionStyle GPT -PassThru
    }

    $partition = Get-Partition -DiskNumber $disk.Number -ErrorAction SilentlyContinue |
        Where-Object { $_.Type -ne 'Reserved' } |
        Select-Object -First 1

    if (-not $partition) {
        $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize -DriveLetter V
    }
    elseif (-not $partition.DriveLetter) {
        $partition = $partition | Set-Partition -NewDriveLetter V -PassThru
    }

    $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
    if (-not $volume.FileSystem) {
        $partition | Format-Volume `
            -FileSystem ReFS `
            -AllocationUnitSize 65536 `
            -NewFileSystemLabel $VolumeLabel `
            -Confirm:$false | Out-Null
    }

    New-Item -Path 'V:\VMs', 'V:\VHDs' -ItemType Directory -Force | Out-Null
}

function Initialize-InternalSwitchAddress {
    param(
        [Parameter(Mandatory)]
        [string]$SwitchName,

        [Parameter(Mandatory)]
        [string]$IpAddress,

        [Parameter(Mandatory)]
        [ValidateRange(1, 32)]
        [int]$PrefixLength
    )

    if (-not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        New-VMSwitch -Name $SwitchName -SwitchType Internal | Out-Null
    }

    $adapter = Get-NetAdapter -Name "vEthernet ($SwitchName)"
    $configuredAddress = Get-NetIPAddress `
        -InterfaceIndex $adapter.ifIndex `
        -AddressFamily IPv4 `
        -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -eq $IpAddress }

    if (-not $configuredAddress) {
        Get-NetIPAddress `
            -InterfaceIndex $adapter.ifIndex `
            -AddressFamily IPv4 `
            -ErrorAction SilentlyContinue |
            Where-Object { $_.PrefixOrigin -ne 'WellKnown' } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        New-NetIPAddress `
            -InterfaceIndex $adapter.ifIndex `
            -IPAddress $IpAddress `
            -PrefixLength $PrefixLength | Out-Null
    }
}

function Initialize-HostNetworking {
    Initialize-InternalSwitchAddress -SwitchName 'InternalSwitch' -IpAddress '192.168.1.20' -PrefixLength 24
    Initialize-InternalSwitchAddress -SwitchName 'InternalNAT' -IpAddress '192.168.128.1' -PrefixLength 24

    $existingNat = Get-NetNat -Name 'AzureLocalSandboxNAT' -ErrorAction SilentlyContinue
    if ($existingNat -and $existingNat.InternalIPInterfaceAddressPrefix -ne '192.168.128.0/24') {
        throw "NAT 'AzureLocalSandboxNAT' already exists with prefix '$($existingNat.InternalIPInterfaceAddressPrefix)'."
    }

    if (-not $existingNat) {
        New-NetNat -Name 'AzureLocalSandboxNAT' -InternalIPInterfaceAddressPrefix '192.168.128.0/24' | Out-Null
    }
}

function Invoke-PostRebootConfiguration {
    Write-DeploymentState -Phase 'ConfiguringHost' -Message 'Configuring storage and Hyper-V networking.'

    $vmManagementService = Get-Service -Name 'vmms'
    if ($vmManagementService.Status -ne 'Running') {
        Start-Service -Name 'vmms'
        $vmManagementService.WaitForStatus('Running', (New-TimeSpan -Minutes 5))
    }

    Initialize-NestedVmStorage
    Initialize-HostNetworking
    Initialize-SetupLauncher

    Unregister-ScheduledTask -TaskName $ContinuationTaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-DeploymentState -Phase 'HostReady' -Message 'Hyper-V host storage and networking are ready for nested VM creation.'
}

$transcriptStarted = $false

try {
    New-Item -Path $SandboxRoot, $ScriptsPath, $LogsPath, $StatePath -ItemType Directory -Force | Out-Null
    Write-DeploymentContext `
        -ContextSubscriptionId $SubscriptionId `
        -ContextTenantId $TenantId `
        -ContextResourceGroupName $ResourceGroupName `
        -ContextAzureLocation $AzureLocation `
        -ContextHciResourceProviderObjectId $HciResourceProviderObjectId
    Start-Transcript -Path (Join-Path $LogsPath 'Bootstrap.log') -Append | Out-Null
    $transcriptStarted = $true
    Initialize-SandboxSource `
        -ArchiveUriBase64 $SourceArchiveUriBase64 `
        -ArchiveSha256Base64 $SourceArchiveSha256Base64 `
        -IsContinuation ([bool]$Continue)

    if ($Continue) {
        Invoke-PostRebootConfiguration
        return
    }

    if ((Resolve-Path -LiteralPath $PSCommandPath).Path -ne $InstalledScriptPath) {
        Copy-Item -LiteralPath $PSCommandPath -Destination $InstalledScriptPath -Force
    }

    Write-DeploymentState -Phase 'InstallingHyperV' -Message 'Installing the Hyper-V role and management tools.'
    Register-ContinuationTask

    $featureResult = Install-WindowsFeature `
        -Name 'Hyper-V' `
        -IncludeAllSubFeature `
        -IncludeManagementTools

    if ((Get-WindowsFeature -Name 'Hyper-V').InstallState -ne 'Installed') {
        throw 'The Hyper-V role did not install successfully.'
    }

    if ([string]$featureResult.RestartNeeded -eq 'Yes') {
        Write-DeploymentState -Phase 'RebootScheduled' -Message 'Hyper-V is installed; post-reboot configuration is scheduled.'
        & shutdown.exe /r /t 120 /d p:4:1 /c 'Azure Local sandbox host bootstrap requires a restart.' | Out-Null
        return
    }

    Invoke-PostRebootConfiguration
}
catch {
    Write-DeploymentState -Phase 'Failed' -Message $_.Exception.Message
    throw
}
finally {
    if ($transcriptStarted) {
        Stop-Transcript | Out-Null
    }
}