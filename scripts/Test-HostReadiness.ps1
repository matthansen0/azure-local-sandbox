#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$results = [System.Collections.Generic.List[object]]::new()

function Add-ReadinessCheck {
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [bool]$Passed,

        [Parameter(Mandatory)]
        [string]$Detail
    )

    $results.Add([pscustomobject]@{
        Name   = $Name
        Passed = $Passed
        Detail = $Detail
    })
}

$operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem
$computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
$processor = Get-CimInstance -ClassName Win32_Processor | Select-Object -First 1

Add-ReadinessCheck `
    -Name 'Host operating system' `
    -Passed ($operatingSystem.Caption -match 'Windows Server 2025') `
    -Detail "$($operatingSystem.Caption), build $($operatingSystem.BuildNumber)"

Add-ReadinessCheck `
    -Name 'Host memory' `
    -Passed ($computerSystem.TotalPhysicalMemory -ge 256GB) `
    -Detail "$([math]::Round($computerSystem.TotalPhysicalMemory / 1GB, 1)) GiB"

$virtualizationFirmwareEnabled = [bool]$processor.VirtualizationFirmwareEnabled
Add-ReadinessCheck `
    -Name 'Virtualization extensions' `
    -Passed $virtualizationFirmwareEnabled `
    -Detail "VirtualizationFirmwareEnabled: $virtualizationFirmwareEnabled"

$stateFile = 'C:\AzureLocalSandbox\State\bootstrap.json'
if (Test-Path -LiteralPath $stateFile) {
    $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    Add-ReadinessCheck `
        -Name 'Bootstrap state' `
        -Passed ($state.phase -eq 'HostReady') `
        -Detail "Phase: $($state.phase)"
}
else {
    Add-ReadinessCheck -Name 'Bootstrap state' -Passed $false -Detail "Missing: $stateFile"
}

$hyperVFeature = Get-WindowsFeature -Name 'Hyper-V'
Add-ReadinessCheck `
    -Name 'Hyper-V role' `
    -Passed ($hyperVFeature.InstallState -eq 'Installed') `
    -Detail "State: $($hyperVFeature.InstallState)"

$vmManagementService = Get-Service -Name 'vmms' -ErrorAction SilentlyContinue
Add-ReadinessCheck `
    -Name 'Hyper-V service' `
    -Passed ($null -ne $vmManagementService -and $vmManagementService.Status -eq 'Running') `
    -Detail $(if ($vmManagementService) { "State: $($vmManagementService.Status)" } else { 'Service not found' })

$nestedVmVolume = Get-Volume -DriveLetter V -ErrorAction SilentlyContinue
Add-ReadinessCheck `
    -Name 'Nested VM volume' `
    -Passed ($null -ne $nestedVmVolume -and $nestedVmVolume.FileSystemLabel -eq 'NestedVMs') `
    -Detail $(if ($nestedVmVolume) { "V: $($nestedVmVolume.FileSystem), label $($nestedVmVolume.FileSystemLabel)" } else { 'V: not found' })

if ($nestedVmVolume) {
    Add-ReadinessCheck `
        -Name 'Nested VM free space' `
        -Passed ($nestedVmVolume.SizeRemaining -ge 1500GB) `
        -Detail "$([math]::Round($nestedVmVolume.SizeRemaining / 1GB, 1)) GiB free"
}

$sourceRoot = 'C:\AzureLocalSandbox\Source'
$requiredSourcePaths = @(
    'config\dependencies.psd1'
    'config\lab.psd1'
    'scripts\Invoke-SandboxDeployment.ps1'
    'scripts\Test-SandboxDeployment.ps1'
)
$missingSourcePaths = @(
    $requiredSourcePaths |
        Where-Object { -not (Test-Path -LiteralPath (Join-Path $sourceRoot $_)) }
)
Add-ReadinessCheck `
    -Name 'Sandbox source' `
    -Passed ($missingSourcePaths.Count -eq 0) `
    -Detail $(if ($missingSourcePaths.Count) { "Missing: $($missingSourcePaths -join ', ')" } else { $sourceRoot })

foreach ($switchName in @('InternalSwitch', 'InternalNAT')) {
    $virtualSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
    Add-ReadinessCheck `
        -Name "Switch $switchName" `
        -Passed ($null -ne $virtualSwitch) `
        -Detail $(if ($virtualSwitch) { "Type: $($virtualSwitch.SwitchType)" } else { 'Not found' })
}

$networkAddressTranslation = Get-NetNat -Name 'AzureLocalSandboxNAT' -ErrorAction SilentlyContinue
Add-ReadinessCheck `
    -Name 'Host NAT' `
    -Passed ($null -ne $networkAddressTranslation -and $networkAddressTranslation.InternalIPInterfaceAddressPrefix -eq '192.168.128.0/24') `
    -Detail $(if ($networkAddressTranslation) { "Prefix: $($networkAddressTranslation.InternalIPInterfaceAddressPrefix)" } else { 'Not found' })

$results | Format-Table -AutoSize

$failedChecks = @($results | Where-Object { -not $_.Passed })
if ($failedChecks.Count -gt 0) {
    throw "$($failedChecks.Count) host readiness check(s) failed."
}

Write-Information 'Host readiness checks passed.' -InformationAction Continue