#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Checks the Azure-side prerequisites that would otherwise only fail hours into a deployment.

.DESCRIPTION
The managed-identity sign-in and the soft-deleted key vault collision are both first exercised by
Deploy-AzureLocal.ps1, which runs after the images, guests, management plane and Arc registration are
already built. Running the same checks up front turns a six-hour failure into a first-minute one.
#>

[CmdletBinding()]
param(
    [string]$DeploymentContextPath = 'C:\AzureLocalSandbox\State\deployment-context.json',

    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..\config\lab.psd1'),

    [string]$DependenciesPath = (Join-Path $PSScriptRoot '..\config\dependencies.psd1'),

    [string]$ReportPath = 'C:\AzureLocalSandbox\State\preflight.json',

    # Purging is irreversible, so a blocking vault is reported rather than removed unless this is set.
    [switch]$PurgeSoftDeletedKeyVault
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$results = [System.Collections.Generic.List[object]]::new()

function Write-Step {
    param(
        [Parameter(Mandatory)]
        [string]$Message
    )

    Write-Information "[$((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))] $Message" -InformationAction Continue
}

function Add-PreflightCheck {
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

function Get-StableSuffix {
    # Mirrors Get-StableSuffix in Deploy-AzureLocal.ps1; CloudContract.Tests.ps1 asserts they agree.
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

function Get-PreflightKeyVaultName {
    param(
        [Parameter(Mandatory)][string]$SubscriptionId,
        [Parameter(Mandatory)][string]$ResourceGroupName
    )

    return "azlsb-$(Get-StableSuffix -InputValue "$SubscriptionId/$ResourceGroupName")-kv"
}

$dependencies = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $DependenciesPath)
if ($dependencies.SchemaVersion -ne 1) {
    throw "Unsupported dependency schema '$($dependencies.SchemaVersion)'."
}

$contextPresent = Test-Path -LiteralPath $DeploymentContextPath
Add-PreflightCheck `
    -Name 'Deployment context' `
    -Passed $contextPresent `
    -Detail $(if ($contextPresent) { $DeploymentContextPath } else { "Missing: $DeploymentContextPath" })

if (-not $contextPresent) {
    $results | Format-Table -AutoSize
    throw 'The deployment context is required before any Azure preflight check can run.'
}

$context = Get-Content -LiteralPath $DeploymentContextPath -Raw | ConvertFrom-Json
$requiredContextFields = @('subscriptionId', 'tenantId', 'resourceGroupName', 'azureLocation')
$missingContextFields = @(
    $requiredContextFields |
        Where-Object { -not ($context.PSObject.Properties.Name -contains $_) -or -not $context.$_ }
)
Add-PreflightCheck `
    -Name 'Deployment context fields' `
    -Passed ($missingContextFields.Count -eq 0) `
    -Detail $(if ($missingContextFields.Count) { "Missing: $($missingContextFields -join ', ')" } else { $requiredContextFields -join ', ' })

$supportedRegions = @($dependencies.AzureLocal.SupportedRegions)
$regionSupported = $context.azureLocation -in $supportedRegions
Add-PreflightCheck `
    -Name 'Azure Local region' `
    -Passed $regionSupported `
    -Detail $(if ($regionSupported) { $context.azureLocation } else { "'$($context.azureLocation)' is not one of: $($supportedRegions -join ', ')" })

$configuration = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $ConfigurationPath)
$nodeCount = @($configuration.VMs | Where-Object Role -eq 'AzureLocalNode').Count
Add-PreflightCheck `
    -Name 'Lab topology' `
    -Passed ($nodeCount -eq 2) `
    -Detail "$nodeCount Azure Local node(s) defined (2 required)"

if ($missingContextFields.Count -gt 0) {
    $results | Format-Table -AutoSize
    throw 'The deployment context is incomplete, so the Azure checks cannot run.'
}

Import-Module `
    -Name $dependencies.PowerShellModules.AzAccounts.Name `
    -RequiredVersion $dependencies.PowerShellModules.AzAccounts.Version `
    -Force

Write-Step 'Signing in to Azure with the host managed identity...'
$signedIn = $false
$azureContext = $null
try {
    $null = Connect-AzAccount `
        -Identity `
        -Tenant $context.tenantId `
        -Subscription $context.subscriptionId
    $azureContext = Get-AzContext
    $signedIn = $null -ne $azureContext
}
catch {
    Add-PreflightCheck `
        -Name 'Managed identity sign-in' `
        -Passed $false `
        -Detail "$($_.Exception.Message)"
}

if ($signedIn) {
    Add-PreflightCheck `
        -Name 'Managed identity sign-in' `
        -Passed $true `
        -Detail "$($azureContext.Account.Id)"

    $subscriptionMatches = $azureContext.Subscription.Id -eq $context.subscriptionId
    Add-PreflightCheck `
        -Name 'Subscription context' `
        -Passed $subscriptionMatches `
        -Detail $(if ($subscriptionMatches) { $context.subscriptionId } else { "Signed in to '$($azureContext.Subscription.Id)', expected '$($context.subscriptionId)'" })

    $resourceGroupResponse = Invoke-AzRestMethod `
        -Method GET `
        -Path "/subscriptions/$($context.subscriptionId)/resourcegroups/$($context.resourceGroupName)?api-version=2021-04-01" `
        -ErrorAction SilentlyContinue
    $resourceGroupReadable = $resourceGroupResponse -and $resourceGroupResponse.StatusCode -eq 200
    Add-PreflightCheck `
        -Name 'Sandbox resource group' `
        -Passed ([bool]$resourceGroupReadable) `
        -Detail $(if ($resourceGroupReadable) { $context.resourceGroupName } else { "Cannot read '$($context.resourceGroupName)'; the managed identity may lack a role assignment" })

    # The vault name is derived from subscription and resource group, so a rebuilt group hits its own
    # soft-deleted vault. Deploy-AzureLocal.ps1 only discovers this after Arc registration completes.
    $keyVaultName = Get-PreflightKeyVaultName `
        -SubscriptionId $context.subscriptionId `
        -ResourceGroupName $context.resourceGroupName
    $deletedVaultResponse = Invoke-AzRestMethod `
        -Method GET `
        -Path "/subscriptions/$($context.subscriptionId)/providers/Microsoft.KeyVault/locations/$($context.azureLocation)/deletedVaults/$keyVaultName?api-version=2023-07-01" `
        -ErrorAction SilentlyContinue
    $vaultBlocked = $deletedVaultResponse -and $deletedVaultResponse.StatusCode -eq 200
    $purgeInstruction = "Purge it first: az keyvault purge --name $keyVaultName --location $($context.azureLocation)"

    if ($vaultBlocked -and $PurgeSoftDeletedKeyVault) {
        Write-Step "Purging the soft-deleted key vault '$keyVaultName'..."
        $purgeResponse = Invoke-AzRestMethod `
            -Method POST `
            -Path "/subscriptions/$($context.subscriptionId)/providers/Microsoft.KeyVault/locations/$($context.azureLocation)/deletedVaults/$keyVaultName/purge?api-version=2023-07-01" `
            -ErrorAction SilentlyContinue
        if ($purgeResponse -and $purgeResponse.StatusCode -in @(200, 202, 204)) {
            $vaultBlocked = $false
            Add-PreflightCheck -Name 'Key vault name available' -Passed $true -Detail "Purged '$keyVaultName'"
        }
        else {
            $purgeStatus = if ($purgeResponse) { $purgeResponse.StatusCode } else { 'no response' }
            Add-PreflightCheck `
                -Name 'Key vault name available' `
                -Passed $false `
                -Detail "Purge of '$keyVaultName' returned '$purgeStatus'. $purgeInstruction"
        }
    }
    else {
        Add-PreflightCheck `
            -Name 'Key vault name available' `
            -Passed (-not $vaultBlocked) `
            -Detail $(if ($vaultBlocked) { "'$keyVaultName' is soft-deleted in '$($context.azureLocation)'. $purgeInstruction" } else { $keyVaultName })
    }
}

$results | Format-Table -AutoSize

$reportDirectory = Split-Path -Parent $ReportPath
if ($reportDirectory) {
    New-Item -Path $reportDirectory -ItemType Directory -Force | Out-Null
}
$failedChecks = @($results | Where-Object { -not $_.Passed })
[ordered]@{
    phase     = if ($failedChecks.Count -eq 0) { 'PreflightPassed' } else { 'PreflightFailed' }
    updatedAt = (Get-Date).ToUniversalTime().ToString('o')
    checks    = @($results)
} | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $ReportPath -Encoding UTF8

if ($failedChecks.Count -gt 0) {
    throw "$($failedChecks.Count) deployment preflight check(s) failed. See $ReportPath."
}

Write-Information 'Deployment preflight checks passed.' -InformationAction Continue
