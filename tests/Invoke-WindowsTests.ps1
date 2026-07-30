#Requires -Version 5.1

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$dependencies = Import-PowerShellDataFile (Join-Path $repoRoot 'config\dependencies.psd1')
$pester = $dependencies.PowerShellModules.Pester

Import-Module -Name $pester.Name -RequiredVersion $pester.Version

# The Linux suite only ever parses these with the PowerShell 7 grammar.
foreach ($hostScript in Get-ChildItem (Join-Path $repoRoot 'scripts') -Filter '*.ps1' -Recurse) {
    $parseErrors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($hostScript.FullName, [ref]$null, [ref]$parseErrors)
    if ($parseErrors) {
        $parseErrors | ForEach-Object { Write-Warning "$($hostScript.Name): $($_.Message)" }
        throw "$($hostScript.Name) does not parse under Windows PowerShell $($PSVersionTable.PSVersion)."
    }
}

$pesterConfiguration = New-PesterConfiguration
$pesterConfiguration.Run.Path = Join-Path $PSScriptRoot 'Windows51.Tests.ps1'
$pesterConfiguration.Run.PassThru = $true
$pesterConfiguration.Output.Verbosity = 'Detailed'

$pesterResult = Invoke-Pester -Configuration $pesterConfiguration
if ($pesterResult.FailedCount -gt 0) {
    throw "$($pesterResult.FailedCount) Windows PowerShell test(s) failed."
}

Write-Information "Windows PowerShell validation passed: $($pesterResult.PassedCount) test(s)." -InformationAction Continue
