#Requires -Version 7.2

[CmdletBinding()]
param(
    [ValidateSet('Validate', 'WhatIf', 'Deploy')]
    [string]$Mode = 'Deploy',

    [string]$Location = 'eastus',

    [string]$AzureLocalLocation = $Location,

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

function Invoke-AzureCliWithRetry {
    param(
        [Parameter(Mandatory)]
        [string[]]$Arguments,

        [Parameter(Mandatory)]
        [string]$Activity,

        [int]$MaxAttempts = 20,

        [int]$DelaySeconds = 15
    )

    for ($attempt = 1; ; $attempt++) {
        try {
            return Invoke-AzureCli -Arguments $Arguments
        }
        catch {
            if ($attempt -ge $MaxAttempts) {
                throw
            }
            Write-Step "$Activity failed on attempt $attempt of $MaxAttempts; retrying in $DelaySeconds seconds."
            Start-Sleep -Seconds $DelaySeconds
        }
    }
}

function Get-DeploymentPrincipal {
    param(
        [Parameter(Mandatory)]$Account
    )

    switch ($Account.user.type) {
        'user' {
            $objectId = Invoke-AzureCli `
                -Arguments @('ad', 'signed-in-user', 'show', '--query', 'id', '--only-show-errors', '--output', 'tsv')
            $principalType = 'User'
        }
        'servicePrincipal' {
            $objectId = Invoke-AzureCli `
                -Arguments @('ad', 'sp', 'show', '--id', $Account.user.name, '--query', 'id', '--only-show-errors', '--output', 'tsv')
            $principalType = 'ServicePrincipal'
        }
        default {
            throw "Unsupported Azure CLI principal type '$($Account.user.type)'. Sign in as a user or service principal."
        }
    }

    $objectId = ($objectId -join '').Trim()
    if (-not $objectId) {
        throw 'Unable to resolve the signed-in principal used to stage deployment artifacts.'
    }

    return [pscustomobject]@{
        ObjectId      = $objectId
        PrincipalType = $principalType
    }
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

function Get-SourceSnapshot {
    param(
        [string]$Revision,
        [Parameter(Mandatory)][string]$RepositoryRoot
    )

    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) {
        throw 'Git is required to package immutable deployment artifacts. Supply both explicit artifact URIs to bypass local packaging.'
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

    $snapshotRoot = Join-Path ([IO.Path]::GetTempPath()) "azure-local-sandbox-$([guid]::NewGuid())"
    New-Item -Path $snapshotRoot -ItemType Directory | Out-Null
    $bootstrapPath = Join-Path $snapshotRoot 'Bootstrap.ps1'
    $archivePath = Join-Path $snapshotRoot 'source.zip'

    $bootstrapContent = & $git.Source -C $RepositoryRoot show "${Revision}:scripts/Bootstrap.ps1"
    if ($LASTEXITCODE -ne 0) {
        Remove-Item -LiteralPath $snapshotRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw "Bootstrap.ps1 was not found in commit '$Revision'."
    }
    [IO.File]::WriteAllLines($bootstrapPath, [string[]]$bootstrapContent, [Text.UTF8Encoding]::new($false))

    & $git.Source -C $RepositoryRoot archive --format=zip --output=$archivePath $Revision
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $archivePath)) {
        Remove-Item -LiteralPath $snapshotRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw "Unable to create a source archive for commit '$Revision'."
    }

    return [pscustomobject]@{
        Root          = $snapshotRoot
        BootstrapPath = $bootstrapPath
        ArchivePath   = $archivePath
        BootstrapHash = (Get-FileHash -LiteralPath $bootstrapPath -Algorithm SHA256).Hash
        ArchiveHash   = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash
        Revision      = $Revision.ToLowerInvariant()
    }
}

function Publish-PrivateArtifact {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroup,
        [Parameter(Mandatory)][string]$AzureLocation,
        [Parameter(Mandatory)]$Principal
    )

    Write-Step "Ensuring resource group $ResourceGroup in $AzureLocation..."
    Invoke-AzureCli `
        -Arguments @(
            'group', 'create',
            '--name', $ResourceGroup,
            '--location', $AzureLocation,
            '--only-show-errors',
            '--output', 'none'
        ) | Out-Null

    $nameSeed = "$SubscriptionId/$ResourceGroup/$($Snapshot.Revision)"
    $seedBytes = [Text.Encoding]::UTF8.GetBytes($nameSeed)
    $sha256 = [Security.Cryptography.SHA256]::Create()
    try {
        $suffix = (($sha256.ComputeHash($seedBytes)[0..8] | ForEach-Object { $_.ToString('x2') }) -join '')
    }
    finally {
        $sha256.Dispose()
    }
    $storageAccountName = "azlsb${suffix}"

    Write-Step "Creating artifact storage account $storageAccountName (this can take a minute)..."
    $storageAccountId = Invoke-AzureCli `
        -Arguments @(
            'storage', 'account', 'create',
            '--name', $storageAccountName,
            '--resource-group', $ResourceGroup,
            '--location', $AzureLocation,
            '--sku', 'Standard_LRS',
            '--kind', 'StorageV2',
            '--https-only', 'true',
            '--min-tls-version', 'TLS1_2',
            '--allow-blob-public-access', 'false',
            '--allow-shared-key-access', 'false',
            '--query', 'id',
            '--only-show-errors',
            '--output', 'tsv'
        )
    $storageAccountId = ($storageAccountId -join '').Trim()
    if (-not $storageAccountId) {
        throw 'Unable to resolve the private artifact storage account resource ID.'
    }

    # Shared key access stays disabled, so the staging principal needs data-plane RBAC.
    Write-Step "Granting Storage Blob Data Contributor to $($Principal.PrincipalType) $($Principal.ObjectId)..."
    try {
        Invoke-AzureCli `
            -Arguments @(
                'role', 'assignment', 'create',
                '--assignee-object-id', $Principal.ObjectId,
                '--assignee-principal-type', $Principal.PrincipalType,
                '--role', 'Storage Blob Data Contributor',
                '--scope', $storageAccountId,
                '--only-show-errors',
                '--output', 'none'
            ) | Out-Null
    }
    catch {
        if ($_.Exception.Message -notmatch 'RoleAssignmentExists') {
            throw
        }
    }

    $containerName = 'deployment-artifacts'
    Write-Step "Creating container $containerName (waiting for role assignment propagation if needed)..."
    Invoke-AzureCliWithRetry `
        -Activity 'Container creation' `
        -Arguments @(
            'storage', 'container', 'create',
            '--name', $containerName,
            '--account-name', $storageAccountName,
            '--auth-mode', 'login',
            '--public-access', 'off',
            '--only-show-errors',
            '--output', 'none'
        ) | Out-Null

    foreach ($artifact in @(
        @{ Name = 'Bootstrap.ps1'; Path = $Snapshot.BootstrapPath }
        @{ Name = 'source.zip'; Path = $Snapshot.ArchivePath }
    )) {
        Write-Step "Uploading $($artifact.Name)..."
        Invoke-AzureCli `
            -Arguments @(
                'storage', 'blob', 'upload',
                '--container-name', $containerName,
                '--name', $artifact.Name,
                '--file', $artifact.Path,
                '--account-name', $storageAccountName,
                '--auth-mode', 'login',
                '--overwrite', 'true',
                '--only-show-errors',
                '--output', 'none'
            ) | Out-Null
    }

    Write-Step 'Generating read-only user delegation SAS URLs...'
    $expiry = (Get-Date).ToUniversalTime().AddHours(24).ToString('yyyy-MM-ddTHH:mmZ')
    $bootstrapSas = Invoke-AzureCli `
        -Arguments @(
            'storage', 'blob', 'generate-sas',
            '--container-name', $containerName,
            '--name', 'Bootstrap.ps1',
            '--account-name', $storageAccountName,
            '--auth-mode', 'login',
            '--as-user',
            '--permissions', 'r',
            '--expiry', $expiry,
            '--https-only',
            '--full-uri',
            '--only-show-errors',
            '--output', 'tsv'
        )
    $archiveSas = Invoke-AzureCli `
        -Arguments @(
            'storage', 'blob', 'generate-sas',
            '--container-name', $containerName,
            '--name', 'source.zip',
            '--account-name', $storageAccountName,
            '--auth-mode', 'login',
            '--as-user',
            '--permissions', 'r',
            '--expiry', $expiry,
            '--https-only',
            '--full-uri',
            '--only-show-errors',
            '--output', 'tsv'
        )

    return [pscustomobject]@{
        StorageAccountName = $storageAccountName
        BootstrapUri       = [uri](($bootstrapSas -join '').Trim())
        ArchiveUri         = [uri](($archiveSas -join '').Trim())
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

Write-Step "Installing Azure CLI Bicep $($dependencies.Bicep.Version)..."
Invoke-AzureCli `
    -Arguments @(
        'bicep', 'install',
        '--version', "v$($dependencies.Bicep.Version)",
        '--only-show-errors'
    ) | Out-Null
$bicepVersion = Invoke-AzureCli -Arguments @('bicep', 'version')
if (($bicepVersion -join ' ') -notmatch "\b$([regex]::Escape($dependencies.Bicep.Version))\b") {
    throw "Azure CLI Bicep version '$($dependencies.Bicep.Version)' is required; received '$($bicepVersion -join ' ')'."
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$sourceSnapshot = $null
$privateArtifactStage = $null
$usesExplicitArtifactUris = $BootstrapScriptUri -or $SourceArchiveUri
if (($BootstrapScriptUri -and -not $SourceArchiveUri) -or ($SourceArchiveUri -and -not $BootstrapScriptUri)) {
    throw 'Supply both BootstrapScriptUri and SourceArchiveUri, or neither.'
}
if (-not $usesExplicitArtifactUris) {
    Write-Step 'Packaging the committed source snapshot...'
    $sourceSnapshot = Get-SourceSnapshot -Revision $SourceRevision -RepositoryRoot $repoRoot
    Write-Step "Source revision: $($sourceSnapshot.Revision)"
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
    'Microsoft.ResourceConnector'
    'Microsoft.Storage'
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
if ($sourceSnapshot) {
    $env:AZURE_LOCAL_SANDBOX_BOOTSTRAP_SHA256 = $sourceSnapshot.BootstrapHash
    $env:AZURE_LOCAL_SANDBOX_SOURCE_SHA256 = $sourceSnapshot.ArchiveHash
}
else {
    Write-Step 'Hashing the supplied remote artifacts...'
    $env:AZURE_LOCAL_SANDBOX_BOOTSTRAP_SHA256 = Get-RemoteArtifactHash `
        -Uri $BootstrapScriptUri `
        -Name 'BootstrapScriptUri'
    $env:AZURE_LOCAL_SANDBOX_SOURCE_SHA256 = Get-RemoteArtifactHash `
        -Uri $SourceArchiveUri `
        -Name 'SourceArchiveUri'
}

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

try {
    if (-not $usesExplicitArtifactUris) {
        if ($Mode -eq 'Deploy') {
            Write-Step 'Staging private deployment artifacts...'
            $privateArtifactStage = Publish-PrivateArtifact `
                -Snapshot $sourceSnapshot `
                -SubscriptionId $account.id `
                -ResourceGroup $ResourceGroupName `
                -AzureLocation $Location `
                -Principal (Get-DeploymentPrincipal -Account $account)
            $BootstrapScriptUri = $privateArtifactStage.BootstrapUri
            $SourceArchiveUri = $privateArtifactStage.ArchiveUri
            Write-Step "Staged private deployment artifacts in $($privateArtifactStage.StorageAccountName)."
        }
        else {
            $BootstrapScriptUri = [uri]'https://validation.invalid/Bootstrap.ps1'
            $SourceArchiveUri = [uri]'https://validation.invalid/source.zip'
        }
    }

    $env:AZURE_LOCAL_SANDBOX_BOOTSTRAP_URI = $BootstrapScriptUri.AbsoluteUri
    $env:AZURE_LOCAL_SANDBOX_SOURCE_URI = $SourceArchiveUri.AbsoluteUri

    $commonArguments = @(
        '--name', $DeploymentName,
        '--location', $Location,
        '--template-file', $templateFile,
        '--parameters', $resolvedParameterFile,
        "location=$Location",
        "azureLocalLocation=$AzureLocalLocation",
        "resourceGroupName=$ResourceGroupName",
        "vmSize=$VmSize",
        "hostImageVersion=$HostImageVersion",
        '--only-show-errors'
    )

    Write-Step 'Validating subscription deployment...'
    Invoke-AzureCli `
        -Arguments (@('deployment', 'sub', 'validate') + $commonArguments + @('--output', 'none')) |
        Out-Null

    switch ($Mode) {
        'Validate' {
            Write-Step 'Deployment validation succeeded.'
        }
        'WhatIf' {
            Write-Step 'Running what-if analysis...'
            Invoke-AzureCli `
                -Arguments (@('deployment', 'sub', 'what-if') + $commonArguments + @('--output', 'jsonc'))
        }
        'Deploy' {
            Write-Step 'Creating Azure Local sandbox host. The template takes roughly 20-30 minutes; track progress in the portal deployment blade.'
            $deployment = Invoke-AzureCli `
                -Arguments (@('deployment', 'sub', 'create') + $commonArguments + @('--output', 'json')) `
                -ParseJson

            Write-Step 'Deployment completed.'
            $deployment.properties.outputs | ConvertTo-Json -Depth 10
        }
    }
}
finally {
    if ($sourceSnapshot) {
        Remove-Item -LiteralPath $sourceSnapshot.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($privateArtifactStage) {
        Write-Step "Removing temporary artifact storage account $($privateArtifactStage.StorageAccountName)..."
        Invoke-AzureCli `
            -Arguments @(
                'storage', 'account', 'delete',
                '--name', $privateArtifactStage.StorageAccountName,
                '--resource-group', $ResourceGroupName,
                '--yes',
                '--only-show-errors'
            ) | Out-Null
    }
}