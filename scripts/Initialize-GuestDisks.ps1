#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules Hyper-V, ServerManager

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCredential]$LocalAdministratorCredential,

    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..\config\lab.psd1')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-UnattendPassword {
    param(
        [Parameter(Mandatory)]
        [SecureString]$Password
    )

    $passwordPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Password)
    try {
        $plainTextPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($passwordPointer)
        return [Convert]::ToBase64String(
            [Text.Encoding]::Unicode.GetBytes("${plainTextPassword}AdministratorPassword")
        )
    }
    finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($passwordPointer)
        $plainTextPassword = $null
    }
}

function ConvertTo-UnattendDocument {
    param(
        [Parameter(Mandatory)]
        [string]$ComputerName,

        [Parameter(Mandatory)]
        [SecureString]$AdministratorPassword
    )

    $encodedPassword = ConvertTo-UnattendPassword -Password $AdministratorPassword
    $escapedComputerName = [Security.SecurityElement]::Escape($ComputerName)

    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>$escapedComputerName</ComputerName>
    </component>
    <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <fDenyTSConnections>false</fDenyTSConnections>
    </component>
  </settings>
  <settings pass="oobeSystem">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <UserAccounts>
        <AdministratorPassword>
          <PlainText>false</PlainText>
          <Value>$encodedPassword</Value>
        </AdministratorPassword>
      </UserAccounts>
      <TimeZone>UTC</TimeZone>
      <OOBE>
        <HideEULAPage>true</HideEULAPage>
        <HideLocalAccountScreen>true</HideLocalAccountScreen>
        <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
        <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
        <NetworkLocation>Work</NetworkLocation>
        <ProtectYourPC>1</ProtectYourPC>
        <SkipMachineOOBE>true</SkipMachineOOBE>
        <SkipUserOOBE>true</SkipUserOOBE>
      </OOBE>
    </component>
    <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <InputLocale>en-US</InputLocale>
      <SystemLocale>en-US</SystemLocale>
      <UILanguage>en-US</UILanguage>
      <UserLocale>en-US</UserLocale>
    </component>
  </settings>
</unattend>
"@
}

function Get-AvailableDriveLetter {
    $usedDriveLetters = @(Get-Volume | Where-Object DriveLetter | Select-Object -ExpandProperty DriveLetter)
    foreach ($driveLetter in [char[]](90..70)) {
        if ($driveLetter -notin $usedDriveLetters) {
            return [string]$driveLetter
        }
    }

    throw 'No temporary drive letter is available for guest disk specialization.'
}

function Mount-GuestVhd {
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [ValidateRange(1, 30)]
        [int]$MaximumAttempts = 12
    )

    for ($attempt = 1; $attempt -le $MaximumAttempts; $attempt++) {
        try {
            return Mount-VHD -Path $Path -Passthru -ErrorAction Stop
        }
        catch {
            if ($attempt -eq $MaximumAttempts) {
                throw
            }
            Start-Sleep -Seconds 5
        }
    }
}

function Write-GuestUnattendFile {
    param(
        [Parameter(Mandatory)]
        [string]$VirtualHardDiskPath,

        [Parameter(Mandatory)]
        [string]$UnattendContent
    )

    $mountedVhd = Mount-GuestVhd -Path $VirtualHardDiskPath
    try {
        $disk = $mountedVhd | Get-Disk
        $windowsPartition = $null
        $temporaryDriveLetter = $null

        foreach ($partition in @($disk | Get-Partition | Where-Object Type -ne 'Reserved')) {
            $driveLetter = $partition.DriveLetter
            if (-not $driveLetter) {
                $driveLetter = Get-AvailableDriveLetter
                $partition | Set-Partition -NewDriveLetter $driveLetter
                $temporaryDriveLetter = $driveLetter
            }

            if (Test-Path -LiteralPath "${driveLetter}:\Windows\System32") {
                $windowsPartition = $partition
                break
            }

            if ($temporaryDriveLetter) {
                $partition | Remove-PartitionAccessPath -AccessPath "${temporaryDriveLetter}:\"
                $temporaryDriveLetter = $null
            }
        }

        if (-not $windowsPartition) {
            throw "A Windows partition was not found in '$VirtualHardDiskPath'."
        }

        $windowsDriveLetter = $windowsPartition.DriveLetter
        if (-not $windowsDriveLetter) {
            $windowsDriveLetter = $temporaryDriveLetter
        }

        $pantherPath = "${windowsDriveLetter}:\Windows\Panther"
        New-Item -Path $pantherPath -ItemType Directory -Force | Out-Null
        Set-Content `
            -LiteralPath (Join-Path $pantherPath 'Unattend.xml') `
            -Value $UnattendContent `
            -Encoding UTF8

        $setupScriptsPath = "${windowsDriveLetter}:\Windows\Setup\Scripts"
        New-Item -Path $setupScriptsPath -ItemType Directory -Force | Out-Null
        @'
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Enable-PSRemoting -Force; Set-NetFirewallRule -DisplayGroup 'Remote Desktop' -Enabled True -ErrorAction SilentlyContinue"
del /f /q C:\Windows\Panther\Unattend.xml 2>nul
del /f /q C:\Windows\Panther\Unattend\Unattend.xml 2>nul
del /f /q C:\Windows\System32\Sysprep\Unattend.xml 2>nul
exit /b 0
'@ | Set-Content `
            -LiteralPath (Join-Path $setupScriptsPath 'SetupComplete.cmd') `
            -Encoding Ascii

        if ($temporaryDriveLetter) {
            $windowsPartition | Remove-PartitionAccessPath -AccessPath "${temporaryDriveLetter}:\"
        }
    }
    finally {
        Dismount-VHD -Path $VirtualHardDiskPath -ErrorAction SilentlyContinue
    }
}

function Initialize-ManagementImageStore {
    param(
        [Parameter(Mandatory)]
        [string]$VirtualHardDiskPath,

        [Parameter(Mandatory)]
        [string]$SourceImagePath
    )

    $sourceImage = Get-Item -LiteralPath $SourceImagePath
    $sourceHash = (Get-FileHash -LiteralPath $sourceImage.FullName -Algorithm SHA256).Hash
    $mountedVhd = Mount-GuestVhd -Path $VirtualHardDiskPath
    $temporaryDriveLetter = $null

    try {
        $disk = $mountedVhd | Get-Disk
        if ($disk.IsOffline) {
            $disk | Set-Disk -IsOffline $false
        }
        if ($disk.IsReadOnly) {
            $disk | Set-Disk -IsReadOnly $false
        }
        if ($disk.PartitionStyle -eq 'RAW') {
            $disk = $disk | Initialize-Disk -PartitionStyle GPT -PassThru
        }

        $partition = $disk | Get-Partition -ErrorAction SilentlyContinue |
            Where-Object Type -ne 'Reserved' |
            Select-Object -First 1
        if (-not $partition) {
            $temporaryDriveLetter = Get-AvailableDriveLetter
            $partition = New-Partition `
                -DiskNumber $disk.Number `
                -UseMaximumSize `
                -DriveLetter $temporaryDriveLetter
        }
        elseif (-not $partition.DriveLetter) {
            $temporaryDriveLetter = Get-AvailableDriveLetter
            $partition = $partition | Set-Partition -NewDriveLetter $temporaryDriveLetter -PassThru
        }

        $driveLetter = if ($partition.DriveLetter) {
            [string]$partition.DriveLetter
        }
        else {
            $temporaryDriveLetter
        }
        $volume = $partition | Get-Volume -ErrorAction SilentlyContinue
        if (-not $volume.FileSystem) {
            $partition | Format-Volume `
                -FileSystem NTFS `
                -AllocationUnitSize 65536 `
                -NewFileSystemLabel 'ManagementVMs' `
                -Confirm:$false | Out-Null
        }
        elseif ($volume.FileSystem -ne 'NTFS') {
            throw "Management data disk '$VirtualHardDiskPath' uses unsupported filesystem '$($volume.FileSystem)'."
        }

        $destinationDirectory = "${driveLetter}:\VMs\Base"
        $destinationPath = Join-Path $destinationDirectory 'WindowsServer2025.vhdx'
        New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null

        $result = 'Copied'
        if (Test-Path -LiteralPath $destinationPath) {
            $destinationFile = Get-Item -LiteralPath $destinationPath
            if ($destinationFile.Length -eq $sourceImage.Length -and
                (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash -eq $sourceHash) {
                $result = 'AlreadyVerified'
            }
            else {
                Remove-Item -LiteralPath $destinationPath -Force
            }
        }

        if ($result -eq 'Copied') {
            Copy-Item -LiteralPath $sourceImage.FullName -Destination $destinationPath -Force
            $destinationHash = (Get-FileHash -LiteralPath $destinationPath -Algorithm SHA256).Hash
            if ($destinationHash -ne $sourceHash) {
                Remove-Item -LiteralPath $destinationPath -Force -ErrorAction SilentlyContinue
                throw "Checksum verification failed after copying '$SourceImagePath' into the AzLMGMT data disk."
            }
        }

        return [pscustomobject]@{
            SourcePath      = $sourceImage.FullName
            DestinationPath = 'D:\VMs\Base\WindowsServer2025.vhdx'
            Sha256          = $sourceHash
            Result          = $result
        }
    }
    finally {
        if ($temporaryDriveLetter) {
            $partition | Remove-PartitionAccessPath `
                -AccessPath "${temporaryDriveLetter}:\" `
                -ErrorAction SilentlyContinue
        }
        Dismount-VHD -Path $VirtualHardDiskPath -ErrorAction SilentlyContinue
    }
}

if ($LocalAdministratorCredential.UserName -ne 'Administrator') {
    throw "The generalized images require the built-in 'Administrator' account for first boot."
}
if ($LocalAdministratorCredential.Password.Length -lt 14) {
    throw 'The nested local Administrator password must be at least 14 characters long.'
}

$configuration = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $ConfigurationPath)
if ($configuration.SchemaVersion -ne 2) {
    throw "Unsupported configuration schema '$($configuration.SchemaVersion)'."
}

$results = foreach ($virtualMachineConfiguration in @($configuration.VMs)) {
    $virtualMachine = Get-VM -Name $virtualMachineConfiguration.Name -ErrorAction Stop
    if ($virtualMachine.State -ne 'Off') {
        throw "VM '$($virtualMachine.Name)' must be off before its OS disk can be specialized."
    }

    $operatingSystemDisk = Get-VMHardDiskDrive -VM $virtualMachine |
        Sort-Object ControllerNumber, ControllerLocation |
        Select-Object -First 1
    if (-not $operatingSystemDisk) {
        throw "VM '$($virtualMachine.Name)' has no operating system disk."
    }

    foreach ($featureName in @($virtualMachineConfiguration.OfflineFeatures)) {
        $feature = Get-WindowsFeature -Vhd $operatingSystemDisk.Path -Name $featureName
        if ($feature.InstallState -ne 'Installed') {
            Install-WindowsFeature `
                -Vhd $operatingSystemDisk.Path `
                -Name $featureName `
                -IncludeAllSubFeature `
                -IncludeManagementTools | Out-Null
        }
    }

    $unattendDocument = ConvertTo-UnattendDocument `
        -ComputerName $virtualMachineConfiguration.Name `
        -AdministratorPassword $LocalAdministratorCredential.Password
    Write-GuestUnattendFile `
        -VirtualHardDiskPath $operatingSystemDisk.Path `
        -UnattendContent $unattendDocument

    [pscustomobject]@{
        Name     = $virtualMachine.Name
        Features = @($virtualMachineConfiguration.OfflineFeatures)
        Result   = 'Specialized'
    }
}

$managementVm = Get-VM -Name 'AzLMGMT' -ErrorAction Stop
$managementOsDisk = Get-VMHardDiskDrive -VM $managementVm |
    Sort-Object ControllerNumber, ControllerLocation |
    Select-Object -First 1
$managementDataDisk = Get-VMHardDiskDrive -VM $managementVm |
    Where-Object Path -ne $managementOsDisk.Path |
    Select-Object -First 1
if (-not $managementDataDisk) {
    throw 'AzLMGMT data disk was not found.'
}

$managementParentImage = Initialize-ManagementImageStore `
    -VirtualHardDiskPath $managementDataDisk.Path `
    -SourceImagePath 'V:\VHDs\WindowsServer2025.vhdx'

$stateFile = 'C:\AzureLocalSandbox\State\guest-disks.json'
[ordered]@{
    phase                 = 'GuestDisksSpecialized'
    updatedAt             = (Get-Date).ToUniversalTime().ToString('o')
    machines              = @($results)
    managementParentImage = $managementParentImage
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding UTF8

$results | Format-Table -AutoSize