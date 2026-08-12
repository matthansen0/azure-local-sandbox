#Requires -Version 7.2

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$dependencies = Import-PowerShellDataFile (Join-Path $repoRoot 'config/dependencies.psd1')

foreach ($moduleDependency in @(
    $dependencies.PowerShellModules.Pester
    $dependencies.PowerShellModules.PSScriptAnalyzer
)) {
    if (-not (Get-Module -ListAvailable -Name $moduleDependency.Name | Where-Object Version -eq ([version]$moduleDependency.Version))) {
        Install-Module `
            -Name $moduleDependency.Name `
            -RequiredVersion $moduleDependency.Version `
            -Scope CurrentUser `
            -Force `
            -AllowClobber
    }
}

$binDirectory = Join-Path $HOME '.local/bin'
$bicepPath = Join-Path $binDirectory 'bicep'
$installBicep = -not (Test-Path -LiteralPath $bicepPath)
if (-not $installBicep) {
    $actualHash = (Get-FileHash -LiteralPath $bicepPath -Algorithm SHA256).Hash
    $installBicep = $actualHash -ne $dependencies.Bicep.Sha256
}

if ($installBicep) {
    New-Item -ItemType Directory -Path $binDirectory -Force | Out-Null
    Invoke-WebRequest -Uri $dependencies.Bicep.DownloadUri -OutFile $bicepPath
    $actualHash = (Get-FileHash -LiteralPath $bicepPath -Algorithm SHA256).Hash
    if ($actualHash -ne $dependencies.Bicep.Sha256) {
        Remove-Item -LiteralPath $bicepPath -Force
        throw "Bicep hash mismatch. Expected $($dependencies.Bicep.Sha256), got $actualHash."
    }
    chmod +x $bicepPath
}

Write-Information 'Development dependencies are ready.' -InformationAction Continue