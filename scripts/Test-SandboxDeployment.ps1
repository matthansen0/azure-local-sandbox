#Requires -Version 5.1
#Requires -RunAsAdministrator

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseUsingScopeModifierInNewRunspaces',
    '',
    Justification = 'PowerShell Direct script blocks receive serialized values through ArgumentList and declare them in local param blocks.'
)]
param(
    [Parameter(Mandatory)]
    [PSCredential]$LocalAdministratorCredential,

    [PSCredential]$DomainAdministratorCredential,

    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..\config\lab.psd1'),

    [switch]$RequireAzureLocalDeployment
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-MachineLocalCredential {
    # Azure Local joins the nodes to the domain, after which an unqualified user name authenticates
    # against the domain instead of the node's own SAM database and PowerShell Direct rejects it.
    param([Parameter(Mandatory)][PSCredential]$Credential)

    if ($Credential.UserName -match '[\\@]') {
        return $Credential
    }

    return New-Object System.Management.Automation.PSCredential(".\$($Credential.UserName)", $Credential.Password)
}

$LocalAdministratorCredential = Get-MachineLocalCredential -Credential $LocalAdministratorCredential

function Invoke-NodeCommand {
    # Cloud deployment applies the Azure Local security baseline, which disables the node's local
    # administrator account, so a deployed node only answers to the domain credential. A node that
    # is merely validated still only has the local one.
    param(
        [Parameter(Mandatory)][string]$VMName,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    $candidates = @($LocalAdministratorCredential)
    if ($DomainAdministratorCredential) {
        $candidates += $DomainAdministratorCredential
    }

    $lastError = $null
    foreach ($candidate in $candidates) {
        try {
            return Invoke-Command `
                -VMName $VMName `
                -Credential $candidate `
                -ArgumentList $ArgumentList `
                -ScriptBlock $ScriptBlock `
                -ErrorAction Stop
        }
        catch {
            $lastError = $_
        }
    }

    throw $lastError
}

$results = [Collections.Generic.List[object]]::new()

function Add-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Layer,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Passed,
        [Parameter(Mandatory)][string]$Detail
    )

    $results.Add([pscustomobject]@{
        Layer  = $Layer
        Name   = $Name
        Passed = $Passed
        Detail = $Detail
    })
}

function Add-StateCheck {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$ExpectedPhases
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Add-CheckResult -Layer 'State' -Name $Name -Passed $false -Detail "Missing: $Path"
        return
    }

    try {
        $state = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        Add-CheckResult `
            -Layer 'State' `
            -Name $Name `
            -Passed ($state.phase -in $ExpectedPhases) `
            -Detail "Phase: $($state.phase)"
    }
    catch {
        Add-CheckResult -Layer 'State' -Name $Name -Passed $false -Detail $_.Exception.Message
    }
}

$configuration = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $ConfigurationPath)
$stateRoot = 'C:\AzureLocalSandbox\State'

Add-StateCheck -Name 'Host bootstrap' -Path (Join-Path $stateRoot 'bootstrap.json') -ExpectedPhases @('HostReady')
Add-StateCheck -Name 'Verified images' -Path (Join-Path $stateRoot 'images.json') -ExpectedPhases @('ImagesVerified')
Add-StateCheck -Name 'Nested VMs' -Path (Join-Path $stateRoot 'nested-vms.json') -ExpectedPhases @('NestedVMsCreated', 'NestedVMsStarted')
Add-StateCheck -Name 'Guest disks' -Path (Join-Path $stateRoot 'guest-disks.json') -ExpectedPhases @('GuestDisksSpecialized')
Add-StateCheck -Name 'Level one' -Path (Join-Path $stateRoot 'level-one-guests.json') -ExpectedPhases @('LevelOneGuestsReady')
Add-StateCheck -Name 'Management plane' -Path (Join-Path $stateRoot 'management-plane.json') -ExpectedPhases @('ManagementPlaneReady')
Add-StateCheck -Name 'Arc registration' -Path (Join-Path $stateRoot 'arc-registration.json') -ExpectedPhases @('AzureLocalNodesArcConnected')
$deploymentPhases = if ($RequireAzureLocalDeployment) {
    @('AzureLocalDeployed')
}
else {
    @('AzureLocalValidated', 'AzureLocalDeployed')
}
Add-StateCheck -Name 'Azure Local cloud' -Path (Join-Path $stateRoot 'azure-local-deployment.json') -ExpectedPhases $deploymentPhases

foreach ($vmConfiguration in @($configuration.VMs)) {
    $virtualMachine = Get-VM -Name $vmConfiguration.Name -ErrorAction SilentlyContinue
    Add-CheckResult `
        -Layer 'Hyper-V' `
        -Name $vmConfiguration.Name `
        -Passed ($null -ne $virtualMachine -and $virtualMachine.State -eq 'Running') `
        -Detail $(if ($virtualMachine) { "State: $($virtualMachine.State)" } else { 'Not found' })

    if (-not $virtualMachine) {
        continue
    }

    $processor = Get-VMProcessor -VMName $virtualMachine.Name
    Add-CheckResult `
        -Layer 'Hyper-V' `
        -Name "$($virtualMachine.Name) processors" `
        -Passed ($processor.Count -eq $vmConfiguration.ProcessorCount) `
        -Detail "Expected $($vmConfiguration.ProcessorCount); actual $($processor.Count)"

    $actualAdapterNames = @(Get-VMNetworkAdapter -VMName $virtualMachine.Name | Select-Object -ExpandProperty Name)
    $missingAdapters = @($vmConfiguration.NetworkAdapters.Name | Where-Object { $_ -notin $actualAdapterNames })
    Add-CheckResult `
        -Layer 'Hyper-V' `
        -Name "$($virtualMachine.Name) adapters" `
        -Passed ($missingAdapters.Count -eq 0) `
        -Detail $(if ($missingAdapters.Count) { "Missing: $($missingAdapters -join ', ')" } else { 'All configured adapters exist' })
}

foreach ($nodeConfiguration in @($configuration.VMs | Where-Object Role -eq 'AzureLocalNode')) {
    try {
        $nodeResult = Invoke-NodeCommand `
            -VMName $nodeConfiguration.Name `
            -ArgumentList $configuration.Domain.Fqdn, $configuration.Domain.DomainControllerIp `
            -ScriptBlock {
                param([string]$DomainFqdn, [string]$DomainControllerIp)

                $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
                # Deployment moves the management IP onto a SET team vNIC, so FABRIC no longer carries
                # the DNS configuration and querying it by name fails outright.
                $dnsServers = @(
                    Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
                        ForEach-Object { $_.ServerAddresses } |
                        Where-Object { $_ } |
                        Select-Object -Unique
                )
                $azureResourceManagerHost = 'management.azure.com'
                $requiredAdapterNames = @('FABRIC', 'StorageA', 'StorageB')
                [pscustomobject]@{
                    ComputerName      = $env:COMPUTERNAME
                    PartOfDomain      = $computerSystem.PartOfDomain
                    DnsConfigured     = $DomainControllerIp -in $dnsServers
                    DomainResolves    = $null -ne (Resolve-DnsName -Name $DomainFqdn -Type SOA -ErrorAction SilentlyContinue)
                    AzureHttps        = Test-NetConnection -ComputerName $azureResourceManagerHost -Port 443 -InformationLevel Quiet
                    RequiredAdapters  = @($requiredAdapterNames | Where-Object { Get-NetAdapter -Name $_ -ErrorAction SilentlyContinue }).Count
                }
            }

        Add-CheckResult -Layer 'Azure Local node' -Name "$($nodeConfiguration.Name) identity" -Passed ($nodeResult.ComputerName -eq $nodeConfiguration.Name) -Detail "Computer: $($nodeResult.ComputerName)"
        Add-CheckResult `
            -Layer 'Azure Local node' `
            -Name "$($nodeConfiguration.Name) domain state" `
            -Passed ($nodeResult.PartOfDomain -eq [bool]$RequireAzureLocalDeployment) `
            -Detail "Expected PartOfDomain=$([bool]$RequireAzureLocalDeployment); actual $($nodeResult.PartOfDomain)"
        Add-CheckResult -Layer 'Azure Local node' -Name "$($nodeConfiguration.Name) DNS" -Passed ($nodeResult.DnsConfigured -and $nodeResult.DomainResolves) -Detail "Configured: $($nodeResult.DnsConfigured); resolves: $($nodeResult.DomainResolves)"
        Add-CheckResult -Layer 'Azure Local node' -Name "$($nodeConfiguration.Name) Azure egress" -Passed $nodeResult.AzureHttps -Detail "HTTPS: $($nodeResult.AzureHttps)"
        Add-CheckResult -Layer 'Azure Local node' -Name "$($nodeConfiguration.Name) NICs" -Passed ($nodeResult.RequiredAdapters -eq 3) -Detail "Required adapters: $($nodeResult.RequiredAdapters)/3"
    }
    catch {
        Add-CheckResult -Layer 'Azure Local node' -Name $nodeConfiguration.Name -Passed $false -Detail $_.Exception.Message
    }
}

if ($RequireAzureLocalDeployment) {
    $firstNodeName = @($configuration.VMs | Where-Object Role -eq 'AzureLocalNode')[0].Name
    try {
        $quorum = Invoke-NodeCommand `
            -VMName $firstNodeName `
            -ArgumentList $configuration.Cluster.Name `
            -ScriptBlock {
                param([string]$ClusterName)

                Import-Module FailoverClusters -ErrorAction SilentlyContinue
                $resource = (Get-ClusterQuorum -Cluster $ClusterName -ErrorAction SilentlyContinue).QuorumResource
                [pscustomobject]@{
                    Witness = if ($resource) { [string]$resource.Name } else { 'None' }
                    State   = if ($resource) { [string]$resource.State } else { 'None' }
                }
            }

        Add-CheckResult `
            -Layer 'Azure Local cluster' `
            -Name 'Quorum witness' `
            -Passed ($quorum.Witness -eq 'File Share Witness' -and $quorum.State -eq 'Online') `
            -Detail "Witness: $($quorum.Witness); state: $($quorum.State)"
    }
    catch {
        Add-CheckResult -Layer 'Azure Local cluster' -Name 'Quorum witness' -Passed $false -Detail $_.Exception.Message
    }
}

try {
    $managementSession = New-PSSession -VMName 'AzLMGMT' -Credential $LocalAdministratorCredential
    try {
        $innerResult = Invoke-Command `
            -Session $managementSession `
            -ArgumentList $LocalAdministratorCredential, $configuration.Domain `
            -ScriptBlock {
                param([PSCredential]$LocalCredential, $Domain)

                $router = Get-VM -Name 'Vm-Router' -ErrorAction SilentlyContinue
                $domainController = Get-VM -Name $Domain.DomainControllerName -ErrorAction SilentlyContinue
                $routerService = $null
                if ($router -and $router.State -eq 'Running') {
                    $routerService = Invoke-Command -VMName 'Vm-Router' -Credential $LocalCredential -ScriptBlock {
                        (Get-Service -Name RemoteAccess).Status
                    }
                }

                [pscustomobject]@{
                    RouterState          = if ($router) { [string]$router.State } else { 'Missing' }
                    DomainControllerState = if ($domainController) { [string]$domainController.State } else { 'Missing' }
                    RouterService        = [string]$routerService
                }
            }

        Add-CheckResult -Layer 'Management' -Name 'Vm-Router' -Passed ($innerResult.RouterState -eq 'Running' -and $innerResult.RouterService -eq 'Running') -Detail "VM: $($innerResult.RouterState); RRAS: $($innerResult.RouterService)"
        Add-CheckResult -Layer 'Management' -Name $configuration.Domain.DomainControllerName -Passed ($innerResult.DomainControllerState -eq 'Running') -Detail "VM: $($innerResult.DomainControllerState)"
    }
    finally {
        Remove-PSSession -Session $managementSession
    }
}
catch {
    Add-CheckResult -Layer 'Management' -Name 'AzLMGMT PowerShell Direct' -Passed $false -Detail $_.Exception.Message
}

$arcStatePath = Join-Path $stateRoot 'arc-registration.json'
if (Test-Path -LiteralPath $arcStatePath) {
    $arcState = Get-Content -LiteralPath $arcStatePath -Raw | ConvertFrom-Json
    foreach ($machine in @($arcState.machines)) {
        Add-CheckResult `
            -Layer 'Azure' `
            -Name "Arc $($machine.Name)" `
            -Passed ($machine.Status -eq 'Connected' -and -not [string]::IsNullOrWhiteSpace($machine.ResourceId)) `
            -Detail "Status: $($machine.Status); resource: $($machine.ResourceId)"
    }
}

try {
    $contextPath = Join-Path $stateRoot 'deployment-context.json'
    $context = Get-Content -LiteralPath $contextPath -Raw | ConvertFrom-Json

    Import-Module Az.Accounts -ErrorAction Stop
    Import-Module Az.ConnectedMachine -ErrorAction Stop
    Import-Module Az.Resources -ErrorAction Stop
    $null = Connect-AzAccount `
        -Identity `
        -Tenant $context.tenantId `
        -Subscription $context.subscriptionId

    foreach ($nodeConfiguration in @($configuration.VMs | Where-Object Role -eq 'AzureLocalNode')) {
        $connectedMachine = Get-AzConnectedMachine `
            -Name $nodeConfiguration.Name `
            -ResourceGroupName $context.resourceGroupName `
            -SubscriptionId $context.subscriptionId `
            -ErrorAction SilentlyContinue
        Add-CheckResult `
            -Layer 'Azure live' `
            -Name "Arc $($nodeConfiguration.Name)" `
            -Passed ($null -ne $connectedMachine -and $connectedMachine.Status -eq 'Connected') `
            -Detail $(if ($connectedMachine) { "Status: $($connectedMachine.Status)" } else { 'Resource not found' })
    }

    if ($RequireAzureLocalDeployment) {
        # Get-AzResource resolves this provider only by full resource id; the -ResourceType plus
        # -Name form returns nothing and the cluster reads as missing.
        $clusterResourceId = '/subscriptions/{0}/resourceGroups/{1}/providers/Microsoft.AzureStackHCI/clusters/{2}' -f
            $context.subscriptionId, $context.resourceGroupName, $configuration.Cluster.Name
        $clusterResource = Get-AzResource `
            -ResourceId $clusterResourceId `
            -ExpandProperties `
            -ErrorAction SilentlyContinue
        $clusterProvisioningState = if ($clusterResource) {
            [string]$clusterResource.Properties.provisioningState
        }
        else {
            'NotFound'
        }
        Add-CheckResult `
            -Layer 'Azure live' `
            -Name 'Azure Local cluster' `
            -Passed ($clusterProvisioningState -eq 'Succeeded') `
            -Detail "Provisioning state: $clusterProvisioningState"
    }
}
catch {
    Add-CheckResult -Layer 'Azure live' -Name 'Azure control plane' -Passed $false -Detail $_.Exception.Message
}

$results | Sort-Object Layer, Name | Format-Table -AutoSize -Wrap
$failedChecks = @($results | Where-Object { -not $_.Passed })
if ($failedChecks.Count -gt 0) {
    throw "$($failedChecks.Count) sandbox validation check(s) failed."
}

Write-Information "All $($results.Count) sandbox validation checks passed." -InformationAction Continue