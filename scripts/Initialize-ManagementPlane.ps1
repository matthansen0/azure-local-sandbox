#Requires -Version 5.1
#Requires -RunAsAdministrator
#Requires -Modules Hyper-V

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseUsingScopeModifierInNewRunspaces',
    '',
    Justification = 'Nested PowerShell Direct script blocks receive serialized values through ArgumentList and declare them in local param blocks.'
)]
param(
    [Parameter(Mandatory)]
    [PSCredential]$LocalAdministratorCredential,

    [Parameter(Mandatory)]
    [PSCredential]$DomainAdministratorCredential,

    [Parameter(Mandatory)]
    [PSCredential]$LcmCredential,

    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..\config\lab.psd1'),

    [string]$DependenciesPath = (Join-Path $PSScriptRoot '..\config\dependencies.psd1'),

    [ValidatePattern('^(?:\d{1,3}\.){3}\d{1,3}$')]
    [string]$DnsForwarder = '8.8.8.8',

    [ValidateRange(10, 90)]
    [int]$GuestReadyTimeoutMinutes = 45
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

function ConvertTo-UnattendPassword {
    param([Parameter(Mandatory)][SecureString]$Password)

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
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][SecureString]$AdministratorPassword
    )

    $encodedPassword = ConvertTo-UnattendPassword -Password $AdministratorPassword
    $escapedComputerName = [Security.SecurityElement]::Escape($HostName)

    return @"
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend">
  <settings pass="specialize">
    <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
      <ComputerName>$escapedComputerName</ComputerName>
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
  </settings>
</unattend>
"@
}

function Wait-NestedPowerShellDirect {
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$ManagementSession,

        [Parameter(Mandatory)]
        [string]$VirtualMachineName,

        [Parameter(Mandatory)]
        [PSCredential[]]$Credential,

        [Parameter(Mandatory)]
        [int]$TimeoutMinutes
    )

    Write-Step "Waiting for PowerShell Direct on nested VM $VirtualMachineName (timeout $TimeoutMinutes minutes)..."
    $acceptedIndex = Invoke-Command `
        -Session $ManagementSession `
        -ArgumentList $VirtualMachineName, $Credential, $TimeoutMinutes `
        -ScriptBlock {
            param(
                [string]$VirtualMachineName,
                [PSCredential[]]$Credential,
                [int]$TimeoutMinutes
            )

            $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
            do {
                for ($index = 0; $index -lt $Credential.Count; $index++) {
                    try {
                        $computerName = Invoke-Command `
                            -VMName $VirtualMachineName `
                            -Credential $Credential[$index] `
                            -ScriptBlock { $env:COMPUTERNAME } `
                            -ErrorAction Stop
                        if ($computerName -eq $VirtualMachineName) {
                            return $index
                        }
                    }
                    catch {
                    }
                }

                Start-Sleep -Seconds 10
            } while ((Get-Date) -lt $deadline)

            return -1
        }

    if ($acceptedIndex -lt 0) {
        throw "PowerShell Direct did not become ready on nested VM '$VirtualMachineName' within $TimeoutMinutes minutes."
    }

    return $Credential[$acceptedIndex]
}

function ConvertTo-DomainDistinguishedName {
    param([Parameter(Mandatory)][string]$DomainFqdn)

    return ($DomainFqdn.Split('.') | ForEach-Object { "DC=$_" }) -join ','
}

$configuration = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $ConfigurationPath)
$dependencies = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $DependenciesPath)
if ($configuration.SchemaVersion -ne 2) {
    throw "Unsupported configuration schema '$($configuration.SchemaVersion)'."
}

if ($LocalAdministratorCredential.UserName -ne 'Administrator') {
    throw "LocalAdministratorCredential must use the built-in 'Administrator' account."
}
if ($LocalAdministratorCredential.Password.Length -lt 14) {
    throw 'The nested local Administrator password must be at least 14 characters long.'
}

$expectedDomainAdministratorNames = @(
    'Administrator'
    "$($configuration.Domain.NetBiosName)\Administrator"
    "Administrator@$($configuration.Domain.Fqdn)"
)
if ($DomainAdministratorCredential.UserName -notin $expectedDomainAdministratorNames) {
    throw "DomainAdministratorCredential must identify Administrator in '$($configuration.Domain.Fqdn)'."
}

if ($LcmCredential.UserName -ne $configuration.Domain.DeploymentUserName) {
    throw "LcmCredential username must be '$($configuration.Domain.DeploymentUserName)'."
}
if ($LcmCredential.UserName -match '(?i)admin' -or
    $LcmCredential.UserName -notmatch '^[A-Za-z_][A-Za-z0-9_-]{0,19}$') {
    throw 'The LCM username must be 1-20 valid characters, cannot start with a number or hyphen, and cannot contain admin.'
}
if ($DomainAdministratorCredential.Password.Length -lt 14) {
    throw 'The domain Administrator password must be at least 14 characters long.'
}
if ($LcmCredential.Password.Length -lt 14) {
    throw 'The LCM deployment password must be at least 14 characters long.'
}

Write-Step 'Connecting to AzLMGMT over PowerShell Direct...'
$managementSession = New-PSSession `
    -VMName 'AzLMGMT' `
    -Credential $LocalAdministratorCredential
try {
    Write-Step 'Creating the nested router and domain controller VMs inside AzLMGMT...'
    $dcUnattend = ConvertTo-UnattendDocument `
        -HostName $configuration.Domain.DomainControllerName `
        -AdministratorPassword $DomainAdministratorCredential.Password
    $routerUnattend = ConvertTo-UnattendDocument `
        -HostName 'Vm-Router' `
        -AdministratorPassword $LocalAdministratorCredential.Password

    $domainControllerLocalCredential = [PSCredential]::new(
        'Administrator',
        $DomainAdministratorCredential.Password
    )

    # Promotion replaces the local account with the domain one, so a resumed run has to
    # authenticate to the domain controller as JUMPSTART\Administrator instead.
    $domainCredential = [PSCredential]::new(
        "$($configuration.Domain.NetBiosName)\Administrator",
        $DomainAdministratorCredential.Password
    )

    $creationResults = Invoke-Command `
        -Session $managementSession `
        -ArgumentList $configuration, $dcUnattend, $routerUnattend `
        -ScriptBlock {
            param($Configuration, $DcUnattend, $RouterUnattend)

            Set-StrictMode -Version Latest
            $ErrorActionPreference = 'Stop'

            function Get-DeterministicMacAddress {
                param([string]$VirtualMachineName, [string]$AdapterName)

                $sha256 = [Security.Cryptography.SHA256]::Create()
                try {
                    $bytes = [Text.Encoding]::UTF8.GetBytes("$VirtualMachineName/$AdapterName")
                    $hash = $sha256.ComputeHash($bytes)
                }
                finally {
                    $sha256.Dispose()
                }

                $macBytes = [byte[]]$hash[0..5]
                $macBytes[0] = ($macBytes[0] -band 0xFE) -bor 0x02
                return ($macBytes | ForEach-Object { $_.ToString('X2') }) -join ''
            }

            function Write-UnattendFile {
                param([string]$VirtualHardDiskPath, [string]$Content)

                $mountedVhd = Mount-VHD -Path $VirtualHardDiskPath -Passthru
                try {
                    $disk = $mountedVhd | Get-Disk
                    $windowsPartition = $null
                    $temporaryDriveLetter = $null

                    foreach ($partition in @($disk | Get-Partition | Where-Object Type -ne 'Reserved')) {
                        $driveLetter = $partition.DriveLetter
                        if (-not $driveLetter) {
                            $usedLetters = @(Get-Volume | Where-Object DriveLetter | Select-Object -ExpandProperty DriveLetter)
                            $driveLetter = [string]([char[]](90..70) | Where-Object { $_ -notin $usedLetters } | Select-Object -First 1)
                            if (-not $driveLetter) {
                                throw 'No drive letter is available for nested guest specialization.'
                            }
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

                    $windowsDriveLetter = if ($windowsPartition.DriveLetter) {
                        $windowsPartition.DriveLetter
                    }
                    else {
                        $temporaryDriveLetter
                    }

                    $pantherPath = "${windowsDriveLetter}:\Windows\Panther"
                    New-Item -Path $pantherPath -ItemType Directory -Force | Out-Null
                    Set-Content -LiteralPath (Join-Path $pantherPath 'Unattend.xml') -Value $Content -Encoding UTF8

                    $setupScriptsPath = "${windowsDriveLetter}:\Windows\Setup\Scripts"
                    New-Item -Path $setupScriptsPath -ItemType Directory -Force | Out-Null
                    @'
@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "Enable-PSRemoting -Force; Set-NetFirewallRule -DisplayGroup 'Remote Desktop' -Enabled True -ErrorAction SilentlyContinue"
del /f /q C:\Windows\Panther\Unattend.xml 2>nul
del /f /q C:\Windows\Panther\Unattend\Unattend.xml 2>nul
del /f /q C:\Windows\System32\Sysprep\Unattend.xml 2>nul
exit /b 0
'@ | Set-Content -LiteralPath (Join-Path $setupScriptsPath 'SetupComplete.cmd') -Encoding Ascii

                    if ($temporaryDriveLetter) {
                        $windowsPartition | Remove-PartitionAccessPath -AccessPath "${temporaryDriveLetter}:\"
                    }
                }
                finally {
                    Dismount-VHD -Path $VirtualHardDiskPath -ErrorAction SilentlyContinue
                }
            }

            function Initialize-InnerVirtualMachine {
                param(
                    [string]$Name,
                    [long]$MemoryStartupBytes,
                    [int]$ProcessorCount,
                    [hashtable[]]$NetworkAdapters,
                    [string]$UnattendContent
                )

                $vmPath = "D:\VMs\$Name"
                $osDiskPath = Join-Path $vmPath "$Name-OS.vhdx"
                $parentDiskPath = 'D:\VMs\Base\WindowsServer2025.vhdx'
                New-Item -Path $vmPath -ItemType Directory -Force | Out-Null

                $virtualMachine = Get-VM -Name $Name -ErrorAction SilentlyContinue
                $created = -not $virtualMachine
                if (-not (Test-Path -LiteralPath $osDiskPath)) {
                    if (-not (Test-Path -LiteralPath $parentDiskPath)) {
                        throw "Parent disk '$parentDiskPath' was not found."
                    }
                    New-VHD -Path $osDiskPath -ParentPath $parentDiskPath -Differencing | Out-Null
                }

                if ($created) {
                    Write-UnattendFile -VirtualHardDiskPath $osDiskPath -Content $UnattendContent

                    # Dismount-VHD returns before the disk leaves the storage stack; New-VM fails if it is still attached.
                    $detachDeadline = (Get-Date).AddSeconds(120)
                    while ($true) {
                        $osDisk = Get-VHD -Path $osDiskPath -ErrorAction SilentlyContinue
                        if (-not $osDisk -or -not $osDisk.Attached) {
                            break
                        }
                        if ((Get-Date) -ge $detachDeadline) {
                            throw "'$osDiskPath' was still attached 120 seconds after specialization."
                        }
                        Start-Sleep -Seconds 3
                    }
                }

                if ($created) {
                    $virtualMachine = New-VM `
                        -Name $Name `
                        -Path $vmPath `
                        -Generation 2 `
                        -MemoryStartupBytes $MemoryStartupBytes `
                        -VHDPath $osDiskPath
                }

                if ($virtualMachine.State -eq 'Off') {
                    Set-VM `
                        -VM $virtualMachine `
                        -AutomaticStartAction Start `
                        -AutomaticStartDelay 0 `
                        -AutomaticStopAction ShutDown `
                        -MemoryStartupBytes $MemoryStartupBytes
                    Set-VMMemory `
                        -VMName $Name `
                        -DynamicMemoryEnabled $true `
                        -MinimumBytes 1GB `
                        -StartupBytes $MemoryStartupBytes `
                        -MaximumBytes $MemoryStartupBytes
                    Set-VMProcessor -VMName $Name -Count $ProcessorCount
                }

                $defaultAdapter = Get-VMNetworkAdapter -VMName $Name -Name 'Network Adapter' -ErrorAction SilentlyContinue
                if ($defaultAdapter) {
                    Remove-VMNetworkAdapter -VMNetworkAdapter $defaultAdapter
                }

                foreach ($adapterConfiguration in $NetworkAdapters) {
                    $adapter = Get-VMNetworkAdapter `
                        -VMName $Name `
                        -Name $adapterConfiguration.Name `
                        -ErrorAction SilentlyContinue
                    if (-not $adapter) {
                        Add-VMNetworkAdapter `
                            -VMName $Name `
                            -Name $adapterConfiguration.Name `
                            -SwitchName $adapterConfiguration.SwitchName `
                            -DeviceNaming On
                        $adapter = Get-VMNetworkAdapter -VMName $Name -Name $adapterConfiguration.Name
                    }

                    $adapter | Set-VMNetworkAdapter `
                        -DeviceNaming On `
                        -StaticMacAddress (Get-DeterministicMacAddress -VirtualMachineName $Name -AdapterName $adapterConfiguration.Name) `
                        -MacAddressSpoofing On

                    if ($adapterConfiguration.ContainsKey('VlanId')) {
                        $adapter | Set-VMNetworkAdapterVlan -Access -VlanId $adapterConfiguration.VlanId
                    }
                    else {
                        $adapter | Set-VMNetworkAdapterVlan -Untagged
                    }
                }

                Enable-VMIntegrationService -VMName $Name -Name 'Guest Service Interface' -ErrorAction SilentlyContinue

                return [pscustomobject]@{
                    Name   = $Name
                    Result = if ($created) { 'Created' } else { 'Converged' }
                }
            }

            $routerAdapters = @(
                @{ Name = 'Mgmt'; SwitchName = 'vSwitch-Fabric' }
                @{ Name = 'Provider'; SwitchName = 'vSwitch-Fabric'; VlanId = $Configuration.Networks.Provider.VlanId }
                @{ Name = 'VLAN110'; SwitchName = 'vSwitch-Fabric'; VlanId = $Configuration.Networks.Vlan110.VlanId }
                @{ Name = 'VLAN200'; SwitchName = 'vSwitch-Fabric'; VlanId = $Configuration.Networks.Vlan200.VlanId }
                @{ Name = 'SIMInternet'; SwitchName = 'vSwitch-Fabric'; VlanId = $Configuration.Networks.SimulatedInternet.VlanId }
                @{ Name = 'NAT'; SwitchName = 'NAT' }
            )
            $dcAdapters = @(
                @{ Name = 'Mgmt'; SwitchName = 'vSwitch-Fabric' }
            )

            @(
                Initialize-InnerVirtualMachine `
                    -Name 'Vm-Router' `
                    -MemoryStartupBytes 4GB `
                    -ProcessorCount 2 `
                    -NetworkAdapters $routerAdapters `
                    -UnattendContent $RouterUnattend
                Initialize-InnerVirtualMachine `
                    -Name $Configuration.Domain.DomainControllerName `
                    -MemoryStartupBytes 4GB `
                    -ProcessorCount 2 `
                    -NetworkAdapters $dcAdapters `
                    -UnattendContent $DcUnattend
            )
        }

    $domainControllerName = $configuration.Domain.DomainControllerName
    Write-Step 'Starting the nested router and domain controller...'
    Invoke-Command -Session $managementSession -ArgumentList $domainControllerName -ScriptBlock {
        param([string]$DomainControllerName)

        foreach ($name in @('Vm-Router', $DomainControllerName)) {
            $virtualMachine = Get-VM -Name $name
            if ($virtualMachine.State -eq 'Off') {
                Start-VM -VM $virtualMachine
            }
        }
    }

    $null = Wait-NestedPowerShellDirect `
        -ManagementSession $managementSession `
        -VirtualMachineName 'Vm-Router' `
        -Credential $LocalAdministratorCredential `
        -TimeoutMinutes $GuestReadyTimeoutMinutes

    Write-Step 'Installing routing features on Vm-Router...'
    $routerFeatureResult = Invoke-Command `
        -Session $managementSession `
        -ArgumentList $LocalAdministratorCredential `
        -ScriptBlock {
            param([PSCredential]$Credential)

            Invoke-Command `
                -VMName 'Vm-Router' `
                -Credential $Credential `
                -ScriptBlock {
                    $featureResult = Install-WindowsFeature `
                        -Name RemoteAccess, Routing `
                        -IncludeManagementTools

                    foreach ($featureName in @('RemoteAccess', 'Routing')) {
                        if ((Get-WindowsFeature -Name $featureName).InstallState -ne 'Installed') {
                            throw "Windows feature '$featureName' did not install successfully."
                        }
                    }

                    $restartNeeded =
                        [string]$featureResult.RestartNeeded -eq 'Yes' -or
                        -not (Get-Command -Name Install-RemoteAccess -ErrorAction SilentlyContinue)

                    [pscustomobject]@{
                        RestartNeeded = if ($restartNeeded) { 'Yes' } else { 'No' }
                    }
                }
        }

    if ($routerFeatureResult.RestartNeeded -eq 'Yes') {
        Write-Step 'Restarting Vm-Router to finish routing feature installation...'
        Invoke-Command -Session $managementSession -ScriptBlock {
            Restart-VM -Name 'Vm-Router' -Force
        }
        $null = Wait-NestedPowerShellDirect `
            -ManagementSession $managementSession `
            -VirtualMachineName 'Vm-Router' `
            -Credential $LocalAdministratorCredential `
            -TimeoutMinutes $GuestReadyTimeoutMinutes
    }

    Write-Step 'Configuring routing and NAT on Vm-Router...'
    $routerResult = Invoke-Command `
        -Session $managementSession `
        -ArgumentList $LocalAdministratorCredential, $configuration, $DnsForwarder `
        -ScriptBlock {
            param(
                [PSCredential]$Credential,
                $Configuration,
                [string]$DnsForwarder
            )

            Invoke-Command `
                -VMName 'Vm-Router' `
                -Credential $Credential `
                -ArgumentList $Configuration, $DnsForwarder `
                -ScriptBlock {
                    param(
                        $Configuration,
                        [string]$DnsForwarder
                    )

                    Set-StrictMode -Version Latest
                    $ErrorActionPreference = 'Stop'

                    function Get-NamedAdapter {
                        param([string]$HyperVName)

                        $adapter = Get-NetAdapter -Name $HyperVName -ErrorAction SilentlyContinue
                        if ($adapter) {
                            return $adapter
                        }

                        $properties = @(
                            Get-NetAdapterAdvancedProperty `
                            -RegistryKeyword 'HyperVNetworkAdapterName' `
                            -ErrorAction SilentlyContinue |
                            Where-Object RegistryValue -eq $HyperVName
                        )
                        if ($properties.Count -eq 0) {
                            throw "Adapter '$HyperVName' was not found."
                        }
                        if ($properties.Count -gt 1) {
                            throw "Adapter '$HyperVName' matched multiple guest adapters."
                        }

                        Rename-NetAdapter -Name $properties[0].Name -NewName $HyperVName -Confirm:$false
                        return Get-NetAdapter -Name $HyperVName
                    }

                    function Initialize-Address {
                        param(
                            [string]$InterfaceAlias,
                            [string]$IpAddress,
                            [int]$PrefixLength,
                            [string]$DefaultGateway,
                            [string[]]$DnsServers
                        )

                        $adapter = Get-NamedAdapter -HyperVName $InterfaceAlias
                        Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue
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

                            $parameters = @{
                                InterfaceIndex = $adapter.ifIndex
                                IPAddress      = $IpAddress
                                PrefixLength   = $PrefixLength
                            }
                            if ($DefaultGateway) {
                                $parameters.DefaultGateway = $DefaultGateway
                            }
                            New-NetIPAddress @parameters | Out-Null
                        }

                        if ($DnsServers) {
                            Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses $DnsServers
                        }
                    }

                    Initialize-Address -InterfaceAlias 'Mgmt' -IpAddress '192.168.1.1' -PrefixLength 24 -DnsServers @($DnsForwarder)
                    Initialize-Address -InterfaceAlias 'Provider' -IpAddress '172.16.0.1' -PrefixLength 24
                    Initialize-Address -InterfaceAlias 'VLAN110' -IpAddress '10.10.0.1' -PrefixLength 24
                    Initialize-Address -InterfaceAlias 'VLAN200' -IpAddress '192.168.200.1' -PrefixLength 24
                    Initialize-Address -InterfaceAlias 'SIMInternet' -IpAddress '131.127.0.1' -PrefixLength 24
                    Initialize-Address `
                        -InterfaceAlias 'NAT' `
                        -IpAddress '192.168.46.10' `
                        -PrefixLength 24 `
                        -DefaultGateway $Configuration.Networks.InnerNat.Gateway `
                        -DnsServers @($DnsForwarder)

                    Set-ItemProperty `
                        -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' `
                        -Name 'IPEnableRouter' `
                        -Type DWord `
                        -Value 1

                    $remoteAccess = Get-Service -Name RemoteAccess
                    if ($remoteAccess.StartType -ne 'Automatic') {
                        Set-Service -Name RemoteAccess -StartupType Automatic
                    }
                    try {
                        Install-RemoteAccess -VpnType RoutingOnly -ErrorAction Stop | Out-Null
                    }
                    catch {
                        if ($_.Exception.Message -notmatch '(?i)already|installed|configured') {
                            throw
                        }
                    }

                    $null = & netsh.exe routing ip nat install
                    $natInterfaces = (& netsh.exe routing ip nat show interface) -join "`n"
                    if ($natInterfaces -notmatch '(?im)^\s*NAT\s') {
                        $null = & netsh.exe routing ip nat add interface name='NAT' mode=full
                    }
                    foreach ($privateInterface in @('Mgmt', 'Provider', 'VLAN110', 'VLAN200', 'SIMInternet')) {
                        if ($natInterfaces -notmatch "(?im)^\s*$([regex]::Escape($privateInterface))\s") {
                            $null = & netsh.exe routing ip nat add interface name="$privateInterface" mode=private
                        }
                    }

                    # RRAS refuses a stop control for a short window after its NAT configuration is
                    # rewritten, and Restart-Service reports that as a terminal error even though the
                    # netsh changes are already live in the running service.
                    $restartDeadline = (Get-Date).AddMinutes(5)
                    $routingRestarted = $false
                    while (-not $routingRestarted) {
                        try {
                            Restart-Service -Name RemoteAccess -Force -ErrorAction Stop
                            $routingRestarted = $true
                        }
                        catch {
                            if ((Get-Date) -ge $restartDeadline) {
                                break
                            }
                            Start-Sleep -Seconds 15
                        }
                    }

                    $routingService = Get-Service -Name RemoteAccess
                    if ($routingService.Status -ne 'Running') {
                        Start-Service -Name RemoteAccess -ErrorAction SilentlyContinue
                        $routingService.WaitForStatus('Running', [timespan]::FromSeconds(120))
                    }

                    # Azure Local validation pings the gateway from every address in the infra pool, and
                    # the built-in echo rules are disabled. Match by name because display names localise.
                    if (-not (Get-NetFirewallRule -Name 'AzureLocalSandbox-ICMPv4-In' -ErrorAction SilentlyContinue)) {
                        New-NetFirewallRule `
                            -Name 'AzureLocalSandbox-ICMPv4-In' `
                            -DisplayName 'Azure Local Sandbox ICMPv4 Echo Request' `
                            -Direction Inbound `
                            -Protocol ICMPv4 `
                            -IcmpType 8 `
                            -Action Allow `
                            -Profile Any | Out-Null
                    }

                    Enable-PSRemoting -Force -SkipNetworkProfileCheck

                    [pscustomobject]@{
                        Name             = $env:COMPUTERNAME
                        Result           = 'RouterReady'
                        RoutingRestarted = $routingRestarted
                    }
                }
        }

    $domainControllerCredential = Wait-NestedPowerShellDirect `
        -ManagementSession $managementSession `
        -VirtualMachineName $domainControllerName `
        -Credential @($domainControllerLocalCredential, $domainCredential) `
        -TimeoutMinutes $GuestReadyTimeoutMinutes

    Write-Step 'Promoting the domain controller. Install-ADDSForest takes several minutes...'
    $promotionResult = Invoke-Command `
        -Session $managementSession `
        -ArgumentList $domainControllerName, $domainControllerCredential, $configuration `
        -ScriptBlock {
            param(
                [string]$DomainControllerName,
                [PSCredential]$Credential,
                $Configuration
            )

            Invoke-Command `
                -VMName $DomainControllerName `
                -Credential $Credential `
                -ArgumentList $Configuration, $Credential.Password `
                -ScriptBlock {
                    param(
                        $Configuration,
                        [SecureString]$SafeModeAdministratorPassword
                    )

                    Set-StrictMode -Version Latest
                    $ErrorActionPreference = 'Stop'

                    $adapter = Get-NetAdapter -Name 'Mgmt' -ErrorAction SilentlyContinue
                    if (-not $adapter) {
                        $properties = @(
                            Get-NetAdapterAdvancedProperty `
                            -RegistryKeyword 'HyperVNetworkAdapterName' `
                            -ErrorAction SilentlyContinue |
                            Where-Object RegistryValue -eq 'Mgmt'
                        )
                        if ($properties.Count -eq 0) {
                            throw 'Management adapter was not found on the domain controller.'
                        }
                        if ($properties.Count -gt 1) {
                            throw 'Management adapter matched multiple adapters on the domain controller.'
                        }
                        Rename-NetAdapter -Name $properties[0].Name -NewName 'Mgmt' -Confirm:$false
                        $adapter = Get-NetAdapter -Name 'Mgmt'
                    }

                    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -Dhcp Disabled -ErrorAction SilentlyContinue
                    $address = Get-NetIPAddress `
                        -InterfaceIndex $adapter.ifIndex `
                        -AddressFamily IPv4 `
                        -ErrorAction SilentlyContinue |
                        Where-Object IPAddress -eq $Configuration.Domain.DomainControllerIp
                    if (-not $address) {
                        Get-NetIPAddress `
                            -InterfaceIndex $adapter.ifIndex `
                            -AddressFamily IPv4 `
                            -ErrorAction SilentlyContinue |
                            Where-Object PrefixOrigin -ne 'WellKnown' |
                            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue
                        New-NetIPAddress `
                            -InterfaceIndex $adapter.ifIndex `
                            -IPAddress $Configuration.Domain.DomainControllerIp `
                            -PrefixLength $Configuration.Networks.Management.PrefixLength `
                            -DefaultGateway $Configuration.Networks.Management.Gateway | Out-Null
                    }
                    Set-DnsClientServerAddress `
                        -InterfaceIndex $adapter.ifIndex `
                        -ServerAddresses @($Configuration.Domain.DomainControllerIp)

                    w32tm.exe /config /manualpeerlist:'time.windows.com,0x8' /syncfromflags:manual /update | Out-Null
                    Restart-Service W32Time
                    w32tm.exe /resync /force | Out-Null

                    $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
                    if ($computerSystem.DomainRole -lt 4) {
                        Install-WindowsFeature -Name AD-Domain-Services, DNS -IncludeManagementTools | Out-Null
                        Install-ADDSForest `
                            -DomainName $Configuration.Domain.Fqdn `
                            -DomainNetbiosName $Configuration.Domain.NetBiosName `
                            -InstallDns `
                            -SafeModeAdministratorPassword $SafeModeAdministratorPassword `
                            -NoRebootOnCompletion `
                            -Force `
                            -Confirm:$false
                        return 'RebootRequired'
                    }

                    return 'AlreadyPromoted'
                }
        }

    if ($promotionResult -eq 'RebootRequired') {
        Write-Step 'Restarting the domain controller after promotion...'
        Invoke-Command -Session $managementSession -ArgumentList $domainControllerName -ScriptBlock {
            param([string]$DomainControllerName)
            Restart-VM -Name $DomainControllerName -Force
        }
    }

    $null = Wait-NestedPowerShellDirect `
        -ManagementSession $managementSession `
        -VirtualMachineName $domainControllerName `
        -Credential $domainCredential `
        -TimeoutMinutes $GuestReadyTimeoutMinutes

    Write-Step 'Preparing the deployment OU, LCM account, and DNS forwarders...'
    $domainResult = Invoke-Command `
        -Session $managementSession `
        -ArgumentList $domainControllerName, $domainCredential, $LcmCredential, $configuration, $DnsForwarder, $dependencies.PowerShellModules.AsHciADArtifactsPreCreationTool `
        -ScriptBlock {
            param(
                [string]$DomainControllerName,
                [PSCredential]$DomainCredential,
                [PSCredential]$LcmCredential,
                $Configuration,
                [string]$DnsForwarder,
                $AdPreparationModule
            )

            Invoke-Command `
                -VMName $DomainControllerName `
                -Credential $DomainCredential `
                -ArgumentList $LcmCredential, $Configuration, $DnsForwarder, $AdPreparationModule `
                -ScriptBlock {
                    param(
                        [PSCredential]$LcmCredential,
                        $Configuration,
                        [string]$DnsForwarder,
                        $AdPreparationModule
                    )

                    Set-StrictMode -Version Latest
                    $ErrorActionPreference = 'Stop'

                    # Promotion leaves ADWS disabled, and the ActiveDirectory module has no other
                    # transport, so every AD cmdlet fails until the service is enabled and started.
                    $directoryWebServices = Get-Service -Name ADWS
                    if ($directoryWebServices.StartType -ne 'Automatic') {
                        Set-Service -Name ADWS -StartupType Automatic
                    }
                    if ($directoryWebServices.Status -ne 'Running') {
                        Start-Service -Name ADWS
                        (Get-Service -Name ADWS).WaitForStatus('Running', [timespan]::FromSeconds(180))
                    }

                    Import-Module ActiveDirectory
                    Import-Module DnsServer

                    # ADWS starts accepting directory queries a couple of minutes after it reports running.
                    $directoryDeadline = (Get-Date).AddMinutes(10)
                    while ($true) {
                        try {
                            $null = Get-ADDomain -ErrorAction Stop
                            break
                        }
                        catch {
                            if ((Get-Date) -ge $directoryDeadline) {
                                throw "Active Directory Web Services on '$env:COMPUTERNAME' did not accept directory queries within 10 minutes."
                            }
                            Start-Sleep -Seconds 10
                        }
                    }

                    # Promotion can complete without the forward lookup zone when the DNS server starts
                    # before AD DS signals initial synchronisation, leaving the domain unresolvable.
                    if (-not (Get-DnsServerZone -Name $Configuration.Domain.Fqdn -ErrorAction SilentlyContinue)) {
                        Add-DnsServerPrimaryZone `
                            -Name $Configuration.Domain.Fqdn `
                            -ReplicationScope Domain `
                            -DynamicUpdate Secure
                        Restart-Service -Name Netlogon -Force
                        Register-DnsClient
                    }

                    $locatorRecord = "_ldap._tcp.dc._msdcs.$($Configuration.Domain.Fqdn)"
                    $zoneDeadline = (Get-Date).AddMinutes(5)
                    while ($true) {
                        $startOfAuthority = Resolve-DnsName `
                            -Name $Configuration.Domain.Fqdn `
                            -Type SOA `
                            -Server 127.0.0.1 `
                            -ErrorAction SilentlyContinue
                        $serviceLocator = Resolve-DnsName `
                            -Name $locatorRecord `
                            -Type SRV `
                            -Server 127.0.0.1 `
                            -ErrorAction SilentlyContinue
                        if ($startOfAuthority -and $serviceLocator) {
                            break
                        }
                        if ((Get-Date) -ge $zoneDeadline) {
                            throw "'$($Configuration.Domain.Fqdn)' did not publish SOA and '$locatorRecord' records on '$env:COMPUTERNAME' within 5 minutes."
                        }
                        Start-Sleep -Seconds 15
                    }

                    # A forest with no forwarders reports IPAddress as $null rather than an empty
                    # array, and piping $null runs the body once with $_ unset.
                    $forwarderConfiguration = Get-DnsServerForwarder -ErrorAction SilentlyContinue
                    $existingForwarders = @(
                        $forwarderConfiguration.IPAddress |
                            Where-Object { $_ } |
                            ForEach-Object { $_.IPAddressToString }
                    )
                    if ($DnsForwarder -notin $existingForwarders) {
                        Add-DnsServerForwarder -IPAddress $DnsForwarder -PassThru | Out-Null
                    }
                    $externalDnsProbe = 'management.azure.com'
                    if (-not (Resolve-DnsName -Name $externalDnsProbe -Server $DnsForwarder -ErrorAction SilentlyContinue)) {
                        throw "DNS forwarder '$DnsForwarder' cannot resolve '$externalDnsProbe'."
                    }

                    if (-not (Get-KdsRootKey -ErrorAction SilentlyContinue)) {
                        Add-KdsRootKey -EffectiveTime (Get-Date).AddHours(-10) | Out-Null
                    }

                    $domainDistinguishedName = ($Configuration.Domain.Fqdn.Split('.') | ForEach-Object { "DC=$_" }) -join ','
                    $ouDistinguishedName = "OU=$($Configuration.Domain.DeploymentOuName),$domainDistinguishedName"

                    # -Identity raises a terminating error for a missing object, so -ErrorAction cannot suppress it.
                    $ouExists = $null
                    try {
                        $ouExists = Get-ADOrganizationalUnit -Identity $ouDistinguishedName -ErrorAction Stop
                    }
                    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
                    }

                    $lcmUser = $null
                    try {
                        $lcmUser = Get-ADUser -Identity $Configuration.Domain.DeploymentUserName -ErrorAction Stop
                    }
                    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
                    }

                    if (-not $ouExists -or -not $lcmUser) {
                        # PowerShellGet raises an interactive bootstrap prompt when the provider binary is
                        # older than the version it requires, and nothing can answer it over PowerShell Direct.
                        $installedProvider = @(
                            Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue |
                                Where-Object { $_.Version -ge [version]'2.8.5.208' }
                        )
                        if ($installedProvider.Count -eq 0) {
                            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.208 -Force -ForceBootstrap | Out-Null
                        }
                        $originalPolicy = (Get-PSRepository -Name PSGallery).InstallationPolicy
                        try {
                            if ($originalPolicy -ne 'Trusted') {
                                Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
                            }
                            Install-Module `
                                -Name $AdPreparationModule.Name `
                                -RequiredVersion $AdPreparationModule.Version `
                                -Repository PSGallery `
                                -Scope CurrentUser `
                                -Force
                        }
                        finally {
                            if ($originalPolicy -ne 'Trusted') {
                                Set-PSRepository -Name PSGallery -InstallationPolicy $originalPolicy
                            }
                        }
                        Import-Module `
                            -Name $AdPreparationModule.Name `
                            -RequiredVersion $AdPreparationModule.Version
                        New-HciAdObjectsPreCreation `
                            -AzureStackLCMUserCredential $LcmCredential `
                            -AsHciOUName $ouDistinguishedName
                    }

                    # Promotion leaves the NtpServer provider disabled, so the domain controller keeps
                    # good time but never answers client requests, and every node falls back to its
                    # CMOS clock, which Azure Local validation rejects.
                    $ntpServerProvider = 'HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpServer'
                    if ((Get-ItemProperty -Path $ntpServerProvider -Name 'Enabled' -ErrorAction SilentlyContinue).Enabled -ne 1) {
                        Set-ItemProperty -Path $ntpServerProvider -Name 'Enabled' -Value 1 -Type DWord
                    }

                    w32tm.exe /config /manualpeerlist:'time.windows.com,0x8' /syncfromflags:manual /reliable:yes /update | Out-Null
                    Restart-Service W32Time
                    w32tm.exe /resync /force | Out-Null

                    [pscustomobject]@{
                        Name                = $env:COMPUTERNAME
                        Domain              = (Get-ADDomain).DNSRoot
                        OuDistinguishedName = $ouDistinguishedName
                        LcmUser             = $Configuration.Domain.DeploymentUserName
                        Result              = 'DomainReady'
                    }
                }
        }

    Write-Step 'Pointing the router and Azure Local nodes at the domain controller for DNS...'
    $null = Invoke-Command `
        -Session $managementSession `
        -ArgumentList $LocalAdministratorCredential, $configuration.Domain.DomainControllerIp `
        -ScriptBlock {
            param(
                [PSCredential]$Credential,
                [string]$DomainControllerIp
            )

            Invoke-Command -VMName 'Vm-Router' -Credential $Credential -ArgumentList $DomainControllerIp -ScriptBlock {
                param([string]$DomainControllerIp)
                foreach ($adapterName in @('Mgmt', 'NAT')) {
                    $adapter = Get-NetAdapter -Name $adapterName
                    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($DomainControllerIp)
                }
            }
        }

    $levelOneDnsResults = foreach ($nodeName in @('AzLHOST1', 'AzLHOST2')) {
        Invoke-Command `
            -VMName $nodeName `
            -Credential $LocalAdministratorCredential `
            -ArgumentList $configuration.Domain.DomainControllerIp, $configuration.Domain.Fqdn `
            -ScriptBlock {
                param($DomainControllerIp, $DomainFqdn)

                $adapter = Get-NetAdapter -Name 'FABRIC'
                Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses @($DomainControllerIp)

                # The node cached NXDOMAIN for the domain while it still pointed at a public resolver.
                Clear-DnsClientCache

                $resolutionDeadline = (Get-Date).AddMinutes(5)
                $domainResolution = $null
                while (-not $domainResolution) {
                    $domainResolution = Resolve-DnsName -Name $DomainFqdn -Type SOA -ErrorAction SilentlyContinue
                    if ($domainResolution) {
                        break
                    }
                    if ((Get-Date) -ge $resolutionDeadline) {
                        throw "'$env:COMPUTERNAME' could not resolve '$DomainFqdn' through '$DomainControllerIp' within 5 minutes."
                    }
                    Start-Sleep -Seconds 15
                    Clear-DnsClientCache
                }

                [pscustomobject]@{
                    Name       = $env:COMPUTERNAME
                    DnsServers = @((Get-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4).ServerAddresses)
                    Domain     = $domainResolution.Name
                    Result     = 'DnsReady'
                }
            }
    }

    $internalSwitchAdapter = Get-NetAdapter -Name 'vEthernet (InternalSwitch)'
    Write-Step 'Adding host routes to the nested lab networks...'
    foreach ($destinationPrefix in @(
        $configuration.Networks.Provider.Prefix
        $configuration.Networks.Vlan110.Prefix
        $configuration.Networks.Vlan200.Prefix
        $configuration.Networks.SimulatedInternet.Prefix
    )) {
        $route = Get-NetRoute `
            -InterfaceIndex $internalSwitchAdapter.ifIndex `
            -DestinationPrefix $destinationPrefix `
            -ErrorAction SilentlyContinue |
            Where-Object NextHop -eq $configuration.Networks.Management.Gateway
        if (-not $route) {
            $routeParameters = @{
                InterfaceIndex    = $internalSwitchAdapter.ifIndex
                DestinationPrefix = $destinationPrefix
                NextHop           = $configuration.Networks.Management.Gateway
                RouteMetric       = 50
            }
            try {
                # Windows Server 2025 build 26100 rejects PersistentStore with ERROR_INVALID_PARAMETER.
                New-NetRoute @routeParameters -PolicyStore PersistentStore -ErrorAction Stop | Out-Null
            }
            catch {
                New-NetRoute @routeParameters -ErrorAction Stop | Out-Null
            }
        }
    }
}
finally {
    Remove-PSSession -Session $managementSession -ErrorAction SilentlyContinue
}

$ouDistinguishedName = "OU=$($configuration.Domain.DeploymentOuName),$(ConvertTo-DomainDistinguishedName -DomainFqdn $configuration.Domain.Fqdn)"
$stateFile = 'C:\AzureLocalSandbox\State\management-plane.json'
[ordered]@{
    phase               = 'ManagementPlaneReady'
    updatedAt           = (Get-Date).ToUniversalTime().ToString('o')
    innerMachines       = @($creationResults)
    router              = $routerResult
    domain              = $domainResult
    levelOneDns         = @($levelOneDnsResults)
    ouDistinguishedName = $ouDistinguishedName
} | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $stateFile -Encoding UTF8

[pscustomobject]@{
    Domain              = $configuration.Domain.Fqdn
    DomainController    = $configuration.Domain.DomainControllerName
    Router              = 'Vm-Router'
    OuDistinguishedName = $ouDistinguishedName
    Result              = 'ManagementPlaneReady'
} | Format-List