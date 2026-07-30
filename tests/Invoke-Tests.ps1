#Requires -Version 7.2

[CmdletBinding()]
param(
    [string]$BicepExecutable = 'bicep',

    [switch]$SkipBicep
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$dependencies = Import-PowerShellDataFile (Join-Path $repoRoot 'config/dependencies.psd1')

foreach ($moduleDependency in @(
    $dependencies.PowerShellModules.Pester
    $dependencies.PowerShellModules.PSScriptAnalyzer
)) {
    if (-not (Get-Module -ListAvailable -Name $moduleDependency.Name | Where-Object Version -eq ([version]$moduleDependency.Version))) {
        throw "PowerShell module '$($moduleDependency.Name)' version '$($moduleDependency.Version)' is required."
    }
}

Import-Module `
    -Name $dependencies.PowerShellModules.PSScriptAnalyzer.Name `
    -RequiredVersion $dependencies.PowerShellModules.PSScriptAnalyzer.Version
Import-Module `
    -Name $dependencies.PowerShellModules.Pester.Name `
    -RequiredVersion $dependencies.PowerShellModules.Pester.Version

$analysisIssues = @(
    Invoke-ScriptAnalyzer `
        -Path (Join-Path $repoRoot 'scripts') `
        -Recurse `
        -Severity Warning, Error
)
if ($analysisIssues.Count -gt 0) {
    $analysisIssues | Format-Table ScriptName, Line, RuleName, Severity, Message -Wrap
    throw "PSScriptAnalyzer reported $($analysisIssues.Count) issue(s)."
}

# Host scripts run under Windows PowerShell 5.1, so reject PowerShell 7 only syntax and cmdlets.
$compatibilityIssues = @(
    Invoke-ScriptAnalyzer `
        -Path (Join-Path $repoRoot 'scripts') `
        -Recurse `
        -IncludeRule PSUseCompatibleSyntax, PSUseCompatibleCmdlets `
        -Settings @{
            Rules = @{
                PSUseCompatibleSyntax  = @{ Enable = $true; TargetVersions = @('5.1') }
                PSUseCompatibleCmdlets = @{ Enable = $true; compatibility = @('desktop-5.1.14393.206-windows') }
            }
        }
)
if ($compatibilityIssues.Count -gt 0) {
    $compatibilityIssues | Format-Table ScriptName, Line, RuleName, Message -Wrap
    throw "PSScriptAnalyzer reported $($compatibilityIssues.Count) Windows PowerShell 5.1 compatibility issue(s)."
}

if (-not $SkipBicep) {
    $bicepCommand = Get-Command $BicepExecutable -ErrorAction SilentlyContinue
    if (-not $bicepCommand) {
        throw "Bicep executable '$BicepExecutable' was not found."
    }

    $bicepVersionOutput = & $bicepCommand.Source --version
    if (($bicepVersionOutput -join ' ') -notmatch "\b$([regex]::Escape($dependencies.Bicep.Version))\b") {
        throw "Bicep version '$($dependencies.Bicep.Version)' is required; received '$($bicepVersionOutput -join ' ')'."
    }

    foreach ($templatePath in @(
        'infra/modules/network.bicep'
        'infra/modules/host.bicep'
        'infra/main.bicep'
    )) {
        & $bicepCommand.Source build (Join-Path $repoRoot $templatePath) --stdout | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw "Bicep compilation failed for '$templatePath'."
        }
    }

    $previousPassword = $env:AZURE_LOCAL_SANDBOX_ADMIN_PASSWORD
    $previousProviderObjectId = $env:AZURE_LOCAL_RESOURCE_PROVIDER_OBJECT_ID
    $previousBootstrapHash = $env:AZURE_LOCAL_SANDBOX_BOOTSTRAP_SHA256
    $previousSourceHash = $env:AZURE_LOCAL_SANDBOX_SOURCE_SHA256
    $previousBootstrapUri = $env:AZURE_LOCAL_SANDBOX_BOOTSTRAP_URI
    $previousSourceUri = $env:AZURE_LOCAL_SANDBOX_SOURCE_URI
    $previousHostImageVersion = $env:AZURE_LOCAL_SANDBOX_HOST_IMAGE_VERSION
    try {
        $env:AZURE_LOCAL_SANDBOX_ADMIN_PASSWORD = 'Validation-Only-Password-42!'
        $env:AZURE_LOCAL_RESOURCE_PROVIDER_OBJECT_ID = '11111111-2222-3333-4444-555555555555'
        $env:AZURE_LOCAL_SANDBOX_BOOTSTRAP_SHA256 = 'A' * 64
        $env:AZURE_LOCAL_SANDBOX_SOURCE_SHA256 = 'B' * 64
        $env:AZURE_LOCAL_SANDBOX_BOOTSTRAP_URI = 'https://example.invalid/Bootstrap.ps1'
        $env:AZURE_LOCAL_SANDBOX_SOURCE_URI = 'https://example.invalid/source.zip'
        $env:AZURE_LOCAL_SANDBOX_HOST_IMAGE_VERSION = '2030.01.01'
        & $bicepCommand.Source build-params (Join-Path $repoRoot 'infra/main.bicepparam') --stdout | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Bicep parameter compilation failed.'
        }
    }
    finally {
        $env:AZURE_LOCAL_SANDBOX_ADMIN_PASSWORD = $previousPassword
        $env:AZURE_LOCAL_RESOURCE_PROVIDER_OBJECT_ID = $previousProviderObjectId
        $env:AZURE_LOCAL_SANDBOX_BOOTSTRAP_SHA256 = $previousBootstrapHash
        $env:AZURE_LOCAL_SANDBOX_SOURCE_SHA256 = $previousSourceHash
        $env:AZURE_LOCAL_SANDBOX_BOOTSTRAP_URI = $previousBootstrapUri
        $env:AZURE_LOCAL_SANDBOX_SOURCE_URI = $previousSourceUri
        $env:AZURE_LOCAL_SANDBOX_HOST_IMAGE_VERSION = $previousHostImageVersion
    }
}

$pesterConfiguration = New-PesterConfiguration
$pesterConfiguration.Run.Path = $PSScriptRoot
$pesterConfiguration.Run.PassThru = $true
$pesterConfiguration.Output.Verbosity = 'Detailed'
$pesterConfiguration.TestResult.Enabled = $true
$pesterConfiguration.TestResult.OutputPath = Join-Path $repoRoot 'TestResults/Pester.xml'
$pesterConfiguration.TestResult.OutputFormat = 'NUnitXml'

$pesterResult = Invoke-Pester -Configuration $pesterConfiguration
if ($pesterResult.FailedCount -gt 0) {
    throw "$($pesterResult.FailedCount) Pester test(s) failed."
}

Write-Information "Validation passed: $($pesterResult.PassedCount) Pester tests." -InformationAction Continue