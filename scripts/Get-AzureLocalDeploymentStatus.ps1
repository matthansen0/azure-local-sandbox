#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
    .SYNOPSIS
    Reports Azure Local cloud deployment progress and the real Arc Resource Bridge failure.

    .DESCRIPTION
    The Azure portal surfaces a misleading error when the Arc Resource Bridge (ARB) step fails,
    because Get-ArcHciPreCheckFailureDetails in Microsoft's LCM helper calls .Trim() on an
    ErrorRecord and throws before the genuine precheck message is reported. This script reads the
    node-side LCM logs over PowerShell Direct and returns the underlying error instead, along with
    cluster and MOC cloud agent health.

    Read-only. Safe to run while a deployment is in flight.
#>

[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute(
    'PSUseUsingScopeModifierInNewRunspaces',
    '',
    Justification = 'PowerShell Direct script blocks receive serialized values through ArgumentList and declare them in local param blocks.'
)]
param(
    [Parameter(Mandatory)]
    [PSCredential]$LocalAdministratorCredential,

    [string]$ConfigurationPath = (Join-Path $PSScriptRoot '..\config\lab.psd1'),

    [int]$LogTailLines = 4000
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$configuration = Import-PowerShellDataFile -LiteralPath (Resolve-Path -LiteralPath $ConfigurationPath)
$nodeNames = @($configuration.VMs | Where-Object Role -eq 'AzureLocalNode' | ForEach-Object { $_.Name })

# The nodes are domain joined once cloud deployment starts, so the stored username no longer resolves
# for PowerShell Direct; the built-in account must be addressed in its local form.
$localCredential = New-Object `
    -TypeName System.Management.Automation.PSCredential `
    -ArgumentList '.\Administrator', $LocalAdministratorCredential.Password

function Get-NodeReport {
    param(
        [Parameter(Mandatory)][string]$NodeName,
        [Parameter(Mandatory)][PSCredential]$Credential,
        [Parameter(Mandatory)][int]$TailLines
    )

    $session = $null
    try {
        $session = New-PSSession -VMName $NodeName -Credential $Credential -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{
            Node       = $NodeName
            Reachable  = $false
            Detail     = $_.Exception.Message
            CloudAgent = $null
            ArbVms     = @()
            LastLog    = $null
            Failures   = @()
        }
    }

    try {
        return Invoke-Command -Session $session -ArgumentList $NodeName, $TailLines -ScriptBlock {
            param([string]$Name, [int]$Tail)

            $agent = Get-Service -Name 'wssdcloudagent' -ErrorAction SilentlyContinue
            $vms = @(Get-VM -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })

            $log = Get-ChildItem -LiteralPath 'C:\CloudDeployment\Logs' -Filter 'CloudDeployment*.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime -Descending |
                Select-Object -First 1

            $failures = @()
            if ($log) {
                # The genuine message is the errorCode/errorResponse pair emitted by the az arcappliance
                # call, not the Trim() exception that the LCM helper raises afterwards.
                $failures = @(
                    Get-Content -LiteralPath $log.FullName -Tail $Tail -ErrorAction SilentlyContinue |
                        Select-String -Pattern '"errorCode"|PrepareKvaTimeoutError|failed to create MOC session|Overall ArcHci Mgmt Precheck Result' |
                        ForEach-Object { $_.Line.Trim() } |
                        Select-Object -Last 5
                )
            }

            [pscustomobject]@{
                Node       = $Name
                Reachable  = $true
                Detail     = 'connected'
                CloudAgent = $(if ($agent) { [string]$agent.Status } else { 'absent' })
                ArbVms     = $vms
                LastLog    = $(if ($log) { '{0} @ {1}' -f $log.Name, $log.LastWriteTime.ToString('HH:mm:ss') } else { 'none' })
                Failures   = $failures
            }
        }
    }
    finally {
        if ($session) { Remove-PSSession -Session $session }
    }
}

$reports = foreach ($nodeName in $nodeNames) {
    Get-NodeReport -NodeName $nodeName -Credential $localCredential -TailLines $LogTailLines
}

foreach ($report in $reports) {
    Write-Information "" -InformationAction Continue
    Write-Information "=== $($report.Node) ===" -InformationAction Continue
    if (-not $report.Reachable) {
        Write-Information "  unreachable: $($report.Detail)" -InformationAction Continue
        continue
    }

    Write-Information "  cloud agent : $($report.CloudAgent)" -InformationAction Continue
    Write-Information "  vms         : $(if ($report.ArbVms.Count) { $report.ArbVms -join ', ' } else { '(none yet)' })" -InformationAction Continue
    Write-Information "  latest log  : $($report.LastLog)" -InformationAction Continue

    if ($report.Failures.Count -gt 0) {
        Write-Information "  real errors :" -InformationAction Continue
        foreach ($failure in $report.Failures) {
            $trimmed = if ($failure.Length -gt 300) { $failure.Substring(0, 300) + '...' } else { $failure }
            Write-Information "    $trimmed" -InformationAction Continue
        }
    }
    else {
        Write-Information "  real errors : none in the inspected tail" -InformationAction Continue
    }
}

Write-Information "" -InformationAction Continue
Write-Information "A Stopped cloud agent on one node is expected; it is a clustered single-instance role." -InformationAction Continue

$reports
