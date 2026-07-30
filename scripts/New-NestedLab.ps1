#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

[CmdletBinding()]
param(
    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..\config\lab.psd1'),

    [switch]$Start
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Information "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Message" -InformationAction Continue
}

function Get-DeterministicMacAddress {
    param(
        [Parameter(Mandatory)]
        [string]$VirtualMachineName,

        [Parameter(Mandatory)]
        [string]$AdapterName
    )

    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $inputBytes = [System.Text.Encoding]::UTF8.GetBytes("$VirtualMachineName/$AdapterName")
        $hash = $sha256.ComputeHash($inputBytes)
    }
    finally {
        $sha256.Dispose()
    }

    $macBytes = [byte[]]$hash[0..5]
    $macBytes[0] = ($macBytes[0] -band 0xFE) -bor 0x02
    return ($macBytes | ForEach-Object { $_.ToString('X2') }) -join ''
}

function Assert-LabConfiguration {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Configuration
    )

    if ($Configuration.SchemaVersion -ne 2) {
        throw "Unsupported configuration schema '$($Configuration.SchemaVersion)'."
    }

    if (-not $Configuration.VmRoot -or -not $Configuration.StateFile) {
        throw 'VmRoot and StateFile are required.'
    }

    $virtualMachines = @($Configuration.VMs)
    if ($virtualMachines.Count -ne 3) {
        throw "The initial topology requires AzLMGMT and two Azure Local nodes; found $($virtualMachines.Count) VM definitions."
    }

    $duplicateNames = $virtualMachines.Name |
        Group-Object |
        Where-Object { $_.Count -gt 1 }
    if ($duplicateNames) {
        throw "Duplicate VM names: $($duplicateNames.Name -join ', ')."
    }

    foreach ($virtualMachine in $virtualMachines) {
        if (-not $virtualMachine.Name -or -not $virtualMachine.ParentVhdPath) {
            throw 'Each VM requires Name and ParentVhdPath values.'
        }

        if ($virtualMachine.MemoryStartupBytes -lt 4GB -or $virtualMachine.ProcessorCount -lt 2) {
            throw "VM '$($virtualMachine.Name)' has insufficient CPU or memory."
        }

        $networkAdapters = @($virtualMachine.NetworkAdapters)
        if ($networkAdapters.Count -eq 0) {
            throw "VM '$($virtualMachine.Name)' requires at least one network adapter."
        }

        $duplicateAdapterNames = $networkAdapters.Name |
            Group-Object |
            Where-Object { $_.Count -gt 1 }
        if ($duplicateAdapterNames) {
            throw "VM '$($virtualMachine.Name)' has duplicate adapter names: $($duplicateAdapterNames.Name -join ', ')."
        }

        foreach ($networkAdapter in $networkAdapters) {
            if (-not $networkAdapter.Name -or -not $networkAdapter.SwitchName) {
                throw "Every adapter on VM '$($virtualMachine.Name)' requires Name and SwitchName values."
            }

            if ($networkAdapter.VlanMode -notin @('Access', 'Trunk', 'Untagged')) {
                throw "Adapter '$($networkAdapter.Name)' on VM '$($virtualMachine.Name)' has unsupported VLAN mode '$($networkAdapter.VlanMode)'."
            }
        }
    }
}

function Assert-HostCapacity {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Configuration
    )

    $requiredMemory = (@($Configuration.VMs) | Measure-Object -Property MemoryStartupBytes -Sum).Sum
    $hostMemory = (Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
    $hostReserve = 16GB

    if ($requiredMemory -gt ($hostMemory - $hostReserve)) {
        throw "The topology requires $([math]::Ceiling($requiredMemory / 1GB)) GiB, leaving less than 16 GiB for the host."
    }
}

function Assert-LabPrerequisite {
    param(
        [Parameter(Mandatory)]
        [hashtable]$Configuration
    )

    $hostStatePath = 'C:\AzureLocalSandbox\State\bootstrap.json'
    if (-not (Test-Path -LiteralPath $hostStatePath)) {
        throw "Host state '$hostStatePath' was not found. Run Bootstrap.ps1 first."
    }

    $hostState = Get-Content -LiteralPath $hostStatePath -Raw | ConvertFrom-Json
    if ($hostState.phase -ne 'HostReady') {
        throw "The host is not ready. Current bootstrap phase: '$($hostState.phase)'."
    }

    $requiredSwitches = @($Configuration.VMs.NetworkAdapters.SwitchName | Sort-Object -Unique)
    foreach ($switchName in $requiredSwitches) {
        if (-not (Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue)) {
            throw "Required Hyper-V switch '$switchName' does not exist."
        }
    }

    foreach ($parentVhdPath in @($Configuration.VMs.ParentVhdPath | Sort-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $parentVhdPath)) {
            throw "Parent image '$parentVhdPath' does not exist. Place a generalized, authorized VHDX at that path."
        }
    }
}

function Initialize-LabNetworkAdapter {
    param(
        [Parameter(Mandatory)]
        [string]$VirtualMachineName,

        [Parameter(Mandatory)]
        [hashtable]$AdapterConfiguration,

        [switch]$UseExistingPrimaryAdapter
    )

    $networkAdapter = Get-VMNetworkAdapter `
        -VMName $VirtualMachineName `
        -Name $AdapterConfiguration.Name `
        -ErrorAction SilentlyContinue

    if (-not $networkAdapter -and $UseExistingPrimaryAdapter) {
        $candidateAdapters = @(Get-VMNetworkAdapter -VMName $VirtualMachineName)
        $networkAdapter = $candidateAdapters |
            Where-Object { $_.Name -eq 'Network Adapter' } |
            Select-Object -First 1

        if (-not $networkAdapter -and $candidateAdapters.Count -eq 1) {
            $networkAdapter = $candidateAdapters[0]
        }

        if ($networkAdapter) {
            $networkAdapter | Rename-VMNetworkAdapter -NewName $AdapterConfiguration.Name
            $networkAdapter = Get-VMNetworkAdapter -VMName $VirtualMachineName -Name $AdapterConfiguration.Name
        }
    }

    if (-not $networkAdapter) {
        Add-VMNetworkAdapter `
            -VMName $VirtualMachineName `
            -Name $AdapterConfiguration.Name `
            -SwitchName $AdapterConfiguration.SwitchName `
            -DeviceNaming On
        $networkAdapter = Get-VMNetworkAdapter -VMName $VirtualMachineName -Name $AdapterConfiguration.Name
    }

    if ($networkAdapter.SwitchName -ne $AdapterConfiguration.SwitchName) {
        $networkAdapter | Connect-VMNetworkAdapter -SwitchName $AdapterConfiguration.SwitchName
    }

    $macAddress = Get-DeterministicMacAddress `
        -VirtualMachineName $VirtualMachineName `
        -AdapterName $AdapterConfiguration.Name

    $networkAdapter | Set-VMNetworkAdapter `
        -DeviceNaming On `
        -StaticMacAddress $macAddress `
        -MacAddressSpoofing On `
        -AllowTeaming On

    switch ($AdapterConfiguration.VlanMode) {
        'Access' {
            $networkAdapter | Set-VMNetworkAdapterVlan -Access -VlanId $AdapterConfiguration.VlanId
        }
        'Trunk' {
            $networkAdapter | Set-VMNetworkAdapterVlan `
                -Trunk `
                -NativeVlanId $AdapterConfiguration.NativeVlanId `
                -AllowedVlanIdList $AdapterConfiguration.AllowedVlanIdList
        }
        'Untagged' {
            $networkAdapter | Set-VMNetworkAdapterVlan -Untagged
        }
    }
}

function Add-LabDataDisk {
    param(
        [Parameter(Mandatory)]
        [string]$VirtualMachineName,

        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [long]$SizeBytes
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-VHD -Path $Path -SizeBytes $SizeBytes -Dynamic | Out-Null
    }

    $attachedPaths = @(Get-VMHardDiskDrive -VMName $VirtualMachineName | Select-Object -ExpandProperty Path)
    if ($Path -notin $attachedPaths) {
        Add-VMHardDiskDrive -VMName $VirtualMachineName -Path $Path
    }
}

function Initialize-LabVirtualMachine {
    param(
        [Parameter(Mandatory)]
        [hashtable]$VirtualMachineConfiguration,

        [Parameter(Mandatory)]
        [string]$VmRoot
    )

    $virtualMachineName = $VirtualMachineConfiguration.Name
    Write-Step "Preparing VM $virtualMachineName ($($VirtualMachineConfiguration.Role))..."
    $virtualMachinePath = Join-Path $VmRoot $virtualMachineName
    $operatingSystemDiskPath = Join-Path $virtualMachinePath "$virtualMachineName-OS.vhdx"
    New-Item -Path $virtualMachinePath -ItemType Directory -Force | Out-Null

    $virtualMachine = Get-VM -Name $virtualMachineName -ErrorAction SilentlyContinue
    if ($virtualMachine -and $virtualMachine.State -ne 'Off') {
        return [pscustomobject]@{
            Name   = $virtualMachineName
            Role   = $VirtualMachineConfiguration.Role
            Result = 'AlreadyRunning'
        }
    }

    if (-not (Test-Path -LiteralPath $operatingSystemDiskPath)) {
        New-VHD `
            -Path $operatingSystemDiskPath `
            -ParentPath $VirtualMachineConfiguration.ParentVhdPath `
            -Differencing | Out-Null
    }

    $isNewVirtualMachine = -not $virtualMachine
    if ($isNewVirtualMachine) {
        $primaryAdapter = @($VirtualMachineConfiguration.NetworkAdapters)[0]
        $virtualMachine = New-VM `
            -Name $virtualMachineName `
            -Path $virtualMachinePath `
            -Generation 2 `
            -MemoryStartupBytes $VirtualMachineConfiguration.MemoryStartupBytes `
            -VHDPath $operatingSystemDiskPath `
            -SwitchName $primaryAdapter.SwitchName
    }

    Set-VM `
        -VM $virtualMachine `
        -AutomaticStartAction Start `
        -AutomaticStartDelay $VirtualMachineConfiguration.AutomaticStartDelay `
        -AutomaticStopAction ShutDown `
        -CheckpointType Disabled `
        -MemoryStartupBytes $VirtualMachineConfiguration.MemoryStartupBytes

    Set-VMFirmware `
        -VMName $virtualMachineName `
        -EnableSecureBoot On `
        -SecureBootTemplate 'MicrosoftWindows'
    Set-VMMemory -VMName $virtualMachineName -DynamicMemoryEnabled $false
    Set-VMProcessor `
        -VMName $virtualMachineName `
        -Count $VirtualMachineConfiguration.ProcessorCount `
        -ExposeVirtualizationExtensions $VirtualMachineConfiguration.NestedVirtualization

    if ($VirtualMachineConfiguration.Role -eq 'AzureLocalNode') {
        $guardianName = 'AzureLocalSandboxGuardian'
        $guardian = Get-HgsGuardian -Name $guardianName -ErrorAction SilentlyContinue
        if (-not $guardian) {
            $guardian = New-HgsGuardian -Name $guardianName -GenerateCertificates
        }

        $virtualMachineSecurity = Get-VMSecurity -VMName $virtualMachineName
        if (-not $virtualMachineSecurity.TpmEnabled) {
            $keyProtector = New-HgsKeyProtector -Owner $guardian -AllowUntrustedRoot
            Set-VMKeyProtector -VMName $virtualMachineName -KeyProtector $keyProtector.RawData
            Enable-VMTPM -VMName $virtualMachineName
        }

        Get-VMIntegrationService -VMName $virtualMachineName |
            Where-Object Name -eq 'Time Synchronization' |
            Disable-VMIntegrationService
    }

    $dataDiskIndex = 1
    foreach ($dataDiskSize in @($VirtualMachineConfiguration.DataDisks)) {
        $dataDiskPath = Join-Path $virtualMachinePath ("$virtualMachineName-Data-{0}.vhdx" -f $dataDiskIndex)
        Add-LabDataDisk `
            -VirtualMachineName $virtualMachineName `
            -Path $dataDiskPath `
            -SizeBytes $dataDiskSize
        $dataDiskIndex++
    }

    $storageDiskIndex = 1
    foreach ($storageDiskSize in @($VirtualMachineConfiguration.StorageDisks)) {
        $storageDiskPath = Join-Path $virtualMachinePath ("$virtualMachineName-S2D-{0}.vhdx" -f $storageDiskIndex)
        Add-LabDataDisk `
            -VirtualMachineName $virtualMachineName `
            -Path $storageDiskPath `
            -SizeBytes $storageDiskSize
        $storageDiskIndex++
    }

    $adapterIndex = 0
    foreach ($networkAdapter in @($VirtualMachineConfiguration.NetworkAdapters)) {
        Initialize-LabNetworkAdapter `
            -VirtualMachineName $virtualMachineName `
            -AdapterConfiguration $networkAdapter `
            -UseExistingPrimaryAdapter:($adapterIndex -eq 0)
        $adapterIndex++
    }

    Enable-VMIntegrationService `
        -VMName $virtualMachineName `
        -Name 'Guest Service Interface' `
        -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        Name   = $virtualMachineName
        Role   = $VirtualMachineConfiguration.Role
        Result = if ($isNewVirtualMachine) { 'Created' } else { 'Converged' }
    }
}

$configuration = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $ConfigurationPath)
Assert-LabConfiguration -Configuration $configuration
Assert-LabPrerequisite -Configuration $configuration
Assert-HostCapacity -Configuration $configuration

New-Item -Path $configuration.VmRoot -ItemType Directory -Force | Out-Null

$results = foreach ($virtualMachineConfiguration in @($configuration.VMs)) {
    Initialize-LabVirtualMachine `
        -VirtualMachineConfiguration $virtualMachineConfiguration `
        -VmRoot $configuration.VmRoot
}

if ($Start) {
    foreach ($virtualMachineConfiguration in @($configuration.VMs)) {
        $virtualMachine = Get-VM -Name $virtualMachineConfiguration.Name
        if ($virtualMachine.State -eq 'Off') {
            Write-Step "Starting $($virtualMachine.Name)..."
            Start-VM -VM $virtualMachine
        }
    }
}

$stateDirectory = Split-Path -Parent $configuration.StateFile
New-Item -Path $stateDirectory -ItemType Directory -Force | Out-Null
[ordered]@{
    phase     = if ($Start) { 'NestedVMsStarted' } else { 'NestedVMsCreated' }
    updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    machines  = @($results)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $configuration.StateFile -Encoding UTF8

$results | Format-Table -AutoSize