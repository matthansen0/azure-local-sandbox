#Requires -Version 5.1

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('Validate', 'Deploy')]
    [string]$Mode,

    [Parameter(Mandatory)]
    [PSCredential]$LocalAdministratorCredential,

    [Parameter(Mandatory)]
    [PSCredential]$LcmCredential,

    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..\config\lab.psd1'),

    [string]$DeploymentContextPath = 'C:\AzureLocalSandbox\State\deployment-context.json',

    [string]$ArcStatePath = 'C:\AzureLocalSandbox\State\arc-registration.json',

    [string]$ManagementStatePath = 'C:\AzureLocalSandbox\State\management-plane.json',

    [string]$ArtifactsPath = 'C:\AzureLocalSandbox\Artifacts',

    [string]$DependenciesPath = (Join-Path $PSScriptRoot '..\config\dependencies.psd1'),

    [uri]$TemplateUri,

    [switch]$GenerateParametersOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not $GenerateParametersOnly) {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $currentPrincipal = [Security.Principal.WindowsPrincipal]::new($currentIdentity)
    if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from an elevated PowerShell session.'
    }
}

function Install-RequiredAzModule {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Version
    )

    if (Get-Module -ListAvailable -Name $Name | Where-Object Version -eq ([version]$Version)) {
        return
    }

    if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
        Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
    }
    $originalPolicy = (Get-PSRepository -Name PSGallery).InstallationPolicy
    try {
        if ($originalPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
        }
        Install-Module `
            -Name $Name `
            -RequiredVersion $Version `
            -Repository PSGallery `
            -Scope CurrentUser `
            -Force
    }
    finally {
        if ($originalPolicy -ne 'Trusted') {
            Set-PSRepository -Name PSGallery -InstallationPolicy $originalPolicy
        }
    }
}

function Get-StableSuffix {
    param([Parameter(Mandatory)][string]$InputValue)

    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $hash = $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($InputValue))
    }
    finally {
        $sha256.Dispose()
    }

    return (($hash[0..4] | ForEach-Object { $_.ToString('x2') }) -join '')
}

function Get-AzureDeploymentParameter {
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)]$ArcState,
        [Parameter(Mandatory)]$ManagementState,
        [Parameter(Mandatory)][PSCredential]$LocalCredential,
        [Parameter(Mandatory)][PSCredential]$DeploymentCredential,
        [Parameter(Mandatory)][string]$DeploymentMode
    )

    $suffix = Get-StableSuffix -InputValue "$($Context.subscriptionId)/$($Context.resourceGroupName)"
    $nodeConfigurations = @($Configuration.VMs | Where-Object Role -eq 'AzureLocalNode')

    return @{
        deploymentMode                    = $DeploymentMode
        keyVaultName                      = "azlsb-$suffix-kv"
        createNewKeyVault                 = $true
        softDeleteRetentionDays           = 30
        diagnosticStorageAccountName      = "azlsb${suffix}diag"
        logsRetentionInDays               = 30
        storageAccountType                = 'Standard_LRS'
        clusterName                       = 'localboxcluster'
        location                          = $Context.azureLocation
        tenantId                          = $Context.tenantId
        witnessType                       = 'Cloud'
        clusterWitnessStorageAccountName  = "azlsb${suffix}wit"
        localAdminUserName                = $LocalCredential.UserName
        localAdminPassword                = $LocalCredential.Password
        AzureStackLCMAdminUsername         = $DeploymentCredential.UserName
        AzureStackLCMAdminPassword         = $DeploymentCredential.Password
        hciResourceProviderObjectID        = $Context.hciResourceProviderObjectId
        arcNodeResourceIds                 = @($ArcState.machines.ResourceId)
        domainFqdn                         = $Configuration.Domain.Fqdn
        namingPrefix                       = 'localbox'
        adouPath                           = $ManagementState.ouDistinguishedName
        securityLevel                      = 'Recommended'
        driftControlEnforced               = $true
        credentialGuardEnforced            = $true
        smbSigningEnforced                 = $true
        smbClusterEncryption               = $false
        bitlockerBootVolume                = $true
        bitlockerDataVolumes               = $true
        wdacEnforced                       = $false
        streamingDataClient                = $true
        euLocation                         = $false
        episodicDataUpload                 = $true
        configurationMode                  = 'Express'
        subnetMask                         = '255.255.255.0'
        defaultGateway                     = $Configuration.Networks.Management.Gateway
        startingIPAddress                  = '192.168.1.100'
        endingIPAddress                    = '192.168.1.199'
        dnsServers                         = @($Configuration.Domain.DomainControllerIp)
        useDhcp                            = $false
        physicalNodesSettings              = @(
            $nodeConfigurations | ForEach-Object {
                @{
                    name        = $_.Name
                    ipv4Address = $_.ManagementIpAddress
                }
            }
        )
        networkingType                     = 'switchlessMultiServerDeployment'
        networkingPattern                  = 'convergedManagementCompute'
        intentList                         = @(
            @{
                name                               = 'Compute_Management'
                trafficType                        = @('Management', 'Compute')
                adapter                            = @('FABRIC')
                overrideVirtualSwitchConfiguration = $false
                virtualSwitchConfigurationOverrides = @{
                    enableIov             = ''
                    loadBalancingAlgorithm = ''
                }
                overrideQosPolicy                  = $true
                qosPolicyOverrides                 = @{
                    priorityValue8021Action_Cluster = '7'
                    priorityValue8021Action_SMB     = '3'
                    bandwidthPercentage_SMB         = '50'
                }
                overrideAdapterProperty            = $false
                adapterPropertyOverrides           = @{
                    jumboPacket             = '9014'
                    networkDirect           = 'Enabled'
                    networkDirectTechnology = 'RoCEv2'
                }
            }
            @{
                name                               = 'Storage'
                trafficType                        = @('Storage')
                adapter                            = @('StorageA', 'StorageB')
                overrideVirtualSwitchConfiguration = $false
                virtualSwitchConfigurationOverrides = @{
                    enableIov             = ''
                    loadBalancingAlgorithm = ''
                }
                overrideQosPolicy                  = $true
                qosPolicyOverrides                 = @{
                    priorityValue8021Action_Cluster = '7'
                    priorityValue8021Action_SMB     = '3'
                    bandwidthPercentage_SMB         = '50'
                }
                overrideAdapterProperty            = $false
                adapterPropertyOverrides           = @{
                    jumboPacket             = '9014'
                    networkDirect           = 'Enabled'
                    networkDirectTechnology = 'RoCEv2'
                }
            }
        )
        storageNetworkList                  = @(
            @{
                name               = 'StorageA'
                networkAdapterName = 'StorageA'
                vlanId             = [string]$Configuration.Networks.StorageA.VlanId
            }
            @{
                name               = 'StorageB'
                networkAdapterName = 'StorageB'
                vlanId             = [string]$Configuration.Networks.StorageB.VlanId
            }
        )
        storageConnectivitySwitchless       = $false
        enableStorageAutoIp                 = $true
        customLocation                      = 'localbox'
        sbeVersion                          = ''
        sbeFamily                           = ''
        sbePublisher                        = ''
        sbeManifestSource                   = ''
        sbeManifestCreationDate             = ''
        partnerProperties                   = @()
        partnerCredentiallist               = @()
    }
}

if ($LocalAdministratorCredential.UserName -ne 'Administrator') {
    throw "LocalAdministratorCredential must use the built-in 'Administrator' account."
}
if ($LocalAdministratorCredential.Password.Length -lt 14) {
    throw 'The nested local Administrator password must be at least 14 characters long.'
}
if ($LcmCredential.Password.Length -lt 14) {
    throw 'The LCM deployment password must be at least 14 characters long.'
}

$configuration = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $ConfigurationPath)
$dependencies = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $DependenciesPath)
if ($dependencies.SchemaVersion -ne 1) {
    throw "Unsupported dependency schema '$($dependencies.SchemaVersion)'."
}

$quickstartDependency = $dependencies.AzureLocalQuickstart
if (-not $TemplateUri) {
    $TemplateUri = [uri](
        "https://raw.githubusercontent.com/$($quickstartDependency.Repository)/$($quickstartDependency.Commit)/$($quickstartDependency.TemplatePath)"
    )
}
if ($TemplateUri.Scheme -ne 'https') {
    throw 'The Azure Local deployment template must be downloaded over HTTPS.'
}
if ($LcmCredential.UserName -ne $configuration.Domain.DeploymentUserName) {
    throw "LcmCredential username must be '$($configuration.Domain.DeploymentUserName)'."
}
$context = Get-Content -LiteralPath $DeploymentContextPath -Raw | ConvertFrom-Json
$arcState = Get-Content -LiteralPath $ArcStatePath -Raw | ConvertFrom-Json
$managementState = Get-Content -LiteralPath $ManagementStatePath -Raw | ConvertFrom-Json

if ($arcState.phase -ne 'AzureLocalNodesArcConnected') {
    throw "Arc registration phase is '$($arcState.phase)', not 'AzureLocalNodesArcConnected'."
}
if (@($arcState.machines | Where-Object Status -ne 'Connected').Count -gt 0) {
    throw 'Both Azure Local nodes must be connected in Azure Arc before cloud deployment.'
}
if ($managementState.phase -ne 'ManagementPlaneReady') {
    throw "Management-plane phase is '$($managementState.phase)', not 'ManagementPlaneReady'."
}

$deploymentParameters = Get-AzureDeploymentParameter `
    -Configuration $configuration `
    -Context $context `
    -ArcState $arcState `
    -ManagementState $managementState `
    -LocalCredential $LocalAdministratorCredential `
    -DeploymentCredential $LcmCredential `
    -DeploymentMode $Mode

if ($GenerateParametersOnly) {
    $redactedParameters = [ordered]@{}
    foreach ($parameterName in @($deploymentParameters.Keys | Sort-Object)) {
        $redactedParameters[$parameterName] = if ($parameterName -match '(?i)password') {
            '<secure>'
        }
        else {
            $deploymentParameters[$parameterName]
        }
    }

    return $redactedParameters
}

Install-RequiredAzModule `
    -Name $dependencies.PowerShellModules.AzAccounts.Name `
    -Version $dependencies.PowerShellModules.AzAccounts.Version
Install-RequiredAzModule `
    -Name $dependencies.PowerShellModules.AzResources.Name `
    -Version $dependencies.PowerShellModules.AzResources.Version
Import-Module `
    -Name $dependencies.PowerShellModules.AzAccounts.Name `
    -RequiredVersion $dependencies.PowerShellModules.AzAccounts.Version `
    -Force
Import-Module `
    -Name $dependencies.PowerShellModules.AzResources.Name `
    -RequiredVersion $dependencies.PowerShellModules.AzResources.Version `
    -Force

$null = Connect-AzAccount `
    -Identity `
    -Tenant $context.tenantId `
    -Subscription $context.subscriptionId

New-Item -Path $ArtifactsPath -ItemType Directory -Force | Out-Null
$templatePath = Join-Path $ArtifactsPath 'azure-local-create-cluster.json'
$templateDownloadPath = "${templatePath}.download"
try {
    Invoke-WebRequest -Uri $TemplateUri -OutFile $templateDownloadPath -UseBasicParsing
    $template = Get-Content -LiteralPath $templateDownloadPath -Raw | ConvertFrom-Json

    $requiredTemplateParameters = @(
        'AzureStackLCMAdminPassword'
        'AzureStackLCMAdminUsername'
        'clusterName'
        'diagnosticStorageAccountName'
        'enableStorageAutoIp'
        'hciResourceProviderObjectID'
        'keyVaultName'
        'localAdminPassword'
        'localAdminUserName'
    )
    $missingTemplateParameters = @(
        $requiredTemplateParameters |
            Where-Object { $_ -notin $template.parameters.PSObject.Properties.Name }
    )
    if ($missingTemplateParameters.Count -gt 0) {
        throw "The maintained template contract changed. Missing parameters: $($missingTemplateParameters -join ', ')."
    }

    Move-Item -LiteralPath $templateDownloadPath -Destination $templatePath -Force
}
finally {
    Remove-Item -LiteralPath $templateDownloadPath -Force -ErrorAction SilentlyContinue
}

$templateHash = (Get-FileHash -LiteralPath $templatePath -Algorithm SHA256).Hash
if (-not $PSBoundParameters.ContainsKey('TemplateUri') -and
    $templateHash -ne $quickstartDependency.Sha256) {
    throw "Pinned Quickstart template checksum mismatch. Expected $($quickstartDependency.Sha256); received $templateHash."
}

$validationDeploymentName = 'azure-local-validate'
if ($Mode -eq 'Deploy') {
    $validationStatePath = 'C:\AzureLocalSandbox\State\azure-local-deployment.json'
    if (-not (Test-Path -LiteralPath $validationStatePath)) {
        throw 'Local validation state was not found. Execute this script with -Mode Validate first.'
    }
    $validationState = Get-Content -LiteralPath $validationStatePath -Raw | ConvertFrom-Json
    if ($validationState.phase -ne 'AzureLocalValidated' -or
        $validationState.templateSha256 -ne $templateHash) {
        throw 'The current maintained template revision differs from the successfully validated revision. Run Validate with this revision before Deploy.'
    }

    $validationDeployment = Get-AzResourceGroupDeployment `
        -ResourceGroupName $context.resourceGroupName `
        -Name $validationDeploymentName `
        -ErrorAction SilentlyContinue
    if (-not $validationDeployment -or $validationDeployment.ProvisioningState -ne 'Succeeded') {
        throw "Deployment requires a successful '$validationDeploymentName' run. Execute this script with -Mode Validate first."
    }
}

$deploymentName = if ($Mode -eq 'Validate') {
    $validationDeploymentName
}
else {
    'azure-local-deploy'
}

$deployment = New-AzResourceGroupDeployment `
    -Name $deploymentName `
    -ResourceGroupName $context.resourceGroupName `
    -TemplateFile $templatePath `
    -TemplateParameterObject $deploymentParameters `
    -Mode Incremental `
    -ErrorAction Stop

if ($deployment.ProvisioningState -ne 'Succeeded') {
    throw "Azure Local $Mode deployment finished in state '$($deployment.ProvisioningState)'."
}

$stateFile = 'C:\AzureLocalSandbox\State\azure-local-deployment.json'
[ordered]@{
    phase             = if ($Mode -eq 'Validate') { 'AzureLocalValidated' } else { 'AzureLocalDeployed' }
    mode              = $Mode
    deploymentName    = $deploymentName
    provisioningState = $deployment.ProvisioningState
    correlationId     = $deployment.CorrelationId
    templateUri       = $TemplateUri.AbsoluteUri
    templateSha256    = $templateHash
    updatedAt         = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $stateFile -Encoding UTF8

[pscustomobject]@{
    Mode              = $Mode
    DeploymentName    = $deploymentName
    ProvisioningState = $deployment.ProvisioningState
    CorrelationId     = $deployment.CorrelationId
    TemplateSha256    = $templateHash
} | Format-List