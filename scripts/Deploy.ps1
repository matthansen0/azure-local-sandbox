#Requires -Version 7.2

[CmdletBinding()]
param(
    [ValidateSet('Validate', 'WhatIf', 'Deploy')]
    [string]$Mode = 'Deploy',

    [string]$Location = 'centralus',

    [string]$AzureLocalLocation = 'eastus',

    [ValidateSet('Auto', 'Developer', 'Basic', 'Standard')]
    [string]$BastionSku = 'Auto',

    [ValidateSet('Standard_E32s_v5', 'Standard_E32s_v6')]
    [string]$VmSize = 'Standard_E32s_v6',

    [string]$HostImageVersion,

    [string]$ParameterFile = (Join-Path $PSScriptRoot '..' 'infra' 'main.bicepparam'),

    [string]$DependenciesPath = (Join-Path $PSScriptRoot '..' 'config' 'dependencies.psd1'),

    [string]$ResourceGroupName = 'rg-azure-local-sandbox',

    [string]$DeploymentName = "azure-local-sandbox-$(Get-Date -Format 'yyyyMMdd-HHmmss')",

    [uri]$BootstrapScriptUri,

    [uri]$SourceArchiveUri,

    [ValidatePattern('^[0-9a-fA-F]{40}$')]
    [string]$SourceRevision,

    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$HciResourceProviderObjectId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Information "[$((Get-Date).ToString('HH:mm:ss'))] $Message" -InformationAction Continue
}

function Invoke-AzureCli {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [switch]$ParseJson
    )

    Write-Verbose "az $($Arguments -join ' ')"
    $output = & $script:AzureCliPath @Arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: $($output -join [Environment]::NewLine)"
    }

    if ($ParseJson) {
        return ($output -join [Environment]::NewLine) | ConvertFrom-Json
    }

    return $output
}

function Get-InstalledBicepVersion {
    $output = & $script:AzureCliPath @('bicep', 'version') 2>&1
    if ($LASTEXITCODE -ne 0) {
        return $null
    }
    if (($output -join ' ') -match 'Bicep CLI version\s+(?<version>\d+\.\d+\.\d+)') {
        return $Matches['version']
    }

    return $null
}

function Install-BicepCli {
    param(
        [Parameter(Mandatory)][string]$Version,
        [int]$MaxAttempts = 3
    )

    # When this is set, az resolves Bicep from PATH and silently ignores --version.
    $binaryFromPath = & $script:AzureCliPath @(
        'config', 'get', 'bicep.use_binary_from_path',
        '--query', 'value', '--output', 'tsv'
    ) 2>$null
    $binaryFromPath = ($binaryFromPath -join '').Trim()
    if ($LASTEXITCODE -eq 0 -and $binaryFromPath -and $binaryFromPath -notmatch '^(?i:false)$') {
        throw "Azure CLI is configured with bicep.use_binary_from_path='$binaryFromPath', so it uses whatever Bicep is on PATH instead of the pinned $Version. Run 'az config set bicep.use_binary_from_path=false' and retry."
    }

    $installed = Get-InstalledBicepVersion
    if ($installed -eq $Version) {
        Write-Step "Azure CLI Bicep $Version is already installed."
        return
    }

    $lastError = $null
    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        Write-Step "Installing Azure CLI Bicep $Version (attempt $attempt of $MaxAttempts)..."
        $output = & $script:AzureCliPath @(
            'bicep', 'install',
            '--version', "v$Version",
            '--only-show-errors'
        ) 2>&1
        if ($LASTEXITCODE -eq 0 -and (Get-InstalledBicepVersion) -eq $Version) {
            return
        }

        $lastError = ($output -join [Environment]::NewLine).Trim()
        Write-Warning "Bicep install attempt $attempt failed: $lastError"
        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds ([math]::Pow(2, $attempt) * 5)
        }
    }

    $guidance = @(
        "Unable to install Azure CLI Bicep $Version after $MaxAttempts attempts."
        "Azure CLI downloads it from https://github.com/Azure/bicep/releases/tag/v$Version into its own directory (~/.azure/bin), so a proxy, TLS inspection, or file permissions on that directory will block it."
        "Install it manually with 'az bicep install --version v$Version', then rerun this script; it skips the install when the pinned version is already present."
        "Last error: $lastError"
    )
    throw ($guidance -join [Environment]::NewLine)
}

function Register-SubscriptionFeature {
    param(
        [Parameter(Mandatory)][string]$Namespace,
        [Parameter(Mandatory)][string]$Name,
        [timespan]$Timeout = [timespan]::FromMinutes(15)
    )

    $state = ((Invoke-AzureCli -Arguments @(
                'feature', 'show',
                '--namespace', $Namespace,
                '--name', $Name,
                '--query', 'properties.state',
                '--only-show-errors',
                '--output', 'tsv'
            )) -join '').Trim()

    if ($state -eq 'Registered') {
        Write-Step "$Namespace/$Name is registered."
        return $false
    }

    Write-Step "Registering feature $Namespace/$Name (this can take several minutes)..."
    if ($state -ne 'Registering') {
        try {
            Invoke-AzureCli -Arguments @(
                'feature', 'register',
                '--namespace', $Namespace,
                '--name', $Name,
                '--only-show-errors',
                '--output', 'none'
            ) | Out-Null
        }
        catch {
            throw "Unable to register feature $Namespace/$Name. Subscription-level rights are required. $($_.Exception.Message)"
        }
    }

    $deadline = (Get-Date).Add($Timeout)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 30
        $state = ((Invoke-AzureCli -Arguments @(
                    'feature', 'show',
                    '--namespace', $Namespace,
                    '--name', $Name,
                    '--query', 'properties.state',
                    '--only-show-errors',
                    '--output', 'tsv'
                )) -join '').Trim()

        if ($state -eq 'Registered') {
            Write-Step "$Namespace/$Name is registered."
            return $true
        }

        Write-Step "$Namespace/$Name is $state..."
    }

    throw "Feature $Namespace/$Name did not reach the Registered state within $($Timeout.TotalMinutes) minutes. Rerun once the portal reports it as registered."
}

function Get-RemoteArtifactHash {
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [Parameter(Mandatory)][string]$Name
    )

    if ($Uri.Scheme -ne 'https') {
        throw "$Name must use HTTPS."
    }

    $downloadPath = Join-Path ([IO.Path]::GetTempPath()) "azure-local-sandbox-$([guid]::NewGuid())"
    try {
        Invoke-WebRequest -Uri $Uri -OutFile $downloadPath
        return (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256).Hash
    }
    finally {
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    }
}

function Test-MonitoringContainment {
    param(
        [Parameter(Mandatory)][string]$VirtualMachineId
    )

    # A subscription or management group DeployIfNotExists assignment can attach its own agent and data
    # collection rule to a brand new VM, which bills this lab's event log ingestion to a workspace the
    # sandbox does not own. Surface that here rather than on an invoice.
    $sandboxScope = ($VirtualMachineId -split '/providers/')[0]

    $associationResponse = Invoke-AzureCli `
        -Arguments @(
            'rest',
            '--method', 'get',
            '--url', "https://management.azure.com$VirtualMachineId/providers/Microsoft.Insights/dataCollectionRuleAssociations?api-version=2023-03-11",
            '--only-show-errors',
            '--output', 'json'
        ) `
        -ParseJson

    $associations = @()
    if ($associationResponse.PSObject.Properties['value']) {
        $associations = @($associationResponse.value)
    }

    $foreignRuleIds = @(
        $associations | ForEach-Object {
            # Endpoint-only associations carry no rule ID, so read the property defensively under StrictMode.
            $ruleProperty = $_.properties.PSObject.Properties['dataCollectionRuleId']
            if ($ruleProperty -and $ruleProperty.Value -and $ruleProperty.Value -notlike "$sandboxScope/*") {
                $ruleProperty.Value
            }
        }
    )

    $installedExtensions = @(
        Invoke-AzureCli `
            -Arguments @(
                'vm', 'extension', 'list',
                '--ids', $VirtualMachineId,
                '--query', '[].name',
                '--only-show-errors',
                '--output', 'json'
            ) `
            -ParseJson
    )
    $legacyAgents = @($installedExtensions | Where-Object { $_ -eq 'MicrosoftMonitoringAgent' })

    if ($foreignRuleIds.Count -eq 0 -and $legacyAgents.Count -eq 0) {
        Write-Step 'Monitoring containment verified: the host reports only sandbox-owned data collection rules.'
        return
    }

    foreach ($foreignRuleId in $foreignRuleIds) {
        Write-Warning "The host is associated with a data collection rule outside the sandbox resource group: $foreignRuleId. Its ingestion is billed to whichever workspace that rule targets, not to the sandbox workspace."
    }
    if ($legacyAgents.Count -gt 0) {
        Write-Warning 'The legacy Log Analytics agent (MicrosoftMonitoringAgent) is installed on the host. Microsoft Defender for Cloud auto-provisioning installs it and can stream the full Security event log off this lab.'
    }
    Write-Warning 'Identify the owner with "az policy assignment list --disable-scope-strict-match" and "az security workspace-setting list", then exempt the sandbox resource group.'
}

function Resolve-PublishedSource {
    param(
        [string]$Revision,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        throw 'Git is required to resolve the published deployment source. Supply both explicit artifact URIs to bypass Git.'
    }

    $worktreeStatus = & $git.Source -C $RepositoryRoot status --porcelain --untracked-files=normal
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to inspect the source Git worktree.'
    }
    if ($worktreeStatus) {
        throw 'The source worktree has uncommitted files. Commit the exact deployment source before deployment.'
    }

    if (-not $Revision) {
        $Revision = (& $git.Source -C $RepositoryRoot rev-parse HEAD).Trim()
    }
    if ($LASTEXITCODE -ne 0 -or $Revision -notmatch '^[0-9a-fA-F]{40}$') {
        throw 'Unable to resolve an immutable source commit.'
    }

    $Revision = $Revision.ToLowerInvariant()

    # The host VM pulls the source straight from GitHub, so the commit has to be published.
    $remoteBranches = & $git.Source -C $RepositoryRoot branch --remotes --contains $Revision
    if ($LASTEXITCODE -ne 0 -or -not $remoteBranches) {
        throw "Commit '$Revision' has not been pushed to a remote branch. Push it before deploying so the host can download the source."
    }

    $remoteUrl = (& $git.Source -C $RepositoryRoot remote get-url origin)
    if ($LASTEXITCODE -ne 0) {
        throw 'Unable to read the origin remote. Supply both explicit artifact URIs instead.'
    }
    $remoteUrl = ($remoteUrl -join '').Trim()
    if ($remoteUrl -notmatch '^(?:https://github\.com/|git@github\.com:)(?<owner>[^/]+)/(?<repo>[^/]+?)(?:\.git)?$') {
        throw "Origin '$remoteUrl' is not a GitHub repository. Supply both explicit artifact URIs instead."
    }
    $owner = $Matches['owner']
    $repository = $Matches['repo']

    return [pscustomobject]@{
        Revision     = $Revision
        Repository   = "$owner/$repository"
        BootstrapUri = [uri]"https://raw.githubusercontent.com/$owner/$repository/$Revision/scripts/Bootstrap.ps1"
        ArchiveUri   = [uri]"https://codeload.github.com/$owner/$repository/zip/$Revision"
    }
}

$azureCli = Get-Command 'az' -ErrorAction SilentlyContinue
if (-not $azureCli) {
    throw 'Azure CLI is required. Install it from https://aka.ms/installazurecli.'
}
$script:AzureCliPath = $azureCli.Source

Write-Step "Starting $Mode run for deployment $DeploymentName. Run with -Verbose to trace each Azure CLI call."

$dependencies = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $DependenciesPath)
if ($dependencies.SchemaVersion -ne 1) {
    throw "Unsupported dependency schema '$($dependencies.SchemaVersion)'."
}

$supportedAzureLocalRegions = @($dependencies.AzureLocal.SupportedRegions)
if ($AzureLocalLocation -notin $supportedAzureLocalRegions) {
    throw "Azure Local does not support the region '$AzureLocalLocation'. Choose one of: $($supportedAzureLocalRegions -join ', ')."
}

Install-BicepCli -Version $dependencies.Bicep.Version
$bicepVersion = Invoke-AzureCli -Arguments @('bicep', 'version')
if (($bicepVersion -join ' ') -notmatch "\b$([regex]::Escape($dependencies.Bicep.Version))\b") {
    throw "Azure CLI Bicep version '$($dependencies.Bicep.Version)' is required; received '$($bicepVersion -join ' ')'."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$usesExplicitArtifactUris = $BootstrapScriptUri -or $SourceArchiveUri
if (($BootstrapScriptUri -and -not $SourceArchiveUri) -or ($SourceArchiveUri -and -not $BootstrapScriptUri)) {
    throw 'Supply both BootstrapScriptUri and SourceArchiveUri, or neither.'
}
if (-not $usesExplicitArtifactUris) {
    Write-Step 'Resolving the published source commit on GitHub...'
    $publishedSource = Resolve-PublishedSource -Revision $SourceRevision -RepositoryRoot $repoRoot
    $BootstrapScriptUri = $publishedSource.BootstrapUri
    $SourceArchiveUri = $publishedSource.ArchiveUri
    Write-Step "Source: $($publishedSource.Repository)@$($publishedSource.Revision)"
}

if (-not $env:AZURE_LOCAL_SANDBOX_ADMIN_PASSWORD) {
    throw 'Set AZURE_LOCAL_SANDBOX_ADMIN_PASSWORD before running this command.'
}

if ($env:AZURE_LOCAL_SANDBOX_ADMIN_PASSWORD.Length -lt 12) {
    throw 'AZURE_LOCAL_SANDBOX_ADMIN_PASSWORD must contain at least 12 characters.'
}

$resolvedParameterFile = (Resolve-Path -LiteralPath $ParameterFile).Path
$templateFile = Join-Path (Split-Path -Parent $resolvedParameterFile) 'main.bicep'
if (-not (Test-Path -LiteralPath $templateFile)) {
    throw "Bicep entry point '$templateFile' was not found."
}

$account = Invoke-AzureCli `
    -Arguments @('account', 'show', '--only-show-errors', '--output', 'json') `
    -ParseJson
Write-Step "Subscription: $($account.name) ($($account.id))"

$providerNamespaces = @(
    'Microsoft.Attestation'
    'Microsoft.Authorization'
    'Microsoft.AzureStackHCI'
    'Microsoft.Compute'
    'Microsoft.EdgeMarketplace'
    'Microsoft.ExtendedLocation'
    'Microsoft.GuestConfiguration'
    'Microsoft.HybridCompute'
    'Microsoft.HybridConnectivity'
    'Microsoft.HybridContainerService'
    'Microsoft.Insights'
    'Microsoft.KeyVault'
    'Microsoft.Kubernetes'
    'Microsoft.KubernetesConfiguration'
    'Microsoft.Network'
    'Microsoft.OperationalInsights'
    'Microsoft.ResourceConnector'
    'Microsoft.Storage'
)

# Some subscriptions only allocate public IPs through this feature, which the NAT Gateway and Bastion both need.
$subscriptionFeatures = @(
    [pscustomobject]@{ Namespace = 'Microsoft.Network'; Name = 'AllowBringYourOwnPublicIpAddress' }
)

if ($Mode -eq 'Deploy') {
    Write-Step "Checking $($providerNamespaces.Count) resource provider registrations..."
    foreach ($providerNamespace in $providerNamespaces) {
        $provider = Invoke-AzureCli `
            -Arguments @('provider', 'show', '--namespace', $providerNamespace, '--output', 'json') `
            -ParseJson

        if ($provider.registrationState -ne 'Registered') {
            Write-Step "Registering $providerNamespace (this can take several minutes)..."
            Invoke-AzureCli `
                -Arguments @(
                    'provider', 'register',
                    '--namespace', $providerNamespace,
                    '--wait',
                    '--only-show-errors',
                    '--output', 'none'
                ) | Out-Null
        }
        else {
            Write-Step "$providerNamespace is registered."
        }
    }

    Write-Step "Checking $($subscriptionFeatures.Count) subscription feature registration(s)..."
    $featureRegistrationChanged = $false
    foreach ($feature in $subscriptionFeatures) {
        if (Register-SubscriptionFeature -Namespace $feature.Namespace -Name $feature.Name) {
            $featureRegistrationChanged = $true
        }
    }

    if ($featureRegistrationChanged) {
        # Feature flags only take effect after the owning provider re-reads them.
        Write-Step 'Propagating the new feature registrations to Microsoft.Network...'
        Invoke-AzureCli `
            -Arguments @(
                'provider', 'register',
                '--namespace', 'Microsoft.Network',
                '--wait',
                '--only-show-errors',
                '--output', 'none'
            ) | Out-Null
    }
}

if (-not $HciResourceProviderObjectId) {
    Write-Step 'Resolving the Azure Local resource provider service principal...'
    $HciResourceProviderObjectId = Invoke-AzureCli `
        -Arguments @(
            'ad', 'sp', 'list',
            '--filter', "appId eq '1412d89f-b8a8-4111-b4fd-e82905cbd85d'",
            '--query', '[0].id',
            '--only-show-errors',
            '--output', 'tsv'
        )
    $HciResourceProviderObjectId = ($HciResourceProviderObjectId -join '').Trim()
}
if (-not $HciResourceProviderObjectId) {
    throw "The Azure Local resource provider service principal was not found. Register Microsoft.AzureStackHCI first or pass -HciResourceProviderObjectId. Deploy mode registers providers automatically."
}
$env:AZURE_LOCAL_RESOURCE_PROVIDER_OBJECT_ID = $HciResourceProviderObjectId

Write-Step 'Hashing the published deployment artifacts...'
$env:AZURE_LOCAL_SANDBOX_BOOTSTRAP_SHA256 = Get-RemoteArtifactHash `
    -Uri $BootstrapScriptUri `
    -Name 'BootstrapScriptUri'
$env:AZURE_LOCAL_SANDBOX_SOURCE_SHA256 = Get-RemoteArtifactHash `
    -Uri $SourceArchiveUri `
    -Name 'SourceArchiveUri'
$env:AZURE_LOCAL_SANDBOX_BOOTSTRAP_URI = $BootstrapScriptUri.AbsoluteUri
$env:AZURE_LOCAL_SANDBOX_SOURCE_URI = $SourceArchiveUri.AbsoluteUri

Write-Step "Checking $VmSize availability in $Location..."
$availableSkus = @(
    Invoke-AzureCli `
        -Arguments @(
            'vm', 'list-skus',
            '--location', $Location,
            '--resource-type', 'virtualMachines',
            '--size', $VmSize,
            '--all',
            '--only-show-errors',
            '--output', 'json'
        ) `
        -ParseJson
)

$availableSku = $availableSkus |
    Where-Object { $_.name -eq $VmSize -and @($_.restrictions).Count -eq 0 } |
    Select-Object -First 1
if (-not $availableSku) {
    throw "VM size '$VmSize' is not available without restrictions in '$Location'."
}

if (-not $HostImageVersion) {
    Write-Step 'Resolving the latest Windows Server marketplace image version...'
    $image = $dependencies.OuterHostImage
    $HostImageVersion = Invoke-AzureCli `
        -Arguments @(
            'vm', 'image', 'list',
            '--location', $Location,
            '--publisher', $image.Publisher,
            '--offer', $image.Offer,
            '--sku', $image.Sku,
            '--all',
            '--query', 'sort_by(@, &version)[-1].version',
            '--only-show-errors',
            '--output', 'tsv'
        )
    $HostImageVersion = ($HostImageVersion -join '').Trim()
}
if (-not $HostImageVersion -or $HostImageVersion -eq 'latest') {
    throw 'An exact Windows Server marketplace image version could not be resolved.'
}
$env:AZURE_LOCAL_SANDBOX_HOST_IMAGE_VERSION = $HostImageVersion
Write-Step "Host image version: $HostImageVersion"

if ($BastionSku -eq 'Auto') {
    $developerRegions = @($dependencies.AzureBastion.DeveloperSkuRegions)
    $normalizedLocation = $Location.Replace(' ', '').ToLowerInvariant()
    $script:BastionSkuInUse = if ($developerRegions -contains $normalizedLocation) { 'Developer' } else { 'Standard' }
    Write-Step "Azure Bastion SKU: $script:BastionSkuInUse (auto-selected for $Location)."
}
else {
    $script:BastionSkuInUse = $BastionSku
    Write-Step "Azure Bastion SKU: $script:BastionSkuInUse (requested)."
}

# --parameters takes a variable-length list, so it stays last and every key=value override follows it.
$commonArguments = @(
    '--name', $DeploymentName,
    '--location', $Location,
    '--template-file', $templateFile,
    '--only-show-errors',
    '--parameters', $resolvedParameterFile,
    "location=$Location",
    "azureLocalLocation=$AzureLocalLocation",
    "resourceGroupName=$ResourceGroupName",
    "vmSize=$VmSize",
    "hostImageVersion=$HostImageVersion"
)

function Invoke-SandboxTemplate {
    param(
        [Parameter(Mandatory)][string[]]$Operation,
        [string[]]$ExtraArguments = @(),
        [switch]$ParseJson
    )

    # An auto-selected Developer SKU falls back to Standard when Azure rejects it in this region.
    $candidateSkus = @($script:BastionSkuInUse)
    if ($BastionSku -eq 'Auto' -and $script:BastionSkuInUse -eq 'Developer') {
        $candidateSkus += 'Standard'
    }

    for ($attempt = 0; $attempt -lt $candidateSkus.Count; $attempt++) {
        $candidateSku = $candidateSkus[$attempt]
        try {
            $result = Invoke-AzureCli `
                -Arguments (
                    @('deployment', 'sub') +
                    $Operation +
                    $commonArguments +
                    @("bastionSku=$candidateSku") +
                    $ExtraArguments
                ) `
                -ParseJson:$ParseJson
            $script:BastionSkuInUse = $candidateSku
            return $result
        }
        catch {
            $isCliUsageError = $_.Exception.Message -match '(?i)unrecognized arguments|invalid choice|expected one argument'
            if ($attempt -eq $candidateSkus.Count - 1 -or
                $isCliUsageError -or
                $_.Exception.Message -notmatch '(?i)bastion|developer') {
                throw
            }

            Write-Warning "Azure rejected the Developer Bastion SKU in '$Location'. Retrying with the Standard SKU. $($_.Exception.Message)"
        }
    }
}

Write-Step 'Validating subscription deployment...'
Invoke-SandboxTemplate -Operation @('validate') -ExtraArguments @('--output', 'none') |
    Out-Null

switch ($Mode) {
    'Validate' {
        Write-Step 'Deployment validation succeeded.'
    }
    'WhatIf' {
        Write-Step 'Running what-if analysis...'
        Invoke-SandboxTemplate -Operation @('what-if') -ExtraArguments @('--output', 'jsonc')
    }
    'Deploy' {
        Write-Step 'Creating Azure Local sandbox host. The template takes roughly 20-30 minutes; track progress in the portal deployment blade.'
        $deployment = Invoke-SandboxTemplate `
            -Operation @('create') `
            -ExtraArguments @('--output', 'json') `
            -ParseJson

        Write-Step 'Deployment completed.'
        $deployment.properties.outputs | ConvertTo-Json -Depth 10
        Test-MonitoringContainment -VirtualMachineId $deployment.properties.outputs.hostVirtualMachineId.value
    }
}