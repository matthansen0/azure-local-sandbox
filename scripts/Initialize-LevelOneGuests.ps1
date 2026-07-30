#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [PSCredential]$LocalAdministratorCredential,

    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..\config\lab.psd1'),

    [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}$')]
    [string]$PublicDnsServer = '8.8.8.8',

    [ValidateRange(5, 90)]
    [int]$GuestReadyTimeoutMinutes = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Information "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Message" -InformationAction Continue
}

function Wait-PowerShellDirect {
    param(
        [Parameter(Mandatory)]
        [string]$VirtualMachineName,

        [Parameter(Mandatory)]
        [PSCredential]$Credential,

        [Parameter(Mandatory)]
        [int]$TimeoutMinutes
    )

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    do {
        try {
            $computerName = Invoke-Command `
                -VMName $VirtualMachineName `
                -Credential $Credential `
                -ScriptBlock { $env:COMPUTERNAME } `
                -ErrorAction Stop
            if ($computerName -eq $VirtualMachineName) {
                return
            }
        }
        catch {
            Start-Sleep -Seconds 10
        }
    } while ((Get-Date) -lt $deadline)

    throw "PowerShell Direct did not become ready on '$VirtualMachineName' within $TimeoutMinutes minutes."
}

if ($LocalAdministratorCredential.UserName -ne 'Administrator') {
    throw "Use the built-in 'Administrator' credential created during guest disk specialization."
}
if ($LocalAdministratorCredential.Password.Length -lt 14) {
    throw 'The nested local Administrator password must be at least 14 characters long.'
}

$configuration = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $ConfigurationPath)
if ($configuration.SchemaVersion -ne 2) {
    throw "Unsupported configuration schema '$($configuration.SchemaVersion)'."
}

foreach ($virtualMachineConfiguration in @($configuration.VMs)) {
    $virtualMachine = Get-VM -Name $virtualMachineConfiguration.Name -ErrorAction Stop
    if ($virtualMachine.State -eq 'Off') {
        Write-Step "Starting $($virtualMachine.Name)..."
        Start-VM -VM $virtualMachine
    }

    Write-Step "Waiting for PowerShell Direct on $($virtualMachine.Name). First boot specialization can take up to $GuestReadyTimeoutMinutes minutes..."
    Wait-PowerShellDirect `
        -VirtualMachineName $virtualMachine.Name `
        -Credential $LocalAdministratorCredential `
        -TimeoutMinutes $GuestReadyTimeoutMinutes
    Write-Step "$($virtualMachine.Name) is responding to PowerShell Direct."
}

$results = foreach ($virtualMachineConfiguration in @($configuration.VMs)) {
    Write-Step "Configuring networking inside $($virtualMachineConfiguration.Name)..."
    Invoke-Command `
        -VMName $virtualMachineConfiguration.Name `
        -Credential $LocalAdministratorCredential `
        -ArgumentList $virtualMachineConfiguration, $configuration, $PublicDnsServer `
        -ScriptBlock {
            param($VirtualMachineConfiguration, $Configuration, $PublicDnsServer)

            Set-StrictMode -Version Latest
            $ErrorActionPreference = 'Stop'

            function Get-NamedAdapter {
                param([string]$HyperVName)

                $adapter = Get-NetAdapter -Name $HyperVName -ErrorAction SilentlyContinue
                if ($adapter) {
                    return $adapter
                }

                $advancedProperties = @(
                    Get-NetAdapterAdvancedProperty `
                    -RegistryKeyword 'HyperVNetworkAdapterName' `
                    -ErrorAction SilentlyContinue |
                    Where-Object { $_.RegistryValue -eq $HyperVName }
                )
                if ($advancedProperties.Count -eq 0) {
                    throw "Hyper-V adapter '$HyperVName' was not found on '$env:COMPUTERNAME'."
                }
                if ($advancedProperties.Count -gt 1) {
                    throw "Hyper-V adapter name '$HyperVName' matched multiple guest adapters on '$env:COMPUTERNAME'."
                }

                Rename-NetAdapter -Name $advancedProperties[0].Name -NewName $HyperVName -Confirm:$false
                return Get-NetAdapter -Name $HyperVName
            }

            function Initialize-StaticAddress {
                param(
                    [string]$InterfaceAlias,
                    [string]$IpAddress,
                    [int]$PrefixLength,
                    [string]$DefaultGateway,
                    [string[]]$DnsServers
                )

                $adapter = Get-NetAdapter -Name $InterfaceAlias
                Set-NetIPInterface `
                    -InterfaceIndex $adapter.ifIndex `
                    -AddressFamily IPv4 `
                    -Dhcp Disabled `
                    -ErrorAction SilentlyContinue

                $matchingAddress = Get-NetIPAddress `
                    -InterfaceIndex $adapter.ifIndex `
                    -AddressFamily IPv4 `
                    -ErrorAction SilentlyContinue |
                    Where-Object IPAddress -eq $IpAddress
                if (-not $matchingAddress) {
                    Get-NetIPAddress `
                        -InterfaceIndex $adapter.ifIndex `
                        -AddressFamily IPv4 `
                        -ErrorAction SilentlyContinue |
                        Where-Object PrefixOrigin -ne 'WellKnown' |
                        Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

                    $addressParameters = @{
                        InterfaceIndex = $adapter.ifIndex
                        IPAddress      = $IpAddress
                        PrefixLength   = $PrefixLength
                    }
                    if ($DefaultGateway) {
                        $addressParameters.DefaultGateway = $DefaultGateway
                    }
                    New-NetIPAddress @addressParameters | Out-Null
                }

                if ($DnsServers) {
                    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DnsServers
                }
            }

            Enable-PSRemoting -Force -SkipNetworkProfileCheck
            Set-Item WSMan:\localhost\Client\TrustedHosts -Value '*' -Force
            Get-NetConnectionProfile -ErrorAction SilentlyContinue |
                Set-NetConnectionProfile -NetworkCategory Private -ErrorAction SilentlyContinue

            foreach ($adapterConfiguration in @($VirtualMachineConfiguration.NetworkAdapters)) {
                $null = Get-NamedAdapter -HyperVName $adapterConfiguration.Name
            }

            if ($VirtualMachineConfiguration.Role -eq 'Management') {
                $fabricAdapter = Get-NamedAdapter -HyperVName $VirtualMachineConfiguration.ManagementAdapterName
                if ($fabricAdapter.Name -ne 'FABRIC') {
                    Rename-NetAdapter -Name $fabricAdapter.Name -NewName 'FABRIC' -Confirm:$false
                }

                if (-not (Get-VMSwitch -Name 'vSwitch-Fabric' -ErrorAction SilentlyContinue)) {
                    New-VMSwitch `
                        -Name 'vSwitch-Fabric' `
                        -NetAdapterName 'FABRIC' `
                        -AllowManagementOS $true `
                        -MinimumBandwidthMode None | Out-Null
                }

                Initialize-StaticAddress `
                    -InterfaceAlias 'vEthernet (vSwitch-Fabric)' `
                    -IpAddress $VirtualMachineConfiguration.ManagementIpAddress `
                    -PrefixLength $Configuration.Networks.Management.PrefixLength `
                    -DnsServers @($PublicDnsServer)

                Initialize-StaticAddress `
                    -InterfaceAlias 'NAT' `
                    -IpAddress '192.168.128.5' `
                    -PrefixLength $Configuration.Networks.HostNat.PrefixLength `
                    -DefaultGateway $Configuration.Networks.HostNat.Gateway `
                    -DnsServers @($PublicDnsServer)

                $sidebandAddresses = @(
                    @{ Name = 'PROVIDER'; Address = '172.16.0.254'; Network = $Configuration.Networks.Provider }
                    @{ Name = 'VLAN110'; Address = '10.10.0.250'; Network = $Configuration.Networks.Vlan110 }
                    @{ Name = 'VLAN200'; Address = '192.168.200.250'; Network = $Configuration.Networks.Vlan200 }
                    @{ Name = 'simInternet'; Address = '131.127.0.254'; Network = $Configuration.Networks.SimulatedInternet }
                )
                foreach ($sidebandAddress in $sidebandAddresses) {
                    Initialize-StaticAddress `
                        -InterfaceAlias $sidebandAddress.Name `
                        -IpAddress $sidebandAddress.Address `
                        -PrefixLength $sidebandAddress.Network.PrefixLength
                }

                Disable-NetAdapter -Name 'SDN2' -Confirm:$false -ErrorAction SilentlyContinue

                if (-not (Get-VMSwitch -Name 'NAT' -ErrorAction SilentlyContinue)) {
                    New-VMSwitch -Name 'NAT' -SwitchType Internal -MinimumBandwidthMode None | Out-Null
                }
                Initialize-StaticAddress `
                    -InterfaceAlias 'vEthernet (NAT)' `
                    -IpAddress $Configuration.Networks.InnerNat.Gateway `
                    -PrefixLength $Configuration.Networks.InnerNat.PrefixLength

                $innerNat = Get-NetNat -Name 'InnerManagementNAT' -ErrorAction SilentlyContinue
                if (-not $innerNat) {
                    New-NetNat `
                        -Name 'InnerManagementNAT' `
                        -InternalIPInterfaceAddressPrefix $Configuration.Networks.InnerNat.Prefix | Out-Null
                }

                $diskDeadline = (Get-Date).AddMinutes(5)
                do {
                    Update-HostStorageCache
                    $dataDisk = Get-Disk |
                        Where-Object { -not $_.IsBoot -and -not $_.IsSystem } |
                        Select-Object -First 1
                    if (-not $dataDisk) {
                        Start-Sleep -Seconds 5
                    }
                } while (-not $dataDisk -and (Get-Date) -lt $diskDeadline)
                if (-not $dataDisk) {
                    throw 'AzLMGMT data disk was not detected within five minutes.'
                }
                if ($dataDisk.IsOffline) {
                    Set-Disk -Number $dataDisk.Number -IsOffline $false
                }
                if ($dataDisk.IsReadOnly) {
                    Set-Disk -Number $dataDisk.Number -IsReadOnly $false
                }
                if ($dataDisk.PartitionStyle -eq 'RAW') {
                    $dataDisk = Initialize-Disk -Number $dataDisk.Number -PartitionStyle GPT -PassThru
                }
                $dataPartition = Get-Partition -DiskNumber $dataDisk.Number -ErrorAction SilentlyContinue |
                    Where-Object Type -ne 'Reserved' |
                    Select-Object -First 1
                if (-not $dataPartition) {
                    $dataPartition = New-Partition -DiskNumber $dataDisk.Number -UseMaximumSize -DriveLetter D
                }
                elseif (-not $dataPartition.DriveLetter) {
                    $dataPartition = $dataPartition | Set-Partition -NewDriveLetter D -PassThru
                }
                $dataVolume = $dataPartition | Get-Volume -ErrorAction SilentlyContinue
                if (-not $dataVolume.FileSystem) {
                    $dataPartition | Format-Volume `
                        -FileSystem NTFS `
                        -AllocationUnitSize 65536 `
                        -NewFileSystemLabel 'ManagementVMs' `
                        -Confirm:$false | Out-Null
                }

                New-Item -Path 'D:\VMs', 'D:\VMs\Base' -ItemType Directory -Force | Out-Null
                Set-VMHost -VirtualMachinePath 'D:\VMs' -VirtualHardDiskPath 'D:\VMs'
            }
            else {
                $managementAdapter = Get-NamedAdapter -HyperVName $VirtualMachineConfiguration.ManagementAdapterName
                if ($managementAdapter.Name -ne 'FABRIC') {
                    Rename-NetAdapter -Name $managementAdapter.Name -NewName 'FABRIC' -Confirm:$false
                }

                Initialize-StaticAddress `
                    -InterfaceAlias 'FABRIC' `
                    -IpAddress $VirtualMachineConfiguration.ManagementIpAddress `
                    -PrefixLength $Configuration.Networks.Management.PrefixLength `
                    -DefaultGateway $Configuration.Networks.Management.Gateway `
                    -DnsServers @($PublicDnsServer)
            }

            [pscustomobject]@{
                Name   = $env:COMPUTERNAME
                Role   = $VirtualMachineConfiguration.Role
                Result = 'Configured'
            }
        }
}

$guestDiskState = Get-Content `
    -LiteralPath 'C:\AzureLocalSandbox\State\guest-disks.json' `
    -Raw | ConvertFrom-Json
$expectedParentImageHash = $guestDiskState.managementParentImage.Sha256
Write-Step 'Verifying the nested parent image inside AzLMGMT. Hashing takes several minutes...'
$actualParentImageHash = Invoke-Command `
    -VMName 'AzLMGMT' `
    -Credential $LocalAdministratorCredential `
    -ScriptBlock {
        $path = 'D:\VMs\Base\WindowsServer2025.vhdx'
        if (-not (Test-Path -LiteralPath $path)) {
            throw "Nested parent image '$path' was not found."
        }
        (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
    }
if ($actualParentImageHash -ne $expectedParentImageHash) {
    throw 'The Windows Server parent image in AzLMGMT does not match the offline verified copy.'
}
$copyResult = 'VerifiedAfterBoot'

$stateFile = 'C:\AzureLocalSandbox\State\level-one-guests.json'
[ordered]@{
    phase           = 'LevelOneGuestsReady'
    updatedAt       = (Get-Date).ToUniversalTime().ToString('o')
    parentImageCopy = $copyResult
    machines        = @($results)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding UTF8

$results | Format-Table -AutoSize